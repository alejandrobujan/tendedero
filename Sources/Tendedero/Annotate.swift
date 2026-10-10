import AppKit
import CoreImage
import ImageIO

// MARK: - Architecture
//
// A fast, in-place annotation editor for a screenshot on the line. The system
// Markup extension takes seconds to appear and has no mosaic or blur brush,
// so this one draws everything itself.
//
// One borderless key panel covers the screen under the pointer:
//
//   backdrop (solid, dark)
//   ├─ Viewport         clips and zooms/pans the canvas (pinch, ⌘±, scroll)
//   │   └─ CanvasView   the image, fitted to the screen at first
//   │       ├─ image    the untouched screenshot on a layer
//   │       ├─ overlay  every mark, the one being drawn, selection handles
//   │       └─ editor   a text view while a text mark is being typed
//   ├─ Toolbar          a dark HUD pill directly under the image
//   └─ hint line        shortcuts for what you are doing right now
//
// Marks stay objects until the file is saved: a list of value-type marks in
// image pixels (bottom-left origin, never flipped), redrawn as vectors on
// every change. That is what lets a mark be selected again, moved, resized,
// recolored or, for text, edited, and what keeps zooming sharp. Undo and redo
// are snapshots of that list, which costs bytes, not bitmaps.
//
// Sizes are picked in on-screen points at the zoom the editor opens with and
// stored in pixels, so a mark keeps its size in the file whatever the zoom.
//
// Mosaic and blur are a stroked mask over a copy of the whole image that is
// pixellated or blurred once, so the mosaic grid stays aligned across strokes
// and moving a mosaic reveals the right pixels underneath.
//
// Saving composites the marks at the file's own resolution and goes through
// ImageIO with the original file's properties, so the DPI (Retina
// screenshots are 144) and the color profile survive the edit.

@MainActor
final class Annotate: NSObject {
    static let shared = Annotate()

    /// Called with the file once the edited image has been written back.
    var onSaved: (URL) -> Void = { _ in }

    /// Whether the editor is on screen. The line stays tucked away meanwhile.
    var isOpen: Bool { panel != nil }

    /// Raw values are what gets remembered between edits; the number keys
    /// follow the toolbar order instead.
    enum Tool: String, CaseIterable {
        case select, rect, ellipse, arrow, pen, text, textBox, mosaic, blur

        var kind: CanvasView.Mark.Kind? { CanvasView.Mark.Kind(rawValue: rawValue) }
        var usesColor: Bool { kind?.usesColor ?? false }
        var isText: Bool { kind?.isText ?? false }
        var isBrush: Bool { kind?.isBrush ?? false }
        var isFreehand: Bool { kind?.isFreehand ?? false }
        /// Dragged out from corner to corner; Shift squares or snaps them.
        var isShape: Bool { self == .rect || self == .ellipse || self == .arrow }

        /// V for the pointer, 1–8 for the drawing tools.
        var shortcut: String { self == .select ? "V" : String(Self.allCases.firstIndex(of: self)!) }

        init?(shortcut: String) {
            if shortcut.lowercased() == "v" {
                self = .select
                return
            }
            guard let n = Int(shortcut), n >= 1, n < Self.allCases.count else { return nil }
            self = Self.allCases[n]
        }

        var icon: NSImage? {
            let symbol: String
            switch self {
            case .select: symbol = "cursorarrow"
            case .rect: symbol = "rectangle"
            case .ellipse: symbol = "circle"
            case .arrow: symbol = "arrow.up.right"
            case .pen: symbol = "scribble"
            case .text: return Self.letterIcon(boxed: false)
            case .textBox: return Self.letterIcon(boxed: true)
            case .mosaic: symbol = "checkerboard.rectangle"
            case .blur: symbol = "drop.halffull"
            }
            return NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        }

        /// SF Symbols has no plain "T"; "textformat" reads as "Aa", which
        /// nobody takes for "add text".
        private static func letterIcon(boxed: Bool) -> NSImage {
            let text = NSAttributedString(string: "T", attributes: [
                .font: NSFont.systemFont(ofSize: boxed ? 11 : 17, weight: boxed ? .bold : .medium),
                .foregroundColor: NSColor.black,
            ])
            let glyph = text.size()
            let size = boxed ? NSSize(width: 20, height: 17) : NSSize(width: ceil(glyph.width), height: ceil(glyph.height))
            let image = NSImage(size: size, flipped: false) { r in
                if boxed {
                    let box = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
                    box.lineWidth = 1.5
                    NSColor.black.setStroke()
                    box.stroke()
                }
                text.draw(at: NSPoint(x: ((r.width - glyph.width) / 2).rounded(),
                                      y: ((r.height - glyph.height) / 2).rounded()))
                return true
            }
            image.isTemplate = true
            return image
        }

        var title: String {
            switch self {
            case .select: return L("Select and move")
            case .rect: return L("Rectangle")
            case .ellipse: return L("Ellipse")
            case .arrow: return L("Arrow")
            case .pen: return L("Pen")
            case .text: return L("Text")
            case .textBox: return L("Text box")
            case .mosaic: return L("Mosaic")
            case .blur: return L("Blur")
            }
        }
    }

    /// Ink colors. Red first: it is what annotations are made of.
    static let palette: [(NSColor, String)] = [
        (NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1), L("Red")),
        (NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1), L("Yellow")),
        (NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), L("Green")),
        (NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1), L("Blue")),
        (NSColor.white, L("White")),
        (NSColor.black, L("Black")),
    ]

    /// The original file and what is needed to write it back the same way.
    private struct Source {
        let url: URL
        let type: CFString
        let properties: [CFString: Any]
    }

    private let ci = CIContext()
    private var panel: NSPanel?
    private var canvas: CanvasView?
    private var viewport: Viewport?
    private var source: Source?
    private var toolButtons: [Tool: HUDButton] = [:]
    private var sizeButtons: [SizeButton] = []
    private var colorButtons: [DotButton] = []
    private var undoButton: HUDButton?
    private var redoButton: HUDButton?
    private var hint: NSTextField?
    private var hintCenterX: CGFloat = 0
    private var toast: NSView?
    private var toastAnchor: NSPoint = .zero
    /// Escape with unsaved marks only arms the discard; a second one inside
    /// this window confirms it.
    private var escapeArmedUntil = Date.distantPast

    // The last tool, sizes and color are remembered between edits.
    private var tool: Tool {
        get { UserDefaults.standard.string(forKey: "annotateTool").flatMap(Tool.init(rawValue:)) ?? .rect }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "annotateTool") }
    }
    private var lineSize: Int {
        get { Self.clampSize(UserDefaults.standard.object(forKey: "annotateLineSize") as? Int ?? 1) }
        set { UserDefaults.standard.set(Self.clampSize(newValue), forKey: "annotateLineSize") }
    }
    private var textSize: Int {
        get { Self.clampSize(UserDefaults.standard.object(forKey: "annotateTextSize") as? Int ?? 1) }
        set { UserDefaults.standard.set(Self.clampSize(newValue), forKey: "annotateTextSize") }
    }
    private var colorIndex: Int {
        get { min(Self.palette.count - 1, max(0, UserDefaults.standard.integer(forKey: "annotateColor"))) }
        set { UserDefaults.standard.set(newValue, forKey: "annotateColor") }
    }

    private static func clampSize(_ i: Int) -> Int { max(0, min(CanvasView.sizeCount - 1, i)) }

    // MARK: Opening

    func edit(_ url: URL) {
        close(committing: false, animated: false)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let screen = Self.screenUnderPointer() else {
            NSWorkspace.shared.open(url)
            return
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        source = Source(url: url, type: type, properties: properties)

        // The image's size in points comes from its DPI, so a Retina
        // screenshot opens at the size it was on screen, not doubled.
        let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let pointsPerPixel = 72 / (dpi > 0 ? dpi : 72)
        let natural = NSSize(width: CGFloat(cg.width) * pointsPerPixel,
                             height: CGFloat(cg.height) * pointsPerPixel)

        // Panel-local geometry: everything is laid out inside the visible
        // frame, clear of the menu bar and the Dock, on whichever screen.
        let local = NSRect(origin: .zero, size: screen.frame.size)
        let visible = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let area = visible.insetBy(dx: 32, dy: 20)

        let bar = makeToolbar()
        let barSize = bar.frame.size
        let gap: CGFloat = 14, hintHeight: CGFloat = 26
        let maxW = area.width, maxH = area.height - barSize.height - gap - hintHeight
        let fit = min(1, maxW / natural.width, maxH / natural.height)
        let size = NSSize(width: max(1, (natural.width * fit).rounded()),
                          height: max(1, (natural.height * fit).rounded()))

        // Image, toolbar and hint form one group, centered in the area. The
        // viewport reaches from just above the toolbar to the top of the
        // visible frame, so a zoomed-in image has room to grow.
        let groupHeight = size.height + gap + barSize.height + hintHeight
        let bottom = (area.midY - groupHeight / 2).rounded()
        let barY = bottom + hintHeight
        let viewportY = barY + barSize.height + 4
        let viewportFrame = NSRect(x: visible.minX, y: viewportY, width: visible.width, height: visible.maxY - viewportY)
        let fitFrame = NSRect(x: (area.midX - size.width / 2).rounded() - visible.minX, y: gap - 4,
                              width: size.width, height: size.height)

        let cv = CanvasView(frame: fitFrame)
        cv.configure(base: cg, ci: ci)
        cv.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        cv.onChange = { [weak self] in self?.refresh() }
        canvas = cv
        let vp = Viewport(frame: viewportFrame, canvas: cv, fitFrame: fitFrame, naturalWidth: natural.width)
        vp.onZoom = { [weak self] percent in self?.showToast("\(percent)%") }
        viewport = vp

        let panel = KeyPanel(contentRect: screen.frame, styleMask: [.borderless],
                             backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: .darkAqua)
        // Solid, not translucent: the desktop bleeding through makes the
        // screenshot look washed out.
        panel.isOpaque = true
        panel.backgroundColor = NSColor(white: 0.09, alpha: 1)
        let root = NSView(frame: local)
        panel.contentView = root

        root.addSubview(vp)
        bar.frame.origin = NSPoint(x: clamp((area.midX - barSize.width / 2).rounded(),
                                            visible.minX + 8, visible.maxX - barSize.width - 8),
                                   y: barY)
        root.addSubview(bar)

        let hint = NSTextField(labelWithString: "")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor(white: 1, alpha: 0.38)
        hint.frame.origin.y = bottom
        root.addSubview(hint)
        self.hint = hint
        hintCenterX = area.midX
        // Toasts float just inside the bottom edge of the image.
        toastAnchor = NSPoint(x: area.midX, y: viewportY + fitFrame.minY + 16)

        self.panel = panel
        select(tool)

        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(cv)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
    }

    private static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    // MARK: Toolbar

    private func makeToolbar() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        toolButtons = [:]
        for (i, t) in Tool.allCases.enumerated() {
            if t == .rect || t == .mosaic { stack.addArrangedSubview(Self.divider()) }
            let b = HUDButton(image: t.icon, fallback: t.title, tip: "\(t.title)   \(t.shortcut)")
            b.tag = i
            b.target = self
            b.action = #selector(pickTool(_:))
            toolButtons[t] = b
            stack.addArrangedSubview(b)
        }

        stack.addArrangedSubview(Self.divider())
        sizeButtons = []
        for i in 0..<CanvasView.sizeCount {
            let b = SizeButton(level: i)
            b.tag = i
            b.target = self
            b.action = #selector(pickSize(_:))
            sizeButtons.append(b)
            stack.addArrangedSubview(b)
        }

        stack.addArrangedSubview(Self.divider())
        colorButtons = []
        for (i, entry) in Self.palette.enumerated() {
            let b = DotButton(color: entry.0, diameter: 14, tip: entry.1, width: 24)
            b.tag = i
            b.target = self
            b.action = #selector(pickColor(_:))
            colorButtons.append(b)
            stack.addArrangedSubview(b)
        }

        stack.addArrangedSubview(Self.divider())
        let undo = HUDButton(symbol: "arrow.uturn.backward", fallback: "↶",
                             tip: L("Undo") + "   ⌘Z")
        undo.target = self
        undo.action = #selector(undo(_:))
        let redo = HUDButton(symbol: "arrow.uturn.forward", fallback: "↷",
                             tip: L("Redo") + "   ⇧⌘Z")
        redo.target = self
        redo.action = #selector(redo(_:))
        undoButton = undo
        redoButton = redo
        stack.addArrangedSubview(undo)
        stack.addArrangedSubview(redo)

        stack.addArrangedSubview(Self.divider())
        let cancel = HUDButton(symbol: "xmark", fallback: "✕",
                               tip: L("Discard changes") + "   Esc")
        cancel.target = self
        cancel.action = #selector(cancel(_:))
        stack.addArrangedSubview(cancel)
        let done = DoneButton(title: L("Done"),
                              tip: L("Save to the file") + "   ⏎")
        done.target = self
        done.action = #selector(commit(_:))
        stack.addArrangedSubview(done)
        stack.setCustomSpacing(6, after: cancel)

        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor
        bar.layer?.cornerRadius = 12
        bar.layer?.cornerCurve = .continuous
        bar.layer?.borderWidth = 0.5
        bar.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        bar.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.5)
            s.shadowBlurRadius = 16
            s.shadowOffset = NSSize(width: 0, height: -4)
            return s
        }()
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        bar.frame.size = stack.fittingSize
        return bar
    }

    private static func divider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 1),
            v.heightAnchor.constraint(equalToConstant: 18),
        ])
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(v)
        NSLayoutConstraint.activate([
            wrap.widthAnchor.constraint(equalToConstant: 11),
            wrap.heightAnchor.constraint(equalToConstant: 32),
            v.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            v.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
        ])
        return wrap
    }

    // MARK: Actions

    @objc private func pickTool(_ sender: NSButton) {
        select(Tool.allCases[sender.tag])
    }

    /// What the size and color controls act on: the mark being typed or
    /// the selected one, else the defaults for the current tool.
    private var styleTarget: (isText: Bool, isBrush: Bool, usesColor: Bool) {
        if let m = canvas?.focus { return (m.kind.isText, m.kind.isBrush, m.kind.usesColor) }
        return (tool.isText, tool.isBrush, tool.usesColor)
    }

    @objc private func pickSize(_ sender: NSButton) { setSize(sender.tag) }

    private func setSize(_ i: Int) {
        let i = Self.clampSize(i)
        if styleTarget.isText { textSize = i } else { lineSize = i }
        canvas?.style = currentStyle
        canvas?.applySize(i)
        refresh()
    }

    private var displayedSize: Int? {
        if let m = canvas?.focus { return canvas?.sizeIndex(of: m) }
        return tool.isText ? textSize : lineSize
    }

    @objc private func pickColor(_ sender: NSButton) {
        colorIndex = sender.tag
        canvas?.style = currentStyle
        if canvas?.focus != nil {
            canvas?.applyColor(Self.palette[sender.tag].0)
        } else if !tool.usesColor {
            // Picking a color while on mosaic, blur or the pointer means
            // you want to draw: back to the last tool that uses ink.
            select(lastInkTool)
        }
        refresh()
    }

    private var lastInkTool: Tool = .rect

    private func select(_ t: Tool) {
        tool = t
        if t.usesColor { lastInkTool = t }
        canvas?.style = currentStyle
        canvas?.tool = t
        for (k, b) in toolButtons { b.isOn = k == t }
        refresh()
    }

    private var currentStyle: CanvasView.Style {
        CanvasView.Style(color: Self.palette[colorIndex].0, lineSize: lineSize, textSize: textSize)
    }

    /// Brings the toolbar, the history buttons and the hint in line with
    /// the canvas after anything changed.
    private func refresh() {
        guard let canvas else { return }
        let target = styleTarget
        let size = displayedSize
        let last = CanvasView.sizeCount - 1
        for (i, b) in sizeButtons.enumerated() {
            b.mode = target.isText ? .letter : .dot
            b.isOn = i == size
            let points = Int(target.isText ? CanvasView.fontPoints[i]
                             : target.isBrush ? CanvasView.brushPoints[i] : CanvasView.linePoints[i])
            b.toolTip = (target.isText
                ? L("Text size")
                : L("Line width"))
                + " \(points) pt" + (i == 0 ? "   [" : i == last ? "   ]" : "")
        }
        let shownColor = canvas.focus.flatMap { m in Self.palette.firstIndex { $0.0 == m.color } } ?? colorIndex
        for (i, b) in colorButtons.enumerated() {
            b.isDimmed = !target.usesColor
            b.isOn = i == shownColor
        }
        undoButton?.isEnabled = canvas.canUndo
        redoButton?.isEnabled = canvas.canRedo
        refreshHint()
    }

    private func refreshHint() {
        guard let hint, let canvas else { return }
        let text: String
        if canvas.isEditingText {
            text = L("Esc or click outside  Finish   ·   ⏎ New line   ·   ⌘Z Undo typing   ·   Size and color apply as you type")
        } else if canvas.focus != nil {
            text = L("Drag to move   ·   Drag the handles to resize   ·   ⌫ Delete   ·   ←↑↓→ Nudge   ·   ⌘D Duplicate   ·   Double-click text to edit")
        } else {
            text = L("⏎ Done   ·   Esc Cancel   ·   ⌘Z Undo   ·   V Select   ·   1–8 Tools   ·   [ ] Size   ·   ⇧ Straight / square / circle   ·   Pinch or ⌘± Zoom   ·   Space-drag Pan")
        }
        guard hint.stringValue != text else { return }
        hint.stringValue = text
        hint.sizeToFit()
        hint.frame.origin.x = (hintCenterX - hint.frame.width / 2).rounded()
    }

    @objc private func undo(_ sender: Any? = nil) { canvas?.undo() }

    @objc private func redo(_ sender: Any? = nil) { canvas?.redo() }

    @objc private func cancel(_ sender: Any? = nil) { close(committing: false) }

    @objc private func commit(_ sender: Any? = nil) { close(committing: true) }

    /// Escape never throws work away by surprise: it lets go of a selection
    /// first, and with marks on the image the next press only asks for a
    /// second.
    private func escape() {
        if canvas?.deselect() == true { return }
        guard canvas?.isDirty == true, Date() >= escapeArmedUntil else {
            cancel()
            return
        }
        escapeArmedUntil = Date().addingTimeInterval(2)
        showToast(L("Press Esc again to discard your changes"))
    }

    /// Canvas keyboard entry. Text being typed gets its keys first.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let step: CGFloat = flags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 53: escape(); return true                       // Esc
        case 36, 76: commit(); return true                   // Return, Enter
        case 51, 117: return canvas?.deleteSelection() ?? false
        case 123: return canvas?.nudge(dx: -step, dy: 0) ?? false
        case 124: return canvas?.nudge(dx: step, dy: 0) ?? false
        case 125: return canvas?.nudge(dx: 0, dy: -step) ?? false
        case 126: return canvas?.nudge(dx: 0, dy: step) ?? false
        default: break
        }
        if flags.contains(.command) {
            switch chars {
            case "z": flags.contains(.shift) ? redo() : undo(); return true
            case "s": commit(); return true
            case "d": return canvas?.duplicateSelection() ?? false
            case "=", "+": viewport?.zoomStep(in: true); return true
            case "-": viewport?.zoomStep(in: false); return true
            case "0": viewport?.fit(); return true
            case "1": viewport?.actualSize(); return true
            default: return false
            }
        }
        if let t = Tool(shortcut: chars) { select(t); return true }
        if chars == "[" { setSize((displayedSize ?? 1) - 1); return true }
        if chars == "]" { setSize((displayedSize ?? 1) + 1); return true }
        return false
    }

    private func showToast(_ text: String) {
        toast?.removeFromSuperview()
        guard let root = panel?.contentView else { return }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let pill = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.width + 28, height: 32))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(white: 0.24, alpha: 0.96).cgColor
        pill.layer?.cornerRadius = 16
        label.frame.origin = NSPoint(x: 14, y: (32 - label.frame.height) / 2)
        pill.addSubview(label)
        pill.frame.origin = NSPoint(x: (toastAnchor.x - pill.frame.width / 2).rounded(), y: toastAnchor.y)
        root.addSubview(pill)
        toast = pill
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self, weak pill] in
            guard let pill else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                pill.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    pill.removeFromSuperview()
                    if self?.toast === pill { self?.toast = nil }
                }
            })
        }
    }

    // MARK: Closing and saving

    private func close(committing: Bool, animated: Bool = true) {
        canvas?.finishEditing()
        // Nothing drawn means nothing to write: the file is left untouched.
        if committing, let source, let canvas, canvas.isDirty, let baked = canvas.bake() {
            write(baked, to: source)
        }
        guard let panel else { return }
        self.panel = nil
        canvas = nil
        viewport = nil
        source = nil
        toast = nil
        hint = nil
        toolButtons = [:]
        sizeButtons = []
        colorButtons = []
        undoButton = nil
        redoButton = nil
        escapeArmedUntil = .distantPast
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func write(_ image: CGImage, to source: Source) {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, source.type, 1, nil) else {
            NSSound.beep()
            return
        }
        var properties = source.properties
        properties[kCGImageDestinationLossyCompressionQuality] = 0.92
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            NSSound.beep()
            return
        }
        do {
            try (data as Data).write(to: source.url, options: .atomic)
            onSaved(source.url)
        } catch {
            NSSound.beep()
        }
    }
}

private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
    max(lo, min(hi, v))
}

/// A borderless panel that still accepts keystrokes (borderless windows
/// refuse key status by default, which would silence the text tool).
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Toolbar controls

/// The hover highlight every toolbar control shares.
private class HoverButton: NSButton {
    var hovering = false { didSet { hoverChanged() } }
    private var tracking: NSTrackingArea?

    func hoverChanged() { needsDisplay = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    func setUp(width: CGFloat, tip: String?) {
        title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        refusesFirstResponder = true
        if let tip {
            toolTip = tip
            setAccessibilityLabel(tip)
        }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    override var isFlipped: Bool { false }
}

/// An icon button for the dark HUD: a soft highlight on hover, a solid one
/// when it is the current tool.
private final class HUDButton: HoverButton {
    var isOn = false { didSet { refresh() } }

    override var isEnabled: Bool { didSet { refresh() } }

    convenience init(symbol: String, fallback: String, tip: String) {
        self.init(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)), fallback: fallback, tip: tip)
    }

    init(image: NSImage?, fallback: String, tip: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        setUp(width: 32, tip: tip)
        if let image {
            self.image = image
            imagePosition = .imageOnly
        } else {
            title = fallback
        }
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hoverChanged() { refresh() }

    private func refresh() {
        let fill: NSColor = isOn ? NSColor(white: 1, alpha: 0.20)
            : (hovering && isEnabled ? NSColor(white: 1, alpha: 0.08) : .clear)
        layer?.backgroundColor = fill.cgColor
        contentTintColor = isOn ? .white : NSColor(white: 1, alpha: isEnabled ? 0.72 : 0.22)
    }
}

/// One step of the size scale: a dot as thick as the line for strokes, a
/// letter as big as the type for text.
private final class SizeButton: HoverButton {
    enum Mode { case dot, letter }

    private static let dots: [CGFloat] = [3, 5, 7, 10, 13]
    private static let letters: [CGFloat] = [9, 11, 13, 16, 19]

    let level: Int
    var mode = Mode.dot { didSet { if mode != oldValue { needsDisplay = true } } }
    var isOn = false { didSet { needsDisplay = true } }

    init(level: Int) {
        self.level = level
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 32))
        setUp(width: 26, tip: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let plate = NSRect(x: 1, y: 3, width: bounds.width - 2, height: bounds.height - 6)
        if isOn || hovering {
            NSColor(white: 1, alpha: isOn ? 0.20 : 0.08).setFill()
            NSBezierPath(roundedRect: plate, xRadius: 6, yRadius: 6).fill()
        }
        let ink = NSColor(white: 1, alpha: isOn ? 1 : 0.72)
        switch mode {
        case .dot:
            let d = Self.dots[level]
            ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)).fill()
        case .letter:
            let font = NSFont.systemFont(ofSize: Self.letters[level], weight: .semibold)
            let a = NSAttributedString(string: "A", attributes: [.font: font, .foregroundColor: ink])
            let baseline = (bounds.midY - font.capHeight / 2).rounded()
            a.draw(at: NSPoint(x: (bounds.midX - a.size().width / 2).rounded(), y: baseline + font.descender))
        }
    }
}

/// A round color swatch. The current one wears a ring.
private final class DotButton: HoverButton {
    let dotColor: NSColor
    let diameter: CGFloat
    var isOn = false { didSet { needsDisplay = true } }
    var isDimmed = false { didSet { needsDisplay = true } }

    init(color: NSColor, diameter: CGFloat, tip: String, width: CGFloat) {
        dotColor = color
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 32))
        setUp(width: width, tip: tip)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isDimmed ? 0.3 : 1
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let r = diameter / 2
        let around = NSRect(x: c.x - r - 4, y: c.y - r - 4, width: diameter + 8, height: diameter + 8)
        if isOn && !isDimmed {
            let ring = NSBezierPath(ovalIn: around)
            ring.lineWidth = 1.5
            NSColor(white: 1, alpha: 0.9).setStroke()
            ring.stroke()
        } else if hovering && !isDimmed {
            NSColor(white: 1, alpha: 0.08).setFill()
            NSBezierPath(ovalIn: around).fill()
        }
        let dot = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: diameter, height: diameter))
        dotColor.withAlphaComponent(alpha).setFill()
        dot.fill()
        // An edge so black still reads on the dark bar, and white on light.
        dot.lineWidth = 1
        NSColor(white: 1, alpha: 0.28 * alpha).setStroke()
        dot.stroke()
    }
}

/// The one prominent button: an accent-filled "✓ Done". It draws itself,
/// because NSButton's own image-and-title layout pushes the checkmark and
/// the label to opposite ends once the button is wider than its content.
private final class DoneButton: HoverButton {
    private static let labelFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let label: NSAttributedString
    private let check: NSImage?
    private let gap: CGFloat = 5

    init(title: String, tip: String) {
        label = NSAttributedString(string: title, attributes: [.font: Self.labelFont, .foregroundColor: NSColor.white])
        check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
            .map { symbol in
                NSImage(size: symbol.size, flipped: false) { r in
                    symbol.draw(in: r)
                    NSColor.white.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
            }
        super.init(frame: .zero)
        let content = (check.map { $0.size.width + gap } ?? 0) + label.size().width
        setUp(width: ceil(content) + 28, tip: tip)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let fill = isHighlighted ? accent.blended(withFraction: 0.18, of: .black)
            : hovering ? accent.blended(withFraction: 0.10, of: .white) : accent
        (fill ?? accent).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()

        // Checkmark and label sit as one centered group, both centered on
        // the label's cap height so the glyphs line up optically.
        let checkSize = check?.size ?? .zero
        let content = (check == nil ? 0 : checkSize.width + gap) + label.size().width
        var x = ((bounds.width - content) / 2).rounded()
        let mid = bounds.midY
        if let check {
            check.draw(in: NSRect(x: x, y: (mid - checkSize.height / 2).rounded(),
                                  width: checkSize.width, height: checkSize.height))
            x += checkSize.width + gap
        }
        let baseline = (mid - Self.labelFont.capHeight / 2).rounded()
        label.draw(at: NSPoint(x: x, y: baseline + Self.labelFont.descender))
    }
}
