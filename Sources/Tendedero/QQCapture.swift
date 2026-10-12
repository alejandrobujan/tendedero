import AppKit

/// QQ's completed captures contain an image and a URL to its temporary PNG.
/// Treat this one file-backed format as an image, without accepting Finder copies.
enum QQCapture {
    private static let enabledKey = "qqClipboardEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static let temporaryFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.tencent.qq/Data/tmp", isDirectory: true)

    static let standalonePreferences = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/FN2V63AD2J.com.tencent.ScreenCapture3/Data/Library/Preferences/FN2V63AD2J.com.tencent.ScreenCapture3")

    static func matches(_ items: [NSPasteboardItem]) -> Bool {
        guard items.count == 1, let item = items.first,
              item.types.contains(.png) || item.types.contains(.tiff),
              let raw = item.string(forType: .fileURL), let url = URL(string: raw), url.isFileURL,
              url.deletingLastPathComponent().standardizedFileURL == temporaryFolder.standardizedFileURL,
              url.lastPathComponent.range(of: #"^QQ_[0-9]+\.png$"#, options: .regularExpression) != nil
        else { return false }
        return true
    }

    /// A repeatable action, not a toggle. QQ reads the setting on its next launch.
    static func allowStandalone(at preferences: URL = standalonePreferences) throws {
        try FileManager.default.createDirectory(at: preferences.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", preferences.path, "settingkeyrunalone", "-bool", "true"]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            throw NSError(domain: "QQCapture", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "defaults write failed"
            ])
        }
    }
}
