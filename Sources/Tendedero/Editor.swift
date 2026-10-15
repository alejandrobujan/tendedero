import AppKit

/// Annotates a screenshot in a window of its own, modelled on the editor of
/// Greenshot: a tool strip, a colour strip, and marks that stay editable until
/// the image is saved. Saving writes the result over the original file, the
/// way Markup and Trim do.
@MainActor
final class Editor: NSObject, NSWindowDelegate {
    static let shared = Editor()

    /// Called with the file once the edited image has been written back.
    var onSaved: (URL) -> Void = { _ in }
    /// The Trash button: the file is unwanted, the line takes it down.
    var onTrash: (URL) -> Void = { _ in }
    /// The editor is up; the line can get out of the way.
    var onOpen: () -> Void = {}

    private var window: NSWindow?
    private var canvas: EditorCanvas?
    private var url: URL?
    private var scroll: NSScrollView?
    private var toolStrip: NSSegmentedControl?

    private static let palette: [(name: String, color: NSColor)] = [
        (L("Red"), .systemRed), (L("Orange"), .systemOrange), (L("Yellow"), .systemYellow),
        (L("Green"), .systemGreen), (L("Blue"), .systemBlue), (L("Black"), .black), (L("White"), .white),
    ]
    /// Stroke widths in points: thin, medium, thick.
    private static let widths: [CGFloat] = [2, 4, 7]

    func edit(_ url: URL) {
        if let window {
            // One editor at a time. The old one may ask about unsaved changes.
            window.performClose(nil)
            if self.window != nil {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                return
            }
        }

        guard let image = NSImage(contentsOf: url), let cg = Self.pixels(of: image) else {
            NSSound.beep()
            return
        }
        let scale = max(1, CGFloat(cg.width) / max(1, image.size.width))
        let canvas = EditorCanvas(image: cg, scale: scale)
        canvas.zoom = Self.initialZoom(pixels: canvas.pixelSize, scale: scale)
        canvas.color = Self.palette[0].color
        canvas.widthInPoints = Self.widths[1]
        canvas.onToolChange = { [weak self] tool in self?.toolStrip?.selectedSegment = tool.rawValue }
        canvas.onSave = { [weak self] in self?.saveAndClose() }
        canvas.onClose = { [weak self] in self?.window?.performClose(nil) }

        let scroll = NSScrollView()
        scroll.contentView = CenteredClipView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.allowsMagnification = false

        // The bar sits under the title, in the window itself rather than in
        // an NSToolbar: a toolbar hides what does not fit behind a menu,
        // this one wraps onto another row.
        let bar = FlowBar(views: makeBar(), spacing: 8, insets: NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12))
        let column = NSStackView(views: [bar, Separator(), scroll])
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .width
        column.distribution = .fill
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        bar.setContentHuggingPriority(.required, for: .vertical)

        let content = CGSize(width: max(640, canvas.frame.width), height: max(240, canvas.frame.height) + 44)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: content),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = url.lastPathComponent
        window.contentView = column
        window.contentMinSize = CGSize(width: 480, height: 240)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.window = window
        self.canvas = canvas
        self.scroll = scroll
        self.url = url
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        onOpen()
    }

    /// The pixels of the file, not of a version scaled to the screen.
    private static func pixels(of image: NSImage) -> CGImage? {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).max(by: { $0.pixelsWide < $1.pixelsWide }),
           let cg = rep.cgImage {
            return cg
        }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Actual size, unless that does not fit the screen.
    private static func initialZoom(pixels: CGSize, scale: CGFloat) -> CGFloat {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let fit = min((visible.width * 0.9) / pixels.width, (visible.height * 0.8) / pixels.height)
        return min(1 / scale, fit)
    }

    // MARK: Saving

    @discardableResult
    private func save() -> Bool {
        guard let canvas, let url, let rep = canvas.flattened() else { NSSound.beep(); return false }
        let data: Data?
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        case "tiff", "tif": data = rep.representation(using: .tiff, properties: [:])
        default: data = rep.representation(using: .png, properties: [:])
        }
        do {
            guard let data else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
            // Saved and on the clipboard at once, ready to paste somewhere.
            if let png = rep.representation(using: .png, properties: [:]) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(png, forType: .png)
            }
            canvas.markClean()
            onSaved(url)
            return true
        } catch {
            log.error("Could not save the edited screenshot: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let canvas, canvas.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = L("Save your changes?")
        alert.informativeText = L("The screenshot has marks that are not saved yet.")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Don't Save"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        AppDelegate.lastWindowClose = Date()
        window?.delegate = nil
        window = nil
        canvas = nil
        scroll = nil
        url = nil
        toolStrip = nil
    }

    // MARK: Bar

    private func makeBar() -> [NSView] {
        let tools = EditorTool.allCases
        let toolStrip = NSSegmentedControl(images: tools.map { Self.symbol($0.symbol, $0.title) },
                                           trackingMode: .selectOne, target: self,
                                           action: #selector(toolChanged(_:)))
        for (i, tool) in tools.enumerated() {
            toolStrip.setToolTip("\(tool.title) (\(tool.key.uppercased()))", forSegment: i)
        }
        toolStrip.selectedSegment = EditorTool.select.rawValue
        self.toolStrip = toolStrip

        let colors = NSSegmentedControl(images: Self.palette.map { Self.swatch($0.color) },
                                        trackingMode: .selectOne, target: self,
                                        action: #selector(colorChanged(_:)))
        for (i, entry) in Self.palette.enumerated() { colors.setToolTip(entry.name, forSegment: i) }
        colors.selectedSegment = 0

        let sizes = NSSegmentedControl(
            images: [6.0, 9.0, 13.0].map { Self.symbol("circle.fill", L("Size"), pointSize: $0) },
            trackingMode: .selectOne, target: self, action: #selector(sizeChanged(_:)))
        sizes.selectedSegment = 1
        sizes.toolTip = L("Size")

        // Momentary: each segment is a button.
        let zoom = NSSegmentedControl(
            images: ["minus.magnifyingglass", "plus.magnifyingglass", "1.magnifyingglass", "arrow.up.left.and.arrow.down.right"]
                .map { Self.symbol($0, L("Zoom")) },
            trackingMode: .momentary, target: self, action: #selector(zoomChanged(_:)))
        for (i, tip) in [L("Zoom out"), L("Zoom in"), L("Actual size"), L("Fit to window")].enumerated() {
            zoom.setToolTip(tip, forSegment: i)
        }

        return [
            toolStrip, colors, sizes, zoom,
            Self.button(L("Clear Selection"), "eraser", self, #selector(deleteSelected)),
            Self.button(L("Clear All"), "eraser.line.dashed", self, #selector(clearAll)),
            Self.button(L("Move to Trash"), "trash", self, #selector(trashClicked)),
            Self.button(L("Copy"), "doc.on.doc", self, #selector(copyImage)),
            Self.button(L("Save"), "square.and.arrow.down", self, #selector(saveClicked)),
        ]
    }

    private static func button(_ label: String, _ symbolName: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let button = NSButton(image: symbol(symbolName, label), target: target, action: action)
        button.bezelStyle = .toolbar
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    private static func symbol(_ name: String, _ description: String, pointSize: CGFloat? = nil) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
        guard let pointSize else { return image }
        return image.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular)) ?? image
    }

    /// A round chip of the colour. It is not a template image, so the
    /// segmented control leaves its colour alone.
    private static func swatch(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            color.setFill()
            dot.fill()
            NSColor.separatorColor.setStroke()
            dot.lineWidth = 1
            dot.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Actions

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        guard let tool = EditorTool(rawValue: sender.selectedSegment) else { return }
        canvas?.tool = tool
        window?.makeFirstResponder(canvas)
    }

    @objc private func colorChanged(_ sender: NSSegmentedControl) {
        let color = Self.palette[sender.selectedSegment].color
        canvas?.color = color
        canvas?.recolorSelected(color)
        window?.makeFirstResponder(canvas)
    }

    @objc private func sizeChanged(_ sender: NSSegmentedControl) {
        canvas?.widthInPoints = Self.widths[sender.selectedSegment]
        canvas?.resizeSelected()
        window?.makeFirstResponder(canvas)
    }

    @objc private func zoomChanged(_ sender: NSSegmentedControl) {
        guard let canvas else { return }
        switch sender.selectedSegment {
        case 0: canvas.zoom = max(canvas.zoom / 1.25, 0.1)
        case 1: canvas.zoom = min(canvas.zoom * 1.25, 8)
        case 2: canvas.zoom = 1 / canvas.scale
        default: canvas.zoom = fitZoom()
        }
        window?.makeFirstResponder(canvas)
    }

    /// The zoom at which the whole picture is in view.
    private func fitZoom() -> CGFloat {
        guard let canvas, let scroll else { return 1 }
        let room = scroll.contentView.bounds.size
        return max(0.05, min(room.width / canvas.pixelSize.width, room.height / canvas.pixelSize.height))
    }

    @objc private func deleteSelected() { canvas?.deleteSelected() }
    @objc private func clearAll() { canvas?.clearAll() }
    /// The screenshot itself goes, marks and all, and the editor with it.
    /// Nothing to ask: the Trash keeps it.
    @objc private func trashClicked() {
        guard let url else { return }
        canvas?.markClean()
        window?.close()
        onTrash(url)
    }
    @objc private func copyImage() { canvas?.copyToPasteboard() }
    /// Saving is the end of the job: the window goes with it, like Markup.
    private func saveAndClose() {
        guard save() else { return }
        window?.close()
    }

    @objc private func saveClicked() { saveAndClose() }
}

/// A row of controls that wraps onto more rows when the window is too
/// narrow for one, instead of hiding what does not fit.
final class FlowBar: NSView {
    private let spacing: CGFloat
    private let insets: NSEdgeInsets
    private var height: CGFloat = 0

    init(views: [NSView], spacing: CGFloat, insets: NSEdgeInsets) {
        self.spacing = spacing
        self.insets = insets
        super.init(frame: .zero)
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        height = rows(for: 10_000).height
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }

    /// Where each control goes for a given width, and how tall that makes the bar.
    private func rows(for width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        var frames: [CGRect] = []
        var x = insets.left, y = insets.top, rowHeight: CGFloat = 0
        let limit = width - insets.right
        for view in subviews {
            let size = view.fittingSize
            if x > insets.left, x + size.width > limit {
                x = insets.left
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, y + rowHeight + insets.bottom)
    }

    override func layout() {
        super.layout()
        let (frames, newHeight) = rows(for: bounds.width)
        for (view, frame) in zip(subviews, frames) {
            // Controls of different heights share the row's centre line.
            let rowHeight = frames.filter { $0.minY == frame.minY }.map(\.height).max() ?? frame.height
            view.frame = CGRect(x: frame.minX, y: frame.minY + (rowHeight - frame.height) / 2,
                                width: frame.width, height: frame.height).integral
        }
        if newHeight != height {
            height = newHeight
            invalidateIntrinsicContentSize()
        }
    }
}

final class Separator: NSBox {
    init() {
        super.init(frame: .zero)
        boxType = .separator
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Keeps a picture smaller than the window in the middle of it.
final class CenteredClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView else { return rect }
        if document.frame.width < rect.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if document.frame.height < rect.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}
