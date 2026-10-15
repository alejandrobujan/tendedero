import AppKit

/// A transparent strip along the top of the screen that floats over every
/// app and every Space except full screen ones, never takes focus, and lets clicks pass through
/// everywhere except over the photos.
final class LinePanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        // Every Space, full screen ones included. Whether the line comes down
        // over a full screen app is up to the user, see FullScreen.showLineOver.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        contentView = content
    }

    /// Two-finger swipes and the scroll wheel, for moving along a long line.
    var onScroll: ((NSEvent) -> Void)?
    private weak var pulledControl: RopePullControl?

    func cancelControlInteraction() {
        pulledControl?.cancelOperation(nil)
        pulledControl = nil
    }

    /// Use actual AppKit view coordinates, independent of SwiftUI preference delivery.
    func control(atScreenPoint point: NSPoint) -> NSView? {
        guard let contentView else { return nil }
        let windowPoint = convertPoint(fromScreen: point)
        let contentPoint = contentView.convert(windowPoint, from: nil)
        guard contentView.bounds.contains(contentPoint) else { return nil }
        func find(in view: NSView) -> NSView? {
            guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0.01 else { return nil }
            if view is FloatingLineControl,
               view.bounds.intersection(view.visibleRect).contains(view.convert(windowPoint, from: nil)) { return view }
            for child in view.subviews.reversed() {
                if let control = find(in: child) { return control }
            }
            return nil
        }
        return find(in: contentView)
    }

    override func sendEvent(_ event: NSEvent) {
        // Forward native controls explicitly: this panel never becomes key,
        // and must not depend on SwiftUI's focus or first-click behavior.
        if event.type == .leftMouseDown,
           let control = control(atScreenPoint: convertPoint(toScreen: event.locationInWindow)) {
            pulledControl = control as? RopePullControl
            control.mouseDown(with: event)
            return
        }
        if event.type == .leftMouseDragged, let pulledControl {
            pulledControl.mouseDragged(with: event)
            return
        }
        if event.type == .leftMouseUp, let control = pulledControl {
            pulledControl = nil
            control.mouseUp(with: event)
            return
        }
        if event.type == .scrollWheel, let onScroll {
            onScroll(event)
        } else {
            super.sendEvent(event)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The line hangs on the screen you are using, which is the one with the
    /// pointer: that is where you just took the screenshot.
    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    func placeOnScreen(_ screen: NSScreen? = nil) {
        guard let visible = (screen ?? LinePanel.screenUnderPointer())?.visibleFrame else { return }
        let target = NSRect(x: visible.minX, y: visible.maxY - Layout.panelHeight,
                            width: visible.width, height: Layout.panelHeight)
        if frame != target { setFrame(target, display: true) }
    }
}
