import Foundation

/// Watches the folder macOS saves screenshots to and reports new ones.
/// Tendedero never takes screenshots itself: you keep your usual shortcut
/// (or CleanShot, or anything else) and the line just picks them up.
final class ScreenshotWatcher {
    let folder: URL
    /// On the Desktop we only accept real screenshots, tagged by macOS with an
    /// extended attribute. In a dedicated folder, any image counts.
    private let onlyTaggedScreenshots: Bool
    private var known = Set<String>()
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var retryCounts: [String: Int] = [:]
    private var incompleteSources: [String: DispatchSourceFileSystemObject] = [:]
    private let onNew: (URL) -> Bool
    private let onChange: () -> Void

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]

    static let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

    /// Watches the folder macOS saves screenshots to, or a given folder.
    init(folder: URL? = nil, onNew: @escaping (URL) -> Bool, onChange: @escaping () -> Void) {
        self.onNew = onNew
        self.onChange = onChange
        self.folder = folder ?? Self.screenshotFolder()
        onlyTaggedScreenshots = self.folder.standardizedFileURL.path == Self.desktop.standardizedFileURL.path
    }

    static func screenshotFolder() -> URL {
        let fm = FileManager.default
        // Read fresh through cfprefsd: inbox mode changes this value at runtime.
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        // macOS 27 keeps it in "location-screenshot"; earlier versions in "location".
        let domain = "com.apple.screencapture" as CFString
        let raw = (CFPreferencesCopyAppValue("location-screenshot" as CFString, domain) as? String)
            ?? (CFPreferencesCopyAppValue("location" as CFString, domain) as? String)
        if let raw, !raw.isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Anything created after the app launched counts as new, even if it
    /// landed before the watcher was ready (macOS may be asking for Desktop
    /// access at that moment).
    private let launchDate = Date()

    func start() {
        guard source == nil else { return }
        stop()
        known = []
        retryCounts = [:]
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("Tendedero: cannot watch \(folder.path)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleScan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        // Watch before listing, so a capture arriving during startup still
        // generates an event rather than falling into the listing/open gap.
        if let files = listing() {
            known = Set(files.filter { creationDate($0) < launchDate }.map(\.path))
        }
        scan()
    }

    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        for incomplete in incompleteSources.values { incomplete.cancel() }
        incompleteSources = [:]
    }

    deinit { stop() }

    private func watchIncomplete(_ url: URL) {
        guard incompleteSources[url.path] == nil else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let incomplete = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        incomplete.setEventHandler { [weak self] in
            guard let self else { return }
            self.incompleteSources.removeValue(forKey: url.path)?.cancel()
            self.scheduleScan()
        }
        incomplete.setCancelHandler { close(fd) }
        incompleteSources[url.path] = incomplete
        incomplete.resume()
    }

    private func scheduleScan(resetRetries: Bool = true) {
        guard source != nil else { return }
        if resetRetries { retryCounts = [:] }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        pending = work
        // macOS writes a hidden temp file and renames it; give it a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func scan() {
        guard source != nil else { return }
        guard let files = listing() else { return }
        let paths = Set(files.map(\.path))
        known.formIntersection(paths)
        retryCounts = retryCounts.filter { paths.contains($0.key) }
        for path in incompleteSources.keys.filter({ !paths.contains($0) }) {
            incompleteSources.removeValue(forKey: path)?.cancel()
        }
        var needsRetry = false
        for url in files where !known.contains(url.path) {
            if !isCandidate(url) || (retryCounts[url.path] ?? 0) >= 10 { continue }
            if onNew(url) {
                known.insert(url.path)
                retryCounts[url.path] = nil
                incompleteSources.removeValue(forKey: url.path)?.cancel()
            } else {
                // Updating an existing file does not necessarily notify the
                // directory watcher. Watch rejected files themselves as well.
                watchIncomplete(url)
                // A file may exist before it can be decoded. Do not mark it
                // handled until the line actually accepted it. Bound retries
                // for a damaged image; a later file event starts another try.
                let attempts = (retryCounts[url.path] ?? 0) + 1
                retryCounts[url.path] = attempts
                if attempts < 10 { needsRetry = true }
            }
        }
        onChange()
        if needsRetry { scheduleScan(resetRetries: false) }
    }

    private func listing() -> [URL]? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        return urls.sorted { creationDate($0) < creationDate($1) }
    }

    private func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    private func isCandidate(_ url: URL) -> Bool {
        guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
        return onlyTaggedScreenshots ? isScreenCapture(url) : true
    }

    private func isScreenCapture(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
        }
    }
}
