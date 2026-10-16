import AppKit

/// A photo pinned over everything, to keep looking at while you work: a
/// design to copy, numbers to type in, steps to follow. It floats above
/// every app and every Space, just below the line.
///
/// It opens where the screenshot was taken, at its real size. Drag it
/// anywhere, click it and pinch to zoom, double click or Escape to close.
/// It holds its own copy of the image, so the photo can leave the line
/// and the pin stays.
@MainActor
final class Pin: NSObject, NSWindowDelegate {
    private static var open: [Pin] = []

    private let panel: PinPanel
    private let view: PinView
    private let natural: NSSize

    static func show(_ url: URL) {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return }
        open.append(Pin(image: image, at: captureRect(of: url)))
    }

    private init(image: NSImage, at captured: CGRect?) {
        natural = image.size
        view = PinView(image: image)
        panel = PinPanel(content: view)
        super.init()
        panel.delegate = self
        view.onClose = { [weak self] in self?.close() }
        view.onZoom = { [weak self] factor, anchor in self?.zoom(by: factor, around: anchor) }
        view.onActualSize = { [weak self] in self?.actualSize() }
        panel.setFrame(startFrame(captured), display: false)
        panel.orderFrontRegardless()
    }

    /// Where it was taken when that is still on a screen, otherwise in the
    /// middle of the screen with the pointer. Never bigger than most of it.
    private func startFrame(_ captured: CGRect?) -> NSRect {
        if let captured, let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(captured) }) {
            return fitted(captured, in: screen.visibleFrame)
        }
        let screen = LinePanel.screenUnderPointer() ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        // Each new pin a little lower and to the right, so none hides another.
        let step = CGFloat(Self.open.count % 8) * 24
        let frame = NSRect(x: area.midX - natural.width / 2 + step, y: area.midY - natural.height / 2 - step,
                           width: natural.width, height: natural.height)
        return fitted(frame, in: area)
    }

    private func fitted(_ frame: NSRect, in area: NSRect) -> NSRect {
        let scale = min(1, area.width * 0.8 / frame.width, area.height * 0.8 / frame.height)
        let w = frame.width * scale, h = frame.height * scale
        let x = min(max(frame.midX - w / 2, area.minX), area.maxX - w)
        let y = min(max(frame.midY - h / 2, area.minY), area.maxY - h)
        return NSRect(x: x, y: y, width: w, height: h)
    }

    /// Zooms keeping the point under the pointer where it is.
    private func zoom(by factor: CGFloat, around anchor: NSPoint) {
        let frame = panel.frame
        let scale = min(max(frame.width * factor / natural.width, 0.1), 4)
        let w = natural.width * scale, h = natural.height * scale
        guard w >= 40, h >= 40 else { return }
        let fx = (anchor.x - frame.minX) / frame.width, fy = (anchor.y - frame.minY) / frame.height
        panel.setFrame(NSRect(x: anchor.x - w * fx, y: anchor.y - h * fy, width: w, height: h), display: true)
    }

    private func actualSize() {
        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.midX - natural.width / 2, y: frame.midY - natural.height / 2,
                              width: natural.width, height: natural.height), display: true)
    }

    private func close() {
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}

/// Floats over every app and Space, under the line so it never covers it.
/// It takes the keyboard only when clicked, for pinching, Escape and ⌘C.
private final class PinPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class PinView: NSView {
    var onClose: () -> Void = {}
    var onZoom: (CGFloat, NSPoint) -> Void = { _, _ in }
    var onActualSize: () -> Void = {}

    private let image: NSImage
    private let closeButton = NSButton()

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.2).cgColor

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("Close"))
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        closeButton.wantsLayer = true
        closeButton.layer?.shadowOpacity = 0.6
        closeButton.layer?.shadowRadius = 2
        closeButton.layer?.shadowOffset = .zero
        addSubview(closeButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: 6, y: bounds.height - 26, width: 20, height: 20)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // The cross shows while the pointer is over the pin, like on the line.
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onClose()
            return
        }
        // macOS only sends a pinch to the app in front, so a click on a pin
        // brings it there. Until then the pin leaves your app alone.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        window?.performDrag(with: event)
    }

    override func magnify(with event: NSEvent) {
        guard let window else { return }
        onZoom(1 + event.magnification, NSEvent.mouseLocation.clamped(to: window.frame))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onClose()
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            copyImage()
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            onClose()
        } else {
            super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(L("Copy")) { [weak self] in self?.copyImage() })
        menu.addItem(ClosureMenuItem(L("Actual Size")) { [weak self] in self?.onActualSize() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Close")) { [weak self] in self?.onClose() })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func closeClicked() { onClose() }

    /// PNG, like a click on the line copies.
    private func copyImage() {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
    }
}

private extension NSPoint {
    func clamped(to rect: NSRect) -> NSPoint {
        NSPoint(x: min(max(x, rect.minX), rect.maxX), y: min(max(y, rect.minY), rect.maxY))
    }
}
