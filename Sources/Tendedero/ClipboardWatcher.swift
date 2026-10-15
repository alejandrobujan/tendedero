import AppKit
import ClipboardSupport

/// Imports copied image data and copied image files into our own folder.
/// All subsequent actions use the existing screenshot pipeline and its copies.
@MainActor
final class ClipboardWatcher {
    private let onImage: (URL) -> Void
    private let onDuplicate: (URL) -> Void
    private var timer: Timer?
    private var worker: Task<Void, Never>?
    private var lastCount = NSPasteboard.general.changeCount
    private var generation = 0
    private struct Saved: Sendable {
        let url: URL
        let modified: Date?
    }
    private var saved: [String: Saved] = [:]
    private var savedOrder: [String] = []
    private var needsIndex = true
    private static let enabledKey = "clipboardEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    init(onImage: @escaping (URL) -> Void, onDuplicate: @escaping (URL) -> Void = { _ in }) {
        self.onImage = onImage
        self.onDuplicate = onDuplicate
    }

    func start() {
        guard timer == nil else { return }
        lastCount = NSPasteboard.general.changeCount
        needsIndex = true
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        worker?.cancel()
        worker = nil
        generation += 1
    }

    private func check() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastCount else { return }
        lastCount = count
        generation += 1
        worker?.cancel()
        let current = generation
        let inputs = ClipboardImageReader.snapshot(pb)
        guard !inputs.isEmpty, pb.changeCount == count else { return }
        let existing = needsIndex ? (UserDefaults.standard.stringArray(forKey: "pegged") ?? []).map { URL(fileURLWithPath: $0) } : []
        let indexNeeded = needsIndex
        // Process a multi-file copy one image at a time.
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            if indexNeeded {
                var index: [String: Saved] = [:]
                var duplicates: [URL] = []
                for url in existing {
                    guard !Task.isCancelled else { return }
                    guard let image = ClipboardImageReader.decode(.file(url)),
                          let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
                    if index[image.fingerprint] == nil {
                        index[image.fingerprint] = Saved(url: url, modified: attributes[.modificationDate] as? Date)
                    } else if url.lastPathComponent.hasPrefix("Copied ") {
                        duplicates.append(url)
                    }
                }
                guard await self?.adopt(index, duplicates: duplicates, generation: current) == true else { return }
            }
            for input in inputs {
                guard !Task.isCancelled else { return }
                guard let image = ClipboardImageReader.decode(input) else { continue }
                guard !Task.isCancelled,
                      await self?.accept(image.png, fingerprint: image.fingerprint, count: count, generation: current) == true else { return }
            }
        }
    }

    private func adopt(_ index: [String: Saved], duplicates: [URL], generation: Int) -> Bool {
        guard timer != nil, self.generation == generation else { return false }
        saved = index
        savedOrder = Array(index.keys)
        needsIndex = false
        for url in duplicates { onDuplicate(url) }
        return true
    }

    private func accept(_ png: Data, fingerprint: String, count: Int, generation: Int) -> Bool {
        guard timer != nil, self.generation == generation,
              NSPasteboard.general.changeCount == count else { return false }
        let fm = FileManager.default
        let active = Set(UserDefaults.standard.stringArray(forKey: "pegged") ?? [])
        if let old = saved[fingerprint], active.contains(old.url.path), fm.fileExists(atPath: old.url.path),
           let attributes = try? fm.attributesOfItem(atPath: old.url.path),
           attributes[.modificationDate] as? Date == old.modified { return true }
        let url = Inbox.folder.appendingPathComponent("Copied \(Self.stamp()) \(UUID().uuidString.prefix(8)).png")
        do {
            try fm.createDirectory(at: Inbox.folder, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let attributes = try fm.attributesOfItem(atPath: url.path)
            saved[fingerprint] = Saved(url: url, modified: attributes[.modificationDate] as? Date)
            savedOrder.removeAll { $0 == fingerprint }
            savedOrder.append(fingerprint)
            if savedOrder.count > 256 { saved.removeValue(forKey: savedOrder.removeFirst()) }
            onImage(url)
        } catch {
            try? fm.removeItem(at: url)
            log.error("Could not save a copied image: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }
}
