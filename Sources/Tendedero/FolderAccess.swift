import Foundation

/// The user's real home folder. Inside the App Store's sandbox,
/// `FileManager`'s home is the app's container, not the folder with the
/// Desktop in it.
let realHome: URL = {
    if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}()

#if APP_STORE
/// The App Store build lives in a sandbox: it can only look inside the
/// folders the user picked. Each pick is kept as a security-scoped bookmark,
/// so the folder stays open to Tendedero after a restart.
enum FolderAccess {
    private static let bookmarksKey = "folderBookmarks"
    private static let screenshotFolderKey = "screenshotFolder"

    /// The folder screenshots are saved to, as the user chose it.
    static var screenshotFolder: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: screenshotFolderKey) else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            if let old = screenshotFolder, old.standardizedFileURL != newValue?.standardizedFileURL,
               !MainActor.assumeIsolated({ AppDelegate.extraFolders }).contains(where: { $0.standardizedFileURL == old.standardizedFileURL }) {
                forget(old)
            }
            if let newValue { remember(newValue) }
            UserDefaults.standard.set(newValue?.path, forKey: screenshotFolderKey)
        }
    }

    /// Keeps access to a folder picked in an open panel.
    static func remember(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var all = bookmarks
        all[url.standardizedFileURL.path] = data
        bookmarks = all
        _ = url.startAccessingSecurityScopedResource()
    }

    static func forget(_ url: URL) {
        var all = bookmarks
        all[url.standardizedFileURL.path] = nil
        bookmarks = all
        url.stopAccessingSecurityScopedResource()
    }

    /// Opens every folder picked before. Called once, at launch; the access
    /// lasts until the app quits.
    static func restoreAll() {
        var all = bookmarks
        for (path, data) in all {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else {
                all[path] = nil
                continue
            }
            _ = url.startAccessingSecurityScopedResource()
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                        includingResourceValuesForKeys: nil, relativeTo: nil) {
                all[path] = fresh
            }
        }
        bookmarks = all
    }

    private static var bookmarks: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: bookmarksKey) }
    }
}
#endif
