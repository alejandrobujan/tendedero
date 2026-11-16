import AppKit
import Carbon

/// A photo taken off the line to keep in front of you while you work: a
/// design to copy, numbers to type in, steps to follow. It is the photo
/// itself, not a copy: its clip waits empty on the line, and Hang back, or
/// Escape, sends it home.
///
/// It opens in the middle of the screen you are on, framed like a card.
/// Drag it anywhere; stretch it from an edge or a corner, or pinch or scroll
/// over it to zoom. Several can be held at
/// once. It never takes the app you are working in out of the front.
/// A pinned preview uses the same window and keeps its card on the line.
@MainActor
final class Held: NSObject {
    private static var open: [UUID: Held] = [:]
    private static var previews: [UUID: Held] = [:]
    private static var previewMouseTimer: Timer?
    private static var previewEscape: HotKey?
    private static var pointerOverPreview = false

    let id: UUID
    private let panel: HeldPanel
    private let view: HeldView
    /// Its size at 100%, in points.
    private let natural: NSSize
    /// Called with where it was on screen, to fly back to its clip from there.
    private let onHangBack: ((UUID, CGRect) -> Void)?

    static var heldIDs: Set<UUID> { Set(open.keys) }

    static func show(_ id: UUID, url: URL, line: Line, onHangBack: @escaping (UUID, CGRect) -> Void) {
        guard open[id] == nil else { return }
        open[id] = make(id, url: url, line: line, onHangBack: onHangBack)
    }

    /// A separate preview leaves the original card on the line.
    static func showPreview(_ id: UUID, url: URL, line: Line) {
        if let preview = previews[id] {
            preview.panel.orderFrontRegardless()
            return
        }
        guard let preview = make(id, url: url, line: line, onHangBack: nil) else { return }
        previews[id] = preview
        if previewMouseTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
                MainActor.assumeIsolated { updatePreviewEscape() }
            }
            RunLoop.main.add(timer, forMode: .common)
            previewMouseTimer = timer
        }
        updatePreviewEscape()
    }

    /// Borrow Escape only over the frontmost preview, without making it key.
    private static func previewUnderPointer() -> Held? {
        let mouse = NSEvent.mouseLocation
        let candidates = previews.values.filter { $0.panel.isVisible && $0.panel.frame.contains(mouse) }
        guard !candidates.isEmpty else { return nil }
        let number = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)
        return candidates.first { $0.panel.windowNumber == number }
    }

    private static func updatePreviewEscape() {
        let overPreview = previewUnderPointer() != nil
        guard overPreview != pointerOverPreview else { return }
        pointerOverPreview = overPreview
        if overPreview {
            previewEscape = HotKey(Shortcut(keyCode: kVK_Escape, modifiers: [], key: "\u{1b}")) {
                previewUnderPointer()?.dismiss()
            }
        } else {
            previewEscape = nil
        }
    }

    private static func make(_ id: UUID, url: URL, line: Line,
                             onHangBack: ((UUID, CGRect) -> Void)?) -> Held? {
        guard let screen = LinePanel.screenUnderPointer() else { return nil }
        // No sharper than the screen can show, so a huge image stays light.
        let longest = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
        guard let image = makeThumbnail(url, maxPixels: Int(longest)),
              image.size.width > 0, image.size.height > 0 else { return nil }
        return Held(id: id, image: image, on: screen, line: line, onHangBack: onHangBack)
    }

    static func hangBack(_ id: UUID) { open[id]?.dismiss() }

    static func hangEverythingBack() {
        for held in open.values { held.dismiss() }
    }

    /// Its photo left the line some other way: the file moved, for example.
    static func forget(except live: Set<UUID>) {
        for (id, held) in open where !live.contains(id) {
            held.panel.close()
            open[id] = nil
        }
    }

    private init(id: UUID, image: NSImage, on screen: NSScreen, line: Line,
                 onHangBack: ((UUID, CGRect) -> Void)?) {
        self.id = id
        self.onHangBack = onHangBack
        let scale = screen.backingScaleFactor
        natural = NSSize(width: image.size.width / scale + HeldView.border * 2,
                         height: image.size.height / scale + HeldView.border * 2)
        let isPreview = onHangBack == nil
        view = HeldView(image: image, isPreview: isPreview)
        panel = HeldPanel(content: view, takesKeyboard: !isPreview)
        super.init()
        view.onDismiss = { [weak self] in self?.dismiss() }
        view.onZoom = { [weak self] factor, anchor in self?.zoom(by: factor, around: anchor) }
        if !isPreview {
            view.onActualSize = { [weak self] in self?.actualSize() }
            view.onCopy = { line.copy(id) }
            view.onMarkup = { line.markup(id) }
            view.onQuickLook = { line.quickLook(id) }
            // Stretched from an edge or a corner, it keeps the photo's shape.
            panel.contentAspectRatio = natural
            panel.minSize = NSSize(width: 80, height: 80)
        }
        panel.setFrame(startFrame(on: screen), display: false)
        panel.orderFrontRegardless()
    }

    /// In the middle of the screen, each new one a little lower and to the
    /// right so none hides another. Never bigger than most of the screen.
    private func startFrame(on screen: NSScreen) -> NSRect {
        let area = screen.visibleFrame
        let fit = min(1, area.width * 0.7 / natural.width, area.height * 0.7 / natural.height)
        let isPreview = onHangBack == nil
        let minimum: CGFloat = isPreview ? Self.previewMinimumSide : 0
        let w = max(minimum, natural.width * fit), h = max(minimum, natural.height * fit)
        let count = isPreview ? Self.previews.count : Self.open.count
        let step = CGFloat(count % 8) * 24
        let frame = NSRect(x: area.midX - w / 2 + step, y: area.midY - h / 2 - step, width: w, height: h)
        return isPreview ? frame.fittingOrigin(in: area) : frame
    }

    /// Leaves room for the close button even on a very narrow screenshot.
    private static let previewMinimumSide: CGFloat = 38

    /// Zooms keeping the point under the pointer where it is.
    private func zoom(by factor: CGFloat, around anchor: NSPoint) {
        let frame = panel.frame
        let bounds = onHangBack == nil ? panel.screen?.visibleFrame : nil
        let size: NSSize
        if let bounds {
            let longest = max(natural.width, natural.height)
            let largest = min(bounds.width / natural.width, bounds.height / natural.height)
            let smallest = min(largest, 1, 100 / longest)
            let proposed = max(frame.width, frame.height) * factor / longest
            let scale = min(max(proposed, smallest), largest)
            size = NSSize(width: max(Self.previewMinimumSide, natural.width * scale),
                          height: max(Self.previewMinimumSide, natural.height * scale))
        } else {
            let scale = min(max(frame.width * factor / natural.width, 0.1), 4)
            size = NSSize(width: natural.width * scale, height: natural.height * scale)
            guard size.width >= 60, size.height >= 60 else { return }
        }
        let fx = (anchor.x - frame.minX) / frame.width, fy = (anchor.y - frame.minY) / frame.height
        let target = NSRect(x: anchor.x - size.width * fx, y: anchor.y - size.height * fy,
                            width: size.width, height: size.height)
        panel.setFrame(bounds.map { target.fittingOrigin(in: $0) } ?? target, display: true)
    }

    private func actualSize() {
        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.midX - natural.width / 2, y: frame.midY - natural.height / 2,
                              width: natural.width, height: natural.height), display: true)
    }

    private func dismiss() {
        let frame = panel.frame
        panel.close()
        if let onHangBack {
            Self.open[id] = nil
            onHangBack(id, frame)
        } else {
            Self.previews[id] = nil
            if Self.previews.isEmpty {
                Self.previewMouseTimer?.invalidate()
                Self.previewMouseTimer = nil
                Self.previewEscape = nil
                Self.pointerOverPreview = false
            } else {
                Self.updatePreviewEscape()
            }
        }
    }
}

/// Floats over every app and Space, under the line so it never covers it.
/// Held photos take Escape and ⌘C. Pinned previews leave the keyboard
/// with the app you are working in.
private final class HeldPanel: NSPanel {
    private let takesKeyboard: Bool

    init(content: NSView, takesKeyboard: Bool) {
        self.takesKeyboard = takesKeyboard
        // Resizable from its edges and corners, like any window.
        let style: NSWindow.StyleMask = takesKeyboard
            ? [.borderless, .nonactivatingPanel, .resizable] : [.borderless, .nonactivatingPanel]
        super.init(contentRect: .zero, styleMask: style,
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = !takesKeyboard
        contentView = content
    }

    override var canBecomeKey: Bool { takesKeyboard }
    override var canBecomeMain: Bool { false }
}

/// The photo in a glass frame like the cards on the line. Its only control
/// is the button in the corner, which hangs it back, shown on hover like the
/// cards' own; everything else is in its menu.
private final class HeldView: NSVisualEffectView {
    static let border: CGFloat = 6

    var onDismiss: () -> Void = {}
    var onZoom: (CGFloat, NSPoint) -> Void = { _, _ in }
    var onActualSize: () -> Void = {}
    var onCopy: () -> Void = {}
    var onMarkup: () -> Void = {}
    var onQuickLook: () -> Void = {}

    private let photo = CALayer()
    private let dismissButton: CornerButton
    private let isPreview: Bool

    init(image: NSImage, isPreview: Bool) {
        self.isPreview = isPreview
        dismissButton = CornerButton(symbol: isPreview ? "xmark" : "arrow.up.to.line")
        super.init(frame: .zero)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
        photo.contents = image
        photo.contentsGravity = .resizeAspect
        photo.cornerRadius = 7
        photo.masksToBounds = true
        layer?.addSublayer(photo)
        dismissButton.alphaValue = isPreview ? 1 : 0
        dismissButton.onPress = { [weak self] in self?.onDismiss() }
        dismissButton.setAccessibilityLabel(isPreview ? L("Close preview") : L("Hang back"))
        addSubview(dismissButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photo.frame = bounds.insetBy(dx: Self.border, dy: Self.border)
        photo.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        dismissButton.frame = NSRect(x: 9, y: bounds.height - 29, width: 20, height: 20)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { showButton(true) }
    override func mouseExited(with event: NSEvent) { showButton(false) }

    private func showButton(_ on: Bool) {
        guard !isPreview else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            dismissButton.animator().alphaValue = on ? 1 : 0
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if !isPreview {
            window?.makeKey()
            window?.makeFirstResponder(self)
        }
        window?.performDrag(with: event)
    }

    override func magnify(with event: NSEvent) {
        guard let window else { return }
        onZoom(1 + event.magnification, NSEvent.mouseLocation.clamped(to: window.frame))
    }

    /// A mouse wheel zooms too: there is nothing to scroll in a photo.
    override func scrollWheel(with event: NSEvent) {
        guard let window, event.scrollingDeltaY != 0 else { return }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.005 : event.scrollingDeltaY * 0.05
        onZoom(1 + step, NSEvent.mouseLocation.clamped(to: window.frame))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onDismiss()
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            onCopy()
        } else {
            super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let title = isPreview ? L("Close preview") : L("Hang back")
        menu.addItem(ClosureMenuItem(title) { [weak self] in self?.onDismiss() })
        if isPreview {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Copy")) { [weak self] in self?.onCopy() })
        menu.addItem(ClosureMenuItem(L("Quick Look")) { [weak self] in self?.onQuickLook() })
        menu.addItem(ClosureMenuItem(L("Markup")) { [weak self] in self?.onMarkup() })
        menu.addItem(ClosureMenuItem(L("Actual Size")) { [weak self] in self?.onActualSize() })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// A small glass disc with a symbol, as on the line's cards.
private final class CornerButton: NSVisualEffectView {
    var onPress: () -> Void = {}

    init(symbol: String) {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 8, weight: .bold)
        icon.contentTintColor = .labelColor
        icon.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        icon.imageScaling = .scaleNone
        addSubview(icon)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// The whole disc takes the click, symbol included.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress() }
    }
}

private extension NSPoint {
    func clamped(to rect: NSRect) -> NSPoint {
        NSPoint(x: min(max(x, rect.minX), rect.maxX), y: min(max(y, rect.minY), rect.maxY))
    }
}

private extension NSRect {
    func fittingOrigin(in area: NSRect) -> NSRect {
        NSRect(x: min(max(minX, area.minX), area.maxX - width),
               y: min(max(minY, area.minY), area.maxY - height),
               width: width, height: height)
    }
}
