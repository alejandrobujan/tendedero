import XCTest
#if !PORTABLE_TESTS
@testable import Tendedero
#endif

final class ImageGeometryTests: XCTestCase {
    func testBandAcceptsEitherDragDirection() {
        let forward = CutBand(from: 12, to: 37, extent: 100)
        let reverse = CutBand(from: 37, to: 12, extent: 100)
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward?.start, 12)
        XCTAssertEqual(forward?.length, 25)
    }

    func testBandClampsAndRoundsAtPixelEdges() {
        XCTAssertEqual(CutBand(from: -40, to: 12.2, extent: 100)?.start, 0)
        XCTAssertEqual(CutBand(from: -40, to: 12.2, extent: 100)?.end, 13)
        XCTAssertEqual(CutBand(from: 72.7, to: 140, extent: 100)?.start, 72)
        XCTAssertEqual(CutBand(from: 72.7, to: 140, extent: 100)?.end, 100)
    }

    func testBandRejectsEmptyWholeAndInvalidSelections() {
        XCTAssertNil(CutBand(from: 20, to: 20, extent: 100))
        XCTAssertNil(CutBand(from: 20.5, to: 20.5, extent: 100))
        XCTAssertNil(CutBand(from: -1, to: 101, extent: 100))
        XCTAssertNil(CutBand(from: .nan, to: 20, extent: 100))
        XCTAssertNil(CutBand(from: 20, to: .infinity, extent: 100))
        XCTAssertNil(CutBand(from: 0, to: 1, extent: 1))
    }

    func testInvalidPixelBuffersAreRejected() {
        XCTAssertNil(CapturePixels(width: 0, height: 96, rgba: []))
        XCTAssertNil(CapturePixels(width: 64, height: 96, rgba: []))
        XCTAssertNil(CapturePixels(width: Int.max, height: 96, rgba: []))
    }

    func testStationaryAndDownwardFrames() {
        let first = frame(top: 0)
        XCTAssertEqual(ScrollMatcher.match(previous: first, next: first), .unchanged)
        for shift in [1, 2, 13, 45, 72] {
            XCTAssertEqual(ScrollMatcher.match(previous: first, next: frame(top: shift)), .append(shift))
        }
    }

    func testSuccessiveJoinsAndPartialFinalScroll() {
        XCTAssertEqual(ScrollMatcher.match(previous: frame(top: 0), next: frame(top: 31)), .append(31))
        XCTAssertEqual(ScrollMatcher.match(previous: frame(top: 31), next: frame(top: 57)), .append(26))
        XCTAssertEqual(ScrollMatcher.match(previous: frame(top: 57), next: frame(top: 60)), .append(3))
    }

    func testBackwardSkippedAndResizedFramesAreRejected() {
        XCTAssertEqual(ScrollMatcher.match(previous: frame(top: 30), next: frame(top: 0)), .noOverlap)
        XCTAssertEqual(ScrollMatcher.match(previous: frame(top: 0), next: frame(top: 96)), .noOverlap)
        let resized = CapturePixels(width: 32, height: 96, rgba: Array(repeating: 0, count: 32 * 96 * 4))!
        XCTAssertEqual(ScrollMatcher.match(previous: frame(top: 0), next: resized), .noOverlap)
    }

    func testAnimationDoesNotDominateOverlap() {
        let clean = frame(top: 17)
        var bytes = clean.rgba
        for y in 8..<12 {
            for x in 8..<12 {
                let offset = (y * clean.width + x) * 4
                bytes[offset] = 255
                bytes[offset + 1] = 255
                bytes[offset + 2] = 255
            }
        }
        let animated = CapturePixels(width: clean.width, height: clean.height, rgba: bytes)!
        XCTAssertEqual(ScrollMatcher.match(previous: frame(top: 0), next: animated), .append(17))
    }

    func testAmbiguousRepeatingContentIsRejected() {
        func striped(top: Int) -> CapturePixels {
            var bytes: [UInt8] = []
            for y in 0..<96 {
                let value = UInt8(((y + top) % 12) * 20)
                for _ in 0..<64 { bytes += [value, value, value, 255] }
            }
            return CapturePixels(width: 64, height: 96, rgba: bytes)!
        }
        XCTAssertEqual(ScrollMatcher.match(previous: striped(top: 0), next: striped(top: 5)), .noOverlap)
    }

    func testTextLikeDocumentWithWhitespaceMatches() {
        func document(top: Int) -> CapturePixels {
            var bytes: [UInt8] = []
            for y in top..<(top + 96) {
                for x in 0..<64 {
                    let line = y / 16
                    let ink = y % 16 < 9 && x >= 6 && x < 58
                        && ((x * 13 + line * 7) % 11 < 6)
                    let value: UInt8 = ink ? 32 : 255
                    bytes += [value, value, value, 255]
                }
            }
            return CapturePixels(width: 64, height: 96, rgba: bytes)!
        }
        for shift in [3, 19, 41] {
            XCTAssertEqual(ScrollMatcher.match(previous: document(top: 0), next: document(top: shift)), .append(shift))
        }
    }

    func testStickyHeaderAndFooterDoNotPreventSlowScrolling() {
        for shift in [1, 5, 17, 40, 52] {
            let alignment = ScrollMatcher.align(previous: chromeFrame(top: 0), next: chromeFrame(top: shift), axis: .vertical)
            XCTAssertEqual(alignment.result, .append(shift))
            XCTAssertEqual(alignment.insets, ScrollInsets(leading: 12, trailing: 8))
        }
    }

    func testFrozenInsetsMatchSuccessiveFrames() {
        let insets = ScrollInsets(leading: 12, trailing: 8)
        for (top, shift) in [(17, 2), (19, 21), (40, 8)] {
            let alignment = ScrollMatcher.align(previous: chromeFrame(top: top), next: chromeFrame(top: top + shift),
                                                 axis: .vertical, insets: insets)
            XCTAssertEqual(alignment.result, .append(shift))
            XCTAssertEqual(alignment.insets, insets)
        }
    }

    func testHorizontalScrollingAndFixedSidebars() {
        func transpose(_ frame: CapturePixels) -> CapturePixels {
            var bytes = [UInt8](repeating: 0, count: frame.rgba.count)
            for y in 0..<frame.height {
                for x in 0..<frame.width {
                    for c in 0..<4 { bytes[(x * frame.height + y) * 4 + c] = frame.rgba[(y * frame.width + x) * 4 + c] }
                }
            }
            return CapturePixels(width: frame.height, height: frame.width, rgba: bytes)!
        }
        let first = transpose(chromeFrame(top: 0))
        XCTAssertEqual(ScrollMatcher.match(previous: first, next: first, axis: .horizontal), .unchanged)
        for shift in [3, 18, 43] {
            let alignment = ScrollMatcher.align(previous: first, next: transpose(chromeFrame(top: shift)), axis: .horizontal)
            XCTAssertEqual(alignment.result, .append(shift))
            XCTAssertEqual(alignment.insets, ScrollInsets(leading: 12, trailing: 8))
        }
        XCTAssertEqual(ScrollMatcher.match(previous: transpose(chromeFrame(top: 30)), next: first, axis: .horizontal), .noOverlap)
    }

    func testAnimationAcrossRowsAndSmallColorNoiseStillMatch() {
        let clean = chromeFrame(top: 13)
        var bytes = clean.rgba
        for y in 36..<46 {
            for x in 8..<54 {
                for c in 0..<3 { bytes[(y * clean.width + x) * 4 + c] = 255 }
            }
        }
        for y in 0..<clean.height {
            for x in 0..<clean.width {
                let i = (y * clean.width + x) * 4
                bytes[i] = bytes[i] < 255 ? bytes[i] + 1 : bytes[i]
            }
        }
        let next = CapturePixels(width: clean.width, height: clean.height, rgba: bytes)!
        XCTAssertEqual(ScrollMatcher.match(previous: chromeFrame(top: 0), next: next), .append(13))
    }

    func testSparseColouredSectionsMatchAnAutomaticScrollStep() {
        func document(top: Int) -> CapturePixels {
            let width = 256, height = 1_400
            var bytes = [UInt8]()
            bytes.reserveCapacity(width * height * 4)
            for y in top..<(top + height) {
                let section = y / 200
                let row = y % 200
                for x in 0..<width {
                    let ink = (30..<64).contains(row) && (10..<130).contains(x)
                        && (x + section * 7) % 9 < 4
                    bytes += ink ? [24, 24, 24, 255] : [
                        UInt8(180 + section * 17 % 70),
                        UInt8(180 + section * 31 % 70),
                        UInt8(180 + section * 43 % 70), 255,
                    ]
                }
            }
            return CapturePixels(width: width, height: height, rgba: bytes)!
        }
        XCTAssertEqual(ScrollMatcher.match(previous: document(top: 140), next: document(top: 420)), .append(280))
    }

    private func chromeFrame(top: Int) -> CapturePixels {
        let moving = frame(top: top)
        var bytes = moving.rgba
        for y in 0..<96 where y < 12 || y >= 88 {
            for x in 0..<64 {
                let i = (y * 64 + x) * 4
                bytes[i] = UInt8((y * 17 + x * 7) % 256)
                bytes[i + 1] = 90
                bytes[i + 2] = 180
            }
        }
        return CapturePixels(width: 64, height: 96, rgba: bytes)!
    }

    /// Stable textured document rows, independent of the viewport origin.
    private func frame(top: Int) -> CapturePixels {
        var bytes: [UInt8] = []
        for y in top..<(top + 96) {
            for x in 0..<64 {
                var seed = UInt64(y * 64 + x + 1)
                for _ in 0..<3 {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    bytes.append(UInt8(truncatingIfNeeded: seed >> 32))
                }
                bytes.append(255)
            }
        }
        return CapturePixels(width: 64, height: 96, rgba: bytes)!
    }

    static let allTests = [
        ("testSparseColouredSectionsMatchAnAutomaticScrollStep", testSparseColouredSectionsMatchAnAutomaticScrollStep),
        ("testBandAcceptsEitherDragDirection", testBandAcceptsEitherDragDirection),
        ("testBandClampsAndRoundsAtPixelEdges", testBandClampsAndRoundsAtPixelEdges),
        ("testBandRejectsEmptyWholeAndInvalidSelections", testBandRejectsEmptyWholeAndInvalidSelections),
        ("testInvalidPixelBuffersAreRejected", testInvalidPixelBuffersAreRejected),
        ("testStationaryAndDownwardFrames", testStationaryAndDownwardFrames),
        ("testSuccessiveJoinsAndPartialFinalScroll", testSuccessiveJoinsAndPartialFinalScroll),
        ("testBackwardSkippedAndResizedFramesAreRejected", testBackwardSkippedAndResizedFramesAreRejected),
        ("testAnimationDoesNotDominateOverlap", testAnimationDoesNotDominateOverlap),
        ("testAmbiguousRepeatingContentIsRejected", testAmbiguousRepeatingContentIsRejected),
        ("testTextLikeDocumentWithWhitespaceMatches", testTextLikeDocumentWithWhitespaceMatches),
        ("testStickyHeaderAndFooterDoNotPreventSlowScrolling", testStickyHeaderAndFooterDoNotPreventSlowScrolling),
        ("testFrozenInsetsMatchSuccessiveFrames", testFrozenInsetsMatchSuccessiveFrames),
        ("testHorizontalScrollingAndFixedSidebars", testHorizontalScrollingAndFixedSidebars),
        ("testAnimationAcrossRowsAndSmallColorNoiseStillMatch", testAnimationAcrossRowsAndSmallColorNoiseStillMatch),
    ]
}
