import Foundation

/// Inbox mode: Tendedero takes over where screenshots go.
///
/// It changes the macOS screenshot settings in the Options menu of
/// Cmd+Shift+5: the floating thumbnail is turned off, so the file is written
/// at once instead of five seconds later, and captures are saved as files in
/// Tendedero's own folder, so the Desktop only gets what you keep. Saving to
/// the clipboard or Preview would leave nothing to hang, and a click on the
/// line copies anyway.
/// Screen recordings go there too, and hang on the line like screenshots.
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
    /// macOS 27 keeps screen recordings apart, in "location-screenrecording".
    /// Earlier versions send them wherever "location" points.
    private static let recordingLocationKey = "location-screenrecording" as CFString
    private static let thumbnailKey = "show-thumbnail" as CFString
    /// Whether a capture is saved as a file or sent to the clipboard, Preview
    /// and so on. macOS 26 and earlier read "target"; macOS 27 has one for
    /// screenshots and one for recordings.
    private static let targetKey = "target" as CFString
    private static let screenshotTargetKey = "target-screenshot" as CFString
    private static let recordingTargetKey = "target-screenrecording" as CFString

    private static let enabledKey = "inboxEnabled"
    private static let offeredKey = "inboxOffered"
    private static let savedKey = "inboxSavedSettings"

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
        var saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        if !isApplied {
            saved = [:]
            saved["location"] = CFPreferencesCopyAppValue(locationKey, domain) as? String
            saved["locationScreenshot"] = CFPreferencesCopyAppValue(screenshotLocationKey, domain) as? String
            saved["thumbnail"] = CFPreferencesCopyAppValue(thumbnailKey, domain) as? Bool
        }
        // Recordings and the target came later: settings saved by an earlier
        // version lack them, and the value macOS has now is still the user's own.
        if saved["recordingSaved"] == nil {
            saved["locationRecording"] = CFPreferencesCopyAppValue(recordingLocationKey, domain) as? String
            saved["recordingSaved"] = true
        }
        if saved["targetSaved"] == nil {
            saved["target"] = CFPreferencesCopyAppValue(targetKey, domain) as? String
            saved["targetScreenshot"] = CFPreferencesCopyAppValue(screenshotTargetKey, domain) as? String
            saved["targetRecording"] = CFPreferencesCopyAppValue(recordingTargetKey, domain) as? String
            saved["targetSaved"] = true
        }
        UserDefaults.standard.set(saved, forKey: savedKey)
        set(locationKey, folder.path)
        set(screenshotLocationKey, folder.path)
        set(recordingLocationKey, folder.path)
        set(targetKey, "file")
        set(screenshotTargetKey, "file")
        set(recordingTargetKey, "file")
        set(thumbnailKey, false)
    }

    static func restore() {
        guard isApplied else { return }
        let saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        set(locationKey, saved["location"])
        set(screenshotLocationKey, saved["locationScreenshot"])
        set(recordingLocationKey, saved["locationRecording"])
        set(targetKey, saved["target"])
        set(screenshotTargetKey, saved["targetScreenshot"])
        set(recordingTargetKey, saved["targetRecording"])
        set(thumbnailKey, saved["thumbnail"])
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    /// Writes through cfprefsd, so the screenshot service sees it at once.
    /// A nil value removes the key and returns it to the macOS default.
    private static func set(_ key: CFString, _ value: Any?) {
        CFPreferencesSetAppValue(key, value as CFPropertyList?, domain)
        CFPreferencesAppSynchronize(domain)
    }
}
