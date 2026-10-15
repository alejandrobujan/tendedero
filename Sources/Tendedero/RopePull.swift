import AppKit
import QuartzCore
import SwiftUI

/// Owns one gesture and its frozen set of photos. The full-screen overlay
/// is click-through; the original panel keeps receiving the mouse drag.
@MainActor
final class RopePull {
    enum Phase { case idle, dragging, returning, breaking }
    private(set) var phase: Phase = .idle
    var isActive: Bool { phase != .idle }
    var isDragging: Bool { phase == .dragging }
    var onFinish: ((Bool) -> Void)?

    private let line: Line
    private weak var panel: LinePanel?
    private var overlay: NSPanel?
    private var drawing: RopeDrawing?
    private var timer: Timer?
    private var started: CFTimeInterval = 0
    private var origin: CGPoint = .zero
    private var selected: Set<UUID> = []
    private var committed = false

    init(line: Line, panel: LinePanel) {
        self.line = line
        self.panel = panel
    }

    func canGrab(at screenPoint: CGPoint) -> Bool {
        guard !isActive, line.revealed, line.liveCount > 0,
              line.draggingID == nil, line.pressedID == nil,
              !line.items.contains(where: { $0.flying || $0.falling }),
              let panel else { return false }
        let p = CGPoint(x: screenPoint.x - panel.frame.minX, y: panel.frame.maxY - screenPoint.y)
        guard p.x >= 12, p.x <= panel.frame.width - 12,
              !line.hitRects.values.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(p) }) else { return false }
        return abs(p.y - Layout.ropeY(x: p.x, width: panel.frame.width)) <= 9
    }

    @discardableResult
    func begin(at screenPoint: CGPoint) -> Bool {
        guard canGrab(at: screenPoint), let panel, let screen = panel.screen else { return false }
        origin = screenPoint
        selected = Set(line.items.filter { !$0.falling }.map(\.id))
        committed = false
        let view = RopeDrawing(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.motion = RopeMotion(width: panel.frame.width, grabX: screenPoint.x - panel.frame.minX)
        view.topInset = screen.frame.maxY - panel.frame.maxY
        view.leftInset = panel.frame.minX - screen.frame.minX
        view.cards = line.items.enumerated().compactMap { index, item in
            let x = Layout.x(index: index, count: line.items.count, width: panel.frame.width,
                             visible: line.visibleCount, scroll: line.scroll)
            // Off-screen entries are cleared too, but need no animation layers.
            guard x > 0, x < panel.frame.width else { return nil }
            return RopeDrawing.Card(item: item, u: x / panel.frame.width,
                                    opacity: min(1, min(x, panel.frame.width - x) / 90))
        }
        let window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = view
        drawing = view
        overlay = window
        phase = .dragging
        line.ropeInteractionActive = true
        window.orderFrontRegardless()
        panel.ignoresMouseEvents = false
        panel.makeKey()
        panel.updateRopeCursor(at: screenPoint)
        view.needsDisplay = true
        return true
    }

    func drag(to screenPoint: CGPoint) {
        guard isDragging, let drawing else { return }
        drawing.motion.drag(by: CGSize(width: screenPoint.x - origin.x, height: origin.y - screenPoint.y))
        drawing.needsDisplay = true
        panel?.updateRopeCursor(at: screenPoint)
    }

    func release(cancelled: Bool = false) {
        guard isDragging, let drawing else { return }
        if drawing.motion.isArmed && !cancelled {
            let removed = line.discardForRope(selected)
            if !removed.isEmpty {
                committed = true
                drawing.cards.removeAll { !removed.contains($0.item.id) }
                drawing.prepareSlides()
                phase = .breaking
            } else {
                phase = .returning
            }
        } else {
            phase = .returning
        }
        panel?.resignKey()
        panel?.resetRopeCursor()
        drawing.phase = phase
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finish()
            return
        }
        started = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Screen/Space changes and quitting must never turn a cancelled drag
    /// into a clear. A committed clear only finishes its visual cleanup.
    func interrupt() {
        guard isActive else { return }
        finish()
    }

    private func tick() {
        guard let drawing else { finish(); return }
        drawing.time = CACurrentMediaTime() - started
        drawing.needsDisplay = true
        if phase == .returning {
            if drawing.time >= 0.85 { finish() }
        } else if phase == .breaking {
            if drawing.time >= drawing.duration { finish() }
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        overlay?.orderOut(nil)
        overlay = nil
        drawing = nil
        selected = []
        phase = .idle
        panel?.resignKey()
        panel?.resetRopeCursor()
        if committed && line.liveCount == 0 {
            // Do not flash a fresh, unbroken rope between the overlay fading
            // and AppDelegate hiding the empty line.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                line.revealed = false
                line.ropeInteractionActive = false
            }
        } else {
            line.ropeInteractionActive = false
        }
        onFinish?(committed)
    }
}

/// Draws the same small glass cards and metal clips as the resting line.
/// It has the whole display to work in, so falling photos reach the edge.
@MainActor
final class RopeDrawing: NSView {
    struct Card {
        let item: Pegged
        let u: CGFloat
        let opacity: CGFloat
        var slide: RopeMotion.Slide?
    }
    override var isFlipped: Bool { true }
    var motion = RopeMotion(width: 1, grabX: 0.5)
    var topInset: CGFloat = 0
    var leftInset: CGFloat = 0
    var cards: [Card] = []
    var phase: RopePull.Phase = .dragging
    var time: Double = 0
    private(set) var duration: Double = 2.2
    private var ropeFadeStart: Double = 1.2

    func prepareSlides() {
        let indices = cards.indices.sorted { abs(cards[$0].u - motion.grab) < abs(cards[$1].u - motion.grab) }
        for (rank, i) in indices.enumerated() { cards[i].slide = motion.slide(at: cards[i].u, rank: rank) }
        // Allow even the last card to travel beyond the bottom on tall displays.
        let lastSlide = cards.compactMap(\.slide).map { $0.delay + $0.duration }.max() ?? 0
        ropeFadeStart = lastSlide + 0.12
        duration = lastSlide + sqrt(Double(bounds.height + Layout.photoMaxHeight) / 850) + 0.35
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        let translation = NSAffineTransform()
        translation.translateX(by: leftInset, yBy: topInset)
        translation.concat()
        let breaking = phase == .breaking
        let fade = breaking ? min(1, max(0, 1 - (time - ropeFadeStart) / 0.18)) : 1
        let amount = phase == .returning ? RopeMotion.spring(time) : 1
        if breaking {
            rope(from: 0, to: max(0, motion.grab - 0.002), alpha: fade) { motion.brokenPoint(at: $0, left: true, time: time) }
            rope(from: min(1, motion.grab + 0.002), to: 1, alpha: fade) { motion.brokenPoint(at: $0, left: false, time: time) }
        } else {
            rope(from: 0, to: 1, alpha: 1) { motion.point(at: $0, amount: amount) }
        }
        if phase == .dragging && motion.fray > 0 { drawFray() }
        for card in cards {
            let pt: CGPoint
            let rotation: CGFloat
            if breaking, let slide = card.slide {
                let position = motion.position(of: slide, time: time)
                pt = position.point
                rotation = position.rotation
            } else {
                pt = motion.point(at: card.u, amount: amount)
                rotation = (card.u - motion.grab) * motion.pull * 0.025 * amount
            }
            if pt.y < bounds.height + Layout.photoMaxHeight {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.cgContext.setAlpha(card.opacity)
                drawCard(card.item, at: pt, rotation: rotation)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func rope(from a: CGFloat, to b: CGFloat, alpha: CGFloat, point: (CGFloat) -> CGPoint) {
        let path = NSBezierPath()
        let n = max(2, Int((b - a) * motion.width / 8))
        for i in 0...n {
            let p = point(a + (b - a) * CGFloat(i) / CGFloat(n))
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        NSColor(white: 0.55, alpha: alpha).setStroke()
        path.lineWidth = 1.3
        path.lineCapStyle = .round
        path.stroke()
    }

    private func drawFray() {
        let pt = motion.point(at: motion.grab), strain = motion.fray
        let path = NSBezierPath()
        for i in 0..<5 {
            let sign: CGFloat = i.isMultiple(of: 2) ? -1 : 1
            let spread = (2 + CGFloat(i) * 0.7) * strain
            path.move(to: CGPoint(x: pt.x - 9, y: pt.y - 4))
            path.curve(to: CGPoint(x: pt.x - 1, y: pt.y + 3 + sign * spread),
                       controlPoint1: CGPoint(x: pt.x - 5, y: pt.y + sign * spread),
                       controlPoint2: CGPoint(x: pt.x - 3, y: pt.y + sign * spread))
            path.move(to: CGPoint(x: pt.x + 9, y: pt.y - 4))
            path.line(to: CGPoint(x: pt.x + 1, y: pt.y + 2 - sign * spread))
        }
        path.lineWidth = 0.7
        NSColor(white: 0.5, alpha: strain).setStroke()
        path.stroke()
    }

    private func drawCard(_ item: Pegged, at point: CGPoint, rotation: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: point.x, yBy: point.y - Layout.pinAbove)
        transform.rotate(byDegrees: CGFloat(item.tilt) + rotation)
        transform.concat()
        let size = PeggedView.cardSize(for: item.thumb.size)
        let rect = CGRect(x: -size.width / 2, y: PeggedView.cardOffsetBelowTop, width: size.width, height: size.height)
        let frame = NSBezierPath(roundedRect: rect, xRadius: Frame.radius, yRadius: Frame.radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.set()
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        frame.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        let photo = rect.insetBy(dx: Frame.inset, dy: Frame.inset)
        NSBezierPath(roundedRect: photo, xRadius: Frame.radius - Frame.inset, yRadius: Frame.radius - Frame.inset).addClip()
        item.thumb.draw(in: photo, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.6).setStroke()
        frame.lineWidth = 0.75
        frame.stroke()
        let clip = NSBezierPath(roundedRect: CGRect(x: -4.5, y: 0, width: 9, height: 26), xRadius: 3.5, yRadius: 3.5)
        NSGradient(colors: [NSColor(white: 0.70, alpha: 1), NSColor(white: 0.93, alpha: 1), NSColor(white: 0.62, alpha: 1)])?.draw(in: clip, angle: 0)
        NSColor.white.withAlphaComponent(0.7).setStroke()
        clip.lineWidth = 0.6
        clip.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
