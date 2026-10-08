import Foundation

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

    /// Where captures went before inbox mode. Screen recordings are sent
    /// back there, since the line only hangs images.
    static var previousFolder: URL {
        guard let raw = UserDefaults.standard.dictionary(forKey: savedKey)?["location"] as? String, !raw.isEmpty
        else { return ScreenshotWatcher.desktop }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Writes through cfprefsd, so the screenshot service sees it at once.
    /// A nil value removes the key and returns it to the macOS default.
    private static func set(_ key: CFString, _ value: Any?) {
        CFPreferencesSetAppValue(key, value as CFPropertyList?, domain)
        CFPreferencesAppSynchronize(domain)
    }
}
