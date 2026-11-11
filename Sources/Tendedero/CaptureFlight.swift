import AppKit
import QuartzCore

/// Reads where on screen a screenshot was taken. macOS stores the captured
/// area on the file, in global points with the origin at the top left of
/// the main display. Returned in AppKit screen coordinates.
func captureRect(of url: URL) -> CGRect? {
    let name = "com.apple.metadata:kMDItemScreenCaptureGlobalRect"
    let data: Data? = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return nil }
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = Data(count: size)
        let read = buffer.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        return read == size ? buffer : nil
    }
    guard let data,
          let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [NSNumber],
          values.count == 4, let main = NSScreen.screens.first else { return nil }
    let x = CGFloat(truncating: values[0]), y = CGFloat(truncating: values[1])
    let w = CGFloat(truncating: values[2]), h = CGFloat(truncating: values[3])
    guard w > 2, h > 2 else { return nil }
    return CGRect(x: x, y: main.frame.maxY - y - h, width: w, height: h)
}

/// The capture lifting off the screen and flying up to the line. It turns
/// into the hanging card on the way: it shrinks, tilts into place and grows
/// its glass frame and clip, so there is nothing left to change on landing.
@MainActor
final class CaptureFlight {
    static let duration: CFTimeInterval = 0.65
    /// How high the gentle arc rises halfway, in points.
    private static let arc: CGFloat = 30

    private let window: NSWindow
    private let container = CALayer()
    private let glass = CALayer()
    private let edge = CAGradientLayer()
    private let edgeMask = CAShapeLayer()
    private let photo = CALayer()
    private let clip = CAGradientLayer()

    private let from: CGRect
    private let to: CGRect
    private let tilt: CGFloat
    private var falling = false
    /// Which way a card knocked off its clip flies, or nil for a plain fall.
    private var knockDirection: CGFloat?
    /// Speeding up all the way, to strike what is already on the clip.
    private var strikes = false
    /// The turn a returning card starts from, in degrees, as it left the line.
    private var startAngle: CGFloat = 0
    /// Coming back into view from where it fell, rather than lifting off.
    private var returning = false
    private var duration: CFTimeInterval = CaptureFlight.duration
    private var start: CFTimeInterval = 0
    private var timer: Timer?
    private var completion: () -> Void = {}

    private static var current: [CaptureFlight] = []

    /// Captures flying to the line right now. Each one holds a large image,
    /// so in a burst of captures only a couple fly and the rest drop in.
    static var flightsInProgress: Int { current.filter { !$0.falling }.count }

    /// - Parameters:
    ///   - from: the captured area, in screen coordinates.
    ///   - to: the card's frame on the line, in screen coordinates, unrotated.
    ///   - tilt: the card's resting tilt in degrees, clockwise, as SwiftUI uses.
    ///   - strikes: speed up all the way instead of settling in, for a card
    ///     that knocks another off its clip as it lands.
    static func fly(image: CGImage, from: CGRect, to: CGRect, tilt: CGFloat, strikes: Bool = false, on screen: NSScreen,
                    completion: @escaping () -> Void) {
        let flight = CaptureFlight(image: image, from: from, to: to, tilt: tilt, screen: screen)
        flight.strikes = strikes
        if strikes { flight.duration = 0.5 }
        current.append(flight)
        flight.completion = { [weak flight] in
            completion()
            current.removeAll { $0 === flight }
        }
        flight.run()
    }

    /// A discarded card falling off the line, drawn over the whole screen so
    /// it is never cut by the line's strip. Same motion as the app always had:
    /// 520 points down, tilting further, fading, 0.55 s ease in.
    static func fall(image: CGImage, card: CGRect, tilt: CGFloat, pinned: Bool = false, on screen: NSScreen) {
        let flight = CaptureFlight(image: image, from: card, to: card, tilt: tilt, screen: screen)
        flight.falling = true
        // A pinned photo falls with its space grey clip, as it hung.
        if pinned {
            flight.clip.colors = [NSColor(white: 0.30, alpha: 1).cgColor, NSColor(white: 0.47, alpha: 1).cgColor,
                                  NSColor(white: 0.38, alpha: 1).cgColor, NSColor(white: 0.24, alpha: 1).cgColor]
            flight.clip.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
        }
        flight.duration = 0.55
        current.append(flight)
        flight.completion = { [weak flight] in current.removeAll { $0 === flight } }
        flight.run()
    }

    /// A card coming back the way it fell, to strike what took its place.
    /// - Parameter direction: which way it fell, 1 to the right, -1 the left.
    static func comeBack(image: CGImage, to card: CGRect, tilt: CGFloat, direction: CGFloat, on screen: NSScreen,
                         completion: @escaping () -> Void) {
        let start = card.offsetBy(dx: direction * Self.knockAlong, dy: -Self.knockDrop)
        let flight = CaptureFlight(image: image, from: start, to: card, tilt: tilt, screen: screen)
        flight.strikes = true
        flight.returning = true
        flight.startAngle = tilt + direction * Self.knockTurn
        flight.duration = 0.5
        current.append(flight)
        flight.completion = { [weak flight] in
            completion()
            current.removeAll { $0 === flight }
        }
        flight.run()
    }

    /// How far a knocked card travels: the path `comeBack` retraces.
    private static let knockAlong: CGFloat = 110
    private static let knockDrop: CGFloat = 570
    private static let knockTurn: CGFloat = 46

    /// A card struck by the one replacing it: it leaves its clip behind, flies
    /// on the way it was hit and drops, passing behind the line's cards, so
    /// the one that took its place is never covered.
    /// - Parameters:
    ///   - direction: 1 if it was hit towards the right, -1 the left.
    ///   - line: the window the line's cards are in.
    ///   - greyed: drained of colour, to tell it from a replacement that may
    ///     look just the same.
    static func knock(image: CGImage, card: CGRect, tilt: CGFloat, direction: CGFloat, greyed: Bool = false,
                      behind line: NSWindow, on screen: NSScreen) {
        let shown = greyed ? Self.grey(image) ?? image : image
        let flight = CaptureFlight(image: shown, from: card, to: card, tilt: tilt, screen: screen)
        flight.falling = true
        flight.knockDirection = direction
        flight.clip.isHidden = true
        flight.duration = 0.6
        flight.window.level = line.level
        current.append(flight)
        flight.completion = { [weak flight] in current.removeAll { $0 === flight } }
        flight.run(below: line.windowNumber)
    }

    private static func grey(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private init(image: CGImage, from: CGRect, to: CGRect, tilt: CGFloat, screen: NSScreen) {
        self.from = from
        self.to = to
        self.tilt = tilt
        window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        window.contentView = host
        let scale = screen.backingScaleFactor

        container.anchorPoint = CGPoint(x: 0.5, y: 1)   // the card's top center
        container.shadowColor = NSColor.black.cgColor
        container.shadowOpacity = 0.24
        container.shadowRadius = 10
        container.shadowOffset = CGSize(width: 0, height: -5)

        glass.backgroundColor = NSColor(white: 0.97, alpha: 0.72).cgColor
        edge.colors = [NSColor(white: 1, alpha: 0.9).cgColor, NSColor(white: 1, alpha: 0.25).cgColor]
        edge.startPoint = CGPoint(x: 0.5, y: 1); edge.endPoint = CGPoint(x: 0.5, y: 0)
        edgeMask.fillColor = nil
        edgeMask.strokeColor = NSColor.black.cgColor
        edgeMask.lineWidth = 1.5
        edge.mask = edgeMask

        photo.contents = image
        photo.contentsGravity = .resizeAspectFill
        photo.masksToBounds = true
        photo.contentsScale = scale

        clip.colors = [NSColor(white: 0.70, alpha: 1).cgColor, NSColor(white: 0.93, alpha: 1).cgColor,
                       NSColor(white: 0.82, alpha: 1).cgColor, NSColor(white: 0.62, alpha: 1).cgColor]
        clip.locations = [0, 0.35, 0.65, 1]
        clip.startPoint = CGPoint(x: 0, y: 0.5); clip.endPoint = CGPoint(x: 1, y: 0.5)
        clip.cornerRadius = 3.5
        clip.borderColor = NSColor(white: 1, alpha: 0.7).cgColor
        clip.borderWidth = 0.6

        for layer in [container, glass, edge, photo, clip] as [CALayer] { layer.contentsScale = scale }
        container.addSublayer(glass)
        container.addSublayer(photo)
        container.addSublayer(edge)
        container.addSublayer(clip)
        host.layer?.addSublayer(container)
    }

    private func run(below other: Int? = nil) {
        if falling { update(1); updateFall(0) } else { update(0) }
        if let other {
            window.order(.below, relativeTo: other)
        } else {
            window.orderFrontRegardless()
        }
        start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let k = min(1, (CACurrentMediaTime() - start) / duration)
        if falling { updateFall(k) } else { update(k) }
        guard k >= 1 else { return }
        timer?.invalidate()
        timer = nil
        completion()
        if falling {
            window.orderOut(nil)
            return
        }
        // The real card fades in underneath; this one fades out over it. A card
        // that struck goes at once, so it never hides the real one swinging.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = strikes ? 0.04 : 0.16
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            MainActor.assumeIsolated { window.orderOut(nil) }
        })
    }

    private func updateKnock(_ raw: Double, direction: CGFloat) {
        let t = CGFloat(raw)
        let origin = window.frame.origin
        // Moving from the first frame: thrown along, up a touch, then gravity.
        let along = direction * Self.knockAlong * (1 - (1 - t) * (1 - t))
        let height = 130 * t - (Self.knockDrop + 130) * t * t
        // Thrown to the right, it turns clockwise; Core Animation counts the other way.
        let angle = tilt + direction * Self.knockTurn * t
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.position = CGPoint(x: to.midX - origin.x + along, y: to.maxY - origin.y + height)
        container.setAffineTransform(CGAffineTransform(rotationAngle: -angle * .pi / 180))
        container.opacity = Float(1 - Self.smooth(raw, 0.55, 1))
        CATransaction.commit()
    }

    private func updateFall(_ raw: Double) {
        if let knockDirection {
            updateKnock(raw, direction: knockDirection)
            return
        }
        let e = CGFloat(raw * raw * raw)
        let origin = window.frame.origin
        let angle = tilt + (tilt * 7 + 20) * e
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.position = CGPoint(x: to.midX - origin.x, y: to.maxY - origin.y - 520 * e)
        container.setAffineTransform(CGAffineTransform(rotationAngle: -angle * .pi / 180))
        container.opacity = Float(1 - e)
        CATransaction.commit()
    }

    private static func easeInOutCubic(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    private static func smooth(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    private func update(_ raw: Double) {
        let k = CGFloat(strikes ? pow(raw, 2.6) : Self.easeInOutCubic(raw))
        let chrome = returning ? 1 : Float(Self.smooth(Double(k), 0.35, 1))
        let origin = window.frame.origin
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }

        let w = lerp(from.width, to.width), h = lerp(from.height, to.height)
        let topX = lerp(from.midX, to.midX) - origin.x
        let topY = lerp(from.maxY, to.maxY) - origin.y + sin(.pi * k) * Self.arc
        let inset = returning ? 4 : 4 * k
        let radius = returning ? 16 : lerp(0, 16)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        container.position = CGPoint(x: topX, y: topY)
        // SwiftUI tilts clockwise for positive angles; Core Animation the other way.
        let angle = returning ? startAngle + (tilt - startAngle) * k : tilt * k
        container.setAffineTransform(CGAffineTransform(rotationAngle: -angle * .pi / 180))
        if returning { container.opacity = Float(Self.smooth(raw, 0, 0.3)) }
        container.shadowPath = CGPath(roundedRect: container.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)

        glass.frame = container.bounds
        glass.cornerRadius = radius
        glass.opacity = chrome
        edge.frame = container.bounds
        edgeMask.path = CGPath(roundedRect: container.bounds.insetBy(dx: 0.75, dy: 0.75),
                               cornerWidth: max(0, radius - 0.75), cornerHeight: max(0, radius - 0.75), transform: nil)
        edge.opacity = chrome
        photo.frame = container.bounds.insetBy(dx: inset, dy: inset)
        photo.cornerRadius = max(0, radius - inset)
        // The clip grips the top edge: 26 points tall, 12 of them over the card.
        clip.frame = CGRect(x: w / 2 - 4.5, y: h - 12, width: 9, height: 26)
        clip.opacity = chrome
        CATransaction.commit()
    }
}
