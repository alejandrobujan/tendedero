import AppKit
import SwiftUI

/// Route rope hits to an AppKit responder instead of SwiftUI's empty background.
/// An inactive panel receives activeAlways mouse tracking, but AppKit explicitly
/// does not deliver cursorUpdate for that scope.
final class RopeHostingView: NSHostingView<LineView> {
    weak var ropePull: RopePull?
    private var ropeTracking: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let window {
            let local = convert(point, from: superview)
            let screen = window.convertPoint(toScreen: convert(local, to: nil))
            if ropePull?.canGrab(at: screen) == true { return self }
        }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ropeTracking { removeTrackingArea(ropeTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.inVisibleRect, .activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self)
        addTrackingArea(tracking)
        ropeTracking = tracking
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let window, let ropePull, !ropePull.isActive else { return }
        for x in stride(from: CGFloat(12), to: bounds.width - 12, by: 6) {
            let y = Layout.ropeY(x: x, width: bounds.width)
            let screen = window.convertPoint(toScreen: CGPoint(x: x, y: bounds.height - y))
            guard ropePull.canGrab(at: screen) else { continue }
            addCursorRect(CGRect(x: x - 3, y: isFlipped ? y - 9 : bounds.height - y - 9,
                                 width: 6, height: 18), cursor: .openHand)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if !updateRopeCursor(with: event) { super.cursorUpdate(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        if !updateRopeCursor(with: event) { super.mouseMoved(with: event) }
    }

    override func mouseEntered(with event: NSEvent) {
        if !updateRopeCursor(with: event) { super.mouseEntered(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        (window as? LinePanel)?.updateRopeCursor(at: NSEvent.mouseLocation)
        super.mouseExited(with: event)
    }

    private func updateRopeCursor(with event: NSEvent) -> Bool {
        guard let panel = window as? LinePanel else { return false }
        return panel.updateRopeCursor(at: panel.convertPoint(toScreen: event.locationInWindow))
    }
}

/// A transparent strip along the top of the screen that floats over every
/// app and every Space except full screen ones. It leaves the front app active
/// and lets clicks pass through everywhere except photos and the grabbable rope.
final class LinePanel: NSPanel {
    weak var ropePull: RopePull?
    private let ropeCursor = RopeCursor()
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
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        contentView = content
    }

    /// Two-finger swipes and the scroll wheel, for moving along a long line.
    var onScroll: ((NSEvent) -> Void)?

    @discardableResult
    func updateRopeCursor(at screenPoint: CGPoint) -> Bool {
        let dragging = isVisible && ropePull?.isDragging == true
        let hovering = isVisible && !ignoresMouseEvents && ropePull?.canGrab(at: screenPoint) == true
        if dragging || hovering {
            ropeCursor.set(dragging ? .closedHand : .openHand)
            return true
        }
        resetRopeCursor()
        return false
    }

    func resetRopeCursor() { ropeCursor.reset() }

    override func orderOut(_ sender: Any?) {
        resetRopeCursor()
        super.orderOut(sender)
    }

    override func sendEvent(_ event: NSEvent) {
        let screenPoint = convertPoint(toScreen: event.locationInWindow)
        if event.type == .mouseMoved {
            // Handle even when a SwiftUI child would otherwise consume the event.
            super.sendEvent(event)
            updateRopeCursor(at: screenPoint)
            return
        }
        if let ropePull {
            if event.type == .leftMouseDown, ropePull.begin(at: screenPoint) { return }
            if ropePull.isDragging {
                switch event.type {
                case .leftMouseDragged: ropePull.drag(to: screenPoint); return
                case .leftMouseUp:
                    ropePull.drag(to: screenPoint)
                    ropePull.release()
                    return
                case .keyDown where event.keyCode == 53: ropePull.release(cancelled: true); return
                default: break
                }
            }
            if ropePull.isActive, [.scrollWheel, .leftMouseDown, .rightMouseDown].contains(event.type) { return }
        }
        if event.type == .scrollWheel, let onScroll {
            onScroll(event)
        } else {
            super.sendEvent(event)
        }
    }

    override var canBecomeKey: Bool { ropePull?.isDragging == true }
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
