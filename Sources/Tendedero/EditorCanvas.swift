import AppKit
import CoreImage

/// What a click and drag does on the canvas. The set and the order follow the
/// tool strip of Greenshot's editor, with a pointer in front to select.
enum EditorTool: Int, CaseIterable {
    case select, rectangle, ellipse, line, arrow, text, number, blur, pixelate, crop

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .number: "number.circle"
        case .blur: "drop"
        case .pixelate: "square.grid.3x3"
        case .crop: "crop"
        }
    }

    var title: String {
        switch self {
        case .select: L("Select")
        case .rectangle: L("Rectangle")
        case .ellipse: L("Ellipse")
        case .line: L("Line")
        case .arrow: L("Arrow")
        case .text: L("Text")
        case .number: L("Number")
        case .blur: L("Blur")
        case .pixelate: L("Pixelate")
        case .crop: L("Crop")
        }
    }

    /// The key that picks the tool while the canvas has focus.
    var key: String {
        switch self {
        case .select: "v"
        case .rectangle: "r"
        case .ellipse: "e"
        case .line: "l"
        case .arrow: "a"
        case .text: "t"
        case .number: "n"
        case .blur: "b"
        case .pixelate: "p"
        case .crop: "c"
        }
    }
}

/// One mark on the screenshot. Coordinates are pixels of the image, with the
/// origin at the top left, so a mark stays put at any zoom.
struct Annotation: Equatable {
    enum Kind { case rectangle, ellipse, line, arrow, text, number, blur, pixelate }

    let id = UUID()
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var color: NSColor
    /// Stroke width in pixels. It also sets the size of text, numbers and
    /// the strength of blur and pixelate, like the size strip in the toolbar.
    var width: CGFloat
    var text = ""
    var number = 0

    var box: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// Marks that are a line between two points, not a box.
    var isSegment: Bool { kind == .line || kind == .arrow }

    var numberRadius: CGFloat { width * 2 + 12 }
    var fontSize: CGFloat { width * 4 + 8 }
    var font: NSFont { .systemFont(ofSize: fontSize, weight: .semibold) }

    /// Where the mark is, for hit testing. Numbers are a circle around the start.
    var bounds: CGRect {
        kind == .number
            ? CGRect(x: start.x - numberRadius, y: start.y - numberRadius,
                     width: numberRadius * 2, height: numberRadius * 2)
            : box
    }

    func hit(_ p: CGPoint, tolerance t: CGFloat) -> Bool {
        switch kind {
        case .line, .arrow:
            return Self.distance(from: p, toSegment: start, end) <= max(t, width / 2 + t / 2)
        case .number:
            return hypot(p.x - start.x, p.y - start.y) <= numberRadius + t / 2
        default:
            return box.insetBy(dx: -t, dy: -t).contains(p)
        }
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: Drawing

    /// Draws into the current flipped graphics context. `image` is what
    /// blur and pixelate read from.
    @MainActor
    func draw(over image: CGImage) {
        color.setStroke()
        color.setFill()
        switch kind {
        case .rectangle:
            let path = NSBezierPath(rect: box)
            path.lineWidth = width
            path.lineJoinStyle = .miter
            path.stroke()
        case .ellipse:
            let path = NSBezierPath(ovalIn: box)
            path.lineWidth = width
            path.stroke()
        case .line:
            segment().stroke()
        case .arrow:
            segment().stroke()
            head().fill()
        case .text:
            (text as NSString).draw(in: box.insetBy(dx: 2, dy: 2), withAttributes: [
                .font: font, .foregroundColor: color,
            ])
        case .number:
            let circle = CGRect(x: start.x - numberRadius, y: start.y - numberRadius,
                                width: numberRadius * 2, height: numberRadius * 2)
            NSBezierPath(ovalIn: circle).fill()
            let label = "\(number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: numberRadius * 1.1, weight: .bold),
                .foregroundColor: color.isLight ? NSColor.black : NSColor.white,
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: start.x - size.width / 2, y: start.y - size.height / 2),
                       withAttributes: attributes)
        case .blur, .pixelate:
            if let piece = Effects.render(kind, over: image, in: box, strength: width) {
                let target = box.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                NSImage(cgImage: piece, size: target.size).draw(
                    in: target, from: .zero, operation: .copy, fraction: 1,
                    respectFlipped: true, hints: nil)
            }
        }
    }

    private func segment() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = width
        path.lineCapStyle = .round
        return path
    }

    /// The triangle at the end of an arrow.
    private func head() -> NSBezierPath {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = width * 3 + 10
        let spread = CGFloat.pi / 7
        let path = NSBezierPath()
        path.move(to: end)
        path.line(to: CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread)))
        path.line(to: CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread)))
        path.close()
        return path
    }
}

extension NSColor {
    /// Light enough that white on top of it would not read.
    fileprivate var isLight: Bool {
        guard let c = usingColorSpace(.deviceRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.65
    }
}

/// Blur and pixelate: the part of the screenshot under the mark, run through
/// a Core Image filter. Filtering is slow next to drawing a line, and the
/// canvas redraws on every mouse move, so recent results are kept.
@MainActor
private enum Effects {
    private struct Key: Hashable {
        let kind: Annotation.Kind
        let rect: CGRect
        let strength: CGFloat
        let image: UnsafeMutableRawPointer
    }

    private static let context = CIContext()
    private static var cache: [Key: CGImage] = [:]

    static func render(_ kind: Annotation.Kind, over image: CGImage, in rect: CGRect, strength: CGFloat) -> CGImage? {
        let area = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard area.width >= 1, area.height >= 1 else { return nil }

        let key = Key(kind: kind, rect: area, strength: strength,
                      image: Unmanaged.passUnretained(image).toOpaque())
        if let hit = cache[key] { return hit }

        guard let piece = image.cropping(to: area) else { return nil }
        let source = CIImage(cgImage: piece)
        let filtered: CIImage
        if kind == .blur {
            // Clamped, so the edges blur into the picture and not into black.
            filtered = source.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: strength * 2.5 + 4])
                .cropped(to: source.extent)
        } else {
            filtered = source.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: strength * 2 + 4,
                kCIInputCenterKey: CIVector(x: source.extent.minX, y: source.extent.minY),
            ]).cropped(to: source.extent)
        }
        guard let result = context.createCGImage(filtered, from: source.extent) else { return nil }
        if cache.count > 24 { cache.removeAll() }
        cache[key] = result
        return result
    }
}

/// A screenshot with marks on it. Marks are kept apart from the pixels until
/// the image is written, so they stay movable and undoable.
@MainActor
final class EditorCanvas: NSView, NSTextFieldDelegate {
    struct State {
        var image: CGImage
        var annotations: [Annotation]
    }

    private(set) var state: State
    /// Pixels per point of the original screenshot: 2 for a Retina capture.
    /// Widths are chosen in points and stored in pixels.
    let scale: CGFloat

    var tool: EditorTool = .select {
        didSet {
            guard tool != oldValue else { return }
            commitText()
            cropRect = nil
            if tool != .select { selected = nil }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            onToolChange(tool)
        }
    }
    var color: NSColor = .systemRed
    var widthInPoints: CGFloat = 4

    var onToolChange: (EditorTool) -> Void = { _ in }
    var onSave: () -> Void = {}
    var onClose: () -> Void = {}

    /// Whether there is anything not yet written to the file.
    private(set) var isDirty = false

    var zoom: CGFloat = 1 {
        didSet { layoutForZoom() }
    }

    private let undo = UndoManager()
    override var undoManager: UndoManager? { undo }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var selected: UUID?
    private var cropRect: CGRect?

    private enum Drag {
        case create(UUID)
        case move(UUID, last: CGPoint)
        case resize(UUID, handle: Int)
        case crop(origin: CGPoint)
    }
    private var drag: Drag?
    /// The state when the current drag started, for undo.
    private var before: State?

    private var field: NSTextField?
    private var editing: UUID?

    init(image: CGImage, scale: CGFloat) {
        state = State(image: image, annotations: [])
        self.scale = scale
        super.init(frame: .zero)
        layoutForZoom()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var pixelSize: CGSize { CGSize(width: state.image.width, height: state.image.height) }

    private func layoutForZoom() {
        // Frame first: changing the frame size rescales the bounds.
        setFrameSize(CGSize(width: pixelSize.width * zoom, height: pixelSize.height * zoom))
        setBoundsSize(pixelSize)
        needsDisplay = true
    }

    // MARK: State and undo

    private func annotationIndex(_ id: UUID?) -> Int? {
        guard let id else { return nil }
        return state.annotations.firstIndex { $0.id == id }
    }

    /// Swaps in a state and remembers how to go back, which is also how redo works.
    private func set(_ new: State, name: String) {
        let old = state
        undo.registerUndo(withTarget: self) { canvas in
            MainActor.assumeIsolated { canvas.set(old, name: name) }
        }
        undo.setActionName(name)
        apply(new)
    }

    private func apply(_ new: State) {
        let resized = new.image.width != state.image.width || new.image.height != state.image.height
        state = new
        isDirty = true
        if !state.annotations.contains(where: { $0.id == selected }) { selected = nil }
        if resized { layoutForZoom() }
        needsDisplay = true
    }

    private func register(_ old: State, name: String) {
        undo.registerUndo(withTarget: self) { canvas in
            MainActor.assumeIsolated { canvas.set(old, name: name) }
        }
        undo.setActionName(name)
        isDirty = true
    }

    func markClean() { isDirty = false }

    // MARK: Output

    /// The screenshot with the marks burnt in, at its full resolution.
    func flattened() -> NSBitmapImageRep? {
        commitText()
        let width = state.image.width, height = state.image.height
        guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
              let bitmap = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        let cg = bitmap.cgContext
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flipped
        paint(state, skipping: nil)
        NSGraphicsContext.restoreGraphicsState()
        // The size in points, so the file keeps its resolution.
        rep.size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        return rep
    }

    // MARK: Drawing

    private func paint(_ state: State, skipping hidden: UUID?) {
        NSImage(cgImage: state.image, size: pixelSize).draw(
            in: CGRect(origin: .zero, size: pixelSize), from: .zero, operation: .copy,
            fraction: 1, respectFlipped: true, hints: nil)
        for annotation in state.annotations where annotation.id != hidden {
            annotation.draw(over: state.image)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = zoom < 1 ? .high : .none
        paint(state, skipping: editing)

        if let i = annotationIndex(selected) { drawSelection(state.annotations[i]) }
        if let crop = cropRect { drawCrop(crop) }
    }

    private var handleSize: CGFloat { 9 / zoom }

    private func handles(for a: Annotation) -> [CGPoint] {
        if a.isSegment { return [a.start, a.end] }
        if a.kind == .number { return [] }
        let b = a.box
        return [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.maxY)]
    }

    private func drawSelection(_ a: Annotation) {
        let outline = NSBezierPath(rect: a.bounds.insetBy(dx: -2 / zoom, dy: -2 / zoom))
        outline.lineWidth = 1 / zoom
        outline.setLineDash([4 / zoom, 3 / zoom], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        if !a.isSegment { outline.stroke() }

        for point in handles(for: a) {
            let r = CGRect(x: point.x - handleSize / 2, y: point.y - handleSize / 2,
                           width: handleSize, height: handleSize)
            let dot = NSBezierPath(ovalIn: r)
            NSColor.white.setFill()
            dot.fill()
            dot.lineWidth = 1.5 / zoom
            NSColor.controlAccentColor.setStroke()
            dot.stroke()
        }
    }

    private func drawCrop(_ rect: CGRect) {
        let dim = NSBezierPath(rect: CGRect(origin: .zero, size: pixelSize))
        dim.append(NSBezierPath(rect: rect))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        dim.fill()

        let edge = NSBezierPath(rect: rect)
        edge.lineWidth = 1.5 / zoom
        edge.setLineDash([6 / zoom, 4 / zoom], count: 2, phase: 0)
        NSColor.white.setStroke()
        edge.stroke()

        let hint = L("Press Enter to crop") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12 / zoom, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6),
        ]
        let size = hint.size(withAttributes: attributes)
        let y = rect.maxY + size.height + 6 / zoom < pixelSize.height ? rect.maxY + 6 / zoom : rect.minY - size.height - 6 / zoom
        hint.draw(at: CGPoint(x: rect.minX, y: y), withAttributes: attributes)
    }

    override func resetCursorRects() {
        if tool != .select { addCursorRect(bounds, cursor: .crosshair) }
    }

    // MARK: Mouse

    private var tolerance: CGFloat { 6 / zoom }

    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(0, min(pixelSize.width, p.x)), y: max(0, min(pixelSize.height, p.y)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitText()
        let p = convert(event.locationInWindow, from: nil)
        before = state

        if tool == .crop {
            cropRect = nil
            drag = .crop(origin: clamped(p))
            needsDisplay = true
            return
        }

        if let i = annotationIndex(selected), let handle = handle(at: p, of: state.annotations[i]) {
            // Corners are named by position, so put start at the top left first.
            if !state.annotations[i].isSegment {
                let box = state.annotations[i].box
                state.annotations[i].start = box.origin
                state.annotations[i].end = CGPoint(x: box.maxX, y: box.maxY)
            }
            drag = .resize(state.annotations[i].id, handle: handle)
            return
        }

        if let i = state.annotations.lastIndex(where: { $0.hit(p, tolerance: tolerance) }) {
            let hit = state.annotations[i]
            selected = hit.id
            drag = .move(hit.id, last: p)
            needsDisplay = true
            if hit.kind == .text, event.clickCount == 2 {
                drag = nil
                beginText(hit.id)
            }
            return
        }

        selected = nil
        needsDisplay = true
        guard let kind = kind(for: tool) else { return }

        var mark = Annotation(kind: kind, start: clamped(p), end: clamped(p),
                              color: color, width: widthInPoints * scale)
        if kind == .number {
            mark.number = (state.annotations.filter { $0.kind == .number }.map(\.number).max() ?? 0) + 1
        }
        state.annotations.append(mark)
        selected = mark.id
        drag = .create(mark.id)
    }

    private func kind(for tool: EditorTool) -> Annotation.Kind? {
        switch tool {
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .line: .line
        case .arrow: .arrow
        case .text: .text
        case .number: .number
        case .blur: .blur
        case .pixelate: .pixelate
        case .select, .crop: nil
        }
    }

    private func handle(at p: CGPoint, of a: Annotation) -> Int? {
        handles(for: a).firstIndex { hypot($0.x - p.x, $0.y - p.y) <= handleSize }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clamped(convert(event.locationInWindow, from: nil))
        let constrain = event.modifierFlags.contains(.shift)

        switch drag {
        case .crop(let origin):
            cropRect = CGRect(x: min(origin.x, p.x), y: min(origin.y, p.y),
                              width: abs(p.x - origin.x), height: abs(p.y - origin.y))
        case .create(let id):
            guard let i = annotationIndex(id) else { return }
            state.annotations[i].end = constrain ? constrained(p, from: state.annotations[i]) : p
            // A number is a point: it follows the pointer, it is not sized by it.
            if state.annotations[i].kind == .number { state.annotations[i].start = p; state.annotations[i].end = p }
        case .move(let id, let last):
            guard let i = annotationIndex(id) else { return }
            let dx = p.x - last.x, dy = p.y - last.y
            state.annotations[i].start.x += dx
            state.annotations[i].start.y += dy
            state.annotations[i].end.x += dx
            state.annotations[i].end.y += dy
            drag = .move(id, last: p)
        case .resize(let id, let handle):
            guard let i = annotationIndex(id) else { return }
            if state.annotations[i].isSegment {
                if handle == 0 { state.annotations[i].start = p } else {
                    state.annotations[i].end = constrain ? constrained(p, from: state.annotations[i]) : p
                }
            } else {
                // 0 top left, 1 top right, 2 bottom left, 3 bottom right.
                if handle % 2 == 0 { state.annotations[i].start.x = p.x } else { state.annotations[i].end.x = p.x }
                if handle < 2 { state.annotations[i].start.y = p.y } else { state.annotations[i].end.y = p.y }
            }
        case nil:
            return
        }
        needsDisplay = true
    }

    /// Shift: lines snap to 45 degree steps and boxes become squares.
    private func constrained(_ p: CGPoint, from a: Annotation) -> CGPoint {
        let dx = p.x - a.start.x, dy = p.y - a.start.y
        if a.isSegment {
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let length = hypot(dx, dy)
            return CGPoint(x: a.start.x + length * cos(angle), y: a.start.y + length * sin(angle))
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: a.start.x + (dx < 0 ? -side : side), y: a.start.y + (dy < 0 ? -side : side))
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; before = nil; needsDisplay = true }
        guard let before else { return }

        switch drag {
        case .create(let id):
            guard let i = annotationIndex(id) else { return }
            var mark = state.annotations[i]
            let tiny = max(mark.box.width, mark.box.height) < 4 / zoom
            if mark.kind == .text {
                if tiny { mark.end = CGPoint(x: mark.start.x + 220 * scale, y: mark.start.y + mark.fontSize * 1.5) }
                state.annotations[i] = mark
                // Undo for a new text is registered when it is committed.
                textBase = before
                beginText(id)
            } else if mark.kind != .number && tiny {
                state.annotations.remove(at: i)
                selected = nil
            } else if state.annotations != before.annotations {
                register(before, name: L("Add"))
            }
        case .move, .resize:
            if state.annotations != before.annotations { register(before, name: L("Edit")) }
        case .crop, nil:
            if let crop = cropRect, crop.width < 4 / zoom || crop.height < 4 / zoom { cropRect = nil }
        }
    }

    // MARK: Text

    /// The state to go back to when the text being edited is undone.
    private var textBase: State?

    private func beginText(_ id: UUID) {
        guard let i = annotationIndex(id) else { return }
        commitText()
        let mark = state.annotations[i]
        if textBase == nil { textBase = state }

        let field = NSTextField(frame: mark.box)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = mark.font
        field.textColor = mark.color
        field.stringValue = mark.text
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.delegate = self
        addSubview(field)
        self.field = field
        editing = id
        selected = id
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    /// Finishes editing the text mark, if one is open. An empty one is dropped.
    private func commitText() {
        guard let field, let id = editing, let base = textBase else { return }
        let value = field.stringValue
        field.removeFromSuperview()
        self.field = nil
        editing = nil
        textBase = nil

        guard let i = annotationIndex(id) else { return }
        if value.isEmpty {
            state.annotations.remove(at: i)
            selected = nil
        } else {
            var mark = state.annotations[i]
            mark.text = value
            // Grow the box to fit what was typed.
            let bounds = (value as NSString).boundingRect(
                with: CGSize(width: max(1, mark.box.width - 4), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: [.font: mark.font])
            let box = mark.box
            mark.start = box.origin
            mark.end = CGPoint(x: box.maxX, y: box.minY + max(box.height, ceil(bounds.height) + 4))
            state.annotations[i] = mark
        }
        if state.annotations != base.annotations { register(base, name: L("Edit")) }
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Option and Shift keep the line break, Return alone finishes.
            if NSEvent.modifierFlags.isDisjoint(with: [.option, .shift]) {
                commitText()
                return true
            }
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            commitText()
            return true
        default:
            return false
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty else { return super.keyDown(with: event) }

        switch event.keyCode {
        case 51, 117: // Delete, forward delete
            deleteSelected()
        case 36, 76: // Return, Enter
            applyCrop()
        case 53: // Escape
            if cropRect != nil { cropRect = nil; needsDisplay = true } else if selected != nil { selected = nil; needsDisplay = true } else { onClose() }
        case 123, 124, 125, 126:
            nudge(event.keyCode, by: event.modifierFlags.contains(.shift) ? 10 : 1)
        default:
            if let key = event.charactersIgnoringModifiers?.lowercased(),
               let picked = EditorTool.allCases.first(where: { $0.key == key }) {
                tool = picked
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // There is no menu bar, so the editor answers its own shortcuts. Only
        // when the canvas has focus: a text field handles its own.
        guard window?.firstResponder === self,
              event.modifierFlags.intersection([.command, .control, .option]) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch key {
        case "z": shift ? undo.redo() : undo.undo()
        case "c": copyToPasteboard()
        case "s": onSave()
        case "w": onClose()
        case "=", "+": zoom = min(zoom * 1.25, 8)
        case "-": zoom = max(zoom / 1.25, 0.1)
        case "0": zoom = 1 / scale
        default: return false
        }
        return true
    }

    func deleteSelected() {
        guard let i = annotationIndex(selected) else { return }
        let old = state
        state.annotations.remove(at: i)
        selected = nil
        register(old, name: L("Delete"))
        needsDisplay = true
    }

    /// Takes every mark off, leaving the picture as it was. A crop already
    /// applied stays; undo brings it back.
    func clearAll() {
        guard !state.annotations.isEmpty else { return }
        let old = state
        state.annotations.removeAll()
        selected = nil
        register(old, name: L("Clear All"))
        needsDisplay = true
    }

    private func nudge(_ keyCode: UInt16, by amount: CGFloat) {
        guard let i = annotationIndex(selected) else { return }
        let old = state
        let d: CGPoint = switch keyCode {
        case 123: CGPoint(x: -amount, y: 0)
        case 124: CGPoint(x: amount, y: 0)
        case 125: CGPoint(x: 0, y: amount)
        default: CGPoint(x: 0, y: -amount)
        }
        state.annotations[i].start.x += d.x
        state.annotations[i].start.y += d.y
        state.annotations[i].end.x += d.x
        state.annotations[i].end.y += d.y
        register(old, name: L("Edit"))
        needsDisplay = true
    }

    func copyToPasteboard() {
        guard let rep = flattened(), let png = rep.representation(using: .png, properties: [:]) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }

    /// Recolors the selected mark, so the swatches work on what is there as well as on what comes next.
    func recolorSelected(_ color: NSColor) {
        guard let i = annotationIndex(selected), state.annotations[i].color != color else { return }
        let old = state
        state.annotations[i].color = color
        register(old, name: L("Edit"))
        needsDisplay = true
    }

    func resizeSelected() {
        guard let i = annotationIndex(selected), state.annotations[i].width != widthInPoints * scale else { return }
        let old = state
        state.annotations[i].width = widthInPoints * scale
        register(old, name: L("Edit"))
        needsDisplay = true
    }

    private func applyCrop() {
        guard let crop = cropRect?.integral, crop.width >= 1, crop.height >= 1,
              let image = state.image.cropping(to: crop) else { return }
        var new = State(image: image, annotations: state.annotations)
        for i in new.annotations.indices {
            new.annotations[i].start.x -= crop.minX
            new.annotations[i].start.y -= crop.minY
            new.annotations[i].end.x -= crop.minX
            new.annotations[i].end.y -= crop.minY
        }
        cropRect = nil
        set(new, name: L("Crop"))
        tool = .select
    }
}
