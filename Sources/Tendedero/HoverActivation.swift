import Foundation

/// Geometry for the optional, deliberate hover target beside the notch.
enum HoverActivation {
    static let sideWidth: CGFloat = 80

    static func regions(menuBar: CGRect, screen: CGRect, safeAreaTop: CGFloat,
                        left: CGRect?, right: CGRect?) -> [CGRect] {
        let band = menuBar.intersection(screen)
        guard !band.isNull, !band.isEmpty else { return [] }
        let candidates: [CGRect]
        if safeAreaTop > 0, let left, let right,
           !left.isEmpty, !right.isEmpty,
           left.maxX > screen.minX, right.minX < screen.maxX,
           left.maxX < right.minX,
           left.intersects(band), right.intersects(band) {
            candidates = [
                CGRect(x: left.maxX - sideWidth, y: band.minY, width: sideWidth, height: band.height),
                CGRect(x: right.minX, y: band.minY, width: sideWidth, height: band.height)
            ]
        } else {
            candidates = [CGRect(x: screen.midX - sideWidth, y: band.minY,
                                 width: sideWidth * 2, height: band.height)]
        }
        return candidates.map { $0.intersection(band) }.filter { !$0.isNull && !$0.isEmpty }
    }

    /// A dwell belongs to one region on one display. Jumping to another
    /// region or display starts a fresh dwell, even between polling ticks.
    struct Dwell {
        private var region: CGRect?
        private var display: UInt32?
        private var since: Date?

        mutating func reset() {
            region = nil
            display = nil
            since = nil
        }

        mutating func isReady(in region: CGRect, display: UInt32, at now: Date,
                              delay: TimeInterval) -> Bool {
            if self.region != region || self.display != display {
                self.region = region
                self.display = display
                since = now
            }
            return now.timeIntervalSince(since ?? now) >= delay
        }
    }
}
