import AppKit
import XCTest
@testable import Tendedero

final class CaptureNotificationTests: XCTestCase {
    private func makeFixture() throws -> (URL, UserDefaults) {
        let name = "tendedero-capture-test-\(UUID().uuidString)"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(true, forKey: "soundOff")
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: folder)
        }
        return (folder, defaults)
    }

    private func writeImage(to url: URL) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    @MainActor
    func testFullLineReportsNewCaptureAfterEvictionAndPersistence() throws {
        let (folder, defaults) = try makeFixture()
        let line = Line(defaults: defaults)
        line.maxItems = 2
        var notifiedPaths: [[String]] = []
        line.onCapture = {
            let paths = line.items.filter { !$0.falling }.map(\.url.path)
            XCTAssertLessThanOrEqual(paths.count, 2)
            XCTAssertEqual(defaults.stringArray(forKey: "pegged"), paths)
            notifiedPaths.append(paths)
        }
        for index in 0..<3 {
            let url = folder.appendingPathComponent("capture-\(index).png")
            try writeImage(to: url)
            XCTAssertNotNil(line.hang(url))
        }
        XCTAssertEqual(line.liveCount, 2)
        XCTAssertEqual(notifiedPaths.count, 3)
        XCTAssertEqual(notifiedPaths.last?.map { URL(fileURLWithPath: $0).lastPathComponent },
                       ["capture-1.png", "capture-2.png"])
    }

    @MainActor
    func testDuplicatesRejectedFilesAndQuietChangesDoNotReportNewCapture() throws {
        let (folder, defaults) = try makeFixture()
        let line = Line(defaults: defaults)
        let image = folder.appendingPathComponent("capture.png")
        try writeImage(to: image)
        var notifications = 0
        line.onCapture = { notifications += 1 }
        let id = try XCTUnwrap(line.hang(image))
        XCTAssertEqual(notifications, 1)
        XCTAssertNil(line.hang(image))
        let incomplete = folder.appendingPathComponent("unfinished.png")
        try Data().write(to: incomplete)
        XCTAssertNil(line.hang(incomplete))
        line.drop(id, quietly: true)
        XCTAssertNotNil(line.hang(image, quietly: true))
        XCTAssertEqual(notifications, 1)
    }

    @MainActor
    func testRestoredCapturesDoNotNotifyWhenCallbackIsInstalled() throws {
        let (folder, defaults) = try makeFixture()
        let image = folder.appendingPathComponent("saved.png")
        try writeImage(to: image)
        defaults.set([image.path], forKey: "pegged")
        let line = Line(defaults: defaults)
        var notifications = 0
        line.onCapture = { notifications += 1 }
        XCTAssertEqual(line.liveCount, 1)
        line.reloadThumbnail(for: image)
        XCTAssertEqual(notifications, 0)
    }
}
