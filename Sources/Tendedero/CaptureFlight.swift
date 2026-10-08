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

    private weak var overlay: Overlay?
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
    private var duration: CFTimeInterval = CaptureFlight.duration
    private var start: CFTimeInterval = 0
    private var completed = false
    private var completion: () -> Void = {}

    /// Keep burst captures from multiplying large decoded images. Further
    /// captures land directly using the small thumbnail already on the line.
    static let maxImagePixels = 1500
    static var canFly: Bool {
        overlays.values.reduce(0) { count, overlay in
            count + overlay.flights.filter { !$0.falling }.count
        } < 2
    }

    private static var overlays: [CGDirectDisplayID: Overlay] = [:]

    static func fly(image: CGImage, from: CGRect, to: CGRect, tilt: CGFloat, on screen: NSScreen,
                    completion: @escaping () -> Void) {
        guard canFly else { completion(); return }
        let flight = CaptureFlight(image: image, from: from, to: to, tilt: tilt, scale: screen.backingScaleFactor)
        flight.completion = completion
        add(flight, on: screen)
    }

    static func fall(image: CGImage, card: CGRect, tilt: CGFloat, on screen: NSScreen) {
        let flight = CaptureFlight(image: image, from: card, to: card, tilt: tilt, scale: screen.backingScaleFactor)
        flight.falling = true
        flight.duration = 0.55
        add(flight, on: screen)
    }

    private static func add(_ flight: CaptureFlight, on screen: NSScreen) {
        guard let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            flight.completion()
            return
        }
        let overlay = overlays[display] ?? Overlay(display: display, screen: screen)
        overlays[display] = overlay
        overlay.add(flight)
    }

    private init(image: CGImage, from: CGRect, to: CGRect, tilt: CGFloat, scale: CGFloat) {
        self.from = from
        self.to = to
        self.tilt = tilt

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
    }

    /// The top-center follows an arc (or falls 520 points). The diagonal
    /// encloses the card at every rotation; the margin includes clip/shadow.
    private var motionBounds: CGRect {
        let radius = max(hypot(from.width / 2, from.height), hypot(to.width / 2, to.height)) + 40
        let left = min(from.midX, to.midX) - radius
        let right = max(from.midX, to.midX) + radius
        let bottom = min(from.maxY, to.maxY) - radius - (falling ? 520 : 0)
        let top = max(from.maxY, to.maxY) + radius + (falling ? 0 : Self.arc)
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    /// Returns true once the layer, including its landing fade, is finished.
    private func tick(at now: CFTimeInterval) -> Bool {
        let elapsed = now - start
        let k = min(1, elapsed / duration)
        if falling { updateFall(k) } else { update(k) }
        if k >= 1, !completed {
            completed = true
            let done = completion
            completion = {}
            done()
        }
        guard completed else { return false }
        if falling { return true }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.opacity = Float(max(0, 1 - (elapsed - duration) / 0.16))
        CATransaction.commit()
        return elapsed >= duration + 0.16
    }

    /// A display owns one cropped window and one timer for all of its cards.
    /// Nothing is cached once the last card is gone, including AppKit's window.
    @MainActor
    private final class Overlay {
        let display: CGDirectDisplayID
        let screenFrame: CGRect
        let window: NSPanel
        let root = CALayer()
        var flights: [CaptureFlight] = []
        private var timer: Timer?

        init(display: CGDirectDisplayID, screen: NSScreen) {
            self.display = display
            screenFrame = screen.frame
            window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let host = NSView()
            host.wantsLayer = true
            host.layer = root
            root.contentsScale = screen.backingScaleFactor
            window.contentView = host
        }

        func add(_ flight: CaptureFlight) {
            flight.overlay = self
            flight.start = CACurrentMediaTime()
            flights.append(flight)
            root.addSublayer(flight.container)
            resize()
            redraw(at: flight.start)
            window.orderFrontRegardless()
            if timer == nil {
                let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
        }

        private func resize() {
            let bounds = flights.reduce(CGRect.null) { $0.union($1.motionBounds) }.intersection(screenFrame).integral
            guard !bounds.isNull, !bounds.isEmpty else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            window.setFrame(bounds, display: false)
            root.frame = CGRect(origin: .zero, size: bounds.size)
            CATransaction.commit()
        }

        private func redraw(at now: CFTimeInterval) {
            for flight in flights {
                if flight.falling { flight.update(1) }
                _ = flight.tick(at: now)
            }
        }

        private func tick() {
            let now = CACurrentMediaTime()
            // A completion may add another flight; iterate a snapshot and only
            // remove the finished cards so reentrant additions survive.
            let finished = flights.filter { $0.tick(at: now) }
            guard !finished.isEmpty else { return }
            for flight in finished {
                flight.photo.contents = nil
                flight.container.removeFromSuperlayer()
                flight.overlay = nil
            }
            flights.removeAll { flight in finished.contains { $0 === flight } }
            if flights.isEmpty {
                timer?.invalidate()
                timer = nil
                window.contentView = nil
                window.close()
                overlays[display] = nil
            } else {
                resize()
                redraw(at: now)
            }
        }
    }

    private func updateFall(_ raw: Double) {
        let e = CGFloat(raw * raw * raw)
        let origin = overlay?.window.frame.origin ?? .zero
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
        let k = CGFloat(Self.easeInOutCubic(raw))
        let chrome = Float(Self.smooth(Double(k), 0.35, 1))
        let origin = overlay?.window.frame.origin ?? .zero
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }

        let w = lerp(from.width, to.width), h = lerp(from.height, to.height)
        let topX = lerp(from.midX, to.midX) - origin.x
        let topY = lerp(from.maxY, to.maxY) - origin.y + sin(.pi * k) * Self.arc
        let inset = 4 * k
        let radius = lerp(0, 16)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        container.position = CGPoint(x: topX, y: topY)
        // SwiftUI tilts clockwise for positive angles; Core Animation the other way.
        container.setAffineTransform(CGAffineTransform(rotationAngle: -tilt * .pi / 180 * k))
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
