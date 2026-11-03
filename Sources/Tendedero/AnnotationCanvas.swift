import AppKit
import Combine

/// What the toolbar has chosen, shared with the canvas.
@MainActor
final class EditorState: ObservableObject {
    @Published var tool: AnnotationTool = .rectangle
    @Published var color: NSColor = .systemRed
    @Published var widthIndex = 1
    @Published var filled = false
    @Published var canUndo = false
    @Published var canRedo = false

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
    private var watching: AnyCancellable?

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
        watching = state.$tool.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.window?.invalidateCursorRects(for: self)
            }
        }
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
        document.draw(in: graphics, extra: draft)
        graphics.cgContext.restoreGState()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: state.tool == .text ? .iBeam : .crosshair)
    }

    private func refreshState() {
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

        let point = imagePoint(convert(event.locationInWindow, from: nil))
        let width = document.widths[state.widthIndex]
        let color = state.color

        switch state.tool {
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
            if !wasTyping { beginText(at: point) }
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
        guard let finished = draft else { return }
        draft = nil
        if isWorthKeeping(finished) {
            document.change { $0.append(finished) }
        }
        refreshState()
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

    private func beginText(at point: CGPoint) {
        let size = document.fontSizes[state.widthIndex]
        let font = NSFont.systemFont(ofSize: size * scale, weight: .medium)
        let origin = viewPoint(point)
        let field = NSTextField(frame: NSRect(x: origin.x, y: origin.y, width: 80, height: font.boundingRectForFont.height + 4))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = state.color
        field.placeholderString = ""
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        addSubview(field)
        self.field = field
        fieldOrigin = point
        window?.makeFirstResponder(field)
    }

    private func finishText() {
        guard let field else { return }
        self.field = nil
        let text = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
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
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }

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
}
