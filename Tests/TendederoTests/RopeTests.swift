import AppKit
import Testing
@testable import Tendedero

@Suite("Rope geometry")
struct RopeGeometryTests {
    @Test func endpointsStayAnchoredWhilePulling() {
        var rope = RopeMotion(width: 1440, grabX: 410)
        let left = rope.point(at: 0), right = rope.point(at: 1)
        rope.drag(by: CGSize(width: 110, height: 160))
        #expect(rope.point(at: 0) == left)
        #expect(rope.point(at: 1) == right)
        #expect(rope.point(at: rope.grab).y > 100)
        #expect(rope.isArmed)
    }

    @Test func pullingBackDisarmsTheGesture() {
        var rope = RopeMotion(width: 1440, grabX: 800)
        rope.drag(by: CGSize(width: 0, height: 150))
        #expect(rope.isArmed)
        #expect(rope.fray > 0)
        rope.drag(by: CGSize(width: 0, height: 25))
        #expect(!rope.isArmed)
        #expect(rope.fray == 0)
        rope.drag(by: CGSize(width: 0, height: -40))
        #expect(rope.pull == 0)
    }

    @Test func breakStartsAtTheGrabbedPositionAndOpensToBothSides() {
        var rope = RopeMotion(width: 1920, grabX: 530)
        rope.drag(by: CGSize(width: 45, height: 145))
        let grip = rope.point(at: rope.grab)
        #expect(rope.brokenPoint(at: 0.15, left: true, time: 0) == rope.point(at: 0.15))
        #expect(rope.brokenPoint(at: 0.85, left: false, time: 0) == rope.point(at: 0.85))
        #expect(rope.brokenPoint(at: rope.grab, left: true, time: 0) == grip)
        #expect(rope.brokenPoint(at: rope.grab, left: false, time: 0) == grip)
        #expect(rope.brokenPoint(at: rope.grab, left: true, time: 0.3).x < grip.x)
        #expect(rope.brokenPoint(at: rope.grab, left: false, time: 0.3).x > grip.x)
        let edge = RopeMotion(width: 1920, grabX: 20)
        #expect(abs(edge.point(at: edge.grab).x - 20) < 0.001)
    }

    @Test func photosSlideTowardBreakBeforeFalling() {
        var rope = RopeMotion(width: 1440, grabX: 700)
        rope.drag(by: CGSize(width: 0, height: 150))
        for u: CGFloat in [0.1, 0.35, 0.7, 0.9] {
            let slide = rope.slide(at: u, rank: 0)
            let start = rope.position(of: slide, time: 0).point
            let halfway = rope.position(of: slide, time: slide.duration / 2).point
            #expect(u < rope.grab ? halfway.x > start.x : halfway.x < start.x)
            #expect(halfway.y > start.y)
            #expect(rope.position(of: slide, time: 3).point.y > 1600)
            let before = rope.position(of: slide, time: slide.duration - 0.0001).point
            let after = rope.position(of: slide, time: slide.duration + 0.0001).point
            #expect(hypot(after.x - before.x, after.y - before.y) < 1)
        }
    }
}

@Suite("Batch clear", .serialized)
@MainActor
struct BatchClearTests {
    private func fixture() throws -> (URL, UserDefaults, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Tendedero-rope-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "app.tendedero.Tendedero.tests.\(UUID().uuidString)"
        return (dir, try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func image(_ dir: URL, _ name: String) throws -> URL {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = dir.appendingPathComponent(name + ".png")
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    @Test func clearsOnlyTheSnapshotAndPreservesExternalFiles() throws {
        let (dir, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        let line = Line(defaults: defaults, inboxFolder: dir.appendingPathComponent("inbox"))
        let firstURL = try image(dir, "before"), laterURL = try image(dir, "after")
        let first = try #require(line.hang(firstURL, quietly: true))
        let snapshot: Set<UUID> = [first]
        let later = try #require(line.hang(laterURL, quietly: true))
        var falls = 0
        line.onFall = { _ in falls += 1 }
        #expect(line.discardForRope(snapshot) == snapshot)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(line.items.contains { $0.id == later && !$0.falling })
        #expect(defaults.stringArray(forKey: "pegged") == [laterURL.path])
        #expect(falls == 0)
    }

    @Test func trashFailuresRemainVisibleAndPersisted() throws {
        let (dir, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        let badURL = try image(dir, "failure"), goodURL = try image(dir, "success")
        var attempts: [URL] = []
        let line = Line(defaults: defaults, inboxFolder: dir) { url in
            attempts.append(url)
            if url == badURL { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        }
        let bad = try #require(line.hang(badURL, quietly: true))
        let good = try #require(line.hang(goodURL, quietly: true))
        #expect(line.discardForRope([bad, good]) == [good])
        #expect(line.items.contains { $0.id == bad && !$0.falling })
        #expect(defaults.stringArray(forKey: "pegged") == [badURL.path])
        #expect(attempts.count == 2)
        #expect(FileManager.default.fileExists(atPath: badURL.path))
    }

    @Test func includesOffscreenItemsAndDoesNotRepeatSuccessfulDeletes() throws {
        let (dir, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        var calls = 0
        let line = Line(defaults: defaults, inboxFolder: dir) { _ in calls += 1 }
        line.maxItems = 100
        line.visibleCount = 3
        for i in 0..<12 { line.hang(try image(dir, "\(i)"), quietly: true) }
        let ids = Set(line.items.map(\.id))
        #expect(line.discardForRope(ids).count == 12)
        #expect(line.liveCount == 0)
        #expect(line.discardForRope(ids).isEmpty)
        #expect(calls == 12)
    }

    @Test func nativePanelRoutesDragReleaseAndEscape() throws {
        _ = NSApplication.shared
        let (dir, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        let line = Line(defaults: defaults, inboxFolder: dir.appendingPathComponent("inbox"))
        line.hang(try image(dir, "sample"), quietly: true)
        line.revealed = true
        let panel = LinePanel(content: NSView())
        panel.placeOnScreen(try #require(NSScreen.screens.first))
        panel.orderFrontRegardless()
        let pull = RopePull(line: line, panel: panel)
        panel.ropePull = pull
        defer { pull.interrupt(); panel.orderOut(nil) }
        let x = panel.frame.width * 0.25
        let start = CGPoint(x: panel.frame.minX + x,
                            y: panel.frame.maxY - Layout.ropeY(x: x, width: panel.frame.width))
        func mouse(_ type: NSEvent.EventType, down: CGFloat = 0) throws {
            let location = panel.convertPoint(fromScreen: CGPoint(x: start.x, y: start.y - down))
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            panel.sendEvent(event)
        }

        try mouse(.leftMouseDown)
        #expect(pull.isDragging && line.ropeInteractionActive)
        try mouse(.leftMouseDragged, down: 40)
        try mouse(.leftMouseUp, down: 40)
        #expect(pull.phase == .returning && line.liveCount == 1)
        pull.interrupt()
        #expect(!pull.isActive && !line.ropeInteractionActive)

        try mouse(.leftMouseDown)
        try mouse(.leftMouseDragged, down: 150)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        panel.sendEvent(escape)
        #expect(pull.phase == .returning && line.liveCount == 1)
        pull.interrupt()

        try mouse(.leftMouseDown)
        try mouse(.leftMouseDragged, down: 150)
        try mouse(.leftMouseDragged, down: 20)
        try mouse(.leftMouseUp, down: 20)
        #expect(pull.phase == .returning && line.liveCount == 1)
        pull.interrupt()

        try mouse(.leftMouseDown)
        try mouse(.leftMouseDragged, down: 400)
        #expect(line.liveCount == 1)
        let drawing = try #require(NSApp.windows.compactMap { $0.contentView as? RopeDrawing }.first)
        let bitmap = try #require(drawing.bitmapImageRepForCachingDisplay(in: drawing.bounds))
        drawing.cacheDisplay(in: drawing.bounds, to: bitmap)
        try mouse(.leftMouseUp, down: 400)
        #expect(pull.phase == .breaking && line.liveCount == 0)
        #expect(defaults.stringArray(forKey: "pegged") == [])
        for time in [0.0, 0.5, 1.5, 2.5] {
            drawing.time = time
            drawing.cacheDisplay(in: drawing.bounds, to: bitmap)
        }
    }

    @Test func ropeHoverRoutesToNativeViewWithoutTakingKeyFocus() throws {
        _ = NSApplication.shared
        let (dir, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        let line = Line(defaults: defaults, inboxFolder: dir.appendingPathComponent("inbox"))
        line.hang(try image(dir, "hover"), quietly: true)
        line.revealed = true
        let host = RopeHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        let panel = LinePanel(content: host)
        panel.placeOnScreen()
        let pull = RopePull(line: line, panel: panel)
        panel.ropePull = pull
        host.ropePull = pull
        panel.orderFrontRegardless()
        panel.ignoresMouseEvents = false
        defer { pull.interrupt(); panel.orderOut(nil); NSCursor.arrow.set() }
        host.updateTrackingAreas()
        #expect(panel.acceptsMouseMovedEvents)
        let tracking = try #require(host.trackingAreas.first { ($0.owner as? RopeHostingView) === host })
        #expect(tracking.options.contains(.activeAlways))
        #expect(tracking.options.contains(.mouseMoved))
        #expect(!tracking.options.contains(.cursorUpdate))
        let x = panel.frame.width * 0.25
        let location = CGPoint(x: x, y: panel.frame.height - Layout.ropeY(x: x, width: panel.frame.width))
        let local = host.superview!.convert(location, from: nil)
        #expect(host.hitTest(local) === host)
        let activeBeforeHover = NSApp.isActive
        let keyBeforeHover = NSApp.keyWindow

        func move(to location: CGPoint) throws {
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location,
                modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0))
            panel.sendEvent(event)
        }
        NSCursor.arrow.set()
        try move(to: location)
        #expect(NSCursor.current === NSCursor.openHand)
        #expect(NSApp.isActive == activeBeforeHover)
        #expect(NSApp.keyWindow === keyBeforeHover)
        try move(to: CGPoint(x: x, y: location.y - 70))
        #expect(NSCursor.current === NSCursor.arrow)

        // Receiving an old move after hide/click-through must not leave a hand.
        panel.ignoresMouseEvents = true
        try move(to: location)
        #expect(NSCursor.current === NSCursor.arrow)
        panel.ignoresMouseEvents = false
        try move(to: location)
        panel.orderOut(nil)
        #expect(NSCursor.current === NSCursor.arrow)
    }
}
