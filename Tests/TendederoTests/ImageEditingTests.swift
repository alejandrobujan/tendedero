import XCTest
import AppKit
import ImageIO
@testable import Tendedero

final class ImageEditingTests: XCTestCase {
    func testPalettePNGCanBeOpenedAndCutWithoutChangingColours() throws {
        let base = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let palette: [UInt8] = [220, 20, 40, 10, 200, 60]
        let space = try XCTUnwrap(palette.withUnsafeBufferPointer {
            CGColorSpace(indexedBaseSpace: base, last: 1, colorTable: $0.baseAddress!)
        })
        let provider = try XCTUnwrap(CGDataProvider(data: Data([0, 1, 1, 0, 0, 1, 1, 0]) as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 4, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 2, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("palette.png")
        try ImageEditing.png(image).write(to: url)
        let loaded = try XCTUnwrap(ImageEditing.load(url))
        let band = try XCTUnwrap(CutBand(from: 1, to: 3, extent: 4))
        let result = try XCTUnwrap(ImageEditing.cut(loaded, axis: .horizontal, band: band))
        XCTAssertEqual(result.colorSpace?.name, loaded.colorSpace?.baseColorSpace?.name)
        let before = try XCTUnwrap(ImageEditing.pixels(loaded)).rgba
        XCTAssertEqual(ImageEditing.pixels(result)?.rgba, Array(before[0..<8]) + Array(before[24..<32]))
    }

    func testCapturedSparseDocumentMatchesSmallManualStep() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "manual-scroll-document", withExtension: "png", subdirectory: "Fixtures"))
        let image = try XCTUnwrap(ImageEditing.load(url))
        let first = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: 1400)))
        let next = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 20, width: image.width, height: 1400)))
        XCTAssertEqual(ScrollMatcher.match(previous: try XCTUnwrap(ImageEditing.pixels(first)),
            next: try XCTUnwrap(ImageEditing.pixels(next))), .append(20))
    }

    func testCapturedSparseDocumentMatchesAutoScrollStep() throws {
        func pixels(_ name: String) throws -> CapturePixels {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
            return try XCTUnwrap(ImageEditing.pixels(try XCTUnwrap(ImageEditing.load(url))))
        }
        XCTAssertEqual(ScrollMatcher.match(previous: try pixels("auto-scroll-before"),
                                           next: try pixels("auto-scroll-after")), .append(280))
    }

    func testCutAndCropPreserveDisplayP3AndSixteenBitPrecision() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 16,
            bytesPerRow: 32, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0.93, 0.017, 0.41, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let source = try XCTUnwrap(context.makeImage())
        let band = try XCTUnwrap(CutBand(from: 1, to: 3, extent: 4))
        let cut = try XCTUnwrap(ImageEditing.cut(source, axis: .horizontal, band: band))
        let crop = try XCTUnwrap(ImageEditing.compactCrop(source, to: CGRect(x:0,y:0,width:4,height:2)))
        let joined = try XCTUnwrap(ImageEditing.join([crop, crop]))
        for result in [cut, crop, joined] {
            XCTAssertEqual(result.colorSpace?.name, source.colorSpace?.name)
            XCTAssertEqual(result.bitsPerComponent, 16)
            let data = try XCTUnwrap(result.dataProvider?.data) as Data
            let original = try XCTUnwrap(source.dataProvider?.data) as Data
            XCTAssertEqual(data, original.prefix(data.count))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("p3-sixteen-bit.png")
        try ImageEditing.png(cut).write(to: url)
        let reloaded = try XCTUnwrap(ImageEditing.load(url))
        XCTAssertEqual(reloaded.bitsPerComponent, 16)
        XCTAssertEqual(reloaded.colorSpace?.name, space.name)
    }

    func testHorizontalCutKeepsTopAndBottomInOrder() throws {
        let image = try fixture()
        let band = try XCTUnwrap(CutBand(from: 1, to: 3, extent: 4))
        let result = try XCTUnwrap(ImageEditing.cut(image, axis: .horizontal, band: band))
        XCTAssertEqual(result.width, 4)
        XCTAssertEqual(result.height, 2)
        let before = try XCTUnwrap(ImageEditing.pixels(image)).rgba
        let after = try XCTUnwrap(ImageEditing.pixels(result)).rgba
        XCTAssertEqual(after, Array(before[0..<16]) + Array(before[48..<64]))
    }

    func testVerticalCutKeepsLeftAndRightInOrder() throws {
        let image = try fixture()
        let band = try XCTUnwrap(CutBand(from: 1, to: 3, extent: 4))
        let result = try XCTUnwrap(ImageEditing.cut(image, axis: .vertical, band: band))
        XCTAssertEqual(result.width, 2)
        XCTAssertEqual(result.height, 4)
        let before = try XCTUnwrap(ImageEditing.pixels(image)).rgba
        let after = try XCTUnwrap(ImageEditing.pixels(result)).rgba
        var expected: [UInt8] = []
        for row in 0..<4 {
            expected += Array(before[(row * 16)..<(row * 16 + 4)])
            expected += Array(before[(row * 16 + 12)..<(row * 16 + 16)])
        }
        XCTAssertEqual(after, expected)
    }

    func testCutsAtImageEdgesLeaveValidImage() throws {
        let image = try fixture()
        for axis in [CutAxis.horizontal, .vertical] {
            for (start, end) in [(0.0, 1.0), (3.0, 4.0)] {
                let band = try XCTUnwrap(CutBand(from: start, to: end, extent: 4))
                let result = try XCTUnwrap(ImageEditing.cut(image, axis: axis, band: band))
                XCTAssertEqual(result.width * result.height, 12)
            }
        }
    }

    func testJoinMatchesOriginalPixelsWithoutDuplicatingOverlap() throws {
        let image = try fixture()
        let top = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: 4, height: 3)))
        let tail = try XCTUnwrap(ImageEditing.compactCrop(image, to: CGRect(x: 0, y: 3, width: 4, height: 1)))
        let result = try XCTUnwrap(ImageEditing.join([top, tail]))
        XCTAssertEqual(ImageEditing.pixels(result)?.rgba, ImageEditing.pixels(image)?.rgba)
    }

    func testTransparentPixelsSurviveCutAndPNGEncoding() throws {
        let image = try fixture(alpha: 128)
        let band = try XCTUnwrap(CutBand(from: 1, to: 3, extent: 4))
        let result = try XCTUnwrap(ImageEditing.cut(image, axis: .horizontal, band: band))
        let data = try ImageEditing.png(result)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(ImageEditing.pixels(result)?.rgba, ImageEditing.pixels(decoded)?.rgba)
        XCTAssertEqual(ImageEditing.pixels(decoded)?.rgba[3], 128)
    }

    func testHorizontalJoinKeepsLeftAndRightInOrder() throws {
        let image = try fixture()
        let left = try XCTUnwrap(ImageEditing.compactCrop(image, to: CGRect(x: 0, y: 0, width: 3, height: 4)))
        let right = try XCTUnwrap(ImageEditing.compactCrop(image, to: CGRect(x: 3, y: 0, width: 1, height: 4)))
        let result = try XCTUnwrap(ImageEditing.join([left, right], axis: .horizontal))
        XCTAssertEqual(ImageEditing.pixels(result)?.rgba, ImageEditing.pixels(image)?.rgba)
    }

    func testFixedHeaderAndFooterAppearOnceAfterJoining() throws {
        let image = try fixture()
        let initial = try XCTUnwrap(ImageEditing.compactCrop(image, to: CGRect(x: 0, y: 0, width: 4, height: 3)))
        let newBody = try XCTUnwrap(ImageEditing.compactCrop(image, to: CGRect(x: 0, y: 1, width: 4, height: 2)))
        let footer = try XCTUnwrap(ImageEditing.compactCrop(image, to: CGRect(x: 0, y: 3, width: 4, height: 1)))
        let result = try XCTUnwrap(ImageEditing.join([initial, newBody, footer]))
        let pixels = try XCTUnwrap(ImageEditing.pixels(image)).rgba
        let expected = Array(pixels[0..<48]) + Array(pixels[16..<48]) + Array(pixels[48..<64])
        XCTAssertEqual(result.height, 6)
        XCTAssertEqual(ImageEditing.pixels(result)?.rgba, expected)
    }

    func testAnnotationUsesTopLeftImageCoordinates() throws {
        let bytes = [UInt8](repeating: 255, count: 64 * 64 * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 64 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let result = try XCTUnwrap(ImageEditing.annotate(image, from: CGPoint(x: 8, y: 8),
            to: CGPoint(x: 24, y: 24), rectangle: true,
            color: CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [1, 0, 0, 1])!))
        let pixels = try XCTUnwrap(ImageEditing.pixels(result)).rgba
        let topEdge = (8 * 64 + 16) * 4
        XCTAssertEqual(Array(pixels[topEdge..<(topEdge + 4)]), [255, 0, 0, 255])
        let bottom = (55 * 64 + 16) * 4
        XCTAssertEqual(Array(pixels[bottom..<(bottom + 4)]), [255, 255, 255, 255])
    }

    func testInvalidSizesAndMismatchedWidthsAreRejected() throws {
        XCTAssertFalse(ImageEditing.validSize(width: 0, height: 4))
        XCTAssertFalse(ImageEditing.validSize(width: 10_000, height: 10_000))
        XCTAssertFalse(ImageEditing.validSize(width: Int.max, height: 1))
        XCTAssertNil(ImageEditing.join([]))
        let image = try fixture()
        let narrow = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: 2, height: 4)))
        XCTAssertNil(ImageEditing.join([image, narrow]))
    }

    private func fixture(alpha: UInt8 = 255) throws -> CGImage {
        var bytes: [UInt8] = []
        for y in 0..<4 {
            for x in 0..<4 { bytes += [UInt8(y * 24), UInt8(x * 24), 0, alpha] }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 16, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
