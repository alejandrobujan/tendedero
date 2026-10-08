import AppKit
import ImageIO
import XCTest
@testable import Tendedero

final class MemoryTests: XCTestCase {
    private func image(width: Int = 4000, height: Int = 3000) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try image(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    @MainActor
    func testDefaultThumbnailMatchesDisplayBudget() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let thumb = try XCTUnwrap(makeThumbnail(url))
        let cg = try XCTUnwrap(thumb.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        XCTAssertLessThanOrEqual(cg.width, Int(ceil((Layout.cardWidth - 14) * scale)))
        XCTAssertEqual(Double(cg.width) / Double(cg.height), 4.0 / 3.0, accuracy: 0.01)
    }

    @MainActor
    func testExplicitThumbnailBudgetAndInvalidInput() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let thumb = try XCTUnwrap(makeThumbnail(url, maxPixels: 160))
        let cg = try XCTUnwrap(thumb.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.width, 160)
        XCTAssertEqual(cg.height, 120)
        XCTAssertNil(makeThumbnail(url.appendingPathExtension("missing")))
    }

    @MainActor
    func testConcurrentFallsShareCroppedWindowAndReleaseIt() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let cg = try image(width: 100, height: 80)
        let card = CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 100, height: 80)
        weak var overlay: NSWindow?
        autoreleasepool {
            for n in 0..<3 {
                CaptureFlight.fall(image: cg, card: card.offsetBy(dx: CGFloat(n * 110), dy: 0), tilt: 2, on: screen)
            }
            XCTAssertEqual(NSApp.windows.filter { !existing.contains(ObjectIdentifier($0)) }.count, 1)
            overlay = NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) }
            XCTAssertLessThan(overlay?.frame.width ?? screen.frame.width, screen.frame.width)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        }
        XCTAssertNil(overlay, "Idle overlays must release their window and backing surfaces")
    }

    @MainActor
    func testArrivalCompletesOnceAndReleasesOverlayAfterFade() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let rect = CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 100, height: 80)
        var completions = 0
        weak var overlay: NSWindow?
        try autoreleasepool {
            CaptureFlight.fly(image: try image(width: 100, height: 80), from: rect,
                              to: rect.offsetBy(dx: 20, dy: 50), tilt: 2, on: screen) { completions += 1 }
            overlay = NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) }
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        }
        XCTAssertEqual(completions, 1)
        XCTAssertNil(overlay)
    }
    func testPNGEncodingPreservesPixelsAndTransparency() throws {
        let c = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        c.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let original = try XCTUnwrap(c.makeImage())
        let data = try XCTUnwrap(pngData(original))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 64)
        XCTAssertEqual(decoded.height, 32)
        let comparison = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
            bytesPerRow: c.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        comparison.draw(decoded, in: CGRect(x: 0, y: 0, width: 64, height: 32))
        let length = c.bytesPerRow * c.height
        XCTAssertEqual(Data(bytes: try XCTUnwrap(c.data), count: length),
                       Data(bytes: try XCTUnwrap(comparison.data), count: length))
    }

    func testPNGOriginalIsCopiedWithoutReencoding() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try XCTUnwrap(pngData(url)), try Data(contentsOf: url))
    }

    @MainActor
    func testRotatedJPEGKeepsOrientationAndFullResolutionWhenCopied() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let colored = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        colored.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        colored.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        colored.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        colored.fill(CGRect(x: 200, y: 0, width: 200, height: 300))
        CGImageDestinationAddImage(dest, try XCTUnwrap(colored.makeImage()),
                                  [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let data = try XCTUnwrap(pngData(url))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 300)
        XCTAssertEqual(decoded.height, 400)
        // Compare rendered colors with AppKit's established orientation handling.
        let tiff = try XCTUnwrap(NSImage(contentsOf: url)?.tiffRepresentation)
        let reference = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.cgImage)
        XCTAssertEqual(reference.width, decoded.width)
        XCTAssertEqual(reference.height, decoded.height)
        func rgba(_ image: CGImage) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * context.height)
        }
        let expectedPixels = try rgba(reference)
        let actualPixels = try rgba(decoded)
        for (x, y) in [(30, 30), (270, 30), (30, 370), (270, 370)] {
            let offset = (y * decoded.width + x) * 4
            for component in 0..<3 {
                XCTAssertEqual(Int(actualPixels[offset + component]), Int(expectedPixels[offset + component]), accuracy: 3)
            }
        }
        let thumb = try XCTUnwrap(makeThumbnail(url))
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        XCTAssertLessThanOrEqual(thumb.size.height, ceil(104 * scale))
    }

    @MainActor
    func testCaptureBurstBoundsArrivalsAndStillCompletesEveryCard() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let rect = CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 100, height: 80)
        let cg = try image(width: 100, height: 80)
        var completions = 0
        autoreleasepool {
            for _ in 0..<10 {
                CaptureFlight.fly(image: cg, from: rect, to: rect, tilt: 0, on: screen) { completions += 1 }
            }
            XCTAssertFalse(CaptureFlight.canFly)
            XCTAssertEqual(completions, 8, "Excess captures must land without retaining more flight images")
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertEqual(completions, 10)
        XCTAssertTrue(CaptureFlight.canFly)
    }

    @MainActor
    func testCompletionCanStartAnotherFlightInSameOverlay() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let rect = CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 100, height: 80)
        let cg = try image(width: 100, height: 80)
        var completions = 0
        autoreleasepool {
            CaptureFlight.fly(image: cg, from: rect, to: rect, tilt: 0, on: screen) {
                completions += 1
                CaptureFlight.fly(image: cg, from: rect, to: rect, tilt: 0, on: screen) { completions += 1 }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1.7))
        }
        XCTAssertEqual(completions, 2)
        XCTAssertTrue(CaptureFlight.canFly)
    }

    @MainActor
    func testWatcherOnlyReportsNewImagesInCreationOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appendingPathComponent("existing.png")
        try Data([1]).write(to: old)
        try FileManager.default.setAttributes([.creationDate: Date.distantPast], ofItemAtPath: old.path)
        var received: [String] = []
        let watcher = ScreenshotWatcher(folder: folder, onNew: { received.append($0.lastPathComponent) }, onChange: {})
        for name in ["first.png", "notes.txt", "second.jpg"] {
            try Data([1]).write(to: folder.appendingPathComponent(name))
        }
        watcher.start()
        defer { watcher.stop() }
        XCTAssertEqual(received, ["first.png", "second.jpg"])
        try Data([1]).write(to: folder.appendingPathComponent("third.png"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(received, ["first.png", "second.jpg", "third.png"])
    }

    @MainActor
    func testCroppedOverlayPreservesScreenCoordinatesWhenGrowingAndShrinking() throws {
        _ = NSApplication.shared
        for screen in NSScreen.screens {
            try autoreleasepool {
                let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
                let cg = try image(width: 100, height: 80)
                let firstCard = CGRect(x: screen.frame.midX + 100, y: screen.frame.midY, width: 100, height: 80)
                let firstBefore = CACurrentMediaTime()
                CaptureFlight.fall(image: cg, card: firstCard, tilt: 2, on: screen)
                let firstAfter = CACurrentMediaTime()
                let window = try XCTUnwrap(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) })
                let root = try XCTUnwrap(window.contentView?.layer)
                let firstLayer = try XCTUnwrap(root.sublayers?.first)
                XCTAssertEqual(window.frame.minX + firstLayer.position.x, firstCard.midX, accuracy: 0.1)
                XCTAssertEqual(window.frame.minY + firstLayer.position.y, firstCard.maxY, accuracy: 0.1)
                XCTAssertEqual(firstLayer.bounds.size, firstCard.size)
                XCTAssertEqual(firstLayer.affineTransform().b, sin(-2 * .pi / 180), accuracy: 0.0001)
                let initialOrigin = window.frame.origin
                RunLoop.main.run(until: Date().addingTimeInterval(0.12))
                let secondCard = firstCard.offsetBy(dx: -350, dy: 0)
                let secondBefore = CACurrentMediaTime()
                CaptureFlight.fall(image: cg, card: secondCard, tilt: -2, on: screen)
                let secondAfter = CACurrentMediaTime()
                let secondLayer = try XCTUnwrap(root.sublayers?.last)
                XCTAssertNotEqual(window.frame.origin, initialOrigin)
                XCTAssertEqual(window.frame.minX + firstLayer.position.x, firstCard.midX, accuracy: 0.1)
                let y = window.frame.minY + firstLayer.position.y
                let earliestY = firstCard.maxY - 520 * pow((secondAfter - firstBefore) / 0.55, 3)
                let latestY = firstCard.maxY - 520 * pow((secondBefore - firstAfter) / 0.55, 3)
                XCTAssertGreaterThanOrEqual(y, earliestY - 1)
                XCTAssertLessThanOrEqual(y, latestY + 1)
                XCTAssertEqual(window.frame.minX + secondLayer.position.x, secondCard.midX, accuracy: 0.1)
                XCTAssertEqual(window.frame.minY + secondLayer.position.y, secondCard.maxY, accuracy: 0.1)
                let expandedWidth = window.frame.width
                RunLoop.main.run(until: Date().addingTimeInterval(0.48))
                XCTAssertNil(firstLayer.superlayer)
                XCTAssertTrue(secondLayer.superlayer === root)
                XCTAssertLessThan(window.frame.width, expandedWidth)
                XCTAssertEqual(window.frame.minX + secondLayer.position.x, secondCard.midX, accuracy: 0.1)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            }
        }
    }

    @MainActor
    func testMarkupWritesPNGDirectlyAndReplacesExistingFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("edited.png")
        try Data([1, 2, 3]).write(to: target)
        let cg = try image(width: 64, height: 32)
        try writePNG(NSImage(cgImage: cg, size: CGSize(width: 32, height: 16)), to: target)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(target as CFURL, nil))
        let result = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(result.width, 64)
        XCTAssertEqual(result.height, 32)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["edited.png"])
    }

    func testAtomicFileCopyPreservesSourceAndTargetOnFailure() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.png")
        let target = folder.appendingPathComponent("target.png")
        let original = Data([1, 2, 3]), edited = Data([4, 5, 6])
        try original.write(to: target)
        XCTAssertThrowsError(try replaceFileContents(from: source, to: target))
        XCTAssertEqual(try Data(contentsOf: target), original)
        try edited.write(to: source)
        try replaceFileContents(from: source, to: target)
        XCTAssertEqual(try Data(contentsOf: target), edited)
        XCTAssertEqual(try Data(contentsOf: source), edited)
        try FileManager.default.removeItem(at: target)
        try replaceFileContents(from: source, to: target)
        XCTAssertEqual(try Data(contentsOf: target), edited)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["source.png", "target.png"])
    }

    @MainActor
    func testDeferredClipboardKeepsSnapshotAfterOriginalChangesOrIsDeleted() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try Data(contentsOf: url)
        let board = NSPasteboard.withUniqueName()
        defer { board.clearContents(); board.releaseGlobally() }
        XCTAssertTrue(ClipboardImage.copy(url, to: board))
        XCTAssertTrue(board.types?.contains(.png) == true)
        XCTAssertEqual(board.string(forType: .fileURL), url.absoluteString)
        try Data([1, 2, 3]).write(to: url)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(board.data(forType: .png), expected)
    }

    @MainActor
    func testDeferredClipboardMaterializesBeforeQuit() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try Data(contentsOf: url)
        let board = NSPasteboard.withUniqueName()
        defer { board.clearContents(); board.releaseGlobally() }
        XCTAssertTrue(ClipboardImage.copy(url, to: board))
        ClipboardImage.materializeForExit()
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(board.data(forType: .png), expected)
    }

    @MainActor
    func testDeferredClipboardDoesNotOverwriteNewOwnersContentsOnQuit() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let board = NSPasteboard.withUniqueName()
        defer { board.clearContents(); board.releaseGlobally() }
        XCTAssertTrue(ClipboardImage.copy(url, to: board))
        board.clearContents()
        board.setString("new owner", forType: .string)
        ClipboardImage.materializeForExit()
        XCTAssertEqual(board.string(forType: .string), "new owner")
        XCTAssertNil(board.data(forType: .png))
    }

    @MainActor
    func testDeferredClipboardReplacesSnapshotsAndCleansUpWhenCleared() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        func snapshots() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
                .filter { $0.hasPrefix("tendedero-clipboard-") })
        }
        let existing = try snapshots()
        let board = NSPasteboard.withUniqueName()
        defer { board.clearContents(); board.releaseGlobally() }
        XCTAssertTrue(ClipboardImage.copy(url, to: board))
        XCTAssertEqual(try snapshots().subtracting(existing).count, 1)
        XCTAssertTrue(ClipboardImage.copy(url, to: board))
        XCTAssertEqual(try snapshots().subtracting(existing).count, 1)
        // Old completion cleanup must not forget the latest promised image.
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        ClipboardImage.materializeForExit()
        XCTAssertEqual(board.data(forType: .png), try Data(contentsOf: url))
        XCTAssertTrue(try snapshots().subtracting(existing).isEmpty)
        XCTAssertTrue(ClipboardImage.copy(url, to: board))
        board.clearContents()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertTrue(try snapshots().subtracting(existing).isEmpty)
    }

    @MainActor
    func testDeferredJPEGClipboardPreservesFullResolution() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try image(width: 400, height: 300), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let board = NSPasteboard.withUniqueName()
        defer { board.clearContents(); board.releaseGlobally() }
        XCTAssertTrue(ClipboardImage.copy(url, to: board))
        try FileManager.default.removeItem(at: url)
        let data = try XCTUnwrap(board.data(forType: .png))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let result = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(result.width, 400)
        XCTAssertEqual(result.height, 300)
    }

    @MainActor
    func testDeferredClipboardSnapshotsRelativeSymlinkContents() throws {
        let url = try fixture()
        let link = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: url) }
        let expected = try Data(contentsOf: url)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: url.lastPathComponent)
        let board = NSPasteboard.withUniqueName()
        defer { board.clearContents(); board.releaseGlobally() }
        XCTAssertTrue(ClipboardImage.copy(link, to: board))
        XCTAssertEqual(board.string(forType: .fileURL), link.absoluteString)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(board.data(forType: .png), expected)
    }

    func testAtomicFileCopyResolvesRelativeSymlink() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.png")
        let link = folder.appendingPathComponent("link.png")
        let destinationFolder = folder.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let target = destinationFolder.appendingPathComponent("target.png")
        let data = Data([1, 2, 3])
        try data.write(to: source)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: source.lastPathComponent)
        try replaceFileContents(from: link, to: target)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: target), data)
    }

}
