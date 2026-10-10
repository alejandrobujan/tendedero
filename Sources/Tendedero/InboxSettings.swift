import Foundation

/// Screenshot settings and folder selection, independent of AppKit and the
/// global preference domain so restoration can be checked with isolated data.
final class InboxSettings {
    let defaultFolder: URL
    private let defaults: UserDefaults
    private let read: (String) -> Any?
    private let write: (String, Any?) -> Void
    private let fm: FileManager

    private let savedKey = "inboxSavedSettings"
    private let folderKey = "inboxCustomFolder"
    private let appliedKey = "inboxAppliedFolder"

    init(defaultFolder: URL, defaults: UserDefaults,
         fileManager: FileManager = .default,
         read: @escaping (String) -> Any?, write: @escaping (String, Any?) -> Void) {
        self.defaultFolder = defaultFolder.standardizedFileURL
        self.defaults = defaults
        self.fm = fileManager
        self.read = read
        self.write = write
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: "inboxEnabled") }
        set { defaults.set(newValue, forKey: "inboxEnabled") }
    }

    var wasOffered: Bool {
        get { defaults.bool(forKey: "inboxOffered") }
        set { defaults.set(newValue, forKey: "inboxOffered") }
    }

    var customFolder: URL? {
        defaults.string(forKey: folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    var folder: URL { customFolder ?? defaultFolder }

    /// Track the last applied folder separately: switching destinations must
    /// not mistake the old destination for the user's original settings.
    private var isApplied: Bool {
        guard defaults.dictionary(forKey: savedKey) != nil else { return false }
        // Settings saved by an older release have no applied-folder key.
        let applied = defaults.string(forKey: appliedKey) ?? defaultFolder.path
        let locations = ["location", "location-screenshot", "location-screenrecording"].compactMap { read($0) as? String }
        // Any destination can change outside the app, depending on macOS version
        // and whether the user changes it through Options or defaults.
        return !locations.isEmpty && locations.allSatisfy {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL
                == URL(fileURLWithPath: applied).standardizedFileURL
        }
    }

    func selectFolder(_ url: URL?) throws {
        let chosen = url?.standardizedFileURL
        let destination = chosen ?? defaultFolder
        // A custom folder inside the temporary inbox cannot promise retention.
        if chosen != nil, destination.resolvingSymlinksInPath().path
            .hasPrefix(defaultFolder.resolvingSymlinksInPath().path + "/") {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try prepare(destination)
        if isEnabled { try apply(to: destination) }
        if destination.resolvingSymlinksInPath() == defaultFolder.resolvingSymlinksInPath() {
            defaults.removeObject(forKey: folderKey)
        } else {
            defaults.set(destination.path, forKey: folderKey)
        }
    }

    private func prepare(_ destination: URL) throws {
        guard destination.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard fm.isWritableFile(atPath: destination.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    func apply() throws { try apply(to: folder) }

    private func apply(to destination: URL) throws {
        // Validate before changing any preferences or the saved original values.
        try prepare(destination)
        var saved = defaults.dictionary(forKey: savedKey) ?? [:]
        if !isApplied {
            saved = [:]
            saved["location"] = read("location") as? String
            saved["locationScreenshot"] = read("location-screenshot") as? String
            saved["thumbnail"] = read("show-thumbnail") as? Bool
        }
        // Preserve the migration behavior for settings saved by older releases.
        if saved["recordingSaved"] == nil {
            saved["locationRecording"] = read("location-screenrecording") as? String
            saved["recordingSaved"] = true
        }
        if saved["targetSaved"] == nil {
            saved["target"] = read("target") as? String
            saved["targetScreenshot"] = read("target-screenshot") as? String
            saved["targetRecording"] = read("target-screenrecording") as? String
            saved["targetSaved"] = true
        }
        defaults.set(saved, forKey: savedKey)
        defaults.set(destination.path, forKey: appliedKey)
        // Both legacy and split keys are written, as in the original inbox.
        write("location", destination.path)
        write("location-screenshot", destination.path)
        write("location-screenrecording", destination.path)
        write("target", "file")
        write("target-screenshot", "file")
        write("target-screenrecording", "file")
        write("show-thumbnail", false)
    }

    func restore() {
        // Do not overwrite a destination changed by the user outside the app.
        guard isApplied else { return }
        let saved = defaults.dictionary(forKey: savedKey) ?? [:]
        write("location", saved["location"])
        write("location-screenshot", saved["locationScreenshot"])
        write("location-screenrecording", saved["locationRecording"])
        write("target", saved["target"])
        write("target-screenshot", saved["targetScreenshot"])
        write("target-screenrecording", saved["targetRecording"])
        write("show-thumbnail", saved["thumbnail"])
        defaults.removeObject(forKey: savedKey)
        defaults.removeObject(forKey: appliedKey)
    }

    func isTemporaryFile(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL.path
            .hasPrefix(defaultFolder.resolvingSymlinksInPath().standardizedFileURL.path + "/")
    }
}
