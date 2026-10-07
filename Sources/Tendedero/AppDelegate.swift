import AppKit
import Carbon
import Combine
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
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
    private var searchHotKey: HotKey?
    private let index = ScreenshotIndex(
        store: Inbox.folder.deletingLastPathComponent().appendingPathComponent("SearchIndex.plist"),
        loadClip: { Clip.bundled() })
    private var search: SearchController!
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
    /// Whether the line should be up.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    private var lastLiveCount = 0
    /// The screen a new capture was taken on: the line goes there.
    private var pendingScreen: NSScreen?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.placeOnScreen()
        updateCapacity()

        if Inbox.isEnabled { Inbox.apply() }
        restoreSettingsOnTermination()
        startWatcher()

        hotKey = HotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in
            self?.toggle()
        }

        search = SearchController(index: index, line: line) { [weak self] in self?.searchFolders() ?? [] }
        line.onSearch = { [weak self] in self?.search.show() }
        searchHotKey = HotKey(keyCode: kVK_ANSI_F, modifiers: controlKey | optionKey) { [weak self] in
            self?.search.toggle()
        }
        // Catch up on screenshots taken while Tendedero was not running,
        // once launch has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.search.model.refreshIndex() }

        setUpStatusItem()
        watchMenuBarClicks()

        Markup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        line.onFall = { [weak self] item in self?.fall(item) }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerInbox() }
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
    }

    // MARK: Search

    /// Every folder screenshots may be in: Tendedero's own, the Desktop, the
    /// current save location and the one used before Tendedero took over.
    /// Outside its own folder only real screenshots are indexed.
    private func searchFolders() -> [(url: URL, onlyScreenshots: Bool)] {
        var folders: [(url: URL, onlyScreenshots: Bool)] = [(Inbox.folder, false), (ScreenshotWatcher.desktop, true)]
        if let watcher { folders.append((watcher.folder, true)) }
        if let previous = Inbox.previousFolder { folders.append((previous, true)) }
        return folders
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
        alert.messageText = L("Let Tendedero handle your screenshots?",
                              "¿Quieres que Tendedero se encargue de tus capturas?")
        alert.informativeText = L(
            "Screenshots will hang on the line the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. Drag one to a folder to keep it, or discard it with the cross. You can turn this off from the menu bar, and your settings come back when Tendedero quits.",
            "Las capturas se colgarán al instante, sin la miniatura flotante, y no se acumularán en el Escritorio. Arrastra una a una carpeta para guardarla, o descártala con la cruz. Puedes desactivarlo desde la barra de menús, y tus ajustes vuelven a ser los de antes al salir de Tendedero.")
        alert.addButton(withTitle: L("Turn on", "Activar"))
        alert.addButton(withTitle: L("Not now", "Ahora no"))
        if let icon = NSImage(named: "Tendedero") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
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

    private func itemsChanged() {
        let live = line.liveCount
        if live > lastLiveCount {
            panel.placeOnScreen(pendingScreen)
            pendingScreen = nil
            updateCapacity()
            wanted = true
            refresh()
            reveal(peekFor: 2.5)
        } else if live == 0 && !keepOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
                self.wanted = false
                self.refresh()
            }
        }
        lastLiveCount = live
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    private func hangCapture(_ url: URL) {
        index.add(url)
        let from = captureRect(of: url)
        if let from {
            let center = CGPoint(x: from.midX, y: from.midY)
            pendingScreen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
        }
        guard let id = line.hang(url, flying: from != nil), let from else { return }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: from)
        }
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(3000, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), on: screen)
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let index = line.items.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = Layout.x(index: index, count: line.items.count, width: width)
        let viewTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove
        let cardTop = viewTop + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize(for: line.items[index].thumb.size)
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Decides whether the panel is ordered in at all: something to show.
    private func refresh() {
        if wanted {
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
        panel.orderFrontRegardless()
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
        if !on {
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
        }
    }

    @objc private func toggle() {
        if isRevealed {
            setRevealed(false)
            if line.liveCount == 0 {
                keepOpen = false
                wanted = false
                refresh()
            }
        } else {
            keepOpen = true
            wanted = true
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

    /// Like NSMouseInRect, but the top edge is inside.
    static func contains(_ rect: NSRect, _ p: NSPoint) -> Bool {
        p.x >= rect.minX && p.x < rect.maxX && p.y >= rect.minY && p.y <= rect.maxY
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { Self.contains(Self.menuBarBand(of: $0), p) }) else { return }
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

        // Pushed against the top edge, the pointer sits exactly on the screen's
        // maxY, which a plain rect test leaves out, so the top row counts too.
        let screenUnderPointer = NSScreen.screens.first { Self.contains($0.frame, mouse) }
        let inMenuBar = screenUnderPointer.map { Self.contains(Self.menuBarBand(of: $0), mouse) } ?? false
        if !inMenuBar { menuBarSuppressed = false }

        guard isRevealed else {
            // Resting in the menu bar brings the line down on that screen.
            // Pushing against the top edge is part of it, and it also works
            // when another display sits above and the pointer never stops.
            if let screen = screenUnderPointer, inMenuBar, !menuBarSuppressed {
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

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && pinned { pinned = false }

        let busy = pinned || GrabView.isDragging || line.pressedID != nil || now < peekUntil
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

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo. Everywhere else, clicks go to
    /// whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    private func updateCapacity() {
        // Room at the start of the line for the search tag.
        let usable = panel.frame.width - 2 * (SearchTag.x + 60)
        line.maxItems = max(3, min(12, Int(usable / Layout.spacing)))
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "tshirt", accessibilityDescription: "Tendedero")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line", "Ocultar tendedero")
                                                 : L("Show line", "Mostrar tendedero")) { [weak self] in
            self?.toggle()
        }
        toggleItem.keyEquivalent = "t"
        toggleItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(toggleItem)

        let searchItem = ClosureMenuItem(L("Search screenshots…", "Buscar capturas…")) { [weak self] in
            self?.search.show()
        }
        searchItem.keyEquivalent = "f"
        searchItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(searchItem)

        let clearItem = ClosureMenuItem(L("Take everything down", "Descolgar todo")) { [weak self] in
            self?.line.clear()
        }
        clearItem.isEnabled = line.liveCount > 0
        menu.addItem(clearItem)

        let inbox = ClosureMenuItem(L("Handle screenshots", "Encargarse de las capturas")) { [weak self] in
            self?.setInbox(!Inbox.isEnabled)
        }
        inbox.state = Inbox.isEnabled ? .on : .off
        inbox.toolTip = L("Screenshots hang instantly and skip the Desktop",
                          "Las capturas se cuelgan al instante y no pasan por el Escritorio")
        menu.addItem(inbox)

        menu.addItem(ClosureMenuItem(L("Open screenshots folder", "Abrir carpeta de capturas")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher.folder)
        })

        menu.addItem(.separator())

        let sound = ClosureMenuItem(L("Sounds", "Sonidos")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        let login = ClosureMenuItem(L("Open at login", "Abrir al iniciar sesión")) {
            AppDelegate.toggleLaunchAtLogin()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit Tendedero", "Salir de Tendedero"), key: "q") {
            NSApp.terminate(nil)
        })
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
            alert.messageText = L("Could not change the login setting", "No se pudo cambiar el inicio de sesión")
            alert.informativeText = L("Move Tendedero to the Applications folder and try again.",
                                      "Mueve Tendedero a la carpeta Aplicaciones y vuelve a intentarlo.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
