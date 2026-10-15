import AppKit
import Testing
@testable import Tendedero

@Suite("Rope cursor ownership", .serialized)
@MainActor
struct RopeCursorTests {
    @Test func backgroundAccessIsLimitedToTheInteraction() {
        _ = NSApplication.shared
        var changes: [Bool] = []
        var cursorAtDisable: NSCursor?
        let cursor = RopeCursor { enabled in
            changes.append(enabled)
            if !enabled { cursorAtDisable = NSCursor.current }
            return true
        }
        cursor.reset()
        #expect(changes.isEmpty)
        cursor.set(.openHand)
        cursor.set(.closedHand)
        #expect(changes == [true])
        cursor.reset()
        cursor.reset()
        #expect(changes == [true, false])
        #expect(cursorAtDisable === NSCursor.arrow)
        cursor.set(.openHand)
        cursor.reset()
        #expect(changes == [true, false, true, false])
    }

    @Test func unavailableBackgroundAccessStillAllowsAppKitCursors() {
        _ = NSApplication.shared
        var changes: [Bool] = []
        let cursor = RopeCursor { changes.append($0); return false }
        cursor.set(.openHand)
        #expect(NSCursor.current === NSCursor.openHand)
        cursor.set(.closedHand)
        cursor.reset()
        #expect(changes == [true])
        #expect(NSCursor.current === NSCursor.arrow)
    }

    /// Opt-in WindowServer check. Places this test's rope beneath the existing
    /// pointer, then sends events only to the test panel. Never moves the mouse,
    /// activates another app, watches screenshots, or uses the user's images.
    /// Inspect the captured PNGs: NSCursor.current is not visual verification.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TENDEDERO_CURSOR_PROOF"] != nil))
    func captureSystemCursorOverNativeRope() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["TENDEDERO_CURSOR_PROOF"])
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        #expect(!NSApp.isActive)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let suite = "app.tendedero.Tendedero.cursor-proof.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let image = NSImage(size: NSSize(width: 80, height: 50))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 80, height: 50)).fill()
        image.unlockFocus()
        let sample = folder.appendingPathComponent("sample.tiff")
        try #require(image.tiffRepresentation).write(to: sample)
        let line = Line(defaults: defaults, inboxFolder: folder.appendingPathComponent("inbox"))
        line.hang(sample, quietly: true)
        line.revealed = true
        let host = RopeHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        let panel = LinePanel(content: host)
        let mouse = NSEvent.mouseLocation
        let x: CGFloat = 150, width: CGFloat = 600
        panel.setFrame(NSRect(x: mouse.x - x,
                              y: mouse.y + Layout.ropeY(x: x, width: width) - Layout.panelHeight,
                              width: width, height: Layout.panelHeight), display: true)
        let pull = RopePull(line: line, panel: panel)
        panel.ropePull = pull
        host.ropePull = pull
        panel.orderFrontRegardless()
        panel.ignoresMouseEvents = false
        defer { pull.interrupt(); panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(pull.canGrab(at: mouse))
        let keyBeforeHover = NSApp.keyWindow

        func event(_ type: NSEvent.EventType) throws {
            let event = try #require(NSEvent.mouseEvent(with: type,
                location: panel.convertPoint(fromScreen: mouse), modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                clickCount: 0, pressure: type == .leftMouseUp ? 0 : 1))
            panel.sendEvent(event)
        }

        func capture(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(250))
            try #require(NSEvent.mouseLocation == mouse, "Pointer moved during the visual check; rerun with it stationary")
            // A nonactivating panel may temporarily be key during the drag.
            // Hover must not activate; the frontmost app must never change.
            let active = NSApp.isActive
            print("\(name): active=\(active), dragging=\(pull.isDragging)")
            if !pull.isDragging { #expect(!active) }
            #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
            let height = try #require(NSScreen.screens.first).frame.maxY
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-C", "-R", "\(Int(mouse.x) - 50),\(Int(height - mouse.y) - 50),150,150",
                              output + "/" + name + ".png"]
            try task.run()
            task.waitUntilExit()
            #expect(task.terminationStatus == 0)
        }

        panel.resetRopeCursor()
        NSCursor.openHand.set() // Negative control: app cursor alone fails in background.
        try await capture("0-appkit-only")
        try event(.mouseMoved)
        #expect(NSApp.keyWindow === keyBeforeHover)
        try await capture("1-rope-hover")
        try event(.leftMouseDown)
        #expect(pull.isDragging)
        try await capture("2-rope-held")
        try event(.leftMouseUp)
        #expect(pull.phase == .returning)
        try await capture("3-release")
        pull.interrupt()
        try event(.mouseMoved)
        try await capture("4-hover-again")
        panel.ignoresMouseEvents = true
        panel.updateRopeCursor(at: mouse)
        try await capture("5-click-through")
        panel.ignoresMouseEvents = false
        try event(.mouseMoved)
        panel.orderOut(nil)
        try await capture("6-hidden")
        #expect(line.liveCount == 1)
        print("System cursor captures: \(output). Foreground PID stayed \(foreground ?? -1).")
    }
}
