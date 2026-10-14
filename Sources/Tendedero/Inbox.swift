import Foundation

/// Takes over the macOS screenshot destination until the app quits.
/// The default folder is temporary; a chosen folder keeps its files.
enum Inbox {
    static let defaultFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tendedero/Screenshots", isDirectory: true)
    }()

    private static let domain = "com.apple.screencapture" as CFString
    private static let settings = InboxSettings(
        defaultFolder: defaultFolder, defaults: .standard,
        read: { CFPreferencesCopyAppValue($0 as CFString, domain) },
        write: { key, value in
            CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain)
            CFPreferencesAppSynchronize(domain)
        })

    static var folder: URL { settings.folder }
    static var customFolder: URL? { settings.customFolder }

    static var isEnabled: Bool {
        get { settings.isEnabled }
        set { settings.isEnabled = newValue }
    }

    static var wasOffered: Bool {
        get { settings.wasOffered }
        set { settings.wasOffered = newValue }
    }

    static func apply() throws { try settings.apply() }
    static func restore() { settings.restore() }
    static func selectFolder(_ url: URL?) throws { try settings.selectFolder(url) }

    /// Ownership is tied to the default folder, not the current destination.
    /// Old temporary captures still need cleanup after a directory switch.
    static func isTemporaryFile(_ url: URL) -> Bool { settings.isTemporaryFile(url) }
}
