import AppKit
import SwiftUI

/// Marks native controls whose real NSView bounds participate in panel hit testing.
/// Unlike SwiftUI preference geometry, these remain available in a non-key panel.
protocol FloatingLineControl: AnyObject {}

struct ClearLineButton: NSViewRepresentable {
    @ObservedObject var line: Line

    func makeNSView(context: Context) -> ClearLineNativeButton {
        let button = ClearLineNativeButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.contentTintColor = .systemRed
        button.setAccessibilityIdentifier("clear-all")
        button.target = button
        button.action = #selector(ClearLineNativeButton.clearLine)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: ClearLineNativeButton, context: Context) {
        button.line = line
        button.title = L("Take everything down")
        button.toolTip = L("Take everything down")
        button.setAccessibilityLabel(button.title)
        button.isEnabled = line.canClear
    }
}

final class ClearLineNativeButton: NSButton, FloatingLineControl {
    weak var line: Line?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }

    @objc func clearLine() { line?.clear() }

    override func mouseDown(with event: NSEvent) {
        line?.controlPressed = true
        defer { line?.controlPressed = false }
        super.mouseDown(with: event)
    }
}

struct RopePullArea: NSViewRepresentable {
    @ObservedObject var line: Line

    func makeNSView(context: Context) -> RopePullControl {
        let view = RopePullControl()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityIdentifier("pull-to-clear")
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: RopePullControl, context: Context) {
        view.line = line
        view.armed = line.pullArmed
        view.enabled = line.canClear
        view.setAccessibilityEnabled(line.canClear)
        view.toolTip = L("Pull down and release to clear all")
        view.setAccessibilityLabel(L("Take everything down"))
        view.setAccessibilityHelp(view.toolTip)
        view.needsDisplay = true
    }

    static func dismantleNSView(_ view: RopePullControl, coordinator: ()) {
        view.line?.cancelPull()
    }
}

/// A 64 pt target around a 44 pt accent ring. Window-relative drag origins
/// keep the pull stable as SwiftUI moves the ring underneath the pointer.
final class RopePullControl: NSView, FloatingLineControl {
    weak var line: Line?
    var armed = false
    var enabled = true
    private var startY: CGFloat?
    private var hovering = false
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        if enabled { addCursorRect(bounds, cursor: line?.isPulling == true ? .closedHand : .openHand) }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard enabled, line?.beginPull() == true else { return }
        startY = event.locationInWindow.y
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startY else { return }
        line?.updatePull(distance: startY - event.locationInWindow.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard startY != nil else { return }
        mouseDragged(with: event)
        startY = nil
        NSCursor.pop()
        line?.endPull()
    }

    override func cancelOperation(_ sender: Any?) {
        if startY != nil { NSCursor.pop() }
        startY = nil
        line?.cancelPull()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelOperation(nil) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func accessibilityPerformPress() -> Bool {
        guard line?.canClear == true else { return false }
        line?.clear()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let ringRect = bounds.insetBy(dx: 10, dy: 10)
        let ring = NSBezierPath(ovalIn: ringRect)
        let accent = NSColor.controlAccentColor.withAlphaComponent(enabled ? 1 : 0.35)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = hovering ? 8 : 5
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(ovalIn: ringRect.insetBy(dx: -3, dy: -3)).fill()
        NSGraphicsContext.restoreGraphicsState()
        if hovering || line?.isPulling == true {
            accent.withAlphaComponent(armed ? 0.20 : 0.05).setFill()
            ring.fill()
        }
        NSColor.controlBackgroundColor.setStroke()
        ring.lineWidth = 8
        ring.stroke()
        accent.setStroke()
        ring.lineWidth = armed ? 5.5 : 1.5
        ring.stroke()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let arrow = NSBezierPath()
        arrow.move(to: CGPoint(x: center.x - 7, y: center.y - 3))
        arrow.line(to: CGPoint(x: center.x, y: center.y + 4))
        arrow.line(to: CGPoint(x: center.x + 7, y: center.y - 3))
        arrow.lineWidth = armed ? 3 : 2
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        accent.setStroke()
        arrow.stroke()
        let glint = NSBezierPath()
        glint.move(to: CGPoint(x: center.x - 18, y: center.y - 7))
        glint.curve(to: CGPoint(x: center.x - 7, y: center.y - 18),
            controlPoint1: CGPoint(x: center.x - 16, y: center.y - 13),
            controlPoint2: CGPoint(x: center.x - 13, y: center.y - 16))
        NSColor.white.withAlphaComponent(0.75).setStroke()
        glint.lineWidth = 1
        glint.stroke()
    }
}
