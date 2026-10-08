import Foundation

/// Watches the folder macOS saves screenshots to and reports new ones.
/// Tendedero never takes screenshots itself: you keep your usual shortcut
/// (or CleanShot, or anything else) and the line just picks them up.
final class ScreenshotWatcher {
    let folder: URL
    /// On the Desktop we only accept real screenshots, tagged by macOS with an
    /// extended attribute. In a dedicated folder, any image counts.
    private let onlyTaggedScreenshots: Bool
    private var known: Set<String>?
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    /// A `start()` that is still waiting on the folder, off the main thread.
    private var starting = false
    /// A folder listing that is still on its way, off the main thread.
    private var listing = false
    /// A capture landed while that listing was in flight.
    private var missed = false
    /// `stop()` arrived while one of the two was still pending.
    private var stopped = false
    private let onNew: (URL) -> Void
    private let onChange: () -> Void

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]

    static let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

    /// Watches the folder macOS saves screenshots to, or a given folder.
    init(folder: URL? = nil, onNew: @escaping (URL) -> Void, onChange: @escaping () -> Void) {
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

    /// The folder is opened off the main thread, because `open()` blocks while
    /// macOS asks whether Tendedero may look inside it. On the Desktop that is
    /// the consent prompt, and it waits for an answer. Asking from
    /// `applicationDidFinishLaunching` meant the app had not finished launching
    /// while that was pending: no status item appeared, and the signal sources
    /// that put the screenshot settings back never ran.
    func start() {
        stopped = false
        guard source == nil, !starting else { return }
        starting = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fd = open(self.folder.path, O_EVTONLY)
            DispatchQueue.main.async { self.watch(fd) }
        }
    }

    /// Starts watching, then reads the folder. The watcher is live before the
    /// listing begins, so a capture that lands in between is not lost.
    private func watch(_ fd: Int32) {
        starting = false
        guard !stopped else {
            if fd >= 0 { close(fd) }
            return
        }
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
        refresh()
    }

    /// Safe to call while `start()` or a listing is still pending: the file
    /// descriptor is closed as soon as it arrives, and a listing that lands
    /// afterwards is dropped.
    func stop() {
        stopped = true
        missed = false
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func scheduleScan() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        // macOS writes a hidden temp file and renames it; give it a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Reads the folder off the main thread. Sorting by creation date and
    /// reading it back costs one filesystem call per file, and this folder can
    /// be the Desktop, so none of it belongs on the main thread.
    private func refresh() {
        guard !listing else {
            missed = true
            return
        }
        listing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let files = self.listFolder()
            let settled = files.filter { self.creationDate($0) < self.launchDate }
            let candidates = files.filter { self.isCandidate($0) }
            DispatchQueue.main.async { self.adopt(files, settled, candidates) }
        }
    }

    /// Takes a finished listing, reports what is new, then runs the listing
    /// that was asked for while this one was in flight.
    private func adopt(_ files: [URL], _ settled: [URL], _ candidates: [URL]) {
        listing = false
        guard !stopped else { return }
        // The first listing adopts everything that was already there when the
        // app launched. Later ones compare against the previous listing.
        let first = known == nil
        let base = known ?? Set(settled.map(\.path))
        for url in candidates where !base.contains(url.path) {
            onNew(url)
        }
        known = Set(files.map(\.path))
        if !first { onChange() }
        if missed {
            missed = false
            refresh()
        }
    }

    private func listFolder() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
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
