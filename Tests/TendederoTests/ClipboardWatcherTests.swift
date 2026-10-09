import AppKit
import ImageIO
import UniformTypeIdentifiers
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
typealias ClipboardTestCase = XCTestCase
#endif

/// Only in-memory pasteboards and generated pixels. No NSPasteboard.general,
/// Line/AppDelegate construction, application launch or user preferences writes.
final class ClipboardWatcherTests: ClipboardTestCase {
    @MainActor
    private func withWatcher(_ body: (ClipboardWatcher, FakeClipboard, URL, () -> [URL]) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = FakeClipboard()
        var received: [URL] = []
        let watcher = ClipboardWatcher(source: source, folder: folder) { received.append($0) }
        defer {
            watcher.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        try body(watcher, source, folder, { received })
    }

    @MainActor
    func testDisabledWatcherNeverReadsClipboardOrCreatesFolder() throws {
        try withWatcher { watcher, source, folder, received in
            watcher.check()
            XCTAssertEqual(source.countReads, 0)
            XCTAssertEqual(source.typeReads, 0)
            XCTAssertTrue(source.dataReads.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
            XCTAssertTrue(received().isEmpty)
        }
    }

    @MainActor
    func testEnablingSkipsExistingImage() throws {
        try withWatcher { watcher, source, _, received in
            source.copy([.png: try imageData(.png)])
            watcher.start()
            watcher.check()
            XCTAssertTrue(received().isEmpty)
            XCTAssertEqual(source.typeReads, 0)
            XCTAssertTrue(source.dataReads.isEmpty)
        }
    }

    @MainActor
    func testPNGIsSavedOnceAndClipboardRemainsUnchanged() throws {
        try withWatcher { watcher, source, _, received in
            watcher.start()
            let png = try imageData(.png)
            source.copy([.png: png, .string: Data("unread text".utf8)])
            let before = source.items
            let count = source.changeCount
            watcher.check()
            watcher.check()
            XCTAssertEqual(received().count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(received().first)), png)
            XCTAssertEqual(source.items, before)
            XCTAssertEqual(source.changeCount, count)
            XCTAssertEqual(source.dataReads, [.png])
        }
    }

    @MainActor
    func testTIFFConvertsToPNGWithoutChangingClipboard() throws {
        try withWatcher { watcher, source, _, received in
            watcher.start()
            let tiff = try imageData(.tiff)
            source.copy([.tiff: tiff])
            watcher.check()
            let url = try XCTUnwrap(received().first)
            let image = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(image) as String?, UTType.png.identifier)
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 2)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 2)
            let original = try XCTUnwrap(CGImageSourceCreateWithData(tiff as CFData, nil))
            let originalImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(original, 0, nil))
            let savedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image, 0, nil))
            XCTAssertEqual(try rasterBytes(savedImage), try rasterBytes(originalImage))
            XCTAssertEqual(source.items.first?[.tiff], tiff)
        }
    }

    @MainActor
    func testMultipleRepresentationsAndItemsProduceOneCapture() throws {
        try withWatcher { watcher, source, _, received in
            watcher.start()
            source.copy([.png: try imageData(.png), .tiff: try imageData(.tiff)])
            source.items.append([.png: try imageData(.png)])
            watcher.check()
            XCTAssertEqual(received().count, 1)
            XCTAssertEqual(source.dataReads, [.png])
        }
    }

    @MainActor
    func testOwnCopyIsSkippedAndNextExternalImageIsAccepted() throws {
        try withWatcher { watcher, source, _, received in
            watcher.start()
            source.copy([.png: try imageData(.png)])
            ClipboardWatcher.recordOwnCopy(changeCount: source.changeCount)
            watcher.check()
            XCTAssertTrue(received().isEmpty)
            XCTAssertEqual(source.typeReads, 0)
            XCTAssertTrue(source.dataReads.isEmpty)
            source.copy([.png: try imageData(.png)])
            watcher.check()
            XCTAssertEqual(received().count, 1)
        }
    }

    @MainActor
    func testPrivateMarkersOnAnyItemPreventAllImageReads() throws {
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"] {
            for separateItem in [false, true] {
                try withWatcher { watcher, source, _, received in
                    watcher.start()
                    source.copy([.png: try imageData(.png)])
                    let type = NSPasteboard.PasteboardType(marker)
                    if separateItem { source.items.append([type: Data()]) }
                    else { source.items[0][type] = Data() }
                    watcher.check()
                    XCTAssertTrue(received().isEmpty, marker)
                    XCTAssertTrue(source.dataReads.isEmpty, marker)
                }
            }
        }
    }

    @MainActor
    func testFileURLAndFinderIconAreSkippedWithoutReadingEither() throws {
        try withWatcher { watcher, source, _, received in
            watcher.start()
            source.copy([.tiff: try imageData(.tiff), .fileURL: Data("file:///never-open-this.png".utf8)])
            watcher.check()
            XCTAssertTrue(received().isEmpty)
            XCTAssertTrue(source.dataReads.isEmpty)
        }
    }

    @MainActor
    func testUnsupportedAndEmptyClipboardAreIgnored() throws {
        try withWatcher { watcher, source, _, received in
            watcher.start()
            source.copy([.string: Data("text".utf8), .URL: Data("https://example.invalid/image.png".utf8),
                         NSPasteboard.PasteboardType("public.jpeg"): try imageData(.jpeg)])
            watcher.check()
            source.copy([:])
            watcher.check()
            XCTAssertTrue(received().isEmpty)
            XCTAssertTrue(source.dataReads.isEmpty)
        }
    }

    @MainActor
    func testStopAndRestartSkipImagesCopiedWhileDisabled() throws {
        try withWatcher { watcher, source, _, received in
            watcher.start()
            watcher.stop()
            let reads = source.countReads
            source.copy([.png: try imageData(.png)])
            watcher.check()
            XCTAssertEqual(source.countReads, reads)
            watcher.start()
            watcher.check()
            XCTAssertTrue(received().isEmpty)
            source.copy([.png: try imageData(.png)])
            watcher.check()
            XCTAssertEqual(received().count, 1)
        }
    }

    @MainActor
    func testStartingTwiceDoesNotResetBaselineOrDuplicateTimer() throws {
        try withWatcher { watcher, source, _, received in
            watcher.start()
            source.copy([.png: try imageData(.png)])
            watcher.start()
            watcher.check()
            XCTAssertEqual(received().count, 1)
        }
    }

    @MainActor
    func testClipboardChangeDuringMetadataReadIsDiscarded() throws {
        try withWatcher { watcher, source, _, received in
            watcher.start()
            source.copy([.png: try imageData(.png)])
            source.onTypesRead = { source.count += 1; source.onTypesRead = nil }
            watcher.check()
            XCTAssertTrue(received().isEmpty)
            XCTAssertTrue(source.dataReads.isEmpty)
            watcher.check()
            XCTAssertEqual(received().count, 1)
        }
    }

    @MainActor
    func testClipboardChangeDuringDataReadIsDiscarded() throws {
        try withWatcher { watcher, source, _, received in
            watcher.start()
            source.copy([.png: try imageData(.png)])
            source.onDataRead = { source.count += 1; source.onDataRead = nil }
            watcher.check()
            XCTAssertTrue(received().isEmpty)
            watcher.check()
            XCTAssertEqual(received().count, 1)
        }
    }

    @MainActor
    func testInvalidImageIsNotWrittenAndValidTIFFFallbackWorks() throws {
        try withWatcher { watcher, source, folder, received in
            watcher.start()
            source.copy([.png: Data("invalid image".utf8)])
            watcher.check()
            XCTAssertTrue(received().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
            source.copy([.png: Data("invalid image".utf8), .tiff: try imageData(.tiff)])
            watcher.check()
            XCTAssertEqual(received().count, 1)
        }
    }

    @MainActor
    func testValidationRejectsEmptyOversizedAndMislabeledData() throws {
        XCTAssertNil(ClipboardWatcher.validatedPNG(Data(), type: .png))
        XCTAssertNil(ClipboardWatcher.validatedPNG(Data(repeating: 0, count: ClipboardWatcher.maximumDataBytes + 1), type: .png))
        XCTAssertNil(ClipboardWatcher.validatedPNG(try imageData(.jpeg), type: .png))
        XCTAssertNil(ClipboardWatcher.validatedPNG(try imageData(.png), type: .tiff))
        XCTAssertNil(ClipboardWatcher.validatedPNG(try imageData(.png), type: .string))
        XCTAssertNil(ClipboardWatcher.validatedPNG(try oversizedPNGHeader(), type: .png))
    }

    @MainActor
    func testStorageFailureDoesNotHangOrModifyClipboard() throws {
        try withWatcher { watcher, source, folder, received in
            try Data("blocking file".utf8).write(to: folder)
            watcher.start()
            let png = try imageData(.png)
            source.copy([.png: png])
            watcher.check()
            XCTAssertTrue(received().isEmpty)
            XCTAssertEqual(source.items.first?[.png], png)
            XCTAssertEqual(try Data(contentsOf: folder), Data("blocking file".utf8))
        }
    }

    @MainActor
    func testDistinctCopiesUseUniquePrivateFiles() throws {
        try withWatcher { watcher, source, folder, received in
            watcher.start()
            for _ in 0..<2 {
                source.copy([.png: try imageData(.png)])
                watcher.check()
            }
            XCTAssertEqual(Set(received()).count, 2)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
            for url in received() {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            }
        }
    }

    private func rasterBytes(_ image: CGImage) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return Data(bytes)
    }

    private func imageData(_ type: UTType) throws -> Data {
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Advertise too many pixels in a small PNG, without allocating a large bitmap.
    @MainActor
    private func oversizedPNGHeader() throws -> Data {
        var png = try imageData(.png)
        let dimension = UInt32(ClipboardWatcher.maximumPixelCount + 1)
        for n in 0..<4 { png[16 + n] = UInt8(truncatingIfNeeded: dimension >> (24 - 8 * n)) }
        var crc: UInt32 = 0xffffffff
        for byte in png[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        crc ^= 0xffffffff
        for n in 0..<4 { png[29 + n] = UInt8(truncatingIfNeeded: crc >> (24 - 8 * n)) }
        return png
    }
}

@MainActor
private final class FakeClipboard: ClipboardSource {
    private static var nextCount = 10_000
    var count: Int
    var items: [[NSPasteboard.PasteboardType: Data]] = []
    var countReads = 0
    var typeReads = 0
    var dataReads: [NSPasteboard.PasteboardType] = []
    var onTypesRead: (() -> Void)?
    var onDataRead: (() -> Void)?

    init() {
        Self.nextCount += 100
        count = Self.nextCount
    }

    var changeCount: Int { countReads += 1; return count }
    var itemTypes: [[NSPasteboard.PasteboardType]] {
        typeReads += 1
        let types = items.map { Array($0.keys) }
        onTypesRead?()
        return types
    }
    func data(forType type: NSPasteboard.PasteboardType, at index: Int) -> Data? {
        dataReads.append(type)
        let data = items[index][type]
        onDataRead?()
        return data
    }
    func copy(_ values: [NSPasteboard.PasteboardType: Data]) {
        count += 1
        items = [values]
    }
}
