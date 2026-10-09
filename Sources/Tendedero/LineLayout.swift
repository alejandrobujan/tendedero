import Foundation

enum Layout {
    static let panelHeight: CGFloat = 210
    static let ropeTop: CGFloat = 10
    static let spacing: CGFloat = 174
    static let cardWidth: CGFloat = 150
    static let pinAbove: CGFloat = 9.5
    static let edgePadding: CGFloat = 24

    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = max(0, min(1, x / width))
        return ropeTop + 4 * sag(width: width) * f * (1 - f)
    }

    static func x(index: Int, scrollOffset: CGFloat = 0) -> CGFloat {
        edgePadding + cardWidth / 2 + CGFloat(index) * spacing - scrollOffset
    }

    static func contentWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return edgePadding * 2 + cardWidth + CGFloat(count - 1) * spacing
    }

    static func maximumOffset(count: Int, width: CGFloat) -> CGFloat {
        max(0, contentWidth(count: count) - max(1, width))
    }

    /// A one-card buffer keeps entering views ready without decoding the
    /// entire month's history or constructing off-screen SwiftUI cards.
    static func visibleRange(count: Int, width: CGFloat, offset: CGFloat) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let first = max(0, Int(floor(max(0, offset) / spacing)) - 1)
        let last = min(count, Int(ceil((max(0, offset) + max(1, width)) / spacing)) + 1)
        return min(first, last)..<last
    }
}
