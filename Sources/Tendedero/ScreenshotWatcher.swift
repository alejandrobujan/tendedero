import Foundation

/// Watches the folder macOS saves screenshots to and reports new ones.
/// Tendedero never takes screenshots itself: you keep your usual shortcut
/// (or CleanShot, or anything else) and the line just picks them up.
final class ScreenshotWatcher {
    let folder: URL
    /// On the Desktop we only accept real screenshots, tagged by macOS with an
    /// extended attribute. In a dedicated folder, any image counts.
    private let onlyTaggedScreenshots: Bool
    /// Screen recordings carry no tag, so they are only picked up in
    /// Tendedero's own folder, where nothing else is saved.
    private var acceptsRecordings: Bool
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
    /// New images still being written, with their size when last checked.
    /// A watched folder like Downloads gets files that appear under their
    /// final name and fill in over seconds; hung at once, they stayed cut off.
    private var unfinished: [URL: Int] = [:]
    private var checkingUnfinished = false
    /// When each of those was first seen. One that is still not whole after
    /// ten minutes, a stalled download or a broken file, is let go.
    private var firstSeen: [URL: Date] = [:]

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]

    static let desktop = realHome.appendingPathComponent("Desktop", isDirectory: true)

    /// Watches the folder macOS saves screenshots to, or a given folder.
    /// `anyImage` takes every new image even on the Desktop, for a folder
    /// the user chose to watch.
    init(folder: URL? = nil, anyImage: Bool = false, onNew: @escaping (URL) -> Void, onChange: @escaping () -> Void) {
        self.onNew = onNew
        self.onChange = onChange
        self.folder = folder ?? Self.screenshotFolder()
        onlyTaggedScreenshots = !anyImage
            && self.folder.standardizedFileURL.path == Self.desktop.standardizedFileURL.path
        acceptsRecordings = self.folder.standardizedFileURL.path == Inbox.folder.standardizedFileURL.path
        #if APP_STORE
        // A screenshot folder of its own, picked by the user, gets recordings
        // too: nothing else is saved there.
        if folder == nil, self.folder.standardizedFileURL.path != Self.desktop.standardizedFileURL.path {
            acceptsRecordings = true
        }
        #endif
    }

    static func screenshotFolder() -> URL {
        #if APP_STORE
        // The sandbox cannot read the screenshot settings: the user tells us.
        return FolderAccess.screenshotFolder ?? desktop
        #else
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
        return desktop
        #endif
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
        unfinished = [:]
        firstSeen = [:]
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
        let fresh = candidates.filter { !base.contains($0.path) }
        if !fresh.isEmpty { report(fresh) }
        known = Set(files.map(\.path))
        if !first { onChange() }
        if missed {
            missed = false
            refresh()
        }
    }

    /// Hangs what is complete and waits for the rest. Screenshots macOS takes
    /// arrive whole, so they hang with no delay; an image still being written
    /// is looked at again every half second until it is whole.
    private func report(_ urls: [URL], sizes: [URL: Int] = [:]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let checked = urls.map { url -> (URL, Int?, Bool) in
                let size = Self.fileSize(url)
                return (url, size, size.map { Self.isWhole(url, size: $0, before: sizes[url]) } ?? false)
            }
            DispatchQueue.main.async {
                guard !self.stopped else { return }
                for (url, size, whole) in checked {
                    let since = self.firstSeen[url] ?? Date()
                    if whole {
                        self.unfinished[url] = nil
                        self.firstSeen[url] = nil
                        self.onNew(url)
                    } else if let size, Date().timeIntervalSince(since) < 600 {
                        self.unfinished[url] = size
                        self.firstSeen[url] = since
                    } else {
                        // Gone before it was finished, a download that was
                        // cancelled, or never finished at all.
                        self.unfinished[url] = nil
                        self.firstSeen[url] = nil
                    }
                }
                self.checkUnfinishedLater()
            }
        }
    }

    private func checkUnfinishedLater() {
        guard !unfinished.isEmpty, !checkingUnfinished else { return }
        checkingUnfinished = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.checkingUnfinished = false
            guard !self.stopped, !self.unfinished.isEmpty else { return }
            let waiting = self.unfinished
            self.report(Array(waiting.keys), sizes: waiting)
        }
    }

    /// Asked of the file system each time: a URL keeps the resource values it
    /// read once, and a file still being written would seem to stop growing.
    private static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    /// Whether an image has been written to the end. Most formats say where
    /// they end, so a cut-off file is told apart at once; ImageIO alone does
    /// not, and draws the missing part as empty. For the rest, a size that
    /// held still for half a second has to do. Recordings arrive whole: macOS
    /// moves them into the folder once they are saved.
    static func isWhole(_ url: URL, size: Int, before: Int?) -> Bool {
        if isRecording(url) { return true }
        guard size > 0, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        let tailLength = min(size, 32)
        try? handle.seek(toOffset: UInt64(size - tailLength))
        let tail = [UInt8]((try? handle.read(upToCount: tailLength)) ?? Data())
        switch url.pathExtension.lowercased() {
        case "png":
            // The IEND chunk and its checksum close every PNG.
            return tail.count >= 12 && Array(tail.suffix(12)) == [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        case "jpg", "jpeg":
            // The end of image marker, allowing a few bytes of padding after it.
            return zip(tail, tail.dropFirst()).contains { $0 == 0xFF && $1 == 0xD9 }
        case "gif":
            return tail.last == 0x3B
        case "webp":
            // RIFF says how long the file is.
            let h = [UInt8](head)
            guard h.count >= 8, h[0..<4] == [0x52, 0x49, 0x46, 0x46] else { return false }
            let declared = Int(h[4]) | Int(h[5]) << 8 | Int(h[6]) << 16 | Int(h[7]) << 24
            return size >= declared + 8
        case "heic", "heif":
            return isoBoxesEnd(handle, size: size)
        default:
            return before == size
        }
    }

    /// HEIC is a chain of boxes, each starting with its length: whole when the
    /// last one ends where the file does.
    private static func isoBoxesEnd(_ handle: FileHandle, size: Int) -> Bool {
        var offset = 0
        while offset < size {
            try? handle.seek(toOffset: UInt64(offset))
            let header = [UInt8]((try? handle.read(upToCount: 16)) ?? Data())
            guard header.count >= 8 else { return false }
            var length = header[0..<4].reduce(0) { $0 << 8 | Int($1) }
            if length == 1 {
                guard header.count >= 16 else { return false }
                length = header[8..<16].reduce(0) { $0 << 8 | Int($1) }
            } else if length == 0 {
                return true
            }
            guard length >= 8 else { return false }
            offset += length
        }
        return offset == size
    }

    private func listFolder() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.map { ($0, creationDate($0)) }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    private func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    private func isCandidate(_ url: URL) -> Bool {
        if isRecording(url) { return acceptsRecordings }
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
