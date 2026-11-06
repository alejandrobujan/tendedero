import AppKit

/// Share, from a photo's menu: the panel macOS shows in every app, with
/// AirDrop, Messages, Mail and whatever else this Mac can share to. macOS
/// does the sending; Tendedero only hands over the file.
@MainActor
final class Share: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    static let shared = Share()

    private var picker: NSSharingServicePicker?
    /// Sharing is under way: the panel is open, or the service chosen in it
    /// has not finished. The line stays down meanwhile, with the photo in
    /// its place. Some services never say they are done, so after two
    /// minutes the line is free to go up again.
    private(set) var isOpen = false
    private var safety: Timer?

    /// Each share hands over a hard link to the photo, not the photo itself.
    /// Sending to a phone and then letting the photo go is a natural thing
    /// to do, and AirDrop may still be reading the file when it moves to the
    /// Trash. The link keeps the same bytes under the same name, costs no
    /// space and is made at once. Kept in a private folder and cleared after
    /// an hour, when the app starts and when it quits.
    private static let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Tendedero-Sharing", isDirectory: true)

    /// The share panel hangs from a view, and the photo's own view is gone
    /// once the line puts itself away. An invisible window in the card's
    /// place holds the panel. Once a service is chosen, its window belongs
    /// in the middle of that screen, not up against the card's screen edge.
    private lazy var anchor = Self.makeAnchor()
    private lazy var serviceAnchor = Self.makeAnchor()

    private static func makeAnchor() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        // Above the line, which floats.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        return window
    }

    /// Shows the share panel for the photo at `url`, whose card is at
    /// `cardFrame` on screen.
    func show(_ url: URL, from cardFrame: NSRect) {
        clear(olderThan: 3600)
        isOpen = true
        safety?.invalidate()
        let timer = Timer(timeInterval: 120, repeats: false) { _ in
            MainActor.assumeIsolated { Share.shared.done() }
        }
        RunLoop.main.add(timer, forMode: .common)
        safety = timer
        anchor.setFrame(cardFrame, display: false)
        anchor.orderFront(nil)
        // The line is a panel that never takes focus. The panel and the
        // windows services open belong to Tendedero, and answer only if
        // Tendedero is in front.
        NSApp.activate(ignoringOtherApps: true)
        let picker = NSSharingServicePicker(items: [snapshot(of: url)])
        picker.delegate = self
        self.picker = picker
        guard let view = anchor.contentView else { return }
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func clearAll() {
        clear(olderThan: 0)
    }

    private func done() {
        anchor.orderOut(nil)
        serviceAnchor.orderOut(nil)
        picker = nil
        isOpen = false
        safety?.invalidate()
        safety = nil
    }

    private func snapshot(of url: URL) -> URL {
        let directory = Self.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let link = directory.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.linkItem(at: url, to: link)
            return link
        } catch {
            // On another disk there is no link to make: the photo itself goes.
            try? FileManager.default.removeItem(at: directory)
            return url
        }
    }

    private func clear(olderThan age: TimeInterval) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.creationDateKey])
        else { return }
        for entry in entries {
            let made = (try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if Date().timeIntervalSince(made) >= age { try? fm.removeItem(at: entry) }
        }
    }

    // MARK: NSSharingServicePickerDelegate

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                                          delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        self
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                                          didChoose service: NSSharingService?) {
        // Closed without choosing: nothing else will come.
        guard service == nil else { return }
        MainActor.assumeIsolated { done() }
    }

    // MARK: NSSharingServiceDelegate

    nonisolated func sharingService(_ sharingService: NSSharingService,
                                    sourceWindowForShareItems items: [Any],
                                    sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        MainActor.assumeIsolated {
            // Keep the picker's anchor at the photo. Moving that window while
            // AppKit hands over to a service also moves the service's window.
            let centre = NSPoint(x: anchor.frame.midX, y: anchor.frame.midY)
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(centre, $0.frame, false) }) ?? NSScreen.main {
                let area = screen.visibleFrame
                serviceAnchor.setFrame(NSRect(x: area.midX - 1, y: area.midY - 1, width: 2, height: 2), display: false)
            }
            serviceAnchor.orderFront(nil)
            return serviceAnchor
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService,
                                    sourceFrameOnScreenForShareItem item: Any) -> NSRect {
        MainActor.assumeIsolated { serviceAnchor.frame }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated { done() }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService,
                                    didFailToShareItems items: [Any], error: Error) {
        MainActor.assumeIsolated {
            log.notice("Share ended without sending: \(error.localizedDescription, privacy: .public)")
            done()
        }
    }
}
