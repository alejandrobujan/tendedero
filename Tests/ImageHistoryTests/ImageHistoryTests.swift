import AppKit
import ImageIO
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
typealias HistoryTestCase = XCTestCase
#endif

final class ImageHistoryTests: HistoryTestCase {
    private final class Clock { var date = Date() }

    @MainActor
    private func withEnvironment(_ body: (UserDefaults, URL, Clock) throws -> Void) throws {
        let suite = "history-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        try body(defaults, folder, Clock())
    }

    private func file(_ folder: URL, clipboard: Bool = true) throws -> URL {
        let url = folder.appendingPathComponent(clipboard ? "Clipboard \(UUID()).png" : "Screenshot \(UUID()).png")
        let pixels: [UInt8] = [10, 100, 200, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 1),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    @MainActor func testDefaultAndInvalidRetention() throws {
        try withEnvironment { defaults, folder, clock in
            let history = ImageHistory(defaults: defaults, inbox: folder, now: { clock.date })
            XCTAssertEqual(history.retentionDays, 30)
            for value in [0, -1, 2, 365] {
                defaults.set(value, forKey: "historyRetentionDays")
                XCTAssertEqual(history.retentionDays, 30)
            }
            history.setRetentionDays(2)
            XCTAssertEqual(history.retentionDays, 30)
        }
    }

    @MainActor func testEveryRetentionChoicePersists() throws {
        try withEnvironment { defaults, folder, clock in
            for days in [1, 3, 7, 15, 30] {
                let history = ImageHistory(defaults: defaults, inbox: folder, now: { clock.date })
                history.setRetentionDays(days)
                XCTAssertEqual(history.retentionDays, days)
                XCTAssertEqual(ImageHistory(defaults: defaults, inbox: folder).retentionDays, days)
            }
        }
    }

    @MainActor func testNewestFirstAndDuplicatesDoNotRenew() throws {
        try withEnvironment { defaults, folder, clock in
            let history = ImageHistory(defaults: defaults, inbox: folder, now: { clock.date })
            let old = try file(folder), new = try file(folder)
            history.add(old)
            let originalDate = history.entries[0].capturedAt
            clock.date.addTimeInterval(10)
            history.add(new)
            history.add(old)
            XCTAssertEqual(history.entries.map(\.url), [new, old])
            XCTAssertEqual(history.entries[1].capturedAt, originalDate)
        }
    }

    @MainActor func testRestartPreservesOrderAndDates() throws {
        try withEnvironment { defaults, folder, clock in
            let history = ImageHistory(defaults: defaults, inbox: folder, now: { clock.date })
            for _ in 0..<20 {
                history.add(try file(folder))
                clock.date.addTimeInterval(1)
            }
            let restored = ImageHistory(defaults: defaults, inbox: folder, now: { clock.date })
            XCTAssertEqual(restored.entries, history.entries)
            XCTAssertEqual(defaults.stringArray(forKey: "pegged"), history.entries.reversed().map(\.path))
        }
    }

    @MainActor func testExpiryDeletesOwnedCopiesButKeepsOriginals() throws {
        try withEnvironment { defaults, folder, clock in
            let history = ImageHistory(defaults: defaults, inbox: folder, now: { clock.date })
            let owned = try file(folder), original = try file(folder, clipboard: false)
            let outside = folder.appendingPathComponent("external")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let externalCopy = try file(outside)
            for url in [owned, original, externalCopy] { history.add(url) }
            clock.date.addTimeInterval(30 * 86_400)
            history.prune()
            XCTAssertTrue(history.entries.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: externalCopy.path))
        }
    }

    @MainActor func testCutoffAndFreshImage() throws {
        try withEnvironment { defaults, folder, clock in
            let history = ImageHistory(defaults: defaults, inbox: folder, now: { clock.date })
            let old = try file(folder)
            history.add(old)
            clock.date.addTimeInterval(30 * 86_400 - 1)
            history.prune()
            XCTAssertEqual(history.entries.count, 1)
            let fresh = try file(folder)
            history.add(fresh)
            clock.date.addTimeInterval(1)
            history.prune()
            XCTAssertEqual(history.entries.map(\.url), [fresh])
        }
    }

    @MainActor func testShorterRetentionAppliesImmediately() throws {
        try withEnvironment { defaults, folder, clock in
            let history = ImageHistory(defaults: defaults, inbox: folder, now: { clock.date })
            history.add(try file(folder))
            clock.date.addTimeInterval(4 * 86_400)
            let fresh = try file(folder)
            history.add(fresh)
            history.setRetentionDays(3)
            XCTAssertEqual(history.entries.map(\.url), [fresh])
            history.setRetentionDays(30)
            XCTAssertEqual(history.entries.map(\.url), [fresh])
        }
    }

    @MainActor func testMissingFilesArePruned() throws {
        try withEnvironment { defaults, folder, clock in
            let history = ImageHistory(defaults: defaults, inbox: folder, now: { clock.date })
            let url = try file(folder)
            history.add(url)
            try FileManager.default.removeItem(at: url)
            history.prune()
            XCTAssertTrue(history.entries.isEmpty)
        }
    }

    @MainActor func testLegacyMigrationRecoversOnlyOwnedFilesOnce() throws {
        try withEnvironment { defaults, folder, clock in
            let legacy = try file(folder, clipboard: false), orphan = try file(folder)
            _ = try file(folder, clipboard: false)
            defaults.set([legacy.path, legacy.path], forKey: "pegged")
            let history = ImageHistory(defaults: defaults, inbox: folder, now: { clock.date })
            XCTAssertEqual(Set(history.entries.map(\.url)), Set([legacy, orphan]))
            history.remove(orphan)
            let restored = ImageHistory(defaults: defaults, inbox: folder, now: { clock.date })
            XCTAssertEqual(restored.entries.map(\.url), [legacy])
        }
    }

    @MainActor func testOrphanFilesExpireAndLookalikesStay() throws {
        try withEnvironment { defaults, folder, clock in
            let history = ImageHistory(defaults: defaults, inbox: folder, now: { clock.date })
            let owned = try file(folder)
            let lookalike = folder.appendingPathComponent("Clipboard personal.png")
            try Data([1]).write(to: lookalike)
            clock.date.addTimeInterval(31 * 86_400)
            history.prune()
            XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: lookalike.path))
        }
    }

    @MainActor func testSymlinkIsNeverFollowedOrDeleted() throws {
        try withEnvironment { defaults, folder, clock in
            let original = try file(folder, clipboard: false)
            let link = folder.appendingPathComponent("Clipboard \(UUID()).png")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
            let history = ImageHistory(defaults: defaults, inbox: folder, now: { clock.date })
            history.add(link)
            clock.date.addTimeInterval(31 * 86_400)
            history.prune()
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        }
    }

    @MainActor func testSymlinkedInboxDoesNotDeleteFiles() throws {
        try withEnvironment { defaults, folder, clock in
            let real = folder.appendingPathComponent("real")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            let original = try file(real)
            let link = folder.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            let history = ImageHistory(defaults: defaults, inbox: link, now: { clock.date })
            history.add(link.appendingPathComponent(original.lastPathComponent))
            clock.date.addTimeInterval(31 * 86_400)
            history.prune()
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        }
    }

    @MainActor func testCorruptMetadataCanRecoverLegacyList() throws {
        try withEnvironment { defaults, folder, clock in
            let original = try file(folder, clipboard: false)
            defaults.set(Data("bad JSON".utf8), forKey: "imageHistoryV1")
            defaults.set([original.path], forKey: "pegged")
            let history = ImageHistory(defaults: defaults, inbox: folder, now: { clock.date })
            XCTAssertEqual(history.entries.map(\.url), [original])
        }
    }

    @MainActor func testLineKeepsMoreThanScreenCapacityAndBoundsThumbnails() throws {
        try withEnvironment { defaults, folder, clock in
            let line = Line(defaults: defaults, inbox: folder, now: { clock.date }, breeze: false)
            line.setViewportWidth(800)
            var urls: [URL] = []
            for _ in 0..<40 {
                let url = try file(folder)
                urls.append(url)
                XCTAssertTrue(line.hang(url, quietly: true) != nil)
            }
            XCTAssertEqual(line.liveCount, 40)
            XCTAssertEqual(line.items.map(\.url), Array(urls.reversed()))
            XCTAssertTrue(line.items.filter { $0.thumb != nil }.count <= 7)
            let restarted = Line(defaults: defaults, inbox: folder, now: { clock.date }, breeze: false)
            XCTAssertEqual(restarted.items.map(\.url), line.items.map(\.url))
        }
    }

    @MainActor func testWheelBothDirectionsAndResizeClamp() throws {
        try withEnvironment { defaults, folder, clock in
            let line = Line(defaults: defaults, inbox: folder, now: { clock.date }, breeze: false)
            line.setViewportWidth(400)
            for _ in 0..<8 { line.hang(try file(folder), quietly: true) }
            line.scroll(horizontal: 0, vertical: -3, precise: false)
            XCTAssertEqual(line.scrollOffset, 72)
            line.scroll(horizontal: -100, vertical: 0, precise: true)
            XCTAssertEqual(line.scrollOffset, 172)
            line.scroll(horizontal: 0, vertical: 2, precise: false)
            XCTAssertEqual(line.scrollOffset, 124)
            line.setScrollOffset(100_000)
            XCTAssertEqual(line.scrollOffset, line.maximumScrollOffset)
            line.setViewportWidth(10_000)
            XCTAssertEqual(line.scrollOffset, 0)
            XCTAssertEqual(line.maximumScrollOffset, 0)
        }
    }

    @MainActor func testNewCaptureReturnsToNewestAndExpiredLineClamps() throws {
        try withEnvironment { defaults, folder, clock in
            let line = Line(defaults: defaults, inbox: folder, now: { clock.date }, breeze: false)
            line.setViewportWidth(300)
            for _ in 0..<6 { line.hang(try file(folder), quietly: true) }
            line.setScrollOffset(500)
            let new = try file(folder)
            line.hang(new, quietly: true)
            XCTAssertEqual(line.scrollOffset, 0)
            XCTAssertEqual(line.items.first?.url, new)
            line.setScrollOffset(500)
            clock.date.addTimeInterval(31 * 86_400)
            line.prune()
            XCTAssertTrue(line.items.isEmpty)
            XCTAssertEqual(line.scrollOffset, 0)
        }
    }

    @MainActor func testScrollLoadsVisibleThumbnailsAndEvictsOffscreenImages() throws {
        try withEnvironment { defaults, folder, clock in
            let line = Line(defaults: defaults, inbox: folder, now: { clock.date }, breeze: false)
            line.setViewportWidth(400)
            for _ in 0..<30 { line.hang(try file(folder), quietly: true) }
            line.setScrollOffset(line.maximumScrollOffset)
            XCTAssertTrue(line.items.last?.thumb != nil)
            XCTAssertNil(line.items.first?.thumb)
            XCTAssertTrue(line.items.filter { $0.thumb != nil }.count <= 6)
            line.setScrollOffset(.nan)
            XCTAssertTrue(line.scrollOffset.isFinite)
        }
    }

    func testLayoutStartsLeftAndLastCardIsReachable() {
        XCTAssertEqual(Layout.x(index: 0), 99)
        XCTAssertEqual(Layout.x(index: 1) - Layout.x(index: 0), 174)
        let maximum = Layout.maximumOffset(count: 50, width: 1000)
        XCTAssertEqual(Layout.x(index: 49, scrollOffset: maximum) + Layout.cardWidth / 2, 976)
        XCTAssertTrue(Layout.visibleRange(count: 50, width: 1000, offset: maximum).contains(49))
        XCTAssertEqual(Layout.maximumOffset(count: 1, width: 1000), 0)
    }

    @MainActor func testPanelRoutesSyntheticWheelLocally() throws {
        _ = NSApplication.shared
        let panel = LinePanel(content: NSView())
        var deltas: [(CGFloat, CGFloat, Bool)] = []
        panel.onScroll = { deltas.append(($0, $1, $2)) }
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
            wheelCount: 2, wheel1: -3, wheel2: 0, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        panel.sendEvent(event)
        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas.first?.1, event.scrollingDeltaY)
        XCTAssertFalse(panel.canBecomeKey)
    }
    @MainActor func testClearPersistsAndDoesNotReimportOrphans() throws {
        try withEnvironment { defaults, folder, clock in
            defaults.set(true, forKey: "soundOff")
            let line = Line(defaults: defaults, inbox: folder, now: { clock.date }, breeze: false)
            for _ in 0..<25 { line.hang(try file(folder), quietly: true) }
            line.clear()
            XCTAssertTrue(line.items.isEmpty)
            XCTAssertTrue(Line(defaults: defaults, inbox: folder, now: { clock.date }, breeze: false).items.isEmpty)
        }
    }

    @MainActor func testNestedClipboardNamesAreNotDeleted() throws {
        try withEnvironment { defaults, folder, clock in
            let nested = folder.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let url = try file(nested)
            let history = ImageHistory(defaults: defaults, inbox: folder, now: { clock.date })
            history.add(url)
            clock.date.addTimeInterval(31 * 86_400)
            history.prune()
            XCTAssertTrue(history.entries.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @MainActor func testMenuOffersEveryDurationAndChecksSelection() throws {
        _ = NSApplication.shared
        try withEnvironment { defaults, folder, clock in
            let line = Line(defaults: defaults, inbox: folder, now: { clock.date }, breeze: false)
            let delegate = AppDelegate(line: line)
            let menu = NSMenu()
            delegate.menuNeedsUpdate(menu)
            let history = try XCTUnwrap(menu.items.first { $0.title == L("Keep image history") }?.submenu)
            XCTAssertEqual(history.items.map(\.title), [L("1 day"), L("3 days"), L("7 days"), L("15 days"), L("30 days")])
            XCTAssertEqual(history.items.map(\.state), [.off, .off, .off, .off, .on])
            for (index, days) in ImageHistory.dayChoices.enumerated() {
                history.performActionForItem(at: index)
                XCTAssertEqual(line.retentionDays, days)
                delegate.menuNeedsUpdate(menu)
                let current = try XCTUnwrap(menu.items.first { $0.title == L("Keep image history") }?.submenu)
                XCTAssertEqual(current.items.filter { $0.state == .on }.map(\.title), [current.items[index].title])
            }
        }
    }

}
