import AppKit
import XCTest
@testable import Tendedero

final class ScreenshotWatcherTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tendedero-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func writeImage(to url: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    @MainActor
    func testExistingFilesAreSkippedAndAcceptedCaptureIsNotReportedTwice() async throws {
        let folder = try temporaryFolder()
        let old = folder.appendingPathComponent("old.png")
        try writeImage(to: old)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -60)],
                                              ofItemAtPath: old.path)
        let accepted = expectation(description: "Only the new capture is accepted")
        var reported: [URL] = []
        let watcher = ScreenshotWatcher(folder: folder, onNew: { candidate in
            reported.append(candidate)
            accepted.fulfill()
            return true
        }, onChange: {})
        defer { watcher.stop() }
        watcher.start()
        watcher.start()
        let new = folder.appendingPathComponent("new.png")
        try writeImage(to: new)
        await fulfillment(of: [accepted], timeout: 3)
        // Updating a handled file and adding an unrelated file must not replay it.
        try writeImage(to: new)
        try Data().write(to: folder.appendingPathComponent("unrelated.txt"))
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(reported.map { $0.resolvingSymlinksInPath() }, [new.resolvingSymlinksInPath()])
    }

    @MainActor
    func testStoppingCancelsPendingRetriesAndFileMonitoring() async throws {
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("unfinished.png")
        var attempts = 0
        let watcher = ScreenshotWatcher(folder: folder, onNew: { _ in
            attempts += 1
            return false
        }, onChange: {})
        defer { watcher.stop() }
        try Data().write(to: file)
        watcher.start()
        XCTAssertEqual(attempts, 1)
        watcher.stop()
        try writeImage(to: file)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(attempts, 1)
    }

    @MainActor
    func testWatcherRetriesRejectedCaptureWithoutAnotherFileEvent() async throws {
        let folder = try temporaryFolder()
        let accepted = expectation(description: "Accepted on retry")
        var attempts = 0
        let watcher = ScreenshotWatcher(folder: folder, onNew: { _ in
            attempts += 1
            if attempts == 1 { return false }
            accepted.fulfill()
            return true
        }, onChange: {})
        defer { watcher.stop() }
        try writeImage(to: folder.appendingPathComponent("capture.png"))
        watcher.start()
        await fulfillment(of: [accepted], timeout: 3)
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testWatcherAcceptsImageThatFinishesWritingLater() async throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("slow.png")
        let accepted = expectation(description: "Image decoded after writing completed")
        var rejected = 0
        var acceptedCount = 0
        let watcher = ScreenshotWatcher(folder: folder, onNew: { candidate in
            guard makeThumbnail(candidate) != nil else { rejected += 1; return false }
            acceptedCount += 1
            accepted.fulfill()
            return true
        }, onChange: {})
        defer { watcher.stop() }
        watcher.start()
        try Data().write(to: url)
        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertGreaterThan(rejected, 0)
        try writeImage(to: url)
        await fulfillment(of: [accepted], timeout: 3)
        XCTAssertEqual(acceptedCount, 1)
    }

    @MainActor
    func testDamagedImageRetriesAreBoundedAndLaterWriteRecovers() async throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("damaged.png")
        let accepted = expectation(description: "File recovered after retries were exhausted")
        var attempts = 0
        let watcher = ScreenshotWatcher(folder: folder, onNew: { candidate in
            attempts += 1
            guard makeThumbnail(candidate) != nil else { return false }
            accepted.fulfill()
            return true
        }, onChange: {})
        defer { watcher.stop() }
        try Data().write(to: url)
        watcher.start()
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertGreaterThan(attempts, 0)
        let stoppedAt = attempts
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(attempts, stoppedAt, "Damaged files must not trigger an endless polling loop")
        try writeImage(to: url)
        await fulfillment(of: [accepted], timeout: 3)
        XCTAssertGreaterThan(attempts, stoppedAt)
    }
}
