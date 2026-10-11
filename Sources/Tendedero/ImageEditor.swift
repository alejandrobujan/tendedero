import AppKit
import UniformTypeIdentifiers

enum EditorTool: Int { case crop, cutOut, arrow, rectangle }

/// A native editor shared by ordinary screenshots and scrolling captures.
/// All edits stay in memory until Save Copy or Export; the source is preserved.
@MainActor
final class ImageEditor: NSObject, NSWindowDelegate {
    static let shared = ImageEditor()
    var onSaved: (URL, URL) -> Void = { _, _ in }
    var closingPrompt: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }

    private var window: NSWindow?
    private var canvas: EditorCanvas?
    private var scroll: NSScrollView?
    private var previous: CGImage?
    private var source: URL?
    private var applyButton: NSButton?
    private var undoButton: NSButton?
    private var saveButton: NSButton?
    private var axes: NSSegmentedControl?
    private var instruction: NSTextField?
    private var details: NSTextField?
    private var zoomLabel: NSTextField?
    private var zoomObserver: NSKeyValueObservation?
    private var edits = 0

    func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { edit(url) }
    }

    func edit(_ url: URL, tool: EditorTool = .cutOut, present: Bool = true) {
        guard let image = ImageEditing.load(url) else {
            showError(L("Could not open this image"))
            return
        }
        guard confirmClosing() else { return }
        window?.close()
        source = url
        let screen = LinePanel.screenUnderPointer()
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = NSSize(width: min(1040, visible.width - 48), height: min(760, visible.height - 48))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false, screen: screen)
        window.title = L("Image Editor") + ": " + url.lastPathComponent
        window.representedURL = url
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 820, height: 440)
        window.isReleasedWhenClosed = false
        window.delegate = self

        let tools = NSSegmentedControl(labels: [L("Crop"), L("Cut Out"), L("Arrow"), L("Rectangle")],
                                       trackingMode: .selectOne, target: self, action: #selector(changeTool(_:)))
        tools.segmentStyle = .rounded
        for (index, symbol) in ["crop", "scissors", "arrow.up.right", "rectangle"].enumerated() {
            tools.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: tools.label(forSegment: index)), forSegment: index)
        }
        tools.selectedSegment = tool.rawValue
        let undo = ImageToolsUI.icon(L("Undo"), symbol: "arrow.uturn.backward", target: self, action: #selector(undoEdit))
        undo.keyEquivalent = "z"
        undo.keyEquivalentModifierMask = [.command]
        undo.isEnabled = false
        undoButton = undo
        let copy = ImageToolsUI.button(L("Copy"), symbol: "doc.on.doc", target: self, action: #selector(copyImage))
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = [.command]
        let export = ImageToolsUI.button(L("Export…"), symbol: "square.and.arrow.up", target: self, action: #selector(exportImage))
        let save = ImageToolsUI.button(L("Save Copy"), symbol: "checkmark", target: self, action: #selector(saveCopy), primary: true)
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = [.command]
        save.isEnabled = false
        save.toolTip = L("Original preserved")
        saveButton = save
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let toolbar = ImageToolsUI.row([tools, undo, spacer, copy, export, save])

        let axes = NSSegmentedControl(labels: [L("Horizontal"), L("Vertical")],
                                      trackingMode: .selectOne, target: self, action: #selector(changeAxis(_:)))
        axes.selectedSegment = 0
        axes.setToolTip(L("Horizontal strip"), forSegment: 0)
        axes.setToolTip(L("Vertical strip"), forSegment: 1)
        self.axes = axes
        let apply = ImageToolsUI.button(L("Cut"), symbol: "scissors", target: self, action: #selector(applyEdit))
        apply.isEnabled = false
        applyButton = apply
        let instruction = ImageToolsUI.caption()
        self.instruction = instruction
        let options = ImageToolsUI.row([axes, apply, instruction], spacing: 12)
        instruction.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = ImageToolsUI.surface()
        for row in [toolbar, options] { row.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(row) }

        let scroll = NSScrollView()
        let clip = ImageToolsClipView()
        clip.backgroundColor = .underPageBackgroundColor
        scroll.contentView = clip
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 8
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.setAccessibilityLabel(L("Image Editor"))
        let canvas = EditorCanvas(image: image)
        canvas.tool = tool
        canvas.onSelection = { [weak self] in self?.updateSelection() }
        scroll.documentView = canvas
        self.canvas = canvas
        self.scroll = scroll

        let details = ImageToolsUI.caption()
        self.details = details
        let zoomOut = ImageToolsUI.icon(L("Zoom out"), symbol: "minus.magnifyingglass", target: self, action: #selector(zoomOut))
        let zoomIn = ImageToolsUI.icon(L("Zoom in"), symbol: "plus.magnifyingglass", target: self, action: #selector(zoomIn))
        let fit = NSButton(title: L("Fit"), target: self, action: #selector(fitImage))
        fit.bezelStyle = .rounded
        let zoomLabel = ImageToolsUI.caption()
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        self.zoomLabel = zoomLabel
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footerRow = ImageToolsUI.row([details, footerSpacer, zoomOut, zoomLabel, zoomIn, fit])
        let footer = ImageToolsUI.surface()
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerRow)
        let content = NSView()
        window.contentView = content
        for view in [header, scroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            toolbar.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            options.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            options.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            options.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            options.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -12),
            options.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footerRow.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
            footerRow.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            footerRow.topAnchor.constraint(equalTo: footer.topAnchor, constant: 8),
            footerRow.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -8),
        ])
        window.minSize.width = max(window.minSize.width, [tools, undo, copy, export, save].reduce(CGFloat(64)) { $0 + $1.fittingSize.width })
        self.window = window
        updateTool()
        content.layoutSubtreeIfNeeded()
        fitImage()
        zoomObserver = scroll.observe(\.magnification, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateDetails() }
        }
        if present {
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func changeTool(_ control: NSSegmentedControl) {
        canvas?.tool = EditorTool(rawValue: control.selectedSegment) ?? .cutOut
        canvas?.clearSelection()
        updateTool()
    }

    private func updateTool() {
        guard let canvas else { return }
        axes?.isHidden = canvas.tool != .cutOut
        switch canvas.tool {
        case .cutOut:
            applyButton?.title = L("Cut")
            instruction?.stringValue = L("Drag over the band to remove.")
        case .crop:
            applyButton?.title = L("Crop")
            instruction?.stringValue = L("Drag around the area to keep.")
        case .arrow, .rectangle:
            applyButton?.title = L("Apply")
            instruction?.stringValue = L("Drag to draw, then click Apply.")
        }
        let symbol = canvas.tool == .cutOut ? "scissors" : canvas.tool == .crop ? "crop" : "checkmark"
        if let applyButton {
            applyButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: applyButton.title)
            applyButton.setAccessibilityLabel(applyButton.title)
        }
        updateSelection()
    }

    @objc private func changeAxis(_ control: NSSegmentedControl) {
        canvas?.axis = control.selectedSegment == 0 ? .horizontal : .vertical
        canvas?.clearSelection()
    }

    private func updateSelection() {
        applyButton?.isEnabled = canvas?.hasSelection ?? false
        updateDetails()
    }

    private func updateDetails() {
        guard let canvas else { return }
        var text = ImageToolsUI.dimensions(width: canvas.image.width, height: canvas.image.height)
        if canvas.hasSelection, canvas.tool == .cutOut, let band = canvas.band {
            text += " · " + String(format: L("Remove %@ pixels"), ImageToolsUI.number(band.length))
        } else { text += " · " + L("Original preserved") }
        details?.stringValue = text
        zoomLabel?.stringValue = Double((scroll?.magnification ?? 1) * canvas.frame.width / CGFloat(canvas.image.width)).formatted(.percent.precision(.fractionLength(0)).locale(Locale(identifier: "en_CA")))
    }

    @objc private func applyEdit() {
        guard let canvas, canvas.hasSelection else { return }
        let result: CGImage?
        switch canvas.tool {
        case .cutOut:
            guard let band = canvas.band else { return }
            result = ImageEditing.cut(canvas.image, axis: canvas.axis, band: band)
        case .crop:
            guard let rect = canvas.pixelRect else { return }
            result = ImageEditing.compactCrop(canvas.image, to: rect)
        case .arrow, .rectangle:
            guard let start = canvas.pixelStart, let end = canvas.pixelEnd else { return }
            result = ImageEditing.annotate(canvas.image, from: start, to: end,
                                          rectangle: canvas.tool == .rectangle,
                                          color: NSColor.systemRed.cgColor)
        }
        guard let result else { return }
        // One-step undo bounds memory for very long screenshots.
        previous = canvas.image
        canvas.image = result
        edits += 1
        undoButton?.isEnabled = true
        saveButton?.isEnabled = true
        updateDetails()
    }

    @objc private func undoEdit() {
        guard let previous else { return }
        canvas?.image = previous
        self.previous = nil
        edits -= 1
        undoButton?.isEnabled = false
        saveButton?.isEnabled = edits > 0
        updateDetails()
    }

    @objc private func zoomOut() { scroll?.magnification = max(0.1, (scroll?.magnification ?? 1) / 1.25) }
    @objc private func zoomIn() { scroll?.magnification = min(8, (scroll?.magnification ?? 1) * 1.25) }
    @objc private func fitImage() {
        guard let scroll, let canvas else { return }
        scroll.magnification = max(0.1, min(1, min((scroll.contentSize.width - 48) / canvas.frame.width,
                                                 (scroll.contentSize.height - 48) / canvas.frame.height)))
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(scroll.contentView.bounds).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        updateDetails()
    }

    @objc private func copyImage() {
        guard let image = canvas?.image else { return }
        do {
            let data = try ImageEditing.png(image)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .png)
            instruction?.stringValue = L("Copied")
        } catch { showError(L("Could not save the image"), detail: error.localizedDescription) }
    }

    @objc private func exportImage() {
        guard let window, let image = canvas?.image else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(source?.deletingPathExtension().lastPathComponent ?? "Image") Edited.png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try ImageEditing.png(image).write(to: url, options: .atomic) }
            catch { self?.showError(L("Could not save the image"), detail: error.localizedDescription) }
        }
    }

    @objc private func saveCopy() { if save() { window?.close() } }

    private func save() -> Bool {
        guard let image = canvas?.image, let source else { return false }
        do {
            let url = try ImageEditing.saveCopy(image, name: "Edited \(source.deletingPathExtension().lastPathComponent)")
            edits = 0
            onSaved(url, source)
            return true
        } catch {
            showError(L("Could not save the image"), detail: error.localizedDescription)
            return false
        }
    }

    func confirmClosing() -> Bool {
        guard edits > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = L("Save changes before closing?")
        alert.addButton(withTitle: L("Save Copy"))
        alert.addButton(withTitle: L("Discard"))
        alert.addButton(withTitle: L("Cancel"))
        switch closingPrompt(alert) {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClosing() }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        window = nil
        canvas = nil
        scroll = nil
        previous = nil
        source = nil
        applyButton = nil
        undoButton = nil
        saveButton = nil
        axes = nil
        instruction = nil
        details = nil
        zoomLabel = nil
        zoomObserver = nil
        edits = 0
    }

    private func showError(_ message: String, detail: String = "") {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

@MainActor
private final class EditorCanvas: NSView {
    var image: CGImage { didSet { resizeImage(); clearSelection() } }
    var tool: EditorTool = .cutOut
    var axis: CutAxis = .horizontal
    var onSelection: () -> Void = {}
    private var first: NSPoint?
    private var last: NSPoint?
    override var isFlipped: Bool { true }

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        resizeImage()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func resizeImage() {
        let scale = min(1, 980 / CGFloat(image.width))
        setFrameSize(NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
        needsDisplay = true
    }

    private func pixelPoint(_ point: NSPoint?) -> CGPoint? {
        guard let point, bounds.width > 0, bounds.height > 0 else { return nil }
        return CGPoint(x: max(0, min(CGFloat(image.width), point.x / bounds.width * CGFloat(image.width))),
                       y: max(0, min(CGFloat(image.height), point.y / bounds.height * CGFloat(image.height))))
    }
    var pixelStart: CGPoint? { pixelPoint(first) }
    var pixelEnd: CGPoint? { pixelPoint(last) }
    var pixelRect: CGRect? {
        guard let a = pixelStart, let b = pixelEnd else { return nil }
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(a.x - b.x), height: abs(a.y - b.y)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return rect.width >= 1 && rect.height >= 1 ? rect : nil
    }
    var band: CutBand? {
        guard let a = pixelStart, let b = pixelEnd else { return nil }
        return CutBand(from: Double(axis == .horizontal ? a.y : a.x),
                       to: Double(axis == .horizontal ? b.y : b.x),
                       extent: axis == .horizontal ? image.height : image.width)
    }
    var hasSelection: Bool {
        guard let first, let last, hypot(first.x - last.x, first.y - last.y) >= 2 else { return false }
        return tool == .cutOut ? band != nil : (tool == .arrow ? true : pixelRect != nil)
    }

    func clearSelection() { first = nil; last = nil; needsDisplay = true; onSelection() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        first = convert(event.locationInWindow, from: nil)
        last = first
        needsDisplay = true
        onSelection()
    }
    override func mouseDragged(with event: NSEvent) {
        last = convert(event.locationInWindow, from: nil)
        autoscroll(with: event)
        needsDisplay = true
        onSelection()
    }
    override func mouseUp(with event: NSEvent) {
        last = convert(event.locationInWindow, from: nil)
        needsDisplay = true
        onSelection()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds, from: .zero,
            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        guard hasSelection, let a = first, let b = last else { return }
        let path = NSBezierPath()
        NSColor.systemRed.setStroke()
        let stroke = max(3, CGFloat(min(image.width, image.height)) / 180) * bounds.width / CGFloat(image.width)
        path.lineWidth = tool == .cutOut || tool == .crop ? 2 : stroke
        if tool == .arrow {
            path.move(to: a)
            path.line(to: b)
            let angle = atan2(b.y - a.y, b.x - a.x)
            let length = min(stroke * 5, hypot(b.x - a.x, b.y - a.y) / 3)
            for turn in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                path.move(to: NSPoint(x: b.x - length * cos(angle + turn), y: b.y - length * sin(angle + turn)))
                path.line(to: b)
            }
        } else {
            var rect = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            if tool == .cutOut, let band {
                let scale = bounds.width / CGFloat(image.width)
                rect = axis == .horizontal
                    ? NSRect(x: 0, y: CGFloat(band.start) * scale, width: bounds.width, height: CGFloat(band.length) * scale)
                    : NSRect(x: CGFloat(band.start) * scale, y: 0, width: CGFloat(band.length) * scale, height: bounds.height)
                NSColor.systemRed.withAlphaComponent(0.3).setFill()
                rect.fill()
            }
            path.appendRect(rect)
        }
        path.stroke()
    }
}
