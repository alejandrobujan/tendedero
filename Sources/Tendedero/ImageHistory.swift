import Foundation

/// Only metadata is persisted. Expiry never touches the system clipboard.
@MainActor
final class ImageHistory {
    struct Entry: Codable, Equatable {
        let path: String
        let capturedAt: Date
        var url: URL { URL(fileURLWithPath: path) }
    }

    static let dayChoices = [1, 3, 7, 15, 30]
    static let defaultDays = 30
    private static let entriesKey = "imageHistoryV1"
    private static let daysKey = "historyRetentionDays"
    private let defaults: UserDefaults
    private let inbox: URL
    private let now: () -> Date
    private(set) var entries: [Entry] = []

    var retentionDays: Int {
        let value = defaults.integer(forKey: Self.daysKey)
        return Self.dayChoices.contains(value) ? value : Self.defaultDays
    }

    init(defaults: UserDefaults, inbox: URL, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.inbox = inbox.standardizedFileURL
        self.now = now
        if let data = defaults.data(forKey: Self.entriesKey),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            var seen = Set<String>()
            entries = saved.filter { seen.insert($0.path).inserted }
        } else {
            // The old list was oldest first. Recover clipboard images that the
            // old screen-capacity limit removed, once, without resurrecting
            // deliberately removed entries on later launches.
            let paths = defaults.stringArray(forKey: "pegged") ?? []
            var seen = Set<String>()
            let urls = paths.map { URL(fileURLWithPath: $0) } + ownedClipboardFiles()
            entries = urls.enumerated().compactMap { index, url in
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { return nil }
                let date = creationDate(url) ?? now().addingTimeInterval(Double(index - urls.count))
                return Entry(path: path, capturedAt: date)
            }.sorted { $0.capturedAt > $1.capturedAt }
        }
        prune()
    }

    func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !entries.contains(where: { $0.path == path }) else { return }
        entries.insert(Entry(path: path, capturedAt: now()), at: 0)
        save()
    }

    func remove(_ url: URL) {
        entries.removeAll { $0.path == url.standardizedFileURL.path }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    func setRetentionDays(_ days: Int) {
        guard Self.dayChoices.contains(days) else { return }
        defaults.set(days, forKey: Self.daysKey)
        prune()
    }

    func prune() {
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)
        for entry in entries where entry.capturedAt <= cutoff {
            removeOwnedClipboardFile(entry.url)
        }
        entries.removeAll {
            $0.capturedAt <= cutoff || !FileManager.default.fileExists(atPath: $0.path)
        }
        let trackedPaths = Set(entries.map(\.path))
        // Removed cards no longer have a history entry, but their private
        // clipboard files must still age out. Never scan external folders.
        for url in ownedClipboardFiles() {
            if !trackedPaths.contains(url.standardizedFileURL.path),
               let date = creationDate(url), date <= cutoff { removeOwnedClipboardFile(url) }
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.entriesKey)
        // Keep the old path list current for a reversible app downgrade.
        defaults.set(entries.reversed().map(\.path), forKey: "pegged")
    }

    private func creationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    private func ownedClipboardFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: inbox,
            includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls.filter(isOwnedClipboardFile)
    }

    private func isOwnedClipboardFile(_ url: URL) -> Bool {
        guard url.standardizedFileURL.deletingLastPathComponent() == inbox,
              inbox.resolvingSymlinksInPath() == inbox,
              url.pathExtension == "png" else { return false }
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("Clipboard "), UUID(uuidString: String(name.dropFirst(10))) != nil,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        return true
    }

    private func removeOwnedClipboardFile(_ url: URL) {
        guard isOwnedClipboardFile(url) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { log.error("Could not remove an expired clipboard image") }
    }
}
