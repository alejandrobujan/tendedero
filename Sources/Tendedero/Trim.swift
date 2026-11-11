import AppKit
import AVKit
import Combine

/// Trims a screen recording in place, with the same trimming bar QuickTime
/// shows. It is to recordings what Markup is to screenshots: press and hold,
/// edit, and the result hangs as a new recording or replaces the original.
@MainActor
final class Trim: NSObject, NSWindowDelegate {
    static let shared = Trim()

    /// Called with the file once the trimmed recording has replaced it, where
    /// on screen the editor showed it, where the original went in the Trash,
    /// and how its length changed.
    var onSaved: (URL, CGRect, URL, String) -> Void = { _, _, _, _ in }
    /// Called with the new file once the trimmed recording is saved beside
    /// the original, the original, and where on screen the editor showed it.
    var onSavedAsNew: (URL, URL, CGRect) -> Void = { _, _, _ in }

    private var window: NSWindow?
    private var ready: AnyCancellable?

    func edit(_ url: URL, size: CGSize) {
        window?.close()

        let item = AVPlayerItem(url: url)
        let playerView = AVPlayerView()
        playerView.player = AVPlayer(playerItem: item)
        playerView.controlsStyle = .inline

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.windowSize(for: size)),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = url.lastPathComponent
        window.contentView = playerView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // The trimming bar can only come up once the recording has loaded.
        ready = item.publisher(for: \.status)
            .first { $0 != .unknown }
            .receive(on: RunLoop.main)
            .sink { [weak self, weak playerView] status in
                guard let self, let playerView, status == .readyToPlay, playerView.canBeginTrimming else {
                    log.error("Could not trim \(url.lastPathComponent, privacy: .public)")
                    return
                }
                playerView.beginTrimming { result in
                    DispatchQueue.main.async {
                        guard result == .okButton else {
                            self.window?.close()
                            return
                        }
                        self.askHowToSave(item, original: url)
                    }
                }
            }
    }

    /// The recording at its own proportions, as large as fits comfortably.
    private static func windowSize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 720, height: 450) }
        let scale = min(720 / size.width, 520 / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        (window?.contentView as? AVPlayerView)?.player?.pause()
        ready = nil
        window = nil
    }

    /// Replacing can't be undone, so the choice comes after the trim, when
    /// it is clear what would be lost.
    private func askHowToSave(_ item: AVPlayerItem, original url: URL) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L("How should the trimmed recording be saved?")
        alert.informativeText = L("Save as New hangs it on the line and leaves the original as it is. Replace puts it in the original's place and sends the original to the Trash. ⌘Z brings it back.")
        alert.addButton(withTitle: L("Save as New"))
        alert.addButton(withTitle: L("Replace"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: self.save(item, to: url, asNew: true)
            case .alertSecondButtonReturn: self.save(item, to: url, asNew: false)
            default: self.window?.close()
            }
        }
    }

    // MARK: Writing back

    /// Copies the kept part without re-encoding, to a hidden file next to the
    /// original so the watcher ignores it, then moves it beside the original
    /// or swaps it in. The editor stays open until then, so the recording
    /// leaves for the line from where you were looking at it.
    private func save(_ item: AVPlayerItem, to original: URL, asNew: Bool) {
        let editor = window
        let frame = editor.map { $0.convertToScreen($0.contentLayoutRect) } ?? .zero
        (editor?.contentView as? AVPlayerView)?.player?.pause()
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
        guard let export = AVAssetExportSession(asset: item.asset, presetName: AVAssetExportPresetPassthrough) else {
            editor?.close()
            NSSound.beep()
            return
        }
        let folder = original.deletingLastPathComponent()
        let temp = folder
            .appendingPathComponent(".trimming-\(UUID().uuidString)")
            .appendingPathExtension(original.pathExtension)
        let target = asNew ? uniqueURL(in: folder, for: Self.newName(for: original)) : original
        export.outputURL = temp
        export.outputFileType = original.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        export.timeRange = CMTimeRange(start: start, end: end)
        Task {
            await export.export()
            // Once the images for the flight are made, so nothing is left blank.
            defer { editor?.close() }
            let finished = export.status == .completed
            if finished, asNew, (try? FileManager.default.moveItem(at: temp, to: target)) != nil {
                log.notice("Trimmed \(target.lastPathComponent, privacy: .public)")
                onSavedAsNew(target, original, frame)
            } else if finished, !asNew, let trashed = try? swapIn(temp, at: target) {
                log.notice("Trimmed \(target.lastPathComponent, privacy: .public)")
                onSaved(target, frame, trashed, Self.lengths(from: item.duration, to: end - start))
            } else {
                log.error("Could not trim \(target.lastPathComponent, privacy: .public): \(export.error?.localizedDescription ?? "", privacy: .public)")
                try? FileManager.default.removeItem(at: temp)
                NSSound.beep()
            }
        }
    }

    /// "0:31 → 0:05". Digits and an arrow read the same in every language.
    private static func lengths(from before: CMTime, to after: CMTime) -> String {
        func clock(_ time: CMTime) -> String {
            let total = time.seconds.isFinite ? Int(time.seconds.rounded()) : 0
            let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        }
        return "\(clock(before)) → \(clock(after))"
    }

    private static func newName(for original: URL) -> String {
        let base = original.deletingPathExtension().lastPathComponent
        // Trimming a trimmed recording again doesn't say so twice.
        let suffix = " \(L("trimmed"))"
        return "\(base.hasSuffix(suffix) ? base : base + suffix).\(original.pathExtension)"
    }
}
