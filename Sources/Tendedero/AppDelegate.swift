import AppKit
import Carbon
import Combine
import Quartz
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let line = Line()
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher!
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), captures keep
    /// landing on the Desktop, and they still hang on the line.
    private var safetyWatcher: ScreenshotWatcher?
    /// Folders chosen in "Also watch folders", like the one another
    /// screenshot app saves to.
    private var folderWatchers: [ScreenshotWatcher] = []
    private var clipboardWatcher: ClipboardWatcher!
    private var noteWatcher: NoteWatcher!
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
    /// ⌃⌥F searches the line. Fixed, apart from the shortcut that shows it.
    private var searchHotKey: HotKey?
    private var searchBar: SearchBar!
    private let zoom = Zoom()
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?
    /// Whether the line should be up, if nothing prevents it. A full screen
    /// app on that screen does: the line waits until you leave full screen.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    /// Opened on purpose with the shortcut or the menu, which counts over a
    /// full screen app too, until the line tucks away.
    private var openedOnPurpose = false

    // What brings the line down, from the menu bar's "Bring the line down".
    // Out of the box, the first two are on and the third off.

    /// Resting the pointer in the menu bar. Off, only the shortcut and the
    /// menu open it.
    static var opensFromMenuBar: Bool {
        get { !UserDefaults.standard.bool(forKey: "menuBarRevealOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "menuBarRevealOff") }
    }

    /// Something new hanging shows itself for a moment. Off, it hangs
    /// quietly and waits for you to bring the line down.
    static var peeksAtNew: Bool {
        get { !UserDefaults.standard.bool(forKey: "quietHang") }
        set { UserDefaults.standard.set(!newValue, forKey: "quietHang") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.placeOnScreen()
        updateCapacity()

        if Inbox.isEnabled { Inbox.apply() }
        restoreSettingsOnTermination()
        startWatcher()
        clipboardWatcher = ClipboardWatcher { [weak self] url in self?.hangCapture(url) }
        if ClipboardWatcher.isEnabled { clipboardWatcher.start() }
        noteWatcher = NoteWatcher { [weak self] in self?.line.refreshNotes() }
        noteWatcher.start()

        registerShortcut()
        searchBar = SearchBar(line: line)
        searchBar.onReturn = { [weak self] in self?.copyFirstMatch() }
        searchBar.onEnd = { [weak self] in self?.endSearch(tuckAway: true) }
        searchHotKey = HotKey(Self.searchShortcut) { [weak self] in self?.startSearch() }

        setUpStatusItem()
        watchMenuBarClicks()
        watchPutBackKey()

        // Hang on Tendedero, in the menu of images in Finder and other apps.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        Markup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        Share.shared.clearAll()
        Trim.shared.onSaved = { [weak self] url, from, original, lengths in
            self?.line.rememberReplaced(url, original: original)
            self?.replaceOnLine(url, from: from, lengths: lengths)
        }
        Trim.shared.onSavedAsNew = { [weak self] url, original, from in
            self?.hangCapture(url, squeezing: true, trimmedFrom: from, after: original)
            self?.line.rememberSavedAsNew(url)
        }
        panel.onScroll = { [weak self] event in
            // Sideways on a trackpad, or the wheel of a mouse.
            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX : event.scrollingDeltaY
            self?.line.scroll(by: event.hasPreciseScrollingDeltas ? delta : delta * 12)
        }
        line.onOriginalBack = { [weak self] trimmed, thumb in self?.originalBack(replacing: trimmed, thumb: thumb) }
        line.onFall = { [weak self] item in self?.fall(item) }
        line.onHold = { [weak self] id in self?.hold(id) }
        line.onHangBack = { id in Held.hangBack(id) }
        line.onUndoableAction = { [weak self] in self?.keepUndoAtPointer() }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)
        // Photos kept from last time show themselves for a moment.
        if line.liveCount > 0 { comeDown(on: nil) }

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Opened on purpose counts for the Space it was opened on.
                    if name == NSWorkspace.activeSpaceDidChangeNotification { self?.openedOnPurpose = false }
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self?.refresh()
                        self?.keepOnActiveSpace()
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
            }
        }

        if !Inbox.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.offerInbox()
                self?.offerCopying()
            }
        } else if !Self.copyingOffered {
            // Updated from a version that only hung screenshots: shown once.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerCopying() }
        } else if Self.shouldOfferLogin {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { Self.offerLogin() }
        }

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            keepOpen = true
            wanted = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.line.liveCount == 0 else { return }
                self.keepOpen = false
                self.wanted = false
                self.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Inbox.isEnabled { Inbox.restore() }
        Share.shared.clearAll()
    }

    // MARK: Inbox mode

    private func startWatcher() {
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        watcher = ScreenshotWatcher(
            onNew: { [weak self] url in self?.hangCapture(url) },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        if Inbox.isEnabled, watcher.folder.standardizedFileURL != ScreenshotWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                onNew: { [weak self] url in
                    log.notice("Screenshot landed on the Desktop despite inbox mode: \(url.lastPathComponent, privacy: .public)")
                    self?.hangCapture(url)
                },
                onChange: { [weak self] in self?.line.prune() })
            safety.start()
            safetyWatcher = safety
        }
        folderWatchers.forEach { $0.stop() }
        folderWatchers = []
        // A folder may also be watched for screenshots, like the Desktop; an
        // image both report hangs once.
        for folder in Self.extraFolders {
            let extra = ScreenshotWatcher(
                folder: folder, anyImage: true,
                onNew: { [weak self] url in self?.hangCapture(url) },
                onChange: { [weak self] in self?.line.prune() })
            extra.start()
            folderWatchers.append(extra)
        }
    }

    /// Up to three folders: enough for another screenshot app or an export
    /// folder, few enough that screenshots still have room on the line.
    static let maxExtraFolders = 3

    /// The folders from "Also watch folders" that still exist. New images in
    /// them hang like screenshots; taking one down leaves the file there.
    static var extraFolders: [URL] {
        get {
            let paths = UserDefaults.standard.stringArray(forKey: "extraFolders") ?? []
            return paths.compactMap { path in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: "extraFolders") }
    }

    private func chooseExtraFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Watch")
        panel.message = L("New images saved to this folder will hang on the line.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, Self.extraFolders.count < Self.maxExtraFolders,
              !Self.extraFolders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        Self.extraFolders.append(url)
        startWatcher()
    }

    private func setInbox(_ on: Bool) {
        Inbox.isEnabled = on
        if on { Inbox.apply() } else { Inbox.restore() }
        startWatcher()
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        Inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = L("Let Tendedero handle your screenshots?")
        alert.informativeText = L(
            "Screenshots will hang on the line the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. Drag one to a folder to keep it, or discard it with the cross. You can turn this off from the menu bar, and your settings come back when Tendedero quits.")
        alert.addButton(withTitle: L("Turn on"))
        alert.addButton(withTitle: L("Not now"))
        if let icon = NSImage(named: "Tendedero") ?? NSApp.applicationIconImage { alert.icon = icon }
        // A menu bar app that does not open at login is gone after the first
        // restart, so the first launch offers it too, ticked.
        let login = Self.shouldOfferLogin ? NSButton(checkboxWithTitle: L("Open at login"), target: nil, action: nil) : nil
        if let login {
            login.state = .on
            alert.accessoryView = login
            Self.loginOffered()
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
        if login?.state == .on { Self.openAtLogin() }
    }

    // MARK: Hang what you copy

    private static let copyingOfferedKey = "copyingOffered"
    private static var copyingOffered: Bool {
        get { UserDefaults.standard.bool(forKey: copyingOfferedKey) }
        set { UserDefaults.standard.set(newValue, forKey: copyingOfferedKey) }
    }

    /// Asked once, on the first launch or the first after an update: what
    /// you copy can hang too. Each kind is ticked and shown, but nothing is
    /// kept until Turn on. Open at login rides along when it is due, so an
    /// update asks one thing, not two.
    private func offerCopying() {
        Self.copyingOffered = true
        let alert = NSAlert()
        alert.messageText = L("Hang what you copy too?")
        alert.informativeText = L("Images, text and links you copy can hang on the line as well: text as a note, a link with its site. They stay on this Mac, and nothing is ever kept from a password field. Change it anytime under Hang what you copy in the menu bar.")
        alert.addButton(withTitle: L("Turn on"))
        alert.addButton(withTitle: L("Not now"))
        if let icon = NSImage(named: "Tendedero") ?? NSApp.applicationIconImage { alert.icon = icon }
        let kinds: [(String, ReferenceWritableKeyPath<ClipboardWatcher.Type, Bool>)] = [
            (L("Images"), \.imagesEnabled), (L("Text"), \.textEnabled), (L("Links"), \.linksEnabled),
        ]
        let boxes = kinds.map { kind -> NSButton in
            let box = NSButton(checkboxWithTitle: kind.0, target: nil, action: nil)
            box.state = .on
            return box
        }
        let login = Self.shouldOfferLogin ? NSButton(checkboxWithTitle: L("Open at login"), target: nil, action: nil) : nil
        login?.state = .on
        if login != nil { Self.loginOffered() }
        let stack = NSStackView(views: boxes + (login.map { [$0] } ?? []))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        // Open at login is a separate question: a little apart.
        if login != nil { stack.setCustomSpacing(14, after: boxes[boxes.count - 1]) }
        stack.frame = NSRect(x: 0, y: 0, width: 240, height: stack.fittingSize.height)
        alert.accessoryView = stack
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            for (kind, box) in zip(kinds, boxes) { ClipboardWatcher.self[keyPath: kind.1] = box.state == .on }
            refreshClipboardWatcher()
        }
        if login?.state == .on { Self.openAtLogin() }
    }

    // MARK: Open at login

    private static let loginOfferedKey = "loginOfferedVersion"
    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Each install or update asks once whether Tendedero should open at
    /// login, unless it already does.
    private static var shouldOfferLogin: Bool {
        SMAppService.mainApp.status != .enabled
            && UserDefaults.standard.string(forKey: loginOfferedKey) != version
    }

    private static func loginOffered() {
        UserDefaults.standard.set(version, forKey: loginOfferedKey)
    }

    private static func offerLogin() {
        loginOffered()
        let alert = NSAlert()
        alert.messageText = L("Open Tendedero at login?")
        alert.informativeText = L("Tendedero does not open when you log in, so after a restart the line is gone until you open it again.")
        alert.addButton(withTitle: L("Open at login"))
        alert.addButton(withTitle: L("Not now"))
        if let icon = NSImage(named: "Tendedero") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openAtLogin() }
    }

    /// Turned off in System Settings, macOS asks for approval there.
    private static func openAtLogin() {
        guard SMAppService.mainApp.status != .enabled else { return }
        toggleLaunchAtLogin()
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// Watching the clipboard is opt in, from the menu bar only.
    private func refreshClipboardWatcher() {
        if ClipboardWatcher.isEnabled { clipboardWatcher.start() } else { clipboardWatcher.stop() }
        updateStatusIcon()
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                if Inbox.isEnabled { Inbox.restore() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    /// An empty line goes away, unless it was opened on purpose.
    private func itemsChanged() {
        updateStatusIcon()
        Held.forget(except: Set(line.items.filter { !$0.falling && $0.held }.map(\.id)))
        guard line.liveCount == 0, !keepOpen, undoAnchor == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.line.liveCount == 0, !self.keepOpen, self.undoAnchor == nil else { return }
            self.wanted = false
            self.refresh()
        }
    }

    /// The line comes down on that screen for a moment, then tucks away.
    /// Without a screen, it uses the one under the pointer.
    private func comeDown(on screen: NSScreen?, whateverTheSetting: Bool = false) {
        panel.placeOnScreen(screen)
        updateCapacity()
        wanted = true
        refresh()
        if Self.peeksAtNew || whateverTheSetting { reveal(peekFor: 2.5) }
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    private func hangCapture(_ url: URL, squeezing: Bool = false, trimmedFrom: CGRect? = nil, after: URL? = nil) {
        // Several watchers may report a file we just saved. Keep ignoring
        // that same file after either a move or a copy.
        guard !line.isDesktopSave(url) else { return }
        // Already hanging: a photo put back with ⌘Z comes out of the Trash
        // into the folder, and the watcher sees it arrive. It must not pull
        // the line over to the screen it was first taken on.
        guard !line.items.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL && !$0.falling })
        else { return }
        let from = trimmedFrom ?? captureRect(of: url)
        let prepared = trimmedFrom.flatMap { Self.flightImage(of: url, from: $0) }
        let screen = from.flatMap(Self.screen(of:))
        // Every capture brings the line down before it hangs, on the screen it
        // was taken on. On a full line the oldest photo then falls in view as
        // the new one flies in.
        comeDown(on: screen, whateverTheSetting: trimmedFrom != nil)
        // A screenshot macOS took already played its shutter, so it hangs
        // without a chime of its own. Copied images and watched folders,
        // which come with no sound, keep it.
        guard let id = line.hang(url, quietly: from != nil && trimmedFrom == nil, flying: from != nil, squeezing: squeezing, after: after) else {
            // Nothing hung after all, so an empty line goes away again.
            itemsChanged()
            return
        }
        guard let from else { return }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: from, prepared: prepared)
        }
    }

    private func fly(_ id: UUID, from: CGRect, prepared: CGImage? = nil) {
        guard let item = line.items.first(where: { $0.id == id }),
              launch(item, from: from, prepared: prepared, landed: { [weak self] in self?.line.land(id) }) else {
            line.land(id)
            return
        }
    }

    /// Sends a photo flying to its card, if it can fly right now.
    private func launch(_ item: Pegged, from: CGRect, prepared: CGImage? = nil, strikes: Bool = false,
                        landed: @escaping () -> Void) -> Bool {
        guard isPresent, isRevealed, !Self.reducesMotion, CaptureFlight.flightsInProgress < 2,
              let screen = panel.screen,
              let to = cardFrame(for: item.id),
              let image = prepared ?? Self.flightImage(of: item.url, from: from) else { return false }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), strikes: strikes, on: screen, completion: landed)
        return true
    }

    /// Sharp enough while it starts out at the captured size, which a full
    /// Retina screen would otherwise take at full resolution.
    private static func flightImage(of url: URL, from: CGRect) -> CGImage? {
        let scale = screen(of: from)?.backingScaleFactor ?? 2
        let pixels = Int(max(from.width, from.height) * scale)
        return makeThumbnail(url, maxPixels: min(1500, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// A recording replaced by its trimmed version: the new one speeds up to
    /// the old one's clip and knocks it off, so it can't be mistaken for a new
    /// photo hanging.
    private func replaceOnLine(_ url: URL, from: CGRect, lengths: String) {
        guard let old = line.items.first(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return }
        let image = Self.flightImage(of: url, from: from)
        comeDown(on: Self.screen(of: from), whateverTheSetting: true)
        line.bringIntoView(old.id)
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            let flew = self.launch(old, from: from, prepared: image, strikes: true) { [weak self] in
                guard let self else { return }
                let card = self.cardFrame(for: old.id)
                // Hit towards the right, the card's bottom swings to the right,
                // which SwiftUI counts as turning anticlockwise.
                let direction: CGFloat = (card?.midX ?? 0) >= from.midX ? 1 : -1
                self.knock(old, direction: direction, greyed: true)
                self.line.takeClip(old.id, thumb: thumb, struck: -14 * Double(direction), note: lengths)
            }
            if !flew { self.line.takeClip(old.id, thumb: thumb) }
        }
    }

    /// ⌘Z on a replaced recording: the same blow the other way round. The
    /// original rises from where it fell and knocks the trimmed version off.
    private func originalBack(replacing trimmed: Pegged, thumb: NSImage) {
        guard isPresent, isRevealed, !Self.reducesMotion, let screen = panel.screen,
              let card = cardFrame(for: trimmed.id),
              let image = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.takeClip(trimmed.id, thumb: thumb)
            return
        }
        // It rises on the side with the most room, and hits the other way.
        let fellTo: CGFloat = card.midX > panel.frame.midX ? -1 : 1
        CaptureFlight.comeBack(image: image, to: card, tilt: CGFloat(trimmed.tilt), direction: fellTo, on: screen) { [weak self] in
            self?.knock(trimmed, direction: -fellTo)
            self?.line.takeClip(trimmed.id, thumb: thumb, struck: 14 * Double(fellTo))
        }
    }

    private func knock(_ item: Pegged, direction: CGFloat, greyed: Bool = false) {
        guard isPresent, isRevealed, !Self.reducesMotion, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.knock(image: image, card: card, tilt: CGFloat(item.tilt), direction: direction, greyed: greyed, behind: panel, on: screen)
    }

    private static func screen(of rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(CGPoint(x: rect.midX, y: rect.midY), $0.frame, false) }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    /// Reduce motion in Accessibility settings: photos land and leave
    /// without flying across the screen or falling down it.
    private static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, !Self.reducesMotion, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), pinned: item.kept, on: screen)
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let index = line.items.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = Layout.x(index: index, count: line.items.count, width: width,
                         visible: line.visibleCount, scroll: line.scroll, pinned: line.pinnedLead)
        let viewTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove
        let cardTop = viewTop + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize(for: line.items[index].thumb.size)
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen unless you asked for the line.
    private func refresh() {
        let blocked = !openedOnPurpose && (panel.screen.map(FullScreen.blocksLine(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.blocksLine(on:)) ?? false)
        if wanted && !blocked {
            present()
        } else {
            dismiss()
        }
        // The cursor is watched while there is a line, even tucked away,
        // to notice it pushing against the top edge.
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        // The window itself only comes in while the line is down; see setRevealed.
        if isRevealed { panel.orderFrontRegardless() }
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
    }

    /// The line is one window on every Space. After a long time running,
    /// macOS can leave it bound to a single Space, where ordering it in does
    /// nothing on the others while captures keep arriving (#80). Quitting and
    /// opening the app again fixes it because the window is new, so do the
    /// same here: a fresh window with the same contents, in the same place.
    private func keepOnActiveSpace() {
        guard isPresent, isRevealed, panel.isVisible, !panel.isOnActiveSpace else { return }
        log.notice("The line was not on the active Space; making its window again")
        let old = panel!
        let content = old.contentView
        old.contentView = NSView()
        old.orderOut(nil)
        let fresh = LinePanel(content: content ?? NSView())
        fresh.onScroll = old.onScroll
        fresh.setFrame(old.frame, display: false)
        fresh.ignoresMouseEvents = old.ignoresMouseEvents
        fresh.alphaValue = old.alphaValue
        panel = fresh
        fresh.orderFrontRegardless()
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        line.revealed = on
        // It always comes down showing the newest.
        if on { line.scroll = 0 }
        // Tucked away, the line leaves no window behind: an invisible strip
        // over the top of the screen would still sit above other apps for
        // anything that checks what is on top, like screen automation.
        if on {
            if isPresent {
                panel.orderFrontRegardless()
                DispatchQueue.main.async { [weak self] in self?.keepOnActiveSpace() }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.isRevealed else { return }
                self.panel.orderOut(nil)
            }
        }
        if !on {
            // Tucked away by any means, a search under way ends with it.
            if searchBar?.isShown == true { endSearch(tuckAway: false) }
            zoom.hide()
            undoAnchor = nil
            holdPutBackKey(false)
            line.clearSelection()
            holdSelectionKeys(false)
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
            // Opened on purpose lasts until the line tucks away, however that
            // happens: an empty line then goes, as with the shortcut, and over
            // a full screen app the line goes too.
            if keepOpen || openedOnPurpose {
                keepOpen = false
                openedOnPurpose = false
                if line.liveCount == 0 { wanted = false }
                refresh()
            }
        }
    }

    // MARK: Searching the line

    static let searchShortcut = Shortcut(keyCode: kVK_ANSI_F, modifiers: [.control, .option], key: "f")

    /// Brings the line down and opens the search field under it.
    private func startSearch() {
        if !isRevealed { toggle() }
        keepOpen = true
        pinned = true
        searchBar.show(below: panel.frame)
    }

    /// Return copies the newest photo, note or link that matches, and the
    /// line goes back up, as after picking a result in Spotlight.
    private func copyFirstMatch() {
        guard line.isSearching, let item = line.shown.last(where: { !$0.falling }) else { return }
        line.copy(item.id)
        endSearch(tuckAway: true)
    }

    /// The whole line comes back. With Escape it also tucks away; after a
    /// click elsewhere it stays as it is.
    private func endSearch(tuckAway: Bool) {
        line.query = ""
        searchBar.hide()
        if tuckAway, isRevealed { setRevealed(false) }
    }

    @objc private func toggle() {
        if isRevealed {
            setRevealed(false)
        } else {
            keepOpen = true
            wanted = true
            openedOnPurpose = true
            panel.placeOnScreen()
            updateCapacity()
            refresh()
            reveal(pinned: true)
        }
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
        holdPutBackKey(false)
        holdPhotoKeys(over: nil)
        holdSelectionKeys(false)
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    private static let revealDelay: TimeInterval = 0.25

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    /// The part of the menu bar that brings the line down: the middle third,
    /// so the menus on the left and the icons on the right stay easy to reach.
    static func revealBand(of screen: NSScreen) -> NSRect {
        let bar = menuBarBand(of: screen)
        let width = bar.width / 3
        return NSRect(x: bar.midX - width / 2, y: bar.minY, width: width, height: bar.height)
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A new click ends the previous menu interaction. If this
                // click performs another undoable action it gets a new anchor.
                self.releaseUndoAnchor()
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { NSMouseInRect(p, Self.menuBarBand(of: $0), false) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { NSMouseInRect(mouse, Self.menuBarBand(of: $0), false) } ?? false
        if !inMenuBar { menuBarSuppressed = false }
        let inRevealBand = screenUnderPointer.map { NSMouseInRect(mouse, Self.revealBand(of: $0), false) } ?? false

        guard isRevealed else {
            holdPutBackKey(false)
            holdPhotoKeys(over: nil)
            holdSelectionKeys(false)
            line.closeGaps()
            // Resting in the middle of the menu bar brings the line down on
            // that screen. Pushing against the top edge is part of it, and it
            // also works when another display sits above and the pointer
            // never stops.
            // An empty line stays up there: only the shortcut and the menu
            // bring it down on purpose.
            if line.liveCount > 0, Self.opensFromMenuBar, let screen = screenUnderPointer,
               inRevealBand, !menuBarSuppressed, !FullScreen.blocksLine(on: screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen()
                        updateCapacity()
                    }
                    refresh()
                    reveal()
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)
        updateZoom(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        // While searching, the keys belong to the search field: Space and
        // Delete type, and ⌘Z undoes typing.
        let searching = searchBar?.isShown == true
        let atUndoAnchor = isAtUndoAnchor(mouse)
        if inside && pinned && !searching { pinned = false }
        holdPutBackKey((inside || atUndoAnchor) && !searching && !GrabView.isShowingMenu && !Share.shared.isOpen)
        holdPhotoKeys(over: inside && !searching ? photo(under: mouse) : nil)
        holdSelectionKeys(inside && !searching && !GrabView.isShowingMenu && !Share.shared.isOpen)
        // Gaps left by discarded photos close once the pointer moves away.
        if !inside { line.closeGaps() }

        // A search keeps the line down until Escape or a click elsewhere.
        let busy = pinned || searching || atUndoAnchor || GrabView.isDragging || GrabView.isShowingMenu || Share.shared.isOpen
            || line.pressedID != nil || now < peekUntil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The card under the pointer opens larger below the line. Not while
    /// dragging, in a card's menu, or while one of our windows is in front,
    /// like Quick Look.
    private func updateZoom(_ mouse: NSPoint) {
        guard Zoom.isEnabled, !GrabView.isDragging, !GrabView.isShowingMenu, NSApp.keyWindow == nil,
              let screen = panel.screen else {
            zoom.hide()
            return
        }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let hit = line.hitRects.first { $0.value.contains(flipped) }
        let item = hit.flatMap { hit in line.items.first { $0.id == hit.key && !$0.falling && !$0.flying } }
        let card = hit.map {
            CGRect(x: panel.frame.minX + $0.value.minX, y: panel.frame.maxY - $0.value.maxY,
                   width: $0.value.width, height: $0.value.height)
        }
        zoom.update(item, card: card, on: screen)
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo. Everywhere else, clicks go to
    /// whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        var overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        // A line longer than the screen also takes the band the photos hang
        // in, gaps included, so a swipe anywhere along it moves it.
        if !overPhoto, line.items.count > line.visibleCount, Line.keepOnLine != nil {
            let band = line.hitRects.values.reduce(CGRect.null) { $0.union($1) }
            overPhoto = !band.isNull && flipped.y >= band.minY - 4 && flipped.y <= band.maxY + 4
        }
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    // MARK: Holding

    /// Takes a photo off the line to hold in front of you. The line goes
    /// up, so it is out of the way of the photo you are looking at.
    private func hold(_ id: UUID) {
        guard let item = line.items.first(where: { $0.id == id && !$0.falling && !$0.held }) else { return }
        line.setHeld(id, true)
        Held.show(id, url: item.url, line: line) { [weak self] id, frame in self?.hangBack(id, from: frame) }
    }

    /// Back onto its clip: the line comes down and the photo flies home.
    private func hangBack(_ id: UUID, from frame: CGRect) {
        line.setHeld(id, false)
        comeDown(on: NSScreen.screens.first { $0.frame.intersects(frame) })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: frame)
        }
    }

    // MARK: Hang on Tendedero

    /// The service macOS lists for images and text files in Finder and
    /// elsewhere. What you hang yourself is pinned, and the line comes down
    /// to show it. A text file is copied in as a note.
    @objc func hangOnLine(_ pasteboard: NSPasteboard, userData: String?,
                          error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        comeDown(on: nil)
        var any = false
        for url in urls {
            let hung = NoteFolder.isTextFile(url) ? NoteFolder.adopt(url) : url
            if let hung, line.hangKept(hung) { any = true }
        }
        if !any { NSSound.beep() }
    }

    // MARK: Keys over a photo

    /// Delete and Space while the pointer rests on a photo: Delete does what
    /// its corner button does, Space takes a quick look, as in Finder. Like
    /// ⌘Z, they are borrowed as hot keys only then, so every other app keeps
    /// them.
    private var photoKeys: [HotKey] = []
    private var photoKeysFor: UUID?

    private func holdPhotoKeys(over id: UUID?) {
        let id = id.flatMap { id in line.items.first { $0.id == id && !$0.falling && !$0.held }?.id }
        guard id != photoKeysFor else { return }
        photoKeysFor = id
        photoKeys = []
        guard let id else { return }
        photoKeys = [
            HotKey(Shortcut(keyCode: kVK_Delete, modifiers: [], key: "\u{8}")) { [weak self] in
                guard let line = self?.line else { return }
                let ids = line.selectedItems.map(\.id)
                if ids.isEmpty { line.pressCorner(id) } else { line.discard(ids) }
            },
            HotKey(Shortcut(keyCode: kVK_Space, modifiers: [], key: " ")) { [weak self] in
                self?.quickLookToggle(id)
            },
        ].compactMap { $0 }
    }

    /// Like Delete and undo, these belong to the line only while the
    /// pointer is over it. Selection never takes focus from another app.
    private var selectionKeys: [HotKey] = []
    private var selectionKeysHeld = false

    private func holdSelectionKeys(_ hold: Bool) {
        let hold = hold && !line.selectedIDs.isEmpty
        guard hold != selectionKeysHeld else { return }
        selectionKeysHeld = hold
        selectionKeys = []
        guard hold else { return }
        selectionKeys = [
            HotKey(Shortcut(keyCode: kVK_Escape, modifiers: [], key: "\u{1b}")) { [weak self] in
                self?.line.clearSelection()
            },
            HotKey(Shortcut(keyCode: kVK_ANSI_C, modifiers: [.command], key: "c")) { [weak self] in
                guard let line = self?.line else { return }
                line.copy(line.selectedItems.map(\.id))
            },
        ].compactMap { $0 }
    }

    /// The photo whose card is under the pointer, if any.
    private func photo(under mouse: NSPoint) -> UUID? {
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        return line.hitRects.first { $0.value.contains(flipped) }?.key
    }

    /// Space opens Quick Look, and closes it again if it is already open.
    private func quickLookToggle(_ id: UUID) {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            line.quickLook(id)
        }
    }

    // MARK: Putting back

    /// ⌘Z while the pointer is on the line or where its menu just closed.
    /// The line never takes the keyboard, so it only borrows ⌘Z then as a
    /// hot key. Everywhere else
    /// ⌘Z stays the undo of the app you are in.
    private var putBackKey: HotKey?
    private var putBackMonitor: Any?
    private var undoAnchor: (point: NSPoint, application: pid_t?)?

    /// Key events delivered to Tendedero itself also need a route to undo,
    /// such as after a menu activates it. The global hot key covers other
    /// apps; this consumes only a local key in the same narrow undo scope.
    private func watchPutBackKey() {
        putBackMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.putBackKey != nil,
                  !GrabView.isShowingMenu, !Share.shared.isOpen,
                  Int(event.keyCode) == Shortcut.putBack.keyCode,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return event }
            self.putBack()
            return nil
        }
    }

    private func keepUndoAtPointer() {
        guard isRevealed else { return }
        undoAnchor = (NSEvent.mouseLocation, NSWorkspace.shared.frontmostApplication?.processIdentifier)
        holdPutBackKey(true)
    }

    /// A context menu can end below the photo band. Keep that spot part of
    /// the undo interaction until the pointer moves, another app is chosen,
    /// or a new click starts something else. Other apps keep their own undo.
    private func isAtUndoAnchor(_ point: NSPoint) -> Bool {
        guard let anchor = undoAnchor else { return false }
        guard line.canPutBack,
              abs(point.x - anchor.point.x) <= 12, abs(point.y - anchor.point.y) <= 12,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == anchor.application else {
            releaseUndoAnchor()
            return false
        }
        return true
    }

    private func releaseUndoAnchor() {
        guard undoAnchor != nil else { return }
        undoAnchor = nil
        holdPutBackKey(false)
        itemsChanged()
    }

    /// Set when another app holds ⌘Z, so it is not asked for again on every
    /// tick, only the next time the pointer comes to the line.
    private var putBackKeyRefused = false

    private func holdPutBackKey(_ hold: Bool) {
        guard hold && line.canPutBack else {
            putBackKey = nil
            putBackKeyRefused = false
            return
        }
        guard putBackKey == nil, !putBackKeyRefused else { return }
        putBackKey = HotKey(Shortcut.putBack) { [weak self] in self?.putBack() }
        putBackKeyRefused = putBackKey == nil
    }

    /// From the menu the line is usually up, so it comes down for a moment
    /// to show the photos going back.
    private func putBack() {
        if !isRevealed {
            panel.placeOnScreen()
            updateCapacity()
            wanted = true
            refresh()
            reveal(peekFor: 2.5)
        }
        line.putBack()
    }

    // MARK: Shortcut

    private func registerShortcut() {
        hotKey = nil
        guard let shortcut = Shortcut.current else { return }
        hotKey = HotKey(shortcut) { [weak self] in self?.toggle() }
    }

    private func changeShortcut() {
        // Off while recording, so pressing the current one records it
        // instead of showing the line.
        hotKey = nil
        ShortcutRecorder.shared.record { [weak self] result in
            guard let self else { return }
            if let result {
                let previous = Shortcut.current
                Shortcut.current = result
                self.registerShortcut()
                // Taken by another app: keep the one that worked.
                if result != nil && self.hotKey == nil {
                    NSSound.beep()
                    Shortcut.current = previous
                }
            }
            self.registerShortcut()
        }
    }

    private func setKeep(_ n: Int?) {
        guard n != Line.keepOnLine else { return }
        Line.keepOnLine = n
        updateCapacity()
        line.trim()
    }

    private func setSize(_ size: Layout.Size) {
        guard size != Layout.size else { return }
        Layout.size = size
        panel.placeOnScreen(panel.screen)
        updateCapacity()
        line.reloadThumbnails()
    }

    private func updateCapacity() {
        let usable = panel.frame.width - 200
        let fits = max(3, min(12, Int(usable / Layout.spacing)))
        line.visibleCount = fits
        line.maxItems = max(fits, Line.keepOnLine ?? fits)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        let menu = NSMenu()
        // Items say themselves whether they can be used, like Take everything
        // down on an empty line.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The shirt fills in while copied images are hung, so it shows at a
    /// glance that the clipboard is being watched. It is dimmed while the
    /// line is empty, so resting in the menu bar and seeing nothing come down
    /// does not look broken.
    private func updateStatusIcon() {
        let on = ClipboardWatcher.isEnabled
        let count = line.liveCount
        let description = on ? L("Tendedero, hanging copied images") : "Tendedero"
        let state = count == 0 ? L("The line is empty") : String(format: L("%d on the line"), count)
        let image = NSImage(systemSymbolName: on ? "tshirt.fill" : "tshirt",
                            accessibilityDescription: "\(description), \(state)")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = count == 0
        statusItem.button?.toolTip = "\(description)\n\(state)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line") : L("Show line")) { [weak self] in
            self?.toggle()
        }
        if let shortcut = Shortcut.current, shortcut.key.count == 1 {
            toggleItem.keyEquivalent = shortcut.key
            toggleItem.keyEquivalentModifierMask = shortcut.modifiers
        }
        menu.addItem(toggleItem)

        let searchItem = ClosureMenuItem(L("Search the line")) { [weak self] in self?.startSearch() }
        searchItem.keyEquivalent = Self.searchShortcut.key
        searchItem.keyEquivalentModifierMask = Self.searchShortcut.modifiers
        searchItem.isEnabled = line.liveCount > 0
        menu.addItem(searchItem)

        let putBackItem = ClosureMenuItem(L("Put back"), key: "z") { [weak self] in
            self?.putBack()
        }
        putBackItem.isEnabled = line.canPutBack
        menu.addItem(putBackItem)

        let clearItem = ClosureMenuItem(L("Take everything down")) { [weak self] in
            self?.line.clear()
        }
        clearItem.isEnabled = line.liveCount > 0
        menu.addItem(clearItem)

        if !Held.heldIDs.isEmpty {
            menu.addItem(ClosureMenuItem(L("Hang everything back")) { Held.hangEverythingBack() })
        }

        // Where screenshots and other images come from, together.
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: L("Screenshots")))
        let inbox = ClosureMenuItem(L("Handle screenshots")) { [weak self] in
            self?.setInbox(!Inbox.isEnabled)
        }
        inbox.state = Inbox.isEnabled ? .on : .off
        inbox.toolTip = L("Screenshots hang instantly and skip the Desktop")
        menu.addItem(inbox)

        let folderItem = NSMenuItem(title: L("Also watch folders"), action: nil, keyEquivalent: "")
        let folderMenu = NSMenu()
        folderMenu.autoenablesItems = false
        let folders = Self.extraFolders
        // Each folder is ticked: a click stops watching it, as with any
        // ticked item. Holding Option turns it into Show in Finder.
        for folder in folders {
            let name = FileManager.default.displayName(atPath: folder.path)
            let item = ClosureMenuItem(name) { [weak self] in
                AppDelegate.extraFolders.removeAll { $0.standardizedFileURL == folder.standardizedFileURL }
                self?.startWatcher()
            }
            item.state = .on
            folderMenu.addItem(item)
            let reveal = ClosureMenuItem(String(format: L("Show “%@” in Finder"), name)) {
                NSWorkspace.shared.open(folder)
            }
            reveal.isAlternate = true
            reveal.keyEquivalentModifierMask = .option
            folderMenu.addItem(reveal)
        }
        if !folders.isEmpty { folderMenu.addItem(.separator()) }
        let add = ClosureMenuItem(L("Add Folder…")) { [weak self] in self?.chooseExtraFolder() }
        add.isEnabled = folders.count < Self.maxExtraFolders
        folderMenu.addItem(add)
        folderItem.submenu = folderMenu
        menu.addItem(folderItem)

        menu.addItem(ClosureMenuItem(L("Open screenshots folder")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher.folder)
        })

        // What you copy, in a section of its own: each kind is its own choice.
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: L("Hang what you copy")))
        let kinds: [(String, String, ReferenceWritableKeyPath<ClipboardWatcher.Type, Bool>)] = [
            (L("Images"), L("Images you copy hang on the line too"), \.imagesEnabled),
            (L("Text"), L("Text you copy hangs on the line too"), \.textEnabled),
            (L("Links"), L("Links you copy hang on the line too"), \.linksEnabled),
        ]
        for (title, tip, key) in kinds {
            let item = ClosureMenuItem(title) { [weak self] in
                ClipboardWatcher.self[keyPath: key].toggle()
                self?.refreshClipboardWatcher()
            }
            item.state = ClipboardWatcher.self[keyPath: key] ? .on : .off
            item.toolTip = tip
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let bringDown = NSMenuItem(title: L("Bring the line down"), action: nil, keyEquivalent: "")
        let options = NSMenu()
        let hover = ClosureMenuItem(L("When the pointer rests in the menu bar")) {
            AppDelegate.opensFromMenuBar.toggle()
        }
        hover.state = Self.opensFromMenuBar ? .on : .off
        options.addItem(hover)
        let peek = ClosureMenuItem(L("When something new hangs")) {
            AppDelegate.peeksAtNew.toggle()
        }
        peek.state = Self.peeksAtNew ? .on : .off
        options.addItem(peek)
        let fullScreen = ClosureMenuItem(L("Over full screen apps")) { [weak self] in
            FullScreen.showLineOver.toggle()
            self?.refresh()
        }
        fullScreen.state = FullScreen.showLineOver ? .on : .off
        options.addItem(fullScreen)
        bringDown.submenu = options
        menu.addItem(bringDown)

        let keepItem = NSMenuItem(title: L("Keep on line"), action: nil, keyEquivalent: "")
        let keeps = NSMenu()
        let fit = ClosureMenuItem(L("As many as fit")) { [weak self] in self?.setKeep(nil) }
        fit.state = Line.keepOnLine == nil ? .on : .off
        keeps.addItem(fit)
        for n in Line.keepChoices {
            let item = ClosureMenuItem(String(format: L("%d photos"), n)) { [weak self] in self?.setKeep(n) }
            item.state = Line.keepOnLine == n ? .on : .off
            keeps.addItem(item)
        }
        keepItem.submenu = keeps
        menu.addItem(keepItem)

        let sizeItem = NSMenuItem(title: L("Size"), action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for (size, title) in [(Layout.Size.small, L("Small")), (.medium, L("Medium")), (.large, L("Large"))] {
            let item = ClosureMenuItem(title) { [weak self] in self?.setSize(size) }
            item.state = Layout.size == size ? .on : .off
            sizes.addItem(item)
        }
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        let zoomItem = ClosureMenuItem(L("Zoom on hover")) { [weak self] in
            Zoom.isEnabled.toggle()
            if !Zoom.isEnabled { self?.zoom.hide() }
        }
        zoomItem.state = Zoom.isEnabled ? .on : .off
        menu.addItem(zoomItem)

        let shortcutItem = NSMenuItem(title: L("Shortcut"), action: nil, keyEquivalent: "")
        let shortcuts = NSMenu()
        let current = NSMenuItem(title: Shortcut.current?.display ?? L("None"), action: nil, keyEquivalent: "")
        current.isEnabled = false
        shortcuts.addItem(current)
        shortcuts.addItem(ClosureMenuItem(L("Change Shortcut…")) { [weak self] in self?.changeShortcut() })
        shortcutItem.submenu = shortcuts
        menu.addItem(shortcutItem)

        menu.addItem(.separator())

        let sound = ClosureMenuItem(L("Sounds")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        let login = ClosureMenuItem(L("Open at login")) {
            AppDelegate.toggleLaunchAtLogin()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        // The app never connects to anything, so it cannot tell when a new
        // version is out. The website can: it is opened with this version
        // and language, and says whether there is a newer one.
        menu.addItem(ClosureMenuItem(L("Check for Updates…")) {
            NSWorkspace.shared.open(AppDelegate.updatesURL)
        })

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit Tendedero"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    /// tendedero.app with the running version, and the menus' language when
    /// the website has it too, so the page answers in the same words.
    private static var updatesURL: URL {
        var components = URLComponents(string: "https://tendedero.app/")!
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var query = [URLQueryItem(name: "update", value: version)]
        if let language = Bundle.main.preferredLocalizations.first, ["en", "es", "gl", "fr", "pt-BR", "ja", "ko", "zh-Hans"].contains(language) {
            query.append(URLQueryItem(name: "lang", value: language))
        }
        components.queryItems = query
        return components.url!
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting")
            alert.informativeText = L("Move Tendedero to the Applications folder and try again.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: Quick Look

    /// With no window of ours in front, Quick Look finds its controller here.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.take(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.release(panel)
    }

}

