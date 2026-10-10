import AppKit

/// Inbox mode: Tendedero takes over where screenshots go.
///
/// It changes two macOS screenshot settings, the same ones in the Options
/// menu of Cmd+Shift+5: the floating thumbnail is turned off, so the file is
/// written at once instead of five seconds later, and the save location
/// becomes Tendedero's own folder, so the Desktop only gets what you keep.
///
/// The previous values are saved first and put back when the mode is turned
/// off or the app quits, so macOS is never left pointing at a folder nobody
/// is watching.
enum Inbox {
    private static let domain = "com.apple.screencapture" as CFString
    /// macOS 26 and earlier read "location". macOS 27 reads
    /// "location-screenshot" and ignores the old key, so both are written.
    private static let locationKey = "location" as CFString
    private static let screenshotLocationKey = "location-screenshot" as CFString
    private static let thumbnailKey = "show-thumbnail" as CFString

    private static let enabledKey = "inboxEnabled"
    private static let offeredKey = "inboxOffered"
    private static let savedKey = "inboxSavedSettings"
    private static let autoCleanKey = "inboxAutoCleanDays"

    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tendedero/Screenshots", isDirectory: true)
    }()

    /// The user's choice, kept across launches.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Whether we already asked, so the offer appears only once.
    static var wasOffered: Bool {
        get { UserDefaults.standard.bool(forKey: offeredKey) }
        set { UserDefaults.standard.set(newValue, forKey: offeredKey) }
    }

    /// Whether macOS is currently sending screenshots to our folder.
    static var isApplied: Bool {
        guard let current = CFPreferencesCopyAppValue(locationKey, domain) as? String else { return false }
        return URL(fileURLWithPath: (current as NSString).expandingTildeInPath).standardizedFileURL
            == folder.standardizedFileURL
    }

    static func apply() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Never save our own values as the "previous" ones, for example after
        // a crash left them applied.
        if !isApplied {
            let saved: [String: Any] = [
                "location": CFPreferencesCopyAppValue(locationKey, domain) as? String ?? NSNull(),
                "locationScreenshot": CFPreferencesCopyAppValue(screenshotLocationKey, domain) as? String ?? NSNull(),
                "thumbnail": CFPreferencesCopyAppValue(thumbnailKey, domain) as? Bool ?? NSNull(),
            ]
            UserDefaults.standard.set(saved.compactMapValues { $0 is NSNull ? nil : $0 }, forKey: savedKey)
        }
        set(locationKey, folder.path)
        set(screenshotLocationKey, folder.path)
        set(thumbnailKey, false)
    }

    static func restore() {
        guard isApplied else { return }
        let saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        set(locationKey, saved["location"])
        set(screenshotLocationKey, saved["locationScreenshot"])
        set(thumbnailKey, saved["thumbnail"])
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    /// Writes through cfprefsd, so the screenshot service sees it at once.
    /// A nil value removes the key and returns it to the macOS default.
    private static func set(_ key: CFString, _ value: Any?) {
        CFPreferencesSetAppValue(key, value as CFPropertyList?, domain)
        CFPreferencesAppSynchronize(domain)
    }

    // MARK: Reclaiming space

    /// Days after which inbox screenshots are moved to the Trash. 0 = off.
    static var autoCleanDays: Int {
        get { UserDefaults.standard.integer(forKey: autoCleanKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoCleanKey) }
    }

    /// Everything sitting in the inbox folder. Only ever this folder: files
    /// anywhere else, like the Desktop, are the user's to keep.
    static func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles])) ?? []
    }

    /// Combined size of the given files, for the menu to report.
    static func size(of urls: [URL]) -> Int64 {
        urls.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Moves inbox files older than `days` to the Trash, hanging or not: the
    /// age the user picked wins over what is still on the line, the way
    /// deleting a file in the Finder drops its card. The Trash stays the
    /// safety net — nothing is erased permanently.
    @discardableResult
    static func clean(olderThan days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 86400)
        var trashed = 0
        for url in files() {
            // A file whose age cannot be read is left alone: when in doubt,
            // do not trash.
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
            guard created < cutoff else { continue }
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { trashed += 1 }
        }
        return trashed
    }

    /// Copies dropped files into the inbox, never moving them: what lands
    /// on the line is a copy the app may trash, while the original stays
    /// put. Files already inside the inbox hang as they are.
    @discardableResult
    static func copyIn(_ urls: [URL]) -> [URL] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var landed: [URL] = []
        for src in urls {
            if src.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") {
                landed.append(src)
                continue
            }
            var dst = folder.appendingPathComponent(src.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: dst.path) {
                let stem = src.deletingPathExtension().lastPathComponent
                dst = folder.appendingPathComponent("\(stem)-\(n).\(src.pathExtension)")
                n += 1
            }
            if (try? FileManager.default.copyItem(at: src, to: dst)) != nil { landed.append(dst) }
        }
        return landed
    }

    /// Image data dropped from a browser or app: saved as a PNG in the inbox.
    @discardableResult
    static func save(image data: Data) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("Dropped-\(stamp).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return url
    }

    /// Moves everything in the inbox folder to the Trash.
    @discardableResult
    static func empty() -> Int {
        var trashed = 0
        for url in files() {
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { trashed += 1 }
        }
        return trashed
    }
}
