import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Marks up a screenshot in Tendedero's own editor, in place of the system
/// Markup. There is no Done button: closing the window, or Escape, writes the
/// marks into the file, and from there it is an ordinary screenshot again.
/// A window closed with no marks leaves the file alone.
@MainActor
final class Annotate: NSObject, NSWindowDelegate {
    static let shared = Annotate()

    private static let enabledKey = "builtInEditor"

    /// Whether long press opens this editor. Off opens the system Markup.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Called with the file once the marked picture has replaced it.
    var onSaved: (URL) -> Void = { _ in }

    private var window: NSWindow?
    private var panel: NSPanel?
    private var canvas: AnnotationCanvas?
    private var document: AnnotationDocument?
    private var target: URL?

    func edit(_ url: URL) {
        if let window, target == url {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        // One at a time: the one being edited is finished first.
        window?.close()

        guard let document = AnnotationDocument(url: url) else {
            log.error("Could not open \(url.lastPathComponent, privacy: .public) for marking")
            NSWorkspace.shared.open(url)
            return
        }

        let state = EditorState()
        let canvas = AnnotationCanvas(document: document, state: state)

        let panel = Self.makePanel(state: state)
        let size = Self.windowSize(for: document, panelWidth: panel.frame.width - 2 * AnnotationPanelView.margin)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = url.lastPathComponent
        window.contentView = canvas
        window.contentMinSize = NSSize(width: 240, height: 160)
        window.isReleasedWhenClosed = false
        window.delegate = self
        Self.place(window, with: panel)

        canvas.onFinish = { [weak window] in window?.close() }

        self.window = window
        self.panel = panel
        self.canvas = canvas
        self.document = document
        self.target = url

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.addChildWindow(panel, ordered: .above)
        window.makeFirstResponder(canvas)
    }

    private static let gap: CGFloat = 8

    /// The tools in a panel of their own, with no title bar. It never takes
    /// the keyboard, so the picture's window stays the one that is typed into.
    private static func makePanel(state: EditorState) -> NSPanel {
        // Measured with the tool that shows the most options, rectangle,
        // which is how a new editor starts. The window keeps this size.
        let tallest = NSHostingView(rootView: AnnotationToolbar(state: state)).fittingSize
        let margin = AnnotationPanelView.margin
        let size = NSSize(width: tallest.width + 2 * margin, height: tallest.height + 2 * margin)

        let hosting = NSHostingView(rootView: AnnotationPanelView(state: state))
        hosting.sizingOptions = []
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.setContentSize(size)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The card draws its own shadow.
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }

    /// The picture at its natural size on this screen, or smaller to fit,
    /// with room beside it for the panel.
    private static func windowSize(for document: AnnotationDocument, panelWidth: CGFloat) -> NSSize {
        let screen = LinePanel.screenUnderPointer()
        let area = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let density = screen?.backingScaleFactor ?? 2
        let natural = NSSize(width: document.pixelSize.width / density, height: document.pixelSize.height / density)
        let room = NSSize(width: area.width * 0.9 - panelWidth - gap, height: area.height * 0.85)
        let scale = min(1, room.width / max(natural.width, 1), room.height / max(natural.height, 1))
        return NSSize(width: max(240, (natural.width * scale).rounded()),
                      height: max(160, (natural.height * scale).rounded()))
    }

    /// The window and its panel as one group, centred on the screen, the
    /// panel against the window's right edge and level with its top.
    private static func place(_ window: NSWindow, with panel: NSPanel) {
        let area = (LinePanel.screenUnderPointer() ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = window.frame
        let margin = AnnotationPanelView.margin
        let total = frame.width + gap + panel.frame.width - 2 * margin
        let x = (area.midX - total / 2).rounded()
        let y = (area.midY - frame.height / 2).rounded()
        window.setFrameOrigin(NSPoint(x: x, y: y))
        // The card sits inside the panel's margin, so the panel starts a margin early.
        panel.setFrameOrigin(NSPoint(x: x + frame.width + gap - margin,
                                     y: y + frame.height - panel.frame.height + margin))
    }

    /// Closes the editor, which saves what is on it. For when Tendedero quits.
    func finish() { window?.close() }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        canvas?.commitPendingText()
        if let window, let panel {
            window.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        if let document, let target, document.hasMarks { save(document, to: target) }
        window = nil
        panel = nil
        canvas = nil
        document = nil
        target = nil
    }

    // MARK: Writing back

    /// Writes to a hidden file next to the original, so the watcher ignores
    /// it, then swaps it in.
    private func save(_ document: AnnotationDocument, to target: URL) {
        guard let image = document.flattened(),
              let data = Annotate.encoded(image, like: target, dpi: document.dpi) else {
            log.error("Could not render the marks on \(target.lastPathComponent, privacy: .public)")
            NSSound.beep()
            return
        }
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent(".annotating-\(UUID().uuidString)")
            .appendingPathExtension(target.pathExtension)
        do {
            try data.write(to: temp)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            log.notice("Marked up \(target.lastPathComponent, privacy: .public)")
            onSaved(target)
        } catch {
            log.error("Could not save marks: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: temp)
            NSSound.beep()
        }
    }

    /// In the file's own format, so a JPEG stays a JPEG and a PNG stays
    /// lossless, with the resolution it had.
    private static func encoded(_ image: CGImage, like target: URL, dpi: (CGFloat, CGFloat)?) -> Data? {
        let type = UTType(filenameExtension: target.pathExtension) ?? .png
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var properties: [CFString: Any] = [:]
        if let dpi {
            properties[kCGImagePropertyDPIWidth] = dpi.0
            properties[kCGImagePropertyDPIHeight] = dpi.1
        }
        if type.conforms(to: .jpeg) || type.conforms(to: .heic) {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.92
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
