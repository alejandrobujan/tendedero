import AppKit

/// The system presents the recipient picker and handles the transfer. Sharing never
/// takes a photo off the line, including when the recipient picker is cancelled.
@MainActor
final class AirDrop: NSObject {
    static let shared = AirDrop()

    /// AppKit can call back with a different service object, so each send has
    /// its own delegate and finishes by its own ID.
    @MainActor
    private final class Session: NSObject, NSSharingServiceDelegate {
        let service: NSSharingService
        let directory: URL
        private let onFinished: () -> Void

        init(service: NSSharingService, directory: URL, onFinished: @escaping () -> Void) {
            self.service = service
            self.directory = directory
            self.onFinished = onFinished
            super.init()
        }

        nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
            MainActor.assumeIsolated { self.onFinished() }
        }

        nonisolated func sharingService(_ sharingService: NSSharingService,
                                        didFailToShareItems items: [Any], error: Error) {
            MainActor.assumeIsolated { self.onFinished() }
        }
    }

    // The menu closes before the system finishes with the service and its file.
    private var active: [UUID: Session] = [:]
    private var terminationObserver: NSObjectProtocol?

    private override init() {
        super.init()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cleanUp() }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    func canSend(_ url: URL) -> Bool {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path),
              let service = NSSharingService(named: .sendViaAirDrop) else { return false }
        return service.canPerform(withItems: [url])
    }

    func send(_ url: URL) {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path),
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: [url]) else {
            NSSound.beep()
            return
        }
        // A new capture can push the original off the line and into the Trash
        // while the recipient picker is open. Keep a private copy until it ends.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tendedero-AirDrop-\(UUID().uuidString)", isDirectory: true)
        let copy = directory.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            NSSound.beep()
            return
        }
        guard service.canPerform(withItems: [copy]) else {
            try? FileManager.default.removeItem(at: directory)
            NSSound.beep()
            return
        }
        let id = UUID()
        let session = Session(service: service, directory: directory) { [weak self] in
            self?.finish(id)
        }
        active[id] = session
        service.delegate = session
        // The line is a nonactivating panel and retracts when its menu closes.
        // Let AirDrop present its own window instead of attaching it to the line.
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [copy])
    }

    private func finish(_ id: UUID) {
        guard let session = active.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: session.directory)
    }

    /// Quitting can end the app before the sharing service calls back.
    private func cleanUp() {
        let sessions = Array(active.values)
        active.removeAll()
        for session in sessions {
            try? FileManager.default.removeItem(at: session.directory)
        }
    }
}
