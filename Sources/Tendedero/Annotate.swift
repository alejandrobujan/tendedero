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

        let size = Self.windowSize(for: document)
        let content = NSHostingController(rootView: AnnotationEditor(state: state, canvas: canvas))
        // The window is sized here, not by what the content would like.
        content.sizingOptions = []

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = url.lastPathComponent
        window.contentViewController = content
        window.setContentSize(size)
        window.contentMinSize = NSSize(width: Self.minWidth, height: AnnotationToolbar.height + 200)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        canvas.onFinish = { [weak window] in window?.close() }

        self.window = window
        self.canvas = canvas
        self.document = document
        self.target = url

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    /// Wide enough for the second row of the toolbar.
    private static let minWidth: CGFloat = 520

    /// The picture at its natural size on this screen, or smaller to fit.
    private static func windowSize(for document: AnnotationDocument) -> NSSize {
        let screen = LinePanel.screenUnderPointer()
        let area = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let density = screen?.backingScaleFactor ?? 2
        let natural = NSSize(width: document.pixelSize.width / density, height: document.pixelSize.height / density)
        let room = NSSize(width: area.width * 0.85, height: area.height * 0.85 - AnnotationToolbar.height)
        let scale = min(1, room.width / max(natural.width, 1), room.height / max(natural.height, 1))
        return NSSize(width: max(minWidth, (natural.width * scale).rounded()),
                      height: max(200, (natural.height * scale).rounded()) + AnnotationToolbar.height)
    }

    /// Closes the editor, which saves what is on it. For when Tendedero quits.
    func finish() { window?.close() }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        canvas?.commitPendingText()
        if let document, let target, document.hasMarks { save(document, to: target) }
        window = nil
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
