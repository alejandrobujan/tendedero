import AppKit
import Foundation

/// Looks up text in `Resources/<language>.lproj/Localizable.strings`, keyed by
/// the English text itself. macOS picks the language from the user's whole
/// list of preferred languages, and anything missing falls back to English.
///
/// The folders are copied into the app by `scripts/build-app.sh`. Running the
/// bare binary, outside the app, shows English.
func L(_ english: String) -> String {
    NSLocalizedString(english, comment: "")
}

// MARK: Language override

/// Manages a user-chosen app language stored in UserDefaults.
/// On first launch the system language is used (no override). After the user
/// picks a language it is persisted and applied on the next launch.
enum LanguageOverride {

    private static let key = "AppLanguageOverride"

    /// The language code the user has chosen, or nil if none (system default).
    static var current: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The language code that is actually active right now (system or override).
    static var active: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    /// All language codes that have a `.lproj` folder in the app bundle.
    static var available: [String] {
        // Bundle.localizations can contain duplicates (once from CFBundleLocalizations
        // in Info.plist and once from scanning .lproj folders), so deduplicate first.
        let unique = Array(Set(Bundle.main.localizations)).filter { $0 != "Base" }
        return unique.sorted { displayName($0).localizedCompare(displayName($1)) == .orderedAscending }
    }

    /// Human-readable name of a language code, in that language.
    static func displayName(_ code: String) -> String {
        Locale(identifier: code).localizedString(forLanguageCode: code)?.capitalized
            ?? code
    }

    /// Applies a chosen language by writing to UserDefaults and restarting.
    /// Passing nil removes the override and goes back to the system language.
    static func apply(_ code: String?) {
        if let code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
            current = code
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            current = nil
        }
        UserDefaults.standard.synchronize()
        // Relaunch so the new bundle language is picked up from the start.
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
