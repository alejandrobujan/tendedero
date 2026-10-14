import Foundation

/// Image coordinates are pixels from the top left, independent of display scale.
enum CutAxis {
    case horizontal, vertical
}

struct CutBand: Equatable {
    let start: Int
    let end: Int

    var length: Int { end - start }

    init?(from first: Double, to last: Double, extent: Int) {
        guard first.isFinite, last.isFinite, extent > 1 else { return nil }
        let low = max(0, min(Double(extent), min(first, last)))
        let high = max(0, min(Double(extent), max(first, last)))
        guard high > low else { return nil }
        let start = Int(floor(low)), end = Int(ceil(high))
        guard end > start, end - start < extent else { return nil }
        self.start = start
        self.end = end
    }
}

/// A normalized RGBA frame. Sampling ignores alpha and the outer edges, where
/// scrollbars and shadows can move independently of the content.
struct CapturePixels {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init?(width: Int, height: Int, rgba: [UInt8]) {
        guard width > 0, height > 0, width <= 80_000_000 / height,
              rgba.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

enum ScrollMatch: Equatable {
    case unchanged
    /// How many new rows are visible below the previous frame.
    case append(Int)
    case noOverlap
}

enum ScrollAxis { case vertical, horizontal }

struct ScrollInsets: Equatable {
    var leading = 0
    var trailing = 0
}

struct ScrollAlignment {
    let result: ScrollMatch
    let insets: ScrollInsets
}

enum ScrollMatcher {
    static func match(previous: CapturePixels, next: CapturePixels,
                      axis: ScrollAxis = .vertical) -> ScrollMatch {
        align(previous: previous, next: next, axis: axis).result
    }

    /// Match the moving body, allowing a minority of rows to contain sticky
    /// chrome or animation. Pixel coordinates remain at their original scale.
    static func align(previous a: CapturePixels, next b: CapturePixels,
                      axis: ScrollAxis, insets known: ScrollInsets? = nil) -> ScrollAlignment {
        func answer(_ result: ScrollMatch, _ insets: ScrollInsets = ScrollInsets()) -> ScrollAlignment {
            ScrollAlignment(result: result, insets: insets)
        }
        guard a.width == b.width, a.height == b.height else { return answer(.noOverlap) }
        let extent = axis == .vertical ? a.height : a.width
        guard extent >= 48 else { return answer(.noOverlap) }
        let initial = known ?? stationaryEdges(a, b, axis: axis, shift: nil)
        if difference(a, b, axis: axis, shift: 0, insets: initial, columns: 64, rows: 48) <= 0.3 {
            return answer(.unchanged, initial)
        }
        let body = extent - initial.leading - initial.trailing
        let maxShift = body - max(24, body / 6)
        guard maxShift > 0 else { return answer(.noOverlap, initial) }
        var scores = [Double](repeating: .infinity, count: maxShift + 1)
        var best = 1
        for shift in 1...maxShift {
            scores[shift] = difference(a, b, axis: axis, shift: shift,
                                      insets: initial, columns: 32, rows: 24)
            if scores[shift] < scores[best] { best = shift }
        }
        guard scores[best] <= 2.5 else { return answer(.noOverlap, initial) }
        let candidates = (1...maxShift).filter { scores[$0] <= scores[best] + 0.15 }
        // Coarse samples can miss every text edge across several offsets.
        // Choose the detailed winner rather than merely checking the first tie.
        var detailedBest = Double.infinity
        for shift in candidates {
            let score = difference(a, b, axis: axis, shift: shift,
                                   insets: initial, columns: 96, rows: 64)
            if score < detailedBest { best = shift; detailedBest = score }
        }
        let insets = known ?? stationaryEdges(a, b, axis: axis, shift: best)
        let verifiedScore = difference(a, b, axis: axis, shift: best,
                                       insets: insets, columns: 96, rows: 64)
        guard extent - insets.leading - insets.trailing - best >= 24,
              verifiedScore <= 2.5 else {
            return answer(.noOverlap, initial)
        }
        // Sparse text and flat backgrounds can make nearby offsets look equal
        // in the coarse search. Verify plausible alternatives at the same
        // density as the winner before rejecting truly repeating content.
        for shift in candidates where abs(shift - best) > 2 {
            if difference(a, b, axis: axis, shift: shift, insets: insets,
                          columns: 96, rows: 64) <= verifiedScore + 0.15 {
                return answer(.noOverlap, initial)
            }
        }
        return answer(.append(best), insets)
    }

    private static func difference(_ a: CapturePixels, _ b: CapturePixels,
                                   axis: ScrollAxis, shift: Int, insets: ScrollInsets,
                                   columns: Int, rows: Int) -> Double {
        let extent = axis == .vertical ? a.height : a.width
        let overlap = extent - insets.leading - insets.trailing - shift
        guard overlap > 0 else { return .infinity }
        var scores: [Double] = []
        // Sample inside the overlap rather than at its seam. Fixed toolbars
        // at the outer edges then cannot dominate the search.
        let inset = overlap / 12
        let span = max(1, overlap - 2 * inset)
        for row in 0..<rows {
            let y = insets.leading + inset + row * (span - 1) / max(1, rows - 1)
            scores.append(rowDifference(a, b, axis: axis, aRow: y + shift, bRow: y, columns: columns))
        }
        scores.sort()
        let kept = max(1, scores.count * 3 / 4)
        let robust = scores.prefix(kept).reduce(0, +) / Double(kept)
        let mean = scores.reduce(0, +) / Double(scores.count)
        // Keep a small contribution from every row: dropping all text-line
        // edges would make neighboring offsets indistinguishable on white pages.
        return robust * 0.8 + mean * 0.2
    }

    private static func rowDifference(_ a: CapturePixels, _ b: CapturePixels,
                                      axis: ScrollAxis, aRow: Int, bRow: Int, columns: Int) -> Double {
        let width = axis == .vertical ? a.width : a.height
        let margin = max(1, width / 10)
        let span = max(1, width - margin * 2)
        var total = 0
        for column in 0..<columns {
            let x = min(width - 1, margin + column * (span - 1) / max(1, columns - 1))
            let ai = (axis == .vertical ? aRow * a.width + x : x * a.width + aRow) * 4
            let bi = (axis == .vertical ? bRow * b.width + x : x * b.width + bRow) * 4
            for channel in 0..<3 {
                total += min(32, abs(Int(a.rgba[ai + channel]) - Int(b.rgba[bi + channel])))
            }
        }
        return Double(total) / Double(columns * 3)
    }

    private static func stationaryEdges(_ a: CapturePixels, _ b: CapturePixels,
                                        axis: ScrollAxis, shift: Int?) -> ScrollInsets {
        let extent = axis == .vertical ? a.height : a.width
        func edge(trailing: Bool) -> Int {
            var length = 0
            var containsFixedDetail = false
            for offset in 0..<(extent / 4) {
                let row = trailing ? extent - 1 - offset : offset
                guard rowDifference(a, b, axis: axis, aRow: row, bRow: row, columns: 64) <= 1.2 else { break }
                length += 1
                if let shift {
                    let movedRow = trailing ? row - shift : row + shift
                    if movedRow >= 0, movedRow < extent,
                       rowDifference(a, b, axis: axis, aRow: movedRow, bRow: row, columns: 64) > 4 {
                        containsFixedDetail = true
                    }
                }
            }
            // Do not mistake an empty margin for a fixed interface element.
            return length >= 4 && (shift == nil || containsFixedDetail) ? length : 0
        }
        return ScrollInsets(leading: edge(trailing: false), trailing: edge(trailing: true))
    }
}
