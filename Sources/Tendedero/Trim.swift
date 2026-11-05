import AppKit
import AVKit
import Combine

/// Trims a screen recording in place, with the same trimming bar QuickTime
/// shows. It is to recordings what Markup is to screenshots: press and hold,
/// edit, and the result hangs as a new recording or replaces the original.
@MainActor
final class Trim: NSObject, NSWindowDelegate {
    static let shared = Trim()

    /// Called with the file once the trimmed recording has replaced it.
    var onSaved: (URL) -> Void = { _ in }
    /// Called with the new file once the trimmed recording is saved beside
    /// the original.
    var onSavedAsNew: (URL) -> Void = { _ in }

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
        alert.informativeText = L("Save as New hangs it on the line and leaves the original as it is. Replace puts it in the original's place, and the parts you cut can't be brought back.")
        alert.addButton(withTitle: L("Save as New"))
        alert.addButton(withTitle: L("Replace"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: self.save(item, to: url, asNew: true)
            case .alertSecondButtonReturn: self.save(item, to: url, asNew: false)
            default: break
            }
            self.window?.close()
        }
    }

    // MARK: Writing back

    /// Copies the kept part without re-encoding, to a hidden file next to the
    /// original so the watcher ignores it, then moves it beside the original
    /// or swaps it in.
    private func save(_ item: AVPlayerItem, to original: URL, asNew: Bool) {
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
        guard let export = AVAssetExportSession(asset: item.asset, presetName: AVAssetExportPresetPassthrough) else {
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
            if export.status == .completed, Self.place(temp, at: target, asNew: asNew) {
                log.notice("Trimmed \(target.lastPathComponent, privacy: .public)")
                if asNew { onSavedAsNew(target) } else { onSaved(target) }
            } else {
                log.error("Could not trim \(target.lastPathComponent, privacy: .public): \(export.error?.localizedDescription ?? "", privacy: .public)")
                try? FileManager.default.removeItem(at: temp)
                NSSound.beep()
            }
        }
    }

    private static func place(_ temp: URL, at target: URL, asNew: Bool) -> Bool {
        if asNew { return (try? FileManager.default.moveItem(at: temp, to: target)) != nil }
        return (try? FileManager.default.replaceItemAt(target, withItemAt: temp)) != nil
    }

    private static func newName(for original: URL) -> String {
        let base = original.deletingPathExtension().lastPathComponent
        return "\(base) \(L("trimmed")).\(original.pathExtension)"
    }
}
