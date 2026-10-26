import AppKit
import Foundation

/// Third-party screenshot apps Tendedero can take over the same way it takes
/// over macOS: by pointing their save folder at its own, and putting the
/// previous value back when the option is turned off or the app quits.
///
/// An app is offered only when it is installed and its save folder is a
/// preference another process can read and write. CleanShot X and Shottr are
/// not. Neither publishes a save-folder preference: Shottr asks for the
/// folder in its own settings, and CleanShot's is not a key another app can
/// set. Taking either over would mean driving its windows, which Tendedero
/// does not do, so both are left alone.
public enum ThirdPartyCapture {
    /// How an app stores the folder it saves to.
    public enum Preference: Equatable {
        /// A keyed-archive of a file URL, as Clip stores
        /// `screenshotSaveDirectory`. Absent means the app's own default.
        case archivedURL(key: String)
        /// A plain string path plus the security-scoped bookmark the app
        /// resolves in preference to it, as Snapzy stores `exportLocation`
        /// beside `exportLocation.bookmark`. The bookmark is dropped while
        /// the app points at Tendedero and put back verbatim afterwards.
        case stringPath(key: String, bookmarkKey: String)

        fileprivate var directoryKey: String {
            switch self {
            case .archivedURL(let key), .stringPath(let key, _): return key
            }
        }
    }

    /// One app whose new screenshots can be sent to Tendedero's folder.
    public struct App: Equatable {
        /// Stable id, also the UserDefaults domain the app reads.
        public let id: String
        /// What the menu shows. The app's own name, not a translation.
        public let name: String
        /// Where the app keeps its save folder.
        public let preference: Preference
        /// A Bool the app reads to decide whether to ask where to save, when it
        /// has one. Absent means the prompt is on. Nil for an app with no such
        /// prompt. Only Clip has one.
        public let promptKey: String?
        /// A built-in app ships with Tendedero. One the user added is stored in
        /// the JSON file and can be removed again.
        public let builtIn: Bool

        public init(id: String, name: String, preference: Preference,
                    promptKey: String? = nil, builtIn: Bool = false) {
            self.id = id
            self.name = name
            self.preference = preference
            self.promptKey = promptKey
            self.builtIn = builtIn
        }

        fileprivate var domain: CFString { id as CFString }
        fileprivate var key: CFString { preference.directoryKey as CFString }
    }

    /// Clip (`com.chengffei.clip`) stores the folder chosen in its settings.
    /// Until one is chosen the key is absent and captures stay in the app.
    /// Snapzy (`com.trongduong.snapzy`) stores a plain path, with a bookmark
    /// beside it that it resolves first. Its sandbox is off, so the keys can
    /// be read and written from here.
    public static let known: [App] = [
        // Clip reads and writes `screenshotSaveDirectory` as a plain path
        // string, and keeps no bookmark beside it. It also asks where to save
        // unless `askSaveLocation` is off, and while that prompt is on nothing
        // is written to a file at all. An absent value means the prompt is on.
        App(id: "com.chengffei.clip", name: "Clip",
            preference: .stringPath(key: "screenshotSaveDirectory", bookmarkKey: ""),
            promptKey: "askSaveLocation", builtIn: true),
        App(id: "com.trongduong.snapzy", name: "Snapzy",
            preference: .stringPath(key: "exportLocation",
                                     bookmarkKey: "exportLocation.bookmark"), builtIn: true),
    ]

    /// The built-ins plus the apps the user added, built-ins first. A user
    /// entry that repeats a built-in id is dropped, so the built-in wins.
    /// `includingExcluded` keeps the ones the user turned off, which a restore
    /// still has to put back.
    public static func apps(includingExcluded: Bool = false) -> [App] {
        let extras = userApps().filter { extra in !known.contains { $0.id == extra.id } }
        let all = known + extras
        return includingExcluded ? all : all.filter(isIncluded)
    }

    private static let enabledKey = "thirdPartyCaptureEnabled"
    private static let savedKey = "thirdPartyCaptureSaved"
    /// Bundle ids the user turned off, one by one. Absent means included, so a
    /// built-in stays on until someone unchecks it.
    private static let excludedKey = "thirdPartyCaptureExcluded"

    /// The user's choice, kept across launches. Nothing is written to another
    /// app until this is on and that app is actually installed.
    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Apps that are on this Mac, built-ins and user-added alike. Launch
    /// Services matches the bundle id wherever the app lives, so a renamed or
    /// nested copy still counts and an unrelated app does not.
    public static func installed() -> [App] {
        apps().filter { bundleExists(id: $0.id) }
    }

    /// Every app on this Mac, included or not, so the menu can show the ones
    /// the user turned off and let them be turned back on.
    public static func present() -> [App] {
        apps(includingExcluded: true).filter { bundleExists(id: $0.id) }
    }

    /// Whether the user left this app in the takeover. The master switch is a
    /// separate choice and still decides whether any app is taken over.
    public static func isIncluded(_ app: App) -> Bool {
        let excluded = UserDefaults.standard.stringArray(forKey: excludedKey) ?? []
        return !excluded.contains(app.id)
    }

    public static func setIncluded(_ app: App, _ on: Bool) {
        var excluded = UserDefaults.standard.stringArray(forKey: excludedKey) ?? []
        excluded.removeAll { $0 == app.id }
        if !on { excluded.append(app.id) }
        UserDefaults.standard.set(excluded, forKey: excludedKey)
    }

    /// The apps the user added, whether or not they are installed. A missing,
    /// empty, or unreadable file is no extra apps, never a failure.
    public static func userApps(in file: URL = file) -> [App] {
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([StoredApp].self, from: data) else { return [] }
        return entries.compactMap { $0.app }
    }

    /// Why an app was not saved. The menu turns each one into its own text.
    public enum Rejection: Equatable {
        case bundleID, preferenceKey, bookmarkKey, unwritable
    }

    /// Adds an app and remembers it. The id and keys are checked first; a
    /// rejected entry is reported and not saved. `bookmarkKey` is nil for an
    /// archived file URL and a string for a plain path, empty when the app
    /// keeps no bookmark beside it. When the takeover is on, the new app is
    /// pointed at Tendedero's folder straight away. `file` is the JSON file, so
    /// a check can use its own instead of the real one.
    public static func add(id: String, directoryKey: String, bookmarkKey: String?,
                           to file: URL = file) -> Rejection? {
        guard isBundleID(id) else { return .bundleID }
        guard isPreferenceKey(directoryKey) else { return .preferenceKey }
        let bookmark = bookmarkKey?.trimmingCharacters(in: .whitespaces)
        if let bookmark, !bookmark.isEmpty, !isPreferenceKey(bookmark) { return .bookmarkKey }
        let preference: Preference = bookmark == nil
            ? .archivedURL(key: directoryKey)
            : .stringPath(key: directoryKey, bookmarkKey: bookmark ?? "")
        let name = id.split(separator: ".").last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? id
        var entries = read(file)
        entries.removeAll { $0.id == id }
        entries.append(StoredApp(id: id, name: name, preference: preference))
        guard write(entries, to: file) else { return .unwritable }
        if isEnabled { apply(to: App(id: id, name: name, preference: preference)) }
        return nil
    }

    /// Forgets a user-added app. A built-in id is never removed. When the
    /// takeover is on, the app gets its own folder back first.
    public static func remove(id: String, from file: URL = file) {
        guard !known.contains(where: { $0.id == id }) else { return }
        var entries = read(file)
        let removed = entries.first { $0.id == id }
        entries.removeAll { $0.id == id }
        guard write(entries, to: file) else { return }
        if isEnabled, let app = removed?.app { restore(app) }
    }

    /// Points every installed app at Tendedero's folder, remembering what
    /// each one had. An app already pointing there is left out of that
    /// memory, so a crash cannot save Tendedero's own folder as the user's.
    public static func apply() {
        try? FileManager.default.createDirectory(at: Inbox.folder, withIntermediateDirectories: true)
        for app in installed() { apply(to: app) }
    }

    /// One app, so a test can drive a stand-in domain instead of whatever is
    /// installed on the machine. Same rule: a folder that already points at
    /// Tendedero is not remembered over the user's own.
    public static func apply(to app: App) {
        try? FileManager.default.createDirectory(at: Inbox.folder, withIntermediateDirectories: true)
        guard !isRedirected(app) else { return }
        var saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        saved[app.id] = snapshot(of: app)
        UserDefaults.standard.set(saved, forKey: savedKey)
        // The snapshot has to reach disk before the other app is redirected.
        // A kill in between would leave the redirect and forget the folder.
        guard UserDefaults.standard.synchronize() else { return }
        write(Inbox.folder, to: app)
    }

    /// Puts back every known app we redirected, from the snapshot, even when
    /// it is not on this Mac right now. A later reinstall gets its own folder.
    /// One the user moved somewhere else is left alone.
    public static func restore() {
        let saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        for id in saved.keys {
            guard let app = apps(includingExcluded: true).first(where: { $0.id == id }) else { continue }
            restore(app)
        }
    }

    /// Puts one app back and drops it from the memory. The others stay.
    /// A snapshot that was lost is not the same as a key the app never had,
    /// so the preference is left exactly as it is rather than deleted.
    public static func restore(_ app: App) {
        var saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        if isRedirected(app), let snapshot = saved[app.id] as? [String: Any] {
            writeBack(snapshot, to: app)
        }
        saved[app.id] = nil
        if saved.isEmpty {
            UserDefaults.standard.removeObject(forKey: savedKey)
        } else {
            UserDefaults.standard.set(saved, forKey: savedKey)
        }
    }

    /// Where an app saves right now, when that folder is still on disk.
    /// `nil` when the key is absent or the folder is gone, so there is nothing
    /// to watch.
    public static func saveDirectory(of app: App) -> URL? {
        guard let stored = storedURL(app) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: stored.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return stored
    }

    /// Whether this app's preference names Tendedero's folder, even if that
    /// folder has since been removed. A missing folder is not a folder the
    /// user picked. A string-path app whose bookmark is still set is not done
    /// either: the bookmark is what it resolves, so the redirect has to be
    /// tried again.
    public static func isRedirected(_ app: App) -> Bool {
        guard let current = storedURL(app) else { return false }
        guard current.standardizedFileURL == Inbox.folder.standardizedFileURL else { return false }
        if case .stringPath(_, let bookmarkKey) = app.preference, !bookmarkKey.isEmpty,
           CFPreferencesCopyAppValue(bookmarkKey as CFString, app.domain) != nil {
            return false
        }
        return true
    }

    // MARK: - The JSON file of user-added apps

    /// Where the user-added apps are kept. Created the first time one is added.
    public static let file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tendedero/third-party-apps.json")
    }()

    /// One entry in the JSON file. A shape this version does not know decodes
    /// as nil and is skipped, so an older file keeps working.
    private struct StoredApp: Codable {
        let id: String
        let name: String
        let kind: String
        let key: String
        let bookmark: String?

        init(id: String, name: String, preference: Preference) {
            self.id = id
            self.name = name
            switch preference {
            case .archivedURL(let key):
                self.kind = "archivedURL"
                self.key = key
                self.bookmark = nil
            case .stringPath(let key, let bookmarkKey):
                self.kind = "stringPath"
                self.key = key
                self.bookmark = bookmarkKey
            }
        }

        var app: App? {
            guard isBundleID(id), isPreferenceKey(key) else { return nil }
            let preference: Preference
            switch kind {
            case "archivedURL": preference = .archivedURL(key: key)
            case "stringPath":
                // An empty bookmark is a plain path with none beside it, which
                // is how the menu stores one the user left blank.
                guard let bookmark, bookmark.isEmpty || isPreferenceKey(bookmark) else { return nil }
                preference = .stringPath(key: key, bookmarkKey: bookmark)
            default: return nil
            }
            return App(id: id, name: name, preference: preference)
        }
    }

    private static func read(_ file: URL) -> [StoredApp] {
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([StoredApp].self, from: data) else { return [] }
        return entries
    }

    private static func write(_ entries: [StoredApp], to file: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// A reverse-DNS bundle id: two or more segments, each starting with a
    /// letter or digit and otherwise letters, digits, or hyphens.
    private static func isBundleID(_ id: String) -> Bool {
        let segments = id.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy(isSegment)
    }

    private static func isSegment(_ segment: Substring) -> Bool {
        guard let first = segment.first, first.isLetter || first.isNumber else { return false }
        return segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// A preference key: non-empty, and only letters, digits, dots, and hyphens.
    private static func isPreferenceKey(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }

    // MARK: - Reading and writing one preference

    /// What to put back. `present` is false when the key was absent, which is
    /// the app's own default and not the same as an empty path. A string-path
    /// app also keeps the bookmark bytes it had, so they return verbatim.
    private static func snapshot(of app: App) -> [String: Any] {
        var saved: [String: Any] = ["present": false]
        switch app.preference {
        case .archivedURL:
            if let data = CFPreferencesCopyAppValue(app.key, app.domain) as? Data {
                saved = ["present": true, "archive": data]
            }
        case .stringPath(_, let bookmarkKey):
            if let path = CFPreferencesCopyAppValue(app.key, app.domain) as? String {
                saved = ["present": true, "path": path]
            }
            if !bookmarkKey.isEmpty,
               let bookmark = CFPreferencesCopyAppValue(bookmarkKey as CFString, app.domain) as? Data {
                saved["bookmark"] = bookmark
            }
        }
        // An app that asks where to save writes nothing while that prompt is
        // on. The prior answer is remembered so it comes back exactly, and an
        // absent key is remembered as absent rather than guessed.
        if let promptKey = app.promptKey {
            if let on = CFPreferencesCopyAppValue(promptKey as CFString, app.domain) as? Bool {
                saved["prompt"] = on
            }
            saved["promptPresent"] = saved["prompt"] != nil
        }
        return saved
    }

    private static func write(_ folder: URL, to app: App) {
        switch app.preference {
        case .archivedURL:
            guard let data = try? NSKeyedArchiver.archivedData(
                withRootObject: folder as NSURL, requiringSecureCoding: true) else { return }
            CFPreferencesSetAppValue(app.key, data as CFData, app.domain)
        case .stringPath(_, let bookmarkKey):
            // The bookmark is what the app resolves, so a stale one would keep
            // sending captures to the old folder. Both changes are set before
            // the one synchronize, so the path never lands without the removal.
            // It comes back on restore. An empty key means there is no bookmark.
            CFPreferencesSetAppValue(app.key, folder.path as CFString, app.domain)
            if !bookmarkKey.isEmpty {
                CFPreferencesSetAppValue(bookmarkKey as CFString, nil, app.domain)
            }
        }
        if let promptKey = app.promptKey {
            CFPreferencesSetAppValue(promptKey as CFString, false as CFBoolean, app.domain)
        }
        CFPreferencesAppSynchronize(app.domain)
    }

    /// A snapshot whose key was absent removes it, back to the app's default.
    /// One that carries no saved value is left untouched, so a lost snapshot
    /// cannot delete the folder the user had. A string comes back as a string,
    /// never as an archive.
    private static func writeBack(_ snapshot: [String: Any], to app: App) {
        switch app.preference {
        case .archivedURL:
            guard snapshot["archive"] != nil || snapshot["present"] as? Bool == false else { return }
            let archive = snapshot["archive"] as? Data
            CFPreferencesSetAppValue(app.key, archive as CFData?, app.domain)
        case .stringPath(_, let bookmarkKey):
            guard snapshot["path"] != nil || snapshot["present"] as? Bool == false else { return }
            let path = snapshot["path"] as? String
            CFPreferencesSetAppValue(app.key, path as CFString?, app.domain)
            if !bookmarkKey.isEmpty {
                let bookmark = snapshot["bookmark"] as? Data
                CFPreferencesSetAppValue(bookmarkKey as CFString, bookmark as CFData?, app.domain)
            }
        }
        // Only a prompt we actually remembered is put back. A snapshot from
        // before this was recorded carries neither key, and deleting the value
        // then would drop an answer we never saved.
        if let promptKey = app.promptKey, snapshot["promptPresent"] != nil {
            let on = snapshot["prompt"] as? Bool
            CFPreferencesSetAppValue(promptKey as CFString, on as CFBoolean?, app.domain)
        }
        CFPreferencesAppSynchronize(app.domain)
    }

    /// The folder the preference names, whether or not it is still on disk.
    private static func storedURL(_ app: App) -> URL? {
        switch app.preference {
        case .archivedURL:
            guard let data = CFPreferencesCopyAppValue(app.key, app.domain) as? Data,
                  let url = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data) as URL?,
                  url.isFileURL else { return nil }
            return url
        case .stringPath:
            guard let path = CFPreferencesCopyAppValue(app.key, app.domain) as? String,
                  !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    private static func bundleExists(id: String) -> Bool {
        !NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).isEmpty
    }
}
