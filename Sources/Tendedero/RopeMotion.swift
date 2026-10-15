import Foundation

/// Geometry uses points measured down from the top of the line's panel.
/// Shared by live dragging, cancellation and the two broken rope ends.
struct RopeMotion {
    static let threshold: CGFloat = 92
    let width: CGFloat
    let grab: CGFloat
    var pull: CGFloat = 0
    var shift: CGFloat = 0

    init(width: CGFloat, grabX: CGFloat) {
        self.width = max(1, width)
        grab = min(0.999, max(0.001, grabX / max(1, width)))
    }

    var isArmed: Bool { pull >= Self.threshold }
    var fray: CGFloat { min(1, max(0, (pull / Self.threshold - 0.58) / 0.5)) }

    mutating func drag(by delta: CGSize) {
        let raw = max(0, delta.height), knee = Self.threshold * 0.7
        pull = min(Self.threshold * 1.65, raw <= knee ? raw : knee + (raw - knee) * 0.7)
        shift = min(width * 0.12, max(-width * 0.12, delta.width))
    }

    static func spring(_ time: Double) -> CGFloat {
        CGFloat(exp(-5.2 * time) * (cos(15 * time) + 5.2 / 15 * sin(15 * time)))
    }

    func point(at u: CGFloat, amount: CGFloat = 1) -> CGPoint {
        let f = min(1, max(0, u))
        let influence = f <= grab ? pow(f / grab, 1.13) : pow((1 - f) / (1 - grab), 1.13)
        return CGPoint(x: f * width + shift * influence * amount,
                       y: 10 + 4 * min(30, width * 0.018) * f * (1 - f) + pull * influence * amount)
    }

    func brokenPoint(at u: CGFloat, left: Bool, time: Double) -> CGPoint {
        let v = left ? u / grab : (1 - u) / (1 - grab)
        let original = point(at: u)
        let recoil = 20 * (1 - exp(-time * 12))
        let settle = 40 * (1 - exp(-time * 3.5))
        let flutter = 3.5 * sin(time * 20 - v * 4) * exp(-time * 4) * sin(v * .pi) * (1 - exp(-time * 12))
        return CGPoint(x: original.x + (left ? -1 : 1) * recoil * v * v,
                       y: original.y + settle * v * v + flutter)
    }

    struct Slide {
        let u: CGFloat
        let left: Bool
        let delay: Double
        let duration: Double
        let speed: CGFloat
    }

    func slide(at u: CGFloat, rank: Int) -> Slide {
        let a = point(at: u), b = point(at: grab)
        let distance = max(8, hypot(a.x - b.x, a.y - b.y))
        return Slide(u: u, left: u <= grab, delay: Double(rank) * 0.022,
                     duration: sqrt(2 * distance / 1800), speed: sqrt(2 * 1800 * distance))
    }

    func position(of slide: Slide, time: Double) -> (point: CGPoint, rotation: CGFloat) {
        let elapsed = max(0, time - slide.delay)
        let sign: CGFloat = slide.left ? -1 : 1
        if elapsed <= slide.duration {
            let progress = pow(elapsed / slide.duration, 2)
            let u = slide.u + (grab - slide.u) * progress
            return (brokenPoint(at: u, left: slide.left, time: time), sign * 6 * progress)
        }
        let departure = slide.delay + slide.duration
        let flight = CGFloat(time - departure)
        let start = brokenPoint(at: grab, left: slide.left, time: departure)
        let previous = brokenPoint(at: grab + sign * 0.006, left: slide.left, time: departure)
        let length = max(1, hypot(start.x - previous.x, start.y - previous.y))
        let vx = (start.x - previous.x) / length * slide.speed * 0.5
        let vy = (start.y - previous.y) / length * slide.speed * 0.65
        return (CGPoint(x: start.x + vx * flight,
                        y: start.y + vy * flight + 850 * flight * flight), sign * (6 + 36 * flight))
    }
}
