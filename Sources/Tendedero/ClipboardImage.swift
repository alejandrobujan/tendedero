import AppKit

/// Promise PNG bytes only when a receiver requests them. A disk snapshot
/// preserves copy-time contents even if the original is edited or discarded.
/// Native pasteboard callbacks may run off the main queue; only snapshot I/O
/// is shared between them, and it is protected by the lock.
final class ClipboardImage: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    @MainActor private static var current: ClipboardImage?
    @MainActor private let board: NSPasteboard
    @MainActor private var changeCount = 0
    private let directory: URL
    private let snapshot: URL
    private let lock = NSLock()
    private var available = true

    @MainActor
    private init?(url: URL, board: NSPasteboard) {
        self.board = board
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tendedero-clipboard-\(UUID().uuidString)")
        snapshot = directory.appendingPathComponent(url.lastPathComponent)
        super.init()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: url.resolvingSymlinksInPath(), to: snapshot)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    @MainActor
    @discardableResult
    static func copy(_ url: URL, to board: NSPasteboard = .general) -> Bool {
        let entry = NSPasteboardItem()
        let provider = ClipboardImage(url: url, board: board)
        if let provider {
            entry.setDataProvider(provider, forTypes: [.png])
        } else if let data = pngData(url) {
            // Preserve copying if a temporary snapshot cannot be created.
            entry.setData(data, forType: .png)
        }
        entry.setString(url.absoluteString, forType: .fileURL)
        board.clearContents()
        current = provider
        let written = board.writeObjects([entry])
        provider?.changeCount = board.changeCount
        if !written {
            provider?.discardSnapshot()
            current = nil
        }
        return written
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .png else { return }
        let data: Data? = autoreleasepool {
            lock.lock()
            defer { lock.unlock() }
            return available ? pngData(snapshot) : nil
        }
        // Setting the data can synchronously invoke the finished callback.
        // Release the snapshot lock first so that callback can clean it up.
        if let data { item.setData(data, forType: type) }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        discardSnapshot()
        DispatchQueue.main.async { [weak self] in
            if let self, Self.current === self { Self.current = nil }
        }
    }

    /// Once the process exits it cannot fulfill promises. Publish the current
    /// image before quitting, unless another app has taken the clipboard.
    @MainActor
    static func materializeForExit() {
        guard let provider = current else { return }
        if provider.board.changeCount == provider.changeCount {
            _ = provider.board.data(forType: .png)
        }
        provider.discardSnapshot()
        current = nil
    }

    private func discardSnapshot() {
        lock.lock()
        defer { lock.unlock() }
        guard available else { return }
        available = false
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
