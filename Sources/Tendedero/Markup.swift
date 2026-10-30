import AppKit
import UniformTypeIdentifiers

/// Opens a screenshot in the system Markup editor, the window macOS shows
/// when you click the thumbnail of a screenshot you just took. It is a
/// system extension, reached through the sharing service it registers.
@MainActor
final class Markup: NSObject, NSSharingServiceDelegate {
    static let shared = Markup()

    /// Called with the file once the edited image has been written back.
    var onSaved: (URL) -> Void = { _ in }

    private var editing: URL?
    private static let serviceName = NSSharingService.Name("com.apple.MarkupUI.Markup")

    func edit(_ url: URL) {
        guard let service = NSSharingService(named: Markup.serviceName),
              service.canPerform(withItems: [url]) else {
            // Without the extension, Preview is the closest thing.
            NSWorkspace.shared.open(url)
            return
        }
        editing = url
        service.delegate = self
        placeAnchor()
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [url])
    }

    // MARK: NSSharingServiceDelegate

    /// Done was pressed. The extension hands back the edited image and the
    /// host app is the one that writes it over the original file.
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated {
            closeAnchor()
            self.save(items)
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService,
                                    didFailToShareItems items: [Any], error: Error) {
        MainActor.assumeIsolated { closeAnchor() }
        log.notice("Markup ended without saving: \(error.localizedDescription, privacy: .public)")
    }

    /// Markup opens its editor over the window it was shared from, and
    /// about its size, when it is given both that window and its frame.
    /// Tendedero has no window to share from, and without one the editor
    /// lands in a corner of whichever screen macOS picks. An invisible window
    /// in the middle of the screen under the pointer gives it a place.
    private lazy var anchor: NSWindow = {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        // Markup's windows take this level: above the line, so a line that
        // is down does not cover the editor's toolbar.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        return window
    }()

    /// Placed this way, Markup draws its blurred backdrop and its shadow
    /// wider than the editor, which leaves a grey band at its right. While
    /// the editor is open the backdrop is kept to the editor's frame, which
    /// also lets the editor move to the middle, and the shadow is hidden. These are Markup's own windows, found by name: if a
    /// later macOS renames them, the band comes back and nothing else breaks.
    private var tidying: Timer?
    private var centred = false

    private func tidyEditor() {
        tidying?.invalidate()
        centred = false
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let editor = NSApp.windows.first(where: { $0.isVisible && $0.className.contains("RemoteWindow") })
                else { return }
                // Markup keeps the editor to the left of the space it was
                // given. Once, as it shows up, it moves to the middle.
                if !self.centred, let area = editor.screen?.visibleFrame {
                    self.centred = true
                    editor.setFrameOrigin(NSPoint(x: (area.midX - editor.frame.width / 2).rounded(),
                                                  y: (area.midY - editor.frame.height / 2).rounded()))
                }
                for window in NSApp.windows where window.isVisible {
                    if window.className.contains("BlurWindow"), window.frame != editor.frame {
                        window.setFrame(editor.frame, display: true)
                    } else if window.className.contains("ShadowWindow"), window.alphaValue > 0 {
                        window.alphaValue = 0
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tidying = timer
    }

    private func closeAnchor() {
        tidying?.invalidate()
        tidying = nil
        anchor.orderOut(nil)
    }

    private func placeAnchor() {
        guard let screen = LinePanel.screenUnderPointer() else { return }
        // Shaped like the screen, not like the image: Markup fits the image
        // inside, and a tall or narrow image gets the same roomy editor.
        let area = screen.visibleFrame
        anchor.setFrame(area.insetBy(dx: area.width * 0.1, dy: area.height * 0.1), display: false)
        anchor.orderFront(nil)
        tidyEditor()
    }

    nonisolated func sharingService(_ sharingService: NSSharingService,
                                    sourceWindowForShareItems items: [Any],
                                    sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        MainActor.assumeIsolated { anchor }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService,
                                    sourceFrameOnScreenForShareItem item: Any) -> NSRect {
        MainActor.assumeIsolated { anchor.frame }
    }

    // MARK: Writing back

    private func save(_ items: [Any]) {
        guard let target = editing, let item = items.first else { return }
        editing = nil
        log.notice("Markup returned \(String(describing: type(of: item)), privacy: .public)")

        switch item {
        case let url as URL:
            write(from: url, to: target)
        case let image as NSImage:
            write(data: image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                .flatMap { Markup.encoded($0, like: target) }, to: target)
        case let provider as NSItemProvider:
            load(provider, into: target)
        default:
            log.error("Markup returned an unexpected item")
        }
    }

    private func load(_ provider: NSItemProvider, into target: URL) {
        let types = provider.registeredTypeIdentifiers
        log.notice("Markup provider types: \(types.joined(separator: ", "), privacy: .public)")

        if types.contains(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async { if let url { self.write(from: url, to: target) } }
            }
            return
        }
        // Prefer the original format, then any image format.
        let original = UTType(filenameExtension: target.pathExtension)?.identifier
        let imageType = types.first { $0 == original }
            ?? types.first { UTType($0)?.conforms(to: .image) == true }
        guard let imageType else { return }
        provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
            // Encoding a large image takes a moment, so it happens here, off
            // the main thread.
            let data = data.map { Markup.encoded($0, like: target) }
            DispatchQueue.main.async { self.write(data: data, to: target) }
        }
    }

    private func write(from source: URL, to target: URL) {
        if source.standardizedFileURL == target.standardizedFileURL {
            onSaved(target)
        } else {
            write(data: (try? Data(contentsOf: source)).map { Markup.encoded($0, like: target) }, to: target)
        }
    }

    private func write(data: Data?, to target: URL) {
        guard let data else { return }
        do {
            try data.write(to: target, options: .atomic)
            onSaved(target)
        } catch {
            log.error("Could not save markup: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    /// Markup hands back a PNG saved with little compression, more than
    /// twice the size of the screenshot it came from, and a PNG even when
    /// the screenshot was a JPEG or HEIC. Encoding it again with ImageIO, in
    /// the file's own format, keeps the file close to its original size.
    /// Lossless for PNG. Should that fail, Markup's own data is kept.
    nonisolated private static func encoded(_ data: Data, like target: URL) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = encode(like: target, { CGImageDestinationAddImageFromSource($0, source, 0, nil) })
        else { return data }
        return image
    }

    nonisolated private static func encoded(_ image: CGImage, like target: URL) -> Data? {
        encode(like: target) { CGImageDestinationAddImage($0, image, nil) }
    }

    nonisolated private static func encode(like target: URL, _ add: (CGImageDestination) -> Void) -> Data? {
        let type = (UTType(filenameExtension: target.pathExtension) ?? .png).identifier as CFString
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        add(destination)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
