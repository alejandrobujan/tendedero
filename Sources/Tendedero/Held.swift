import AppKit

/// A photo taken off the line to keep in front of you while you work: a
/// design to copy, numbers to type in, steps to follow. It is the photo
/// itself, not a copy: its clip waits empty on the line, and Hang back, or
/// Escape, sends it home.
///
/// It opens in the middle of the screen you are on, framed like a card.
/// Drag it anywhere; stretch it from an edge or a corner, or pinch or scroll
/// over it to zoom. Several can be held at
/// once. It never takes the app you are working in out of the front.
@MainActor
final class Held: NSObject {
    private static var open: [UUID: Held] = [:]

    let id: UUID
    private let panel: HeldPanel
    private let view: HeldView
    /// Its size at 100%, in points.
    private let natural: NSSize
    /// Called with where it was on screen, to fly back to its clip from there.
    private let onHangBack: (UUID, CGRect) -> Void

    static var heldIDs: Set<UUID> { Set(open.keys) }

    static func show(_ id: UUID, url: URL, line: Line, onHangBack: @escaping (UUID, CGRect) -> Void) {
        guard open[id] == nil,
              let screen = LinePanel.screenUnderPointer() else { return }
        // No sharper than the screen can show, so a huge image stays light.
        let longest = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
        guard let image = makeThumbnail(url, maxPixels: Int(longest)), image.size.width > 0 else { return }
        open[id] = Held(id: id, url: url, image: image, on: screen, line: line, onHangBack: onHangBack)
    }

    static func hangBack(_ id: UUID) { open[id]?.hangBack() }

    static func hangEverythingBack() {
        for held in open.values { held.hangBack() }
    }

    /// Its photo left the line some other way: the file moved, for example.
    static func forget(except live: Set<UUID>) {
        for (id, held) in open where !live.contains(id) {
            held.panel.close()
            open[id] = nil
        }
    }

    private init(id: UUID, url: URL, image: NSImage, on screen: NSScreen, line: Line,
                 onHangBack: @escaping (UUID, CGRect) -> Void) {
        self.id = id
        self.onHangBack = onHangBack
        let scale = screen.backingScaleFactor
        natural = NSSize(width: image.size.width / scale + HeldView.border * 2,
                         height: image.size.height / scale + HeldView.border * 2)
        view = HeldView(image: image)
        panel = HeldPanel(content: view)
        super.init()
        view.onHangBack = { [weak self] in self?.hangBack() }
        view.onZoom = { [weak self] factor, anchor in self?.zoom(by: factor, around: anchor) }
        view.onActualSize = { [weak self] in self?.actualSize() }
        view.onCopy = { line.copy(id) }
        view.onMarkup = { line.markup(id) }
        view.onQuickLook = { line.quickLook(id) }
        // Stretched from an edge or a corner, it keeps the photo's shape.
        panel.contentAspectRatio = natural
        panel.minSize = NSSize(width: 80, height: 80)
        panel.setFrame(startFrame(on: screen), display: false)
        panel.orderFrontRegardless()
    }

    /// In the middle of the screen, each new one a little lower and to the
    /// right so none hides another. Never bigger than most of the screen.
    private func startFrame(on screen: NSScreen) -> NSRect {
        let area = screen.visibleFrame
        let fit = min(1, area.width * 0.7 / natural.width, area.height * 0.7 / natural.height)
        let w = natural.width * fit, h = natural.height * fit
        let step = CGFloat((Self.open.count) % 8) * 24
        return NSRect(x: area.midX - w / 2 + step, y: area.midY - h / 2 - step, width: w, height: h)
    }

    /// Zooms keeping the point under the pointer where it is.
    private func zoom(by factor: CGFloat, around anchor: NSPoint) {
        let frame = panel.frame
        let scale = min(max(frame.width * factor / natural.width, 0.1), 4)
        let w = natural.width * scale, h = natural.height * scale
        guard w >= 60, h >= 60 else { return }
        let fx = (anchor.x - frame.minX) / frame.width, fy = (anchor.y - frame.minY) / frame.height
        panel.setFrame(NSRect(x: anchor.x - w * fx, y: anchor.y - h * fy, width: w, height: h), display: true)
    }

    private func actualSize() {
        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.midX - natural.width / 2, y: frame.midY - natural.height / 2,
                              width: natural.width, height: natural.height), display: true)
    }

    private func hangBack() {
        let frame = panel.frame
        panel.close()
        Self.open[id] = nil
        onHangBack(id, frame)
    }
}

/// Floats over every app and Space, under the line so it never covers it.
/// A click makes it key without bringing Tendedero to the front, so the app
/// you work in stays active; it then takes Escape and ⌘C.
private final class HeldPanel: NSPanel {
    init(content: NSView) {
        // Resizable from its edges and corners, like any window.
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = false
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The photo in a glass frame like the cards on the line. Its only control
/// is the button in the corner, which hangs it back, shown on hover like the
/// cards' own; everything else is in its menu.
private final class HeldView: NSVisualEffectView {
    static let border: CGFloat = 6

    var onHangBack: () -> Void = {}
    var onZoom: (CGFloat, NSPoint) -> Void = { _, _ in }
    var onActualSize: () -> Void = {}
    var onCopy: () -> Void = {}
    var onMarkup: () -> Void = {}
    var onQuickLook: () -> Void = {}

    private let photo = CALayer()
    private let hangBackButton = CornerButton(symbol: "arrow.up.to.line")

    init(image: NSImage) {
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
        hangBackButton.alphaValue = 0
        hangBackButton.onPress = { [weak self] in self?.onHangBack() }
        hangBackButton.setAccessibilityLabel(L("Hang back"))
        addSubview(hangBackButton)
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
        hangBackButton.frame = NSRect(x: 9, y: bounds.height - 29, width: 20, height: 20)
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
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            hangBackButton.animator().alphaValue = on ? 1 : 0
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
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
            onHangBack()
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            onCopy()
        } else {
            super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(L("Hang back")) { [weak self] in self?.onHangBack() })
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
