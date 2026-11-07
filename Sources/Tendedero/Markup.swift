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
    private var service: NSSharingService?
    private var sourceWindow: NSWindow?
    private var editorWindow: NSWindow?
    private var remoteWindow: NSWindow?
    private var sourceFrame = NSRect.zero
    private var targetArea = NSRect.zero
    private var presentationTimer: Timer?
    private var presentationTimeout: DispatchWorkItem?
    private var onPresented: (() -> Void)?
    private static let serviceName = NSSharingService.Name("com.apple.MarkupUI.Markup")

    func edit(_ url: URL, on screen: NSScreen? = nil, sourceFrame: NSRect? = nil,
              onPresented: @escaping () -> Void = {}) {
        guard editing == nil else {
            NSApp.activate(ignoringOtherApps: true)
            editorWindow?.makeKeyAndOrderFront(nil)
            onPresented()
            return
        }
        guard let service = NSSharingService(named: Markup.serviceName),
              service.canPerform(withItems: [url]),
              let screen = screen ?? LinePanel.screenUnderPointer() else {
            // Without the extension, Preview is the closest thing.
            NSWorkspace.shared.open(url)
            onPresented()
            return
        }
        editing = url
        self.service = service
        self.onPresented = onPresented
        targetArea = screen.visibleFrame
        let size = NSSize(width: min(900, targetArea.width * 0.74),
                          height: min(650, targetArea.height * 0.78))
        self.sourceFrame = sourceFrame ?? NSRect(
            x: targetArea.midX - size.width / 2, y: targetArea.midY - size.height / 2,
            width: size.width, height: size.height)
        // Markup initially attaches its editor and dimming layers to this host.
        // Once ready, its content moves into a regular, draggable AppKit window.
        let host = NSWindow(contentRect: self.sourceFrame, styleMask: .borderless,
                            backing: .buffered, defer: false)
        host.isOpaque = false
        host.backgroundColor = .clear
        host.hasShadow = false
        host.ignoresMouseEvents = true
        host.isReleasedWhenClosed = false
        host.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        host.contentView = NSView(frame: NSRect(origin: .zero, size: self.sourceFrame.size))
        sourceWindow = host
        host.orderFrontRegardless()
        // The extension can be visible before it gets keyboard focus. Wait for
        // its actual window, rather than making the handoff depend on activation.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let host = self.sourceWindow,
                      let remote = host.childWindows?.first(where: { $0.isVisible && $0.canBecomeKey }),
                      let content = remote.contentView else { return }
                self.remoteWindow = remote
                host.removeChildWindow(remote)
                remote.contentView = nil
                let editor = NSWindow(contentRect: NSRect(origin: .zero, size: content.bounds.size),
                                      styleMask: .titled, backing: .buffered, defer: false)
                editor.title = L("Markup")
                editor.isReleasedWhenClosed = false
                editor.level = host.level
                editor.contentView = content
                self.editorWindow = editor
                // These layers shade the source document during modal editing.
                // Our source is empty; leaving them up creates a floating dark slab.
                host.childWindows?.forEach { $0.orderOut(nil) }
                remote.orderOut(nil)
                host.orderOut(nil)
                // A native title bar supplies a drag region without taking
                // mouse drags away from the extension's annotation canvas.
                editor.isMovable = true
                editor.isMovableByWindowBackground = false
                editor.setFrameOrigin(NSPoint(x: self.targetArea.midX - editor.frame.width / 2,
                                              y: self.targetArea.midY - editor.frame.height / 2))
                editor.makeKeyAndOrderFront(nil)
                self.finishPresentation()
            }
        }
        presentationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        // A service that fails to present must never leave the held photo stuck.
        let timeout = DispatchWorkItem { [weak self] in self?.finishEditing() }
        presentationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        service.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [url])
    }

    // MARK: NSSharingServiceDelegate

    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        sourceWindow
    }

    func sharingService(_ sharingService: NSSharingService, sourceFrameOnScreenForShareItem item: Any) -> NSRect {
        sourceFrame
    }

    /// Done was pressed. The extension hands back the edited image and the
    /// host app is the one that writes it over the original file.
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated {
            self.save(items)
            self.finishEditing()
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService,
                                    didFailToShareItems items: [Any], error: Error) {
        log.notice("Markup ended without saving: \(error.localizedDescription, privacy: .public)")
        MainActor.assumeIsolated { self.finishEditing() }
    }

    private func finishPresentation() {
        presentationTimer?.invalidate()
        presentationTimer = nil
        presentationTimeout?.cancel()
        presentationTimeout = nil
        let completion = onPresented
        onPresented = nil
        completion?()
    }

    private func finishEditing() {
        finishPresentation()
        let host = sourceWindow
        let editor = editorWindow
        let remote = remoteWindow
        sourceWindow = nil
        editorWindow = nil
        remoteWindow = nil
        service?.delegate = nil
        service = nil
        editing = nil
        editor?.orderOut(nil)
        remote?.orderOut(nil)
        host?.orderOut(nil)
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
