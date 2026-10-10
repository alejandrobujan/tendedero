import AppKit
import CoreImage

private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
    max(lo, min(hi, v))
}

// MARK: - Viewport

/// Clips the canvas and moves it: pinch or ⌘-scroll zooms around the
/// pointer, scrolling pans once the image is bigger than the view.
final class Viewport: NSView {
    let canvas: CanvasView
    let fitFrame: NSRect
    let naturalWidth: CGFloat
    var onZoom: (Int) -> Void = { _ in }

    init(frame: NSRect, canvas: CanvasView, fitFrame: NSRect, naturalWidth: CGFloat) {
        self.canvas = canvas
        self.fitFrame = fitFrame
        self.naturalWidth = naturalWidth
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(canvas)
        canvas.frame = fitFrame
        canvas.onPan = { [weak self] origin in self?.move(to: origin) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A click on the backdrop around the image lets go of what is
    /// selected or being typed.
    override func mouseDown(with event: NSEvent) { canvas.clickedOutside() }

    override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        if event.modifierFlags.contains(.command) {
            let dy = precise ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            zoom(to: canvas.frame.width * exp(dy * 0.01), at: convert(event.locationInWindow, from: nil))
            return
        }
        let k: CGFloat = precise ? 1 : 12
        move(to: NSPoint(x: canvas.frame.minX + event.scrollingDeltaX * k,
                         y: canvas.frame.minY - event.scrollingDeltaY * k))
    }

    override func magnify(with event: NSEvent) {
        zoom(to: canvas.frame.width * (1 + event.magnification), at: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        if abs(canvas.frame.width - fitFrame.width) > 1 {
            fit()
        } else {
            zoom(to: max(naturalWidth, fitFrame.width * 2), at: convert(event.locationInWindow, from: nil))
        }
    }

    func zoomStep(in zoomIn: Bool) {
        zoom(to: canvas.frame.width * (zoomIn ? 1.25 : 0.8), at: pointerOrCenter)
    }

    func fit() {
        canvas.frame = fitFrame
        report()
    }

    func actualSize() { zoom(to: naturalWidth, at: pointerOrCenter) }

    private var pointerOrCenter: NSPoint {
        if let w = window {
            let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
            if canvas.frame.contains(p) { return p }
        }
        return NSPoint(x: canvas.frame.midX, y: canvas.frame.midY)
    }

    func zoom(to width: CGFloat, at anchor: NSPoint) {
        let w = clamp(width, fitFrame.width * 0.5, max(naturalWidth * 6, fitFrame.width))
        let old = canvas.frame
        let k = w / old.width
        canvas.frame = clamped(NSRect(x: anchor.x - (anchor.x - old.minX) * k,
                                      y: anchor.y - (anchor.y - old.minY) * k,
                                      width: w, height: old.height * k))
        report()
    }

    func move(to origin: NSPoint) {
        canvas.frame = clamped(NSRect(origin: origin, size: canvas.frame.size))
    }

    private func report() {
        onZoom(Int((canvas.frame.width / naturalWidth * 100).rounded()))
    }

    /// A smaller image stays inside the view; a bigger one covers it
    /// without gaps at the edges.
    private func clamped(_ f: NSRect) -> NSRect {
        func axis(_ o: CGFloat, _ length: CGFloat, _ room: CGFloat) -> CGFloat {
            length <= room ? clamp(o, 0, room - length) : clamp(o, room - length, 0)
        }
        return NSRect(x: axis(f.minX, f.width, bounds.width).rounded(),
                      y: axis(f.minY, f.height, bounds.height).rounded(),
                      width: f.width, height: f.height)
    }
}

// MARK: - Canvas

/// The image plus every mark on it. See the architecture note at the top
/// of Annotate.swift.
@MainActor
final class CanvasView: NSView, NSTextViewDelegate {
    struct Style {
        var color: NSColor
        var lineSize: Int
        var textSize: Int
    }

    /// One annotation, in image pixels.
    struct Mark: Equatable {
        enum Kind: String {
            case rect, ellipse, arrow, pen, text, textBox, mosaic, blur

            var usesColor: Bool { !isBrush }
            var isText: Bool { self == .text || self == .textBox }
            var isBrush: Bool { self == .mosaic || self == .blur }
            var isFreehand: Bool { self == .pen || isBrush }
        }

        var id = UUID()
        var kind: Kind
        /// Rectangle and ellipse: two opposite corners. Arrow: tail, tip.
        /// Freehand: the pointer samples. Text: the top-left of the text.
        var points: [CGPoint]
        var color: NSColor
        /// Stroke or brush width.
        var width: CGFloat = 0
        var fontSize: CGFloat = 0
        var text = ""
    }

    /// The size scales, in on-screen points at the opening zoom.
    static let sizeCount = 5
    static let linePoints: [CGFloat] = [2, 4, 6, 9, 14]
    static let brushPoints: [CGFloat] = [14, 24, 36, 52, 72]
    static let fontPoints: [CGFloat] = [14, 20, 28, 40, 56]

    var tool: Annotate.Tool = .rect {
        didSet {
            finishEditing()
            if tool != .select { selectedID = nil }
            updateCursor()
        }
    }

    var style = Style(color: .systemRed, lineSize: 1, textSize: 1)

    var onKey: (NSEvent) -> Bool = { _ in false }
    /// Marks, selection, editing or history changed.
    var onChange: () -> Void = {}
    /// Space-drag asks the viewport to move the canvas here.
    var onPan: (NSPoint) -> Void = { _ in }

    private var base: CGImage!
    private var ci: CIContext!
    private var space: CGColorSpace!
    /// Image pixels per on-screen point when the editor opened.
    private var unit: CGFloat = 1
    private var filtered: [Mark.Kind: CGImage] = [:]

    private var marks: [Mark] = [] { didSet { overlay.needsDisplay = true } }
    private var undoStack: [[Mark]] = []
    private var redoStack: [[Mark]] = []
    private let maxUndo = 100

    private var selectedID: UUID? { didSet { if selectedID != oldValue { overlay.needsDisplay = true } } }
    /// The mark being drawn, before it joins the list.
    private var draft: Mark? { didSet { overlay.needsDisplay = true } }

    private enum Handle: Equatable {
        /// A corner or edge of the frame: -1, 0 or 1 on each axis.
        case frame(Int, Int)
        /// An end of an arrow.
        case point(Int)
    }

    private enum Drag {
        case draw(start: CGPoint)
        case move(id: UUID, original: Mark, start: CGPoint, moved: Bool, editOnClick: Bool)
        case resize(id: UUID, handle: Handle, original: Mark, frame: CGRect, moved: Bool)
        case pan(start: NSPoint, origin: NSPoint)
    }
    private var drag: Drag?
    private var samples: [CGPoint] = []
    private var lastPointer: CGPoint = .zero
    private var spaceHeld = false

    private var editor: EditorTextView?
    /// The text mark being typed; the list keeps the version from before.
    private var editing: Mark?
    private var editingIsNew = false

    private let imageView = ImageView()
    private let overlay = Overlay()
    private var cursors: [CGFloat: NSCursor] = [:]
    private var tracking: NSTrackingArea?

    /// The mark the size and color controls act on.
    var focus: Mark? { editing ?? selected }
    var isEditingText: Bool { editor != nil }
    var canUndo: Bool { !undoStack.isEmpty || editor != nil }
    var canRedo: Bool { !redoStack.isEmpty && editor == nil }
    var isDirty: Bool { !marks.isEmpty || !(editor?.string.isEmpty ?? true) }

    private var selected: Mark? { selectedID.flatMap { id in marks.first { $0.id == id } } }

    override var acceptsFirstResponder: Bool { true }

    /// On-screen points per image pixel, at the current zoom.
    private var scale: CGFloat { bounds.width / CGFloat(base.width) }
    private var imageRect: CGRect { CGRect(x: 0, y: 0, width: base.width, height: base.height) }

    func configure(base: CGImage, ci: CIContext) {
        self.base = base
        self.ci = ci
        let rgb = base.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        space = rgb ?? CGColorSpace(name: CGColorSpace.sRGB)!
        unit = CGFloat(base.width) / bounds.width

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // A hairline and a shadow, so a dark screenshot still has an edge on
        // the dark backdrop.
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.55)
            s.shadowBlurRadius = 24
            s.shadowOffset = NSSize(width: 0, height: -6)
            return s
        }()

        for v in [imageView, overlay] as [NSView] {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }
        imageView.image = base
        overlay.drawer = { [weak self] ctx in self?.drawOverlay(ctx) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        // The text view is laid out for one zoom; set the text down first.
        if changed { finishEditing() }
        super.setFrameSize(newSize)
        if changed { overlay.needsDisplay = true }
    }

    // MARK: Geometry

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let v = convert(event.locationInWindow, from: nil)
        return CGPoint(x: v.x / scale, y: v.y / scale)
    }

    private func viewPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale, y: p.y * scale) }

    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
    }

    private func linePixels(_ i: Int) -> CGFloat { Self.linePoints[i] * unit }
    private func brushPixels(_ i: Int) -> CGFloat { Self.brushPoints[i] * unit }
    private func fontPixels(_ i: Int) -> CGFloat { Self.fontPoints[i] * unit }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Shift makes squares and circles, and snaps lines to 45 degrees.
    private static func constrained(_ a: CGPoint, _ b: CGPoint, square: Bool) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        if square {
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side))
        }
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
    }

    /// A smooth path through the pointer samples: quadratic curves between
    /// midpoints, so fast strokes do not turn into polygons.
    private static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 1 else {
            // A single click still leaves a round dot.
            path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
            return path
        }
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            path.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    /// A filled arrow with a slightly tapered shaft and a solid head.
    private static func arrowPath(from a: CGPoint, to b: CGPoint, width w: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return path }
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux
        let head = min(length * 0.65, max(w * 4.2, 10))
        let headHalf = head * 0.5
        let neckHalf = w * 0.6
        let tailHalf = w * 0.25
        let neck = CGPoint(x: b.x - ux * head * 0.82, y: b.y - uy * head * 0.82)
        let wing = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
        func p(_ o: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: o.x + nx * k, y: o.y + ny * k) }
        path.move(to: p(a, tailHalf))
        path.addLine(to: p(neck, neckHalf))
        path.addLine(to: p(wing, headHalf))
        path.addLine(to: b)
        path.addLine(to: p(wing, -headHalf))
        path.addLine(to: p(neck, -neckHalf))
        path.addLine(to: p(a, -tailHalf))
        path.closeSubpath()
        return path
    }

    private static func strokeOutline(_ path: CGPath, _ width: CGFloat) -> CGPath {
        path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    // MARK: Text layout

    private static let placeholder = L("Type…")

    private static func font(_ m: Mark, size: CGFloat? = nil) -> NSFont {
        .systemFont(ofSize: size ?? m.fontSize, weight: .semibold)
    }

    /// Padding between the text and its frame: a filled box for a text box,
    /// a little breathing room for plain text.
    private static func padding(_ m: Mark) -> (x: CGFloat, y: CGFloat) {
        m.kind == .textBox ? ((m.fontSize * 0.45).rounded(), (m.fontSize * 0.22).rounded())
            : ((m.fontSize * 0.12).rounded(), (m.fontSize * 0.06).rounded())
    }

    private static func luminance(_ c: NSColor) -> CGFloat {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
    }

    /// Text on a filled box is white, or black on yellow and white boxes.
    private static func textColor(_ m: Mark) -> NSColor {
        m.kind == .textBox ? (luminance(m.color) > 0.6 ? .black : .white) : m.color
    }

    private static func measure(_ string: String, font: NSFont) -> CGSize {
        var s = string.isEmpty ? " " : string
        // A trailing newline is a line the caret is already on.
        if s.hasSuffix("\n") { s += " " }
        let r = (s as NSString).boundingRect(with: CGSize(width: 1e6, height: 1e6),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading],
                                             attributes: [.font: font])
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    /// Where a text mark's glyphs and its frame sit, in image pixels.
    private static func textLayout(_ m: Mark, placeholderIfEmpty: Bool = false) -> (text: CGRect, box: CGRect) {
        let string = m.text.isEmpty && placeholderIfEmpty ? placeholder : m.text
        let size = measure(string, font: font(m))
        let top = m.points[0]
        let text = CGRect(x: top.x, y: top.y - size.height, width: size.width, height: size.height)
        let pad = padding(m)
        return (text, text.insetBy(dx: -pad.x, dy: -pad.y))
    }

    // MARK: Rendering

    /// Draws one mark into a context whose user space is image pixels.
    /// Shadows ignore the transform, so they are sized by `shadowScale`:
    /// context units per image pixel.
    private func render(_ m: Mark, in ctx: CGContext, shadowScale: CGFloat) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch m.kind {
        case .rect, .ellipse:
            let r = Self.rect(m.points[0], m.points[1])
            ctx.addPath(m.kind == .rect ? CGPath(rect: r, transform: nil) : CGPath(ellipseIn: r, transform: nil))
            ctx.setLineWidth(m.width)
            ctx.setLineJoin(m.kind == .rect ? .miter : .round)
            ctx.setStrokeColor(m.color.cgColor)
            ctx.strokePath()
        case .arrow:
            ctx.addPath(Self.arrowPath(from: m.points[0], to: m.points[1], width: m.width))
            ctx.setFillColor(m.color.cgColor)
            ctx.fillPath()
        case .pen:
            ctx.addPath(Self.smoothPath(m.points))
            ctx.setLineWidth(m.width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(m.color.cgColor)
            ctx.strokePath()
        case .mosaic, .blur:
            guard let image = filteredImage(for: m.kind) else { return }
            ctx.addPath(Self.strokeOutline(Self.smoothPath(m.points), m.width))
            ctx.clip()
            ctx.draw(image, in: imageRect)
        case .text, .textBox:
            let layout = Self.textLayout(m)
            if m.kind == .textBox {
                let radius = (m.fontSize * 0.28).rounded()
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -m.fontSize * 0.05 * shadowScale),
                              blur: m.fontSize * 0.25 * shadowScale,
                              color: NSColor.black.withAlphaComponent(0.35).cgColor)
                ctx.addPath(CGPath(roundedRect: layout.box, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.setFillColor(m.color.cgColor)
                ctx.fillPath()
                ctx.restoreGState()
            } else {
                // A soft dark shadow lifts colored and white ink off any
                // screenshot; only near-black ink gets a light halo.
                let dark = Self.luminance(m.color) < 0.2
                ctx.setShadow(offset: .zero, blur: max(1, m.fontSize * 0.1) * shadowScale,
                              color: (dark ? NSColor.white.withAlphaComponent(0.75)
                                      : NSColor.black.withAlphaComponent(0.55)).cgColor)
            }
            let string = NSAttributedString(string: m.text, attributes: [
                .font: Self.font(m), .foregroundColor: Self.textColor(m),
            ])
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            string.draw(with: layout.text, options: [.usesLineFragmentOrigin, .usesFontLeading])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawOverlay(_ ctx: CGContext) {
        guard base != nil else { return }
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        for m in marks where m.id != editing?.id { render(m, in: ctx, shadowScale: scale) }
        if let draft { render(draft, in: ctx, shadowScale: scale) }
        ctx.restoreGState()
        var drawing = false
        if case .draw = drag { drawing = true }
        if let m = selected, editing == nil, !drawing { drawSelection(m, in: ctx) }
    }

    private func drawSelection(_ m: Mark, in ctx: CGContext) {
        let accent = NSColor.controlAccentColor.cgColor
        if m.kind != .arrow {
            let r = viewRect(frame(of: m)).integral.insetBy(dx: 0.5, dy: 0.5)
            ctx.setLineWidth(3)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.stroke(r)
            ctx.setLineWidth(1)
            ctx.setStrokeColor(accent)
            ctx.stroke(r)
        }
        for (_, p) in handles(of: m) {
            let c = viewPoint(p)
            let dot = CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 2, color: NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: dot)
            ctx.restoreGState()
            ctx.setLineWidth(1.5)
            ctx.setStrokeColor(accent)
            ctx.strokeEllipse(in: dot.insetBy(dx: 0.75, dy: 0.75))
        }
    }

    /// The whole image pixellated or blurred once, at full resolution. The
    /// mosaic grid is anchored at the image origin, so every stroke lines up.
    private func filteredImage(for kind: Mark.Kind) -> CGImage? {
        if let f = filtered[kind] { return f }
        let input = CIImage(cgImage: base).clampedToExtent()
        let output: CIImage
        if kind == .mosaic {
            output = input.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: max(6, (11 * unit).rounded()),
                kCIInputCenterKey: CIVector(x: 0, y: 0),
            ])
        } else {
            output = input.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(6, 8 * unit)])
        }
        let image = ci.createCGImage(output.cropped(to: imageRect), from: imageRect,
                                     format: .RGBA8, colorSpace: space)
        filtered[kind] = image
        return image
    }

    // MARK: Frames, handles, hit testing

    /// The box a selected mark shows and resizes by.
    private func frame(of m: Mark) -> CGRect {
        switch m.kind {
        case .rect, .ellipse, .arrow: return Self.rect(m.points[0], m.points[1])
        case .pen, .mosaic, .blur: return Self.strokeOutline(Self.smoothPath(m.points), m.width).boundingBoxOfPath
        case .text, .textBox: return Self.textLayout(m).box
        }
    }

    private func handles(of m: Mark) -> [(Handle, CGPoint)] {
        if m.kind == .arrow { return [(.point(0), m.points[0]), (.point(1), m.points[1])] }
        let f = frame(of: m)
        let shown = viewRect(f)
        // Text scales from its corners only; edge handles would squash it.
        let edges = !m.kind.isText && shown.width > 36 && shown.height > 36
        var out: [(Handle, CGPoint)] = []
        for (hy, y) in [(-1, f.minY), (0, f.midY), (1, f.maxY)] {
            for (hx, x) in [(-1, f.minX), (0, f.midX), (1, f.maxX)] where !(hx == 0 && hy == 0) {
                if (hx == 0 || hy == 0) && !edges { continue }
                out.append((.frame(hx, hy), CGPoint(x: x, y: y)))
            }
        }
        return out
    }

    private func handle(at v: CGPoint, of m: Mark) -> Handle? {
        var best: (Handle, CGFloat)?
        for (h, p) in handles(of: m) {
            let c = viewPoint(p)
            let d = hypot(c.x - v.x, c.y - v.y)
            if d <= 8 && d < (best?.1 ?? .infinity) { best = (h, d) }
        }
        return best?.0
    }

    /// The topmost mark under the pointer. The pointer tool picks anything,
    /// including the inside of shapes and mosaic; drawing tools only pick up
    /// outlines and text, so you can still draw inside a box.
    private func hitMark(at p: CGPoint) -> Mark? {
        let anywhere = tool == .select
        let tol = 5 / scale
        for m in marks.reversed() {
            if m.kind.isBrush && !anywhere { continue }
            let hit: Bool
            switch m.kind {
            case .text, .textBox:
                hit = Self.textLayout(m).box.insetBy(dx: -tol, dy: -tol).contains(p)
            case .rect, .ellipse:
                let r = Self.rect(m.points[0], m.points[1])
                let shape = m.kind == .rect ? CGPath(rect: r, transform: nil) : CGPath(ellipseIn: r, transform: nil)
                hit = (anywhere && shape.contains(p)) || Self.strokeOutline(shape, m.width + 2 * tol).contains(p)
            case .arrow:
                let line = CGMutablePath()
                line.move(to: m.points[0])
                line.addLine(to: m.points[1])
                hit = Self.strokeOutline(line, m.width * 2 + 2 * tol).contains(p)
            case .pen:
                hit = Self.strokeOutline(Self.smoothPath(m.points), m.width + 2 * tol).contains(p)
            case .mosaic, .blur:
                hit = Self.strokeOutline(Self.smoothPath(m.points), m.width).contains(p)
            }
            if hit { return m }
        }
        return nil
    }

    // MARK: Changing marks

    private func record() {
        undoStack.append(marks)
        if undoStack.count > maxUndo { undoStack.removeFirst(undoStack.count - maxUndo) }
        redoStack.removeAll()
    }

    private func replace(_ m: Mark) {
        if let i = marks.firstIndex(where: { $0.id == m.id }) { marks[i] = m }
    }

    private func translated(_ m: Mark, by d: CGPoint) -> Mark {
        var m = m
        m.points = m.points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
        return m
    }

    private func resized(_ original: Mark, _ handle: Handle, frame f: CGRect, to p: CGPoint, shift: Bool) -> Mark {
        var m = original
        switch handle {
        case let .point(i):
            let other = m.points[1 - i]
            m.points[i] = shift ? Self.constrained(other, p, square: false) : p
        case let .frame(hx, hy):
            // The opposite corner or edge stays put.
            let ax = hx < 0 ? f.maxX : f.minX
            let ay = hy < 0 ? f.maxY : f.minY
            if m.kind.isText {
                let s = max(abs(p.x - ax) / max(f.width, 1), abs(p.y - ay) / max(f.height, 1))
                m.fontSize = clamp(original.fontSize * s, 6 * unit, 400 * unit)
                let box = Self.textLayout(m).box
                let minX = hx < 0 ? ax - box.width : ax
                let maxY = hy < 0 ? ay : ay + box.height
                let pad = Self.padding(m)
                m.points[0] = CGPoint(x: minX + pad.x, y: maxY - pad.y)
                return m
            }
            var minX = f.minX, maxX = f.maxX, minY = f.minY, maxY = f.maxY
            var px = p.x, py = p.y
            if shift && hx != 0 && hy != 0 && f.width > 0 && f.height > 0 {
                // Corners keep the proportions with Shift.
                let sx = (p.x - ax) / (CGFloat(hx) * f.width), sy = (p.y - ay) / (CGFloat(hy) * f.height)
                let s = max(abs(sx), abs(sy))
                px = ax + CGFloat(hx) * f.width * s * (sx < 0 ? -1 : 1)
                py = ay + CGFloat(hy) * f.height * s * (sy < 0 ? -1 : 1)
            }
            if hx < 0 { minX = px } else if hx > 0 { maxX = px }
            if hy < 0 { minY = py } else if hy > 0 { maxY = py }
            let sx = f.width > 0.01 ? (maxX - minX) / f.width : 1
            let sy = f.height > 0.01 ? (maxY - minY) / f.height : 1
            m.points = m.points.map { CGPoint(x: minX + ($0.x - f.minX) * sx, y: minY + ($0.y - f.minY) * sy) }
        }
        return m
    }

    private func newMark(from start: CGPoint, to end: CGPoint, shift: Bool) -> Mark? {
        guard let kind = tool.kind else { return nil }
        let color = style.color
        switch kind {
        case .rect, .ellipse:
            let b = shift ? Self.constrained(start, end, square: true) : end
            let r = Self.rect(start, b)
            guard r.width > 2 || r.height > 2 else { return nil }
            return Mark(kind: kind, points: [start, b], color: color, width: linePixels(style.lineSize))
        case .arrow:
            let b = shift ? Self.constrained(start, end, square: false) : end
            let width = linePixels(style.lineSize)
            guard hypot(b.x - start.x, b.y - start.y) > width * 2 else { return nil }
            return Mark(kind: .arrow, points: [start, b], color: color, width: width)
        case .pen:
            return Mark(kind: .pen, points: samples, color: color, width: linePixels(style.lineSize))
        case .mosaic, .blur:
            guard filteredImage(for: kind) != nil else { return nil }
            return Mark(kind: kind, points: samples, color: color, width: brushPixels(style.lineSize))
        case .text, .textBox:
            return nil
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseDown(with event: NSEvent) {
        // A click while typing just sets the text down.
        if editor != nil {
            finishEditing()
            return
        }
        window?.makeFirstResponder(self)
        let p = imagePoint(event)
        let v = convert(event.locationInWindow, from: nil)
        lastPointer = p
        if spaceHeld {
            drag = .pan(start: event.locationInWindow, origin: frame.origin)
            NSCursor.closedHand.set()
            return
        }
        if event.clickCount == 2, let m = hitMark(at: p), m.kind.isText {
            startEditing(m, isNew: false)
            return
        }
        if let m = selected, let h = handle(at: v, of: m) {
            drag = .resize(id: m.id, handle: h, original: m, frame: frame(of: m), moved: false)
            return
        }
        if !tool.isFreehand, let m = hitMark(at: p) {
            let wasSelected = selectedID == m.id
            selectedID = m.id
            drag = .move(id: m.id, original: m, start: p, moved: false,
                         editOnClick: wasSelected && tool.isText && m.kind.isText)
            NSCursor.closedHand.set()
            onChange()
            return
        }
        if selectedID != nil {
            selectedID = nil
            onChange()
        }
        switch tool {
        case .select:
            return
        case .text, .textBox:
            startNewText(at: p)
        default:
            drag = .draw(start: p)
            samples = [p]
            if tool.isFreehand { draft = newMark(from: p, to: p, shift: false) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let p = imagePoint(event)
        lastPointer = p
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case let .draw(start):
            if let last = samples.last, hypot(p.x - last.x, p.y - last.y) >= 0.75 / scale { samples.append(p) }
            draft = newMark(from: start, to: p, shift: shift)
        case let .move(id, original, start, moved, editOnClick):
            var d = CGPoint(x: p.x - start.x, y: p.y - start.y)
            // A small wobble while clicking is not a move.
            guard moved || hypot(d.x, d.y) * scale >= 3 else { return }
            if !moved { record() }
            // Shift keeps a move straight along one axis.
            if shift { d = abs(d.x) > abs(d.y) ? CGPoint(x: d.x, y: 0) : CGPoint(x: 0, y: d.y) }
            replace(translated(original, by: d))
            self.drag = .move(id: id, original: original, start: start, moved: true, editOnClick: editOnClick)
        case let .resize(id, handle, original, f, moved):
            if !moved { record() }
            replace(resized(original, handle, frame: f, to: p, shift: shift))
            self.drag = .resize(id: id, handle: handle, original: original, frame: f, moved: true)
        case let .pan(start, origin):
            let w = event.locationInWindow
            onPan(NSPoint(x: origin.x + w.x - start.x, y: origin.y + w.y - start.y))
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case let .draw(start) where tool.isShape:
            draft = newMark(from: start, to: lastPointer, shift: shift)
        case let .resize(id, handle, original, f, true):
            replace(resized(original, handle, frame: f, to: lastPointer, shift: shift))
            drag = .resize(id: id, handle: handle, original: original, frame: f, moved: true)
        default:
            super.flagsChanged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        switch drag {
        case let .draw(start):
            let mark = newMark(from: start, to: imagePoint(event), shift: event.modifierFlags.contains(.shift))
            draft = nil
            samples = []
            if let mark {
                record()
                marks.append(mark)
                // Shapes stay selected so they can be adjusted right away;
                // a scribble would only wear distracting handles.
                if !mark.kind.isFreehand { selectedID = mark.id }
            }
        case let .move(id, _, _, moved, editOnClick):
            if !moved && editOnClick, let m = marks.first(where: { $0.id == id }) {
                startEditing(m, isNew: false)
            }
        case .resize, .pan:
            break
        }
        overlay.needsDisplay = true
        onChange()
        updateCursor()
    }

    /// Called by the viewport for clicks on the backdrop.
    func clickedOutside() {
        if editor != nil {
            finishEditing()
        } else if selectedID != nil {
            selectedID = nil
            onChange()
        }
        window?.makeFirstResponder(self)
    }

    // MARK: Cursor

    override func cursorUpdate(with event: NSEvent) { updateCursor() }
    override func mouseMoved(with event: NSEvent) { updateCursor() }

    private func updateCursor() {
        guard drag == nil, base != nil, let window else { return }
        let v = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(v) else { return }
        if let editor, editor.frame.contains(v) { return }
        cursor(at: v).set()
    }

    private func cursor(at v: CGPoint) -> NSCursor {
        if spaceHeld { return .openHand }
        if let m = selected, let h = handle(at: v, of: m) { return resizeCursor(h) }
        if !tool.isFreehand, hitMark(at: CGPoint(x: v.x / scale, y: v.y / scale)) != nil { return .openHand }
        switch tool {
        case .select: return .arrow
        case .text, .textBox: return .iBeam
        case .mosaic, .blur: return brushCursor(Self.brushPoints[style.lineSize] * unit * scale)
        default: return .crosshair
        }
    }

    private func resizeCursor(_ h: Handle) -> NSCursor {
        guard case let .frame(hx, hy) = h else { return .crosshair }
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch (hx, hy) {
            case (-1, 1): position = .topLeft
            case (0, 1): position = .top
            case (1, 1): position = .topRight
            case (-1, 0): position = .left
            case (1, 0): position = .right
            case (-1, -1): position = .bottomLeft
            case (0, -1): position = .bottom
            default: position = .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }
        return hy == 0 ? .resizeLeftRight : hx == 0 ? .resizeUpDown : .crosshair
    }

    /// A ring the size of the brush, legible on light and dark pixels.
    private func brushCursor(_ diameter: CGFloat) -> NSCursor {
        let diameter = min(128, max(6, diameter.rounded()))
        if let c = cursors[diameter] { return c }
        let side = diameter + 4
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2))
            ring.lineWidth = 3
            NSColor.black.withAlphaComponent(0.55).setStroke()
            ring.stroke()
            ring.lineWidth = 1.25
            NSColor.white.setStroke()
            ring.stroke()
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
        cursors[diameter] = cursor
        return cursor
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // Holding Space turns the pointer into a hand that pans the image.
        if event.keyCode == 49 {
            if !event.isARepeat {
                spaceHeld = true
                updateCursor()
            }
            return
        }
        if !onKey(event) { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceHeld = false
            updateCursor()
            return
        }
        super.keyUp(with: event)
    }

    // MARK: Commands from the controller

    /// Lets go of the selection. False when there was none.
    func deselect() -> Bool {
        guard selectedID != nil else { return false }
        selectedID = nil
        onChange()
        return true
    }

    func deleteSelection() -> Bool {
        guard let id = selectedID else { return false }
        record()
        marks.removeAll { $0.id == id }
        selectedID = nil
        onChange()
        return true
    }

    /// Moves the selection by on-screen points.
    func nudge(dx: CGFloat, dy: CGFloat) -> Bool {
        guard let m = selected else { return false }
        record()
        replace(translated(m, by: CGPoint(x: dx * unit, y: dy * unit)))
        onChange()
        return true
    }

    func duplicateSelection() -> Bool {
        guard let m = selected else { return false }
        record()
        var copy = translated(m, by: CGPoint(x: 16 * unit, y: -16 * unit))
        copy.id = UUID()
        marks.append(copy)
        selectedID = copy.id
        onChange()
        return true
    }

    func applyColor(_ color: NSColor) {
        if var m = editing {
            m.color = color
            editing = m
            styleEditor()
            return
        }
        guard var m = selected, m.kind.usesColor, m.color != color else { return }
        record()
        m.color = color
        replace(m)
        onChange()
    }

    func applySize(_ i: Int) {
        if var m = editing {
            m.fontSize = fontPixels(i)
            editing = m
            styleEditor()
            return
        }
        guard var m = selected else { return }
        let before = m
        if m.kind.isText {
            m.fontSize = fontPixels(i)
        } else if m.kind.isBrush {
            m.width = brushPixels(i)
        } else {
            m.width = linePixels(i)
        }
        guard m != before else { return }
        record()
        replace(m)
        onChange()
    }

    /// The step of the size scale a mark is at, if it is on one.
    func sizeIndex(of m: Mark) -> Int? {
        let (value, steps): (CGFloat, [CGFloat]) = m.kind.isText ? (m.fontSize, Self.fontPoints)
            : m.kind.isBrush ? (m.width, Self.brushPoints) : (m.width, Self.linePoints)
        return steps.firstIndex { abs($0 * unit - value) < 0.5 }
    }

    // MARK: Text

    private func startNewText(at p: CGPoint) {
        var m = Mark(kind: tool == .textBox ? .textBox : .text, points: [p], color: style.color,
                     fontSize: fontPixels(style.textSize))
        // The click marks where the first line starts, centered on it.
        let line = Self.measure(" ", font: Self.font(m)).height
        m.points[0] = CGPoint(x: p.x, y: p.y + line / 2)
        startEditing(m, isNew: true)
    }

    private func startEditing(_ m: Mark, isNew: Bool) {
        finishEditing()
        editing = m
        editingIsNew = isNew
        selectedID = nil

        let tv = EditorTextView(frame: .zero)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: 1e6, height: 1e6)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.focusRingType = .none
        tv.wantsLayer = true
        tv.string = m.text
        tv.delegate = self
        tv.onFinish = { [weak self] in self?.finishEditing() }
        tv.onCancel = { [weak self] in self?.cancelEditing() }
        addSubview(tv)
        editor = tv
        styleEditor()
        window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        overlay.needsDisplay = true
        onChange()
    }

    /// The text view takes the mark's look at the current zoom: font,
    /// color, the filled box for a text box, a hairline frame otherwise.
    private func styleEditor() {
        guard let tv = editor, let m = editing else { return }
        let font = Self.font(m, size: m.fontSize * scale)
        let color = Self.textColor(m)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        tv.typingAttributes = attributes
        tv.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: tv.textStorage?.length ?? 0))
        tv.insertionPointColor = color
        tv.placeholder = NSAttributedString(string: Self.placeholder, attributes: [
            .font: font, .foregroundColor: color.withAlphaComponent(0.45),
        ])
        if m.kind == .textBox {
            tv.layer?.backgroundColor = m.color.cgColor
            tv.layer?.cornerRadius = (m.fontSize * 0.28).rounded() * scale
            tv.layer?.borderWidth = 0
        } else {
            tv.layer?.backgroundColor = NSColor(white: 0, alpha: 0.15).cgColor
            tv.layer?.cornerRadius = 3
            tv.layer?.borderWidth = 1
            tv.layer?.borderColor = NSColor(white: 1, alpha: 0.6).cgColor
        }
        layoutEditor()
        tv.needsDisplay = true
    }

    private func layoutEditor() {
        guard let tv = editor, var m = editing else { return }
        m.text = tv.string
        let box = viewRect(Self.textLayout(m, placeholderIfEmpty: true).box)
        let pad = Self.padding(m)
        tv.textContainerInset = NSSize(width: pad.x * scale, height: pad.y * scale)
        // A little slack on the right keeps the caret from clipping.
        tv.frame = CGRect(x: box.minX, y: box.minY, width: box.width + 2, height: box.height)
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = editor, var m = editing else { return }
        m.text = tv.string
        editing = m
        layoutEditor()
        onChange()
    }

    /// Sets the text down: a new text joins the marks, an edited one
    /// replaces its old version, and emptied text goes away.
    func finishEditing() {
        guard let tv = editor, var m = editing else { return }
        editor = nil
        editing = nil
        m.text = tv.string
        while m.text.hasSuffix("\n") { m.text.removeLast() }
        hand(keyboardFrom: tv)
        let empty = m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if editingIsNew {
            if !empty {
                record()
                marks.append(m)
                selectedID = m.id
            }
        } else if let old = marks.first(where: { $0.id == m.id }) {
            if empty {
                record()
                marks.removeAll { $0.id == m.id }
            } else {
                if old != m {
                    record()
                    replace(m)
                }
                selectedID = m.id
            }
        }
        overlay.needsDisplay = true
        onChange()
    }

    /// Removing the focused text view would leave the window itself as
    /// first responder, and the tool shortcuts would stop working.
    private func hand(keyboardFrom tv: NSTextView) {
        let focused = window?.firstResponder === tv
        tv.removeFromSuperview()
        if focused || window?.firstResponder === window { window?.makeFirstResponder(self) }
    }

    private func cancelEditing() {
        guard let tv = editor, let m = editing else { return }
        editor = nil
        editing = nil
        hand(keyboardFrom: tv)
        if !editingIsNew { selectedID = m.id }
        overlay.needsDisplay = true
        onChange()
    }

    // MARK: History

    func undo() {
        if editor != nil {
            cancelEditing()
            return
        }
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(marks)
        marks = previous
        if selected == nil { selectedID = nil }
        onChange()
    }

    func redo() {
        guard editor == nil, let next = redoStack.popLast() else { return }
        undoStack.append(marks)
        marks = next
        if selected == nil { selectedID = nil }
        onChange()
    }

    /// The image with every mark composited, at the file's own resolution.
    func bake() -> CGImage? {
        let opaque = [.none, .noneSkipLast, .noneSkipFirst].contains(base.alphaInfo)
        let info = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
        guard let out = CGContext(data: nil, width: base.width, height: base.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: info.rawValue) else { return nil }
        out.draw(base, in: imageRect)
        for m in marks { render(m, in: out, shadowScale: 1) }
        return out.makeImage()
    }
}

/// The untouched screenshot. Never takes a click: those belong to the canvas.
private final class ImageView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .trilinear
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Where marks and selection handles are drawn. Never takes a click.
private final class Overlay: NSView {
    var drawer: (CGContext) -> Void = { _ in }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        if let ctx = NSGraphicsContext.current?.cgContext { drawer(ctx) }
    }
}

/// The text view a text mark is typed into. The app has no main menu, so
/// the editing shortcuts are wired here; Escape or ⌘Return finish.
private final class EditorTextView: NSTextView {
    var onFinish: () -> Void = {}
    var onCancel: () -> Void = {}
    var placeholder: NSAttributedString?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onFinish()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            onFinish()
            return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": selectAll(nil)
        case "c": copy(nil)
        case "x": cut(nil)
        case "v": pasteAsPlainText(nil)
        case "z":
            if flags.contains(.shift) {
                undoManager?.redo()
            } else if undoManager?.canUndo == true {
                undoManager?.undo()
            } else {
                onCancel()
            }
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, let placeholder { placeholder.draw(at: textContainerOrigin) }
    }
}
