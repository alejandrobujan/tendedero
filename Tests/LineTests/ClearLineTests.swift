import AppKit
import SwiftUI
import XCTest
@testable import Tendedero

final class ClearLineTests: XCTestCase {
    @MainActor
    private func withIsolatedLine(_ check: @MainActor (Line, URL) async throws -> Void) async throws {
        // XCTest uses its own preferences domain; never clear the installed app.
        XCTAssertNotEqual(Bundle.main.bundleIdentifier, AppIdentity.bundleIdentifier)
        let defaults = UserDefaults.standard
        let previousPaths = defaults.object(forKey: "pegged")
        let previousSound = defaults.object(forKey: "soundOff")
        defaults.set([], forKey: "pegged")
        defaults.set(true, forKey: "soundOff")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImageLineClearTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.set(previousPaths, forKey: "pegged")
            defaults.set(previousSound, forKey: "soundOff")
            try? FileManager.default.removeItem(at: folder)
        }
        let line = Line()
        line.maxItems = 100
        try await check(line, folder)
    }

    @MainActor
    private func image(at url: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<16 {
            for x in 0..<24 {
                bitmap.setColor(NSColor(srgbRed: 0.12 + Double(x) / 48,
                    green: 0.55 + Double(y) / 80, blue: 0.68, alpha: 1), atX: x, y: y)
            }
        }
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    @MainActor
    func testVisibleControlsHaveNativeWindowHitRegionsAndClearAction() async throws {
        try await withIsolatedLine { line, folder in
            _ = NSApplication.shared
            let url = folder.appendingPathComponent("button-test.png")
            try image(at: url)
            line.hang(url, quietly: true)
            line.revealed = true
            let host = NSHostingView(rootView: LineView(line: line))
            host.sizingOptions = []
            let panel = LinePanel(content: host)
            panel.placeOnScreen()
            panel.orderFrontRegardless()
            defer { panel.orderOut(nil) }
            try await Task.sleep(for: .seconds(0.3))
            let button = try XCTUnwrap(descendants(of: host).compactMap { $0 as? ClearLineNativeButton }.first)
            let ring = try XCTUnwrap(descendants(of: host).compactMap { $0 as? RopePullControl }.first)
            @MainActor func screenCenter(_ view: NSView) -> NSPoint {
                let windowPoint = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                return panel.convertPoint(toScreen: windowPoint)
            }
            let buttonPoint = screenCenter(button)
            XCTAssertTrue(panel.control(atScreenPoint: buttonPoint) === button)
            XCTAssertTrue(panel.control(atScreenPoint: screenCenter(ring)) === ring)
            XCTAssertTrue(button.acceptsFirstMouse(for: nil))
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertGreaterThan(button.bounds.width, 20)
            XCTAssertGreaterThan(button.bounds.height, 20)
            XCTAssertEqual(ring.bounds.width, Layout.pullTargetSize, accuracy: 0.5)
            XCTAssertNil(panel.control(atScreenPoint: panel.convertPoint(toScreen: NSPoint(x: 4, y: 4))))
            button.performClick(nil)
            XCTAssertTrue(line.isClearing)
            try await Task.sleep(for: .seconds(1.15))
            XCTAssertEqual(line.liveCount, 0)
            XCTAssertNil(panel.control(atScreenPoint: buttonPoint))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @MainActor
    func testRingAndButtonStayInsideAllPhotoSizesAndExportPreviews() async throws {
        let previousSize = UserDefaults.standard.object(forKey: "lineSize")
        defer { UserDefaults.standard.set(previousSize, forKey: "lineSize") }
        try await withIsolatedLine { line, folder in
            _ = NSApplication.shared
            let url = folder.appendingPathComponent("layout.png")
            try image(at: url)
            line.hang(url, quietly: true)
            line.revealed = true
            for size in Layout.Size.allCases {
                Layout.size = size
                let host = NSHostingView(rootView: LineView(line: line))
                host.sizingOptions = []
                let panel = LinePanel(content: host)
                panel.setFrame(NSRect(x: 0, y: 0, width: 960, height: Layout.panelHeight), display: true)
                panel.orderFrontRegardless()
                try await Task.sleep(for: .seconds(0.3))
                let ring = try XCTUnwrap(descendants(of: host).compactMap { $0 as? RopePullControl }.first)
                let button = try XCTUnwrap(descendants(of: host).compactMap { $0 as? ClearLineNativeButton }.first)
                let buttonRect = button.convert(button.bounds, to: host)
                XCTAssertTrue(host.bounds.contains(buttonRect))
                XCTAssertEqual(ring.convert(ring.bounds, to: host).midX, host.bounds.width * 0.8, accuracy: 0.5)
                @MainActor func export(_ name: String) throws {
                    guard size == .medium,
                          let path = ProcessInfo.processInfo.environment["IMAGELINE_UI_ARTIFACTS"],
                          let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                    let directory = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: directory.appendingPathComponent(name))
                }
                try export("测试宿主_拉环待拉.png")
                XCTAssertTrue(line.beginPull())
                line.updatePull(distance: Line.maxPull)
                try await Task.sleep(for: .seconds(0.15))
                let ringRect = ring.convert(ring.bounds, to: host)
                XCTAssertTrue(host.bounds.contains(ringRect), "Ring must remain visible at max pull: \(size)")
                XCTAssertFalse(ringRect.intersects(buttonRect))
                XCTAssertTrue(line.pullArmed)
                try export("测试宿主_松手清空.png")
                line.cancelPull()
                panel.orderOut(nil)
            }
        }
    }

    @MainActor
    func testPullThresholdCancellationAndRepeatedRelease() async throws {
        try await withIsolatedLine { line, folder in
            let url = folder.appendingPathComponent("pull-test.png")
            try image(at: url)
            line.hang(url, quietly: true)
            XCTAssertTrue(line.beginPull())
            line.updatePull(distance: Line.pullThreshold - 1)
            XCTAssertFalse(line.pullArmed)
            XCTAssertFalse(line.endPull())
            XCTAssertEqual(line.liveCount, 1)
            XCTAssertEqual(line.ropeOffset, 0)
            XCTAssertTrue(line.beginPull())
            line.updatePull(distance: 200)
            XCTAssertEqual(line.ropeOffset, Line.maxPull)
            XCTAssertTrue(line.pullArmed)
            line.updatePull(distance: -20)
            XCTAssertFalse(line.endPull())
            XCTAssertEqual(line.liveCount, 1)
            XCTAssertTrue(line.beginPull())
            line.updatePull(distance: Line.pullThreshold)
            line.cancelPull()
            XCTAssertFalse(line.endPull())
            XCTAssertEqual(line.liveCount, 1)
            XCTAssertTrue(line.beginPull())
            line.updatePull(distance: Line.pullThreshold)
            XCTAssertTrue(line.endPull())
            XCTAssertTrue(line.isClearing)
            XCTAssertFalse(line.endPull())
            XCTAssertFalse(line.beginPull())
            try await Task.sleep(for: .seconds(1.15))
            XCTAssertEqual(line.liveCount, 0)
            XCTAssertFalse(line.isClearing)
        }
    }

    @MainActor
    func testNativeRingReceivesDragAndReleaseOutsideOriginalHitRegion() async throws {
        try await withIsolatedLine { line, folder in
            _ = NSApplication.shared
            let url = folder.appendingPathComponent("native-drag.png")
            try image(at: url)
            line.hang(url, quietly: true)
            line.revealed = true
            let host = NSHostingView(rootView: LineView(line: line))
            host.sizingOptions = []
            let panel = LinePanel(content: host)
            panel.placeOnScreen()
            panel.orderFrontRegardless()
            defer { panel.orderOut(nil) }
            try await Task.sleep(for: .seconds(0.3))
            let ring = try XCTUnwrap(descendants(of: host).compactMap { $0 as? RopePullControl }.first)
            let origin = ring.convert(NSPoint(x: ring.bounds.midX, y: ring.bounds.midY), to: nil)
            @MainActor func event(_ type: NSEvent.EventType, dy: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: origin.x, y: origin.y - dy),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            panel.sendEvent(event(.leftMouseDown, dy: 0))
            XCTAssertTrue(line.isPulling)
            panel.sendEvent(event(.leftMouseDragged, dy: 60))
            XCTAssertTrue(line.pullArmed)
            panel.sendEvent(event(.leftMouseUp, dy: 60))
            XCTAssertFalse(line.isPulling)
            XCTAssertTrue(line.isClearing)
            try await Task.sleep(for: .seconds(1.15))
            XCTAssertEqual(line.liveCount, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @MainActor
    func testClearPreservesExternalOriginalsAndDoesNotRestoreItems() async throws {
        try await withIsolatedLine { line, folder in
            // More than one screen's capacity: clear must include offscreen items.
            for index in 0..<25 {
                let url = folder.appendingPathComponent("original-\(index).png")
                try image(at: url)
                XCTAssertNotNil(line.hang(url, quietly: true))
            }
            line.clear()
            line.clear() // Repeated clicks must not attempt the same removal twice.
            try await Task.sleep(for: .seconds(2.3))
            XCTAssertEqual(line.liveCount, 0)
            XCTAssertTrue(line.items.isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 25)
            XCTAssertEqual(Line().liveCount, 0)
            line.clear() // Safe when already empty.
            XCTAssertEqual(line.liveCount, 0)
        }
    }

    @MainActor
    func testClearTrashesInternalCopyAndAllowsHangingAgain() async throws {
        try await withIsolatedLine { line, folder in
            let original = folder.appendingPathComponent("original.png")
            try image(at: original)
            try FileManager.default.createDirectory(at: Inbox.folder, withIntermediateDirectories: true)
            let copy = Inbox.folder.appendingPathComponent("Copied clear-test-\(UUID()).png")
            try FileManager.default.copyItem(at: original, to: copy)
            defer { try? FileManager.default.removeItem(at: copy) }
            XCTAssertNotNil(line.hang(original, quietly: true))
            XCTAssertNotNil(line.hang(copy, quietly: true))
            line.clear()
            line.clear()
            try await Task.sleep(for: .seconds(0.9))
            XCTAssertEqual(line.liveCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
            XCTAssertNotNil(line.hang(original, quietly: true))
            XCTAssertEqual(line.liveCount, 1)
        }
    }

    @MainActor
    func testClearSnapshotPreservesNewArrivals() async throws {
        try await withIsolatedLine { line, folder in
            for index in 0..<3 {
                let url = folder.appendingPathComponent("old-\(index).png")
                try image(at: url)
                line.hang(url, quietly: true)
            }
            line.clear()
            let incoming = folder.appendingPathComponent("new.png")
            try image(at: incoming)
            line.hang(incoming, quietly: true)
            try await Task.sleep(for: .seconds(0.9))
            XCTAssertEqual(line.items.filter { !$0.falling }.map(\.url), [incoming])
        }
    }
}
