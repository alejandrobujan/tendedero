import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ClipboardSupport

@MainActor
final class ClipboardImageReaderTests: XCTestCase {
    private func board() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("ImageLineTests-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    private func picture(_ type: UTType = .png, width: Int = 12, height: Int = 7, orientation: Int = 1) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.7, blue: 0.5, alpha: type == .jpeg ? 1 : 0.6)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(context.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ImageLineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func imageItem(_ data: Data, type: NSPasteboard.PasteboardType = .png) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(data, forType: type)
        return item
    }

    func testDirectPNGPreservesBytesAndTransparency() async throws {
        let pb = board(); defer { pb.releaseGlobally() }
        let png = try picture()
        pb.writeObjects([imageItem(png)])
        let inputs = ClipboardImageReader.snapshot(pb)
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(ClipboardImageReader.png(from: inputs[0]), png)
    }

    func testFinderReadsRealFileInsteadOfItsIconAndPreservesOriginal() async throws {
        let pb = board(); defer { pb.releaseGlobally() }
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let png = try picture()
        let url = folder.appendingPathComponent("中文 图片.png")
        try png.write(to: url)
        let item = imageItem(try picture(width: 32, height: 32))
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(url.path, forType: .string)
        pb.writeObjects([item])
        let inputs = ClipboardImageReader.snapshot(pb)
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(ClipboardImageReader.png(from: inputs[0]), png)
        XCTAssertEqual(try Data(contentsOf: url), png)
    }

    func testMultipleFinderImagesAreImportedAndDuplicateURLsCollapsed() async throws {
        let pb = board(); defer { pb.releaseGlobally() }
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("one.png"), b = folder.appendingPathComponent("two.jpg")
        try picture().write(to: a); try picture(.jpeg).write(to: b)
        let items = [a,b,a].map { url -> NSPasteboardItem in
            let item = NSPasteboardItem(); item.setString(url.absoluteString, forType: .fileURL); return item
        }
        pb.writeObjects(items)
        let inputs = ClipboardImageReader.snapshot(pb)
        XCTAssertEqual(inputs.count, 2)
        XCTAssertTrue(inputs.allSatisfy { ClipboardImageReader.png(from: $0) != nil })
    }

    func testNonImageFileNeverFallsBackToItsPNGIcon() async throws {
        let pb = board(); defer { pb.releaseGlobally() }
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("document.txt")
        try Data("plain document".utf8).write(to: file)
        let item = imageItem(try picture()); item.setString(file.absoluteString, forType: .fileURL)
        pb.writeObjects([item])
        let inputs = ClipboardImageReader.snapshot(pb)
        XCTAssertEqual(inputs.count, 1)
        XCTAssertNil(ClipboardImageReader.png(from: inputs[0]))
    }

    func testCopiedFolderNeverImportsItsIcon() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(ClipboardImageReader.png(from: .file(folder)))
    }

    func testLegacyFinderFileListIsSupported() async throws {
        let pb = board(); defer { pb.releaseGlobally() }
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("picture.png"); try picture().write(to: file)
        pb.setPropertyList([file.path], forType: .init("NSFilenamesPboardType"))
        let inputs = ClipboardImageReader.snapshot(pb)
        XCTAssertEqual(inputs.count, 1)
        XCTAssertNotNil(ClipboardImageReader.png(from: inputs[0]))
    }

    func testTextAndOfficePreviewImagesAreIgnored() async throws {
        for type in [NSPasteboard.PasteboardType.string, .rtf, .rtfd, .html, .tabularText, .init("public.utf16-plain-text")] {
            let pb = board(); defer { pb.releaseGlobally() }
            let item = imageItem(try picture()); item.setString("text representation", forType: type)
            pb.writeObjects([item])
            XCTAssertTrue(ClipboardImageReader.snapshot(pb).isEmpty, type.rawValue)
        }
    }

    func testPrivateTransientAndOwnCopiesAreIgnored() async throws {
        for type in [ClipboardImageReader.ownCopyType, .init("org.nspasteboard.ConcealedType"),
                     .init("org.nspasteboard.TransientType"), .init("org.nspasteboard.AutoGeneratedType")] {
            let pb = board(); defer { pb.releaseGlobally() }
            let item = imageItem(try picture()); item.setString("1", forType: type)
            item.setString("file:///tmp/picture.png", forType: .fileURL)
            pb.writeObjects([item])
            XCTAssertTrue(ClipboardImageReader.snapshot(pb).isEmpty, type.rawValue)
        }
    }

    func testJPEGAndTIFFImageDataBecomeUsablePNG() async throws {
        for type in [UTType.jpeg, .tiff, .gif, .bmp] {
            let pb = board(); defer { pb.releaseGlobally() }
            pb.writeObjects([imageItem(try picture(type), type: .init(type.identifier))])
            let inputs = ClipboardImageReader.snapshot(pb)
            XCTAssertEqual(inputs.count, 1)
            let output = try XCTUnwrap(ClipboardImageReader.png(from: inputs[0]))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        }
    }

    func testJPEGOrientationIsApplied() async throws {
        let data = try picture(.jpeg, width: 12, height: 7, orientation: 6)
        let output = try XCTUnwrap(ClipboardImageReader.png(from: .data(data)))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: output))
        XCTAssertEqual(rep.pixelsWide, 7)
        XCTAssertEqual(rep.pixelsHigh, 12)
    }

    func testInvalidMissingAndNonLocalFilesAreRejected() async throws {
        XCTAssertNil(ClipboardImageReader.png(from: .data(Data("not an image".utf8))))
        XCTAssertNil(ClipboardImageReader.png(from: .data(Data())))
        XCTAssertNil(ClipboardImageReader.png(from: .file(URL(fileURLWithPath: "/nonexistent/ImageLine-test.png"))))
        XCTAssertNil(ClipboardImageReader.png(from: .file(URL(string: "https://example.com/image.png")!)))
    }

    func testOversizedFilesRejectedWithoutReadingTheirContents() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("large.png")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ClipboardImageReader.maxBytes + 1)); try handle.close()
        XCTAssertNil(ClipboardImageReader.png(from: .file(file)))
    }

    func testEmptyAndMalformedFileURLCopiesDoNotImportIcons() async throws {
        let pb = board(); defer { pb.releaseGlobally() }
        XCTAssertTrue(ClipboardImageReader.snapshot(pb).isEmpty)
        let item = imageItem(try picture()); item.setString("https://example.com/picture.png", forType: .fileURL)
        pb.writeObjects([item])
        XCTAssertTrue(ClipboardImageReader.snapshot(pb).isEmpty,
            "types=\(pb.types ?? []), URL=\(pb.string(forType: .fileURL) ?? "nil"), legacy=\(String(describing: pb.propertyList(forType: .init("NSFilenamesPboardType"))))")
    }

    private func pngWithText(_ png: Data, value: String) -> Data {
        let payload = Data("Comment\0\(value)".utf8)
        let typeAndData = Data("tEXt".utf8) + payload
        var crc: UInt32 = 0xffffffff
        for byte in typeAndData {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        }
        crc ^= 0xffffffff
        var length = UInt32(payload.count).bigEndian, checksum = crc.bigEndian
        let chunk = withUnsafeBytes(of: &length) { Data($0) } + typeAndData
            + withUnsafeBytes(of: &checksum) { Data($0) }
        // Insert after IHDR; it is ancillary metadata, not a pixel change.
        return png.prefix(33) + chunk + png.dropFirst(33)
    }

    func testFingerprintIgnoresPNGMetadataChanges() async throws {
        let original = try picture()
        let first = pngWithText(original, value: "first copy")
        let second = pngWithText(original, value: "second copy")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try XCTUnwrap(ClipboardImageReader.decode(.data(first))).fingerprint,
                       try XCTUnwrap(ClipboardImageReader.decode(.data(second))).fingerprint)
    }

    func testFingerprintSurvivesJPEGConversionAtDifferentTimes() async throws {
        let jpeg = try picture(.jpeg)
        let first = try XCTUnwrap(ClipboardImageReader.decode(.data(jpeg)))
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let second = try XCTUnwrap(ClipboardImageReader.decode(.data(jpeg)))
        let restored = try XCTUnwrap(ClipboardImageReader.decode(.data(first.png)))
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(first.fingerprint, restored.fingerprint)
    }

    func testPNGAndTIFFHaveSamePixelFingerprint() async throws {
        let png = try XCTUnwrap(ClipboardImageReader.decode(.data(picture(.png))))
        let tiff = try XCTUnwrap(ClipboardImageReader.decode(.data(picture(.tiff))))
        XCTAssertEqual(png.fingerprint, tiff.fingerprint)
    }

    func testChangedImageContentHasDifferentFingerprint() async throws {
        let first = try XCTUnwrap(ClipboardImageReader.decode(.data(picture(width: 12))))
        let changed = try XCTUnwrap(ClipboardImageReader.decode(.data(picture(width: 13))))
        XCTAssertNotEqual(first.fingerprint, changed.fingerprint)
    }
}
