import AppKit
import Combine

/// What the toolbar has chosen, shared with the canvas.
@MainActor
final class EditorState: ObservableObject {
    @Published var tool: AnnotationTool = .rectangle
    /// The kind of mark that is selected, if one is.
    @Published var selection: Annotation.Kind?
    @Published var color: NSColor = EditorState.color(0xFF0000)
    @Published var widthIndex = 1
    @Published var filled = false
    @Published var canUndo = false
    @Published var canRedo = false

    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    var onUndo: () -> Void = {}
    var onRedo: () -> Void = {}
}

/// Shows the picture and the marks on it, and turns the pointer into marks.
@MainActor
final class AnnotationCanvas: NSView, NSTextFieldDelegate {
    let document: AnnotationDocument
    let state: EditorState

    /// Escape, like closing the window, finishes the edit.
    var onFinish: () -> Void = {}

    private var draft: Annotation?
    private var erasing = false
    private var field: NSTextField?
    private var fieldOrigin: CGPoint = .zero
    private var watchers = Set<AnyCancellable>()

    /// The selected mark, and what the pointer is doing to it.
    private var selectedID: UUID?
    private enum Drag {
        case move(last: CGPoint)
        case resize(handle: Int, anchor: CGPoint)
    }
    private var drag: Drag?
    private var dragStarted = false
    /// Set while the toolbar is being brought in line with a selection, so
    /// that does not count as the user changing the mark.
    private var syncing = false
    /// The text being edited again, which is not drawn under its own field.
    private var editingID: UUID?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(document: AnnotationDocument, state: EditorState) {
        self.document = document
        self.state = state
        super.init(frame: .zero)
        // Since macOS 14 a view's drawing is no longer cut off at its edge.
        clipsToBounds = true
        state.onUndo = { [weak self] in self?.undo() }
        state.onRedo = { [weak self] in self?.redo() }
        state.$tool.sink { [weak self] tool in
            guard let self else { return }
            if tool != .select, self.selectedID != nil { self.selectMark(nil) }
            DispatchQueue.main.async { self.window?.invalidateCursorRects(for: self) }
        }.store(in: &watchers)
        // The toolbar's colour, width and fill act on the selected mark.
        state.$color.sink { [weak self] in self?.restyle(color: $0) }.store(in: &watchers)
        state.$widthIndex.sink { [weak self] in self?.restyle(widthIndex: $0) }.store(in: &watchers)
        state.$filled.sink { [weak self] in self?.restyle(filled: $0) }.store(in: &watchers)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    /// Where the picture sits in the view: as large as fits, centred.
    private var imageRect: CGRect {
        let size = document.pixelSize
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// View points per image pixel.
    private var scale: CGFloat {
        let rect = imageRect
        return document.pixelSize.width > 0 ? rect.width / document.pixelSize.width : 1
    }

    private func imagePoint(_ viewPoint: CGPoint) -> CGPoint {
        let rect = imageRect, s = scale
        let x = (viewPoint.x - rect.minX) / s, y = (viewPoint.y - rect.minY) / s
        // Marks may be started a little outside the picture, but not far.
        return CGPoint(x: max(0, min(document.pixelSize.width, x)),
                       y: max(0, min(document.pixelSize.height, y)))
    }

    private func viewPoint(_ imagePoint: CGPoint) -> CGPoint {
        let rect = imageRect, s = scale
        return CGPoint(x: rect.minX + imagePoint.x * s, y: rect.minY + imagePoint.y * s)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard let graphics = NSGraphicsContext.current else { return }
        let rect = imageRect
        graphics.cgContext.saveGState()
        graphics.cgContext.clip(to: rect.intersection(bounds))
        graphics.cgContext.translateBy(x: rect.minX, y: rect.minY)
        graphics.cgContext.scaleBy(x: scale, y: scale)
        graphics.cgContext.interpolationQuality = .high
        document.draw(in: graphics, extra: draft, hiding: editingID)
        graphics.cgContext.restoreGState()
        drawSelection()
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch state.tool {
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    private func refreshState() {
        // Undo can take away the mark that was selected.
        if let id = selectedID, document.index(of: id) == nil { selectMark(nil) }
        state.canUndo = document.canUndo
        state.canRedo = document.canRedo
        needsDisplay = true
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Clicking away from text being typed finishes it.
        let wasTyping = field != nil
        finishText()

        let viewLocation = convert(event.locationInWindow, from: nil)
        let point = imagePoint(viewLocation)
        let width = document.widths[state.widthIndex]
        let color = state.color

        switch state.tool {
        case .select:
            beginSelecting(at: point, viewLocation: viewLocation, clickCount: event.clickCount)
        case .rectangle:
            draft = Annotation(kind: .rectangle, points: [point, point], color: color, width: width, filled: state.filled)
        case .ellipse:
            draft = Annotation(kind: .ellipse, points: [point, point], color: color, width: width, filled: state.filled)
        case .line:
            draft = Annotation(kind: .line, points: [point, point], color: color, width: width)
        case .arrow:
            draft = Annotation(kind: .arrow, points: [point, point], color: color, width: width)
        case .pen:
            draft = Annotation(kind: .pen, points: [point], color: color, width: width)
        case .highlighter:
            draft = Annotation(kind: .highlighter, points: [point], color: color, width: width)
        case .mosaic:
            draft = Annotation(kind: .mosaic, points: [point, point], color: color, width: width)
        case .text:
            // The click that ended one piece of text does not start another.
            if !wasTyping {
                if let existing = textMark(at: point) { beginText(editing: existing) } else { beginText(at: point) }
            }
        case .eraser:
            erasing = false
            erase(at: point)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(convert(event.locationInWindow, from: nil))
        if state.tool == .eraser {
            erase(at: point)
            return
        }
        if state.tool == .select {
            dragSelection(to: point)
            return
        }
        guard var draft else { return }
        switch draft.kind {
        case .pen, .highlighter:
            if let last = draft.points.last, hypot(last.x - point.x, last.y - point.y) < document.unit { return }
            draft.points.append(point)
        default:
            draft.points[1] = point
        }
        self.draft = draft
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        erasing = false
        if state.tool == .select {
            drag = nil
            if dragStarted { dragStarted = false; refreshState() }
            return
        }
        guard let finished = draft else { return }
        draft = nil
        // A click on a mark, with a drawing tool, selects it instead.
        if isClick(finished), let start = finished.points.first,
           let hit = document.topmost(at: start, tolerance: 6 / max(scale, 0.01)) {
            state.tool = .select
            selectMark(document.items[hit].id)
            needsDisplay = true
            return
        }
        if isWorthKeeping(finished) {
            document.change { $0.append(finished) }
        }
        refreshState()
    }

    /// A press that hardly moved.
    private func isClick(_ a: Annotation) -> Bool {
        let box = a.bounds(unit: document.unit)
        return hypot(box.width, box.height) < 3 * document.unit
    }

    /// A click without a drag leaves no shape behind, except a dot of pen.
    private func isWorthKeeping(_ a: Annotation) -> Bool {
        switch a.kind {
        case .pen, .highlighter:
            return true
        default:
            guard a.points.count >= 2 else { return false }
            return hypot(a.points[0].x - a.points[1].x, a.points[0].y - a.points[1].y) > 3 * document.unit
        }
    }

    // MARK: Eraser

    private func erase(at point: CGPoint) {
        let tolerance = 6 / max(scale, 0.01)
        guard let index = document.topmost(at: point, tolerance: tolerance) else { return }
        // One undo step for the whole stroke of the eraser.
        if !erasing {
            erasing = true
            document.change { $0.remove(at: index) }
        } else {
            document.amend { $0.remove(at: index) }
        }
        refreshState()
    }

    // MARK: Text

    /// The text mark under a point, if any.
    private func textMark(at point: CGPoint) -> Annotation? {
        let tolerance = 6 / max(scale, 0.01)
        return document.items.last { $0.kind == .text && $0.hits(point, tolerance: tolerance, unit: document.unit) }
    }

    private func beginText(at point: CGPoint = .zero, editing existing: Annotation? = nil) {
        let size = existing?.fontSize ?? document.fontSizes[state.widthIndex]
        let font = NSFont.systemFont(ofSize: size * scale, weight: .medium)
        let origin = viewPoint(existing?.points.first ?? point)
        let field = NSTextField(frame: NSRect(x: origin.x, y: origin.y, width: 80, height: font.boundingRectForFont.height + 4))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = existing?.color ?? state.color
        field.stringValue = existing?.text ?? ""
        field.placeholderString = ""
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        addSubview(field)
        self.field = field
        fieldOrigin = existing?.points.first ?? point
        if let existing {
            selectMark(nil)
            editingID = existing.id
            needsDisplay = true
        }
        window?.makeFirstResponder(field)
        if existing != nil { controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)) }
    }

    private func finishText() {
        guard let field else { return }
        self.field = nil
        let text = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        // Text edited again replaces what it was, or goes if it is emptied.
        if let id = editingID {
            editingID = nil
            if let i = document.index(of: id) {
                if text.isEmpty {
                    document.change { $0.remove(at: i) }
                } else if text != document.items[i].text {
                    document.change { $0[i].text = text }
                }
            }
            refreshState()
            return
        }
        guard !text.isEmpty else { return }
        let mark = Annotation(kind: .text, points: [fieldOrigin], color: state.color, width: 0,
                              text: text, fontSize: document.fontSizes[state.widthIndex])
        document.change { $0.append(mark) }
        refreshState()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field, let font = field.font else { return }
        let width = (field.stringValue as NSString).size(withAttributes: [.font: font]).width
        field.setFrameSize(NSSize(width: max(80, width + 24), height: field.frame.height))
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // Return, or Tab, ends the text.
        DispatchQueue.main.async { [weak self] in self?.finishText() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape finishes the text and, like everywhere else, the edit.
            finishText()
            onFinish()
            return true
        }
        return false
    }

    /// Called before the window closes, so text still being typed is kept.
    func commitPendingText() { finishText() }

    // MARK: Keys

    /// Escape arrives as cancelOperation only once keys are interpreted.
    override func keyDown(with event: NSEvent) {
        // Delete and forward delete take away the selected mark.
        if (event.keyCode == 51 || event.keyCode == 117), deleteSelection() { return }
        interpretKeyEvents([event])
    }

    override func cancelOperation(_ sender: Any?) { onFinish() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "z":
            if event.modifierFlags.contains(.shift) { redo() } else { undo() }
            return true
        case "w":
            onFinish()
            return true
        default:
            return false
        }
    }

    func undo() {
        finishText()
        document.undo()
        refreshState()
    }

    func redo() {
        finishText()
        document.redo()
        refreshState()
    }

    // MARK: Selection

    private func selectMark(_ id: UUID?) {
        selectedID = id
        drag = nil
        if let id, let i = document.index(of: id) {
            let mark = document.items[i]
            state.selection = mark.kind
            // The toolbar shows the mark's own colour, width and fill.
            syncing = true
            state.color = mark.color
            if mark.kind == .text {
                state.widthIndex = Self.nearest(document.fontSizes, to: mark.fontSize)
            } else if mark.kind != .mosaic {
                state.widthIndex = Self.nearest(document.widths, to: mark.width)
            }
            state.filled = mark.filled
            syncing = false
        } else {
            selectedID = nil
            state.selection = nil
        }
        needsDisplay = true
    }

    private static func nearest(_ values: [CGFloat], to value: CGFloat) -> Int {
        values.indices.min { abs(values[$0] - value) < abs(values[$1] - value) } ?? 0
    }

    private func beginSelecting(at point: CGPoint, viewLocation: CGPoint, clickCount: Int) {
        dragStarted = false
        if clickCount == 2, let text = textMark(at: point) {
            beginText(editing: text)
            return
        }
        // A grip of the selected mark takes the pointer first.
        if let id = selectedID, let i = document.index(of: id),
           let handle = handle(at: viewLocation, of: document.items[i]) {
            let mark = document.items[i]
            let points = Self.handlePoints(of: mark)
            var anchor = points[handle]
            if mark.kind == .rectangle || mark.kind == .ellipse || mark.kind == .mosaic {
                // The corner across from the one held stays where it is.
                anchor = points[3 - handle]
            }
            drag = .resize(handle: handle, anchor: anchor)
            return
        }
        if let hit = document.topmost(at: point, tolerance: 6 / max(scale, 0.01)) {
            selectMark(document.items[hit].id)
            drag = .move(last: point)
        } else {
            selectMark(nil)
        }
    }

    private func dragSelection(to point: CGPoint) {
        guard let drag, let id = selectedID, let i = document.index(of: id) else { return }
        // The first movement is what makes a step to undo, not the click.
        if !dragStarted {
            dragStarted = true
            document.change { _ in }
        }
        switch drag {
        case .move(let last):
            let delta = CGPoint(x: point.x - last.x, y: point.y - last.y)
            document.amend { $0[i].translate(by: delta) }
            self.drag = .move(last: point)
        case .resize(let handle, let anchor):
            document.amend {
                switch $0[i].kind {
                case .rectangle, .ellipse, .mosaic:
                    $0[i].points = [point, anchor]
                case .line, .arrow:
                    $0[i].points[handle] = point
                default:
                    break
                }
            }
        }
        needsDisplay = true
    }

    @discardableResult
    private func deleteSelection() -> Bool {
        guard let id = selectedID, let i = document.index(of: id) else { return false }
        document.change { $0.remove(at: i) }
        selectMark(nil)
        refreshState()
        return true
    }

    /// Applies what the toolbar now says to the selected mark.
    private func restyle(color: NSColor? = nil, widthIndex: Int? = nil, filled: Bool? = nil) {
        guard !syncing, let id = selectedID, let i = document.index(of: id) else { return }
        let before = document.items[i]
        var after = before
        if let color, before.kind != .mosaic { after.color = color }
        if let widthIndex {
            if before.kind == .text {
                after.fontSize = document.fontSizes[widthIndex]
            } else if before.kind != .mosaic {
                after.width = document.widths[widthIndex]
            }
        }
        if let filled, before.kind == .rectangle || before.kind == .ellipse { after.filled = filled }
        guard after.color != before.color || after.width != before.width
                || after.fontSize != before.fontSize || after.filled != before.filled else { return }
        document.change { $0[i] = after }
        refreshState()
    }

    // MARK: Grips

    /// Where a mark can be held to reshape it: the corners of a box, in the
    /// order top left, top right, bottom left, bottom right; or the two ends
    /// of a line. Other marks can be moved but not reshaped.
    private static func handlePoints(of a: Annotation) -> [CGPoint] {
        switch a.kind {
        case .rectangle, .ellipse, .mosaic:
            guard a.points.count >= 2 else { return [] }
            let r = Annotation.rect(a.points[0], a.points[1])
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        case .line, .arrow:
            return Array(a.points.prefix(2))
        default:
            return []
        }
    }

    private func handle(at viewLocation: CGPoint, of mark: Annotation) -> Int? {
        Self.handlePoints(of: mark).indices.first {
            let p = viewPoint(Self.handlePoints(of: mark)[$0])
            return hypot(p.x - viewLocation.x, p.y - viewLocation.y) <= 9
        }
    }

    /// A dashed box round the selected mark, with grips where it has them.
    /// Drawn over the picture in the editor only; the saved file has none.
    private func drawSelection() {
        guard let id = selectedID, let i = document.index(of: id) else { return }
        let mark = document.items[i]
        let box = mark.bounds(unit: document.unit)
        guard !box.isNull else { return }
        let reach = (mark.kind == .highlighter ? mark.width * 1.5 : mark.width / 2) * scale
        let origin = viewPoint(box.origin)
        let rect = CGRect(x: origin.x, y: origin.y, width: box.width * scale, height: box.height * scale)
            .insetBy(dx: -(reach + 4), dy: -(reach + 4))

        let outline = NSBezierPath(rect: rect)
        outline.lineWidth = 1.5
        outline.setLineDash([5, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        outline.stroke()

        for point in Self.handlePoints(of: mark) {
            let p = viewPoint(point)
            let grip = NSBezierPath(rect: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9))
            NSColor.white.setFill()
            grip.fill()
            grip.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            grip.stroke()
        }
    }
}
