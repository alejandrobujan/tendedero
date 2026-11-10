import AppKit
import AVFoundation
import Combine
import os

let log = Logger(subsystem: "app.tendedero.Tendedero", category: "line")

/// One screenshot hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var thumb: NSImage
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false
    /// Pinned, left of the knot: it stays until you take it down.
    var kept = false
    /// Taken off the line to hold in front of you. Its clip waits empty
    /// until it comes back.
    var held = false
    /// Hung from another app with Hang on Tendedero, rather than pinned
    /// from the photos that came and went. Always pinned.
    var byHand = false
    /// A screen recording rather than a screenshot.
    var isRecording: Bool { Tendedero.isRecording(url) }

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.kept == b.kept && a.byHand == b.byHand && a.held == b.held && a.thumb === b.thumb
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// The files never move. The line is only a view onto them.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published private(set) var copiedIDs: Set<UUID> = []
    @Published private(set) var selectedIDs: Set<UUID> = []
    private var copyGeneration = 0
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// Whether the line has slid down into view.
    @Published var revealed = false {
        didSet {
            guard revealed != oldValue else { return }
            gustWork?.cancel()
            gustWork = nil
            if revealed { scheduleGust() }
        }
    }

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]

    var maxItems = 8
    /// How many photos fit across the screen. With Keep on line set, the
    /// line can hold more, and the rest are reached by scrolling.
    var visibleCount = 8
    /// How far the line is scrolled towards older photos, in points; 0 shows
    /// the newest.
    @Published var scroll: CGFloat = 0

    /// Keep on line, from the menu bar: how many photos the line keeps, or
    /// nil for as many as fit across the screen.
    nonisolated static let keepChoices = [25, 50, 100]
    nonisolated static var keepOnLine: Int? {
        get {
            let n = UserDefaults.standard.integer(forKey: "keepOnLine")
            return keepChoices.contains(n) ? n : nil
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: "keepOnLine") }
    }


    var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    /// Photos hung by hand. They hang together at the left end of the line,
    /// before the knot, and never fall to make room.
    var keptCount: Int { items.filter { !$0.falling && $0.kept }.count }

    /// How many photos at the start of the line are pinned, the empty
    /// places of pinned ones that just came down included.
    var pinnedLead: Int { items.prefix { $0.kept }.count }

    /// The oldest photo that can fall: the first one past the knot.
    private var oldestLoose: Pegged? { items.first { !$0.falling && !$0.kept && !$0.held } }

    private let storeKey = "pegged"
    private let pasteboard: NSPasteboard
    private let desktop: URL

    init(pasteboard: NSPasteboard = .general,
         desktop: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")) {
        self.pasteboard = pasteboard
        self.desktop = desktop
        restore()
    }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ url: URL, quietly: Bool = false, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return nil }
        var item = Pegged(url: url, thumb: thumb)
        item.flying = flying
        // The line moves anyway for a new photo, so the gaps close with it.
        sweepFallen()
        items.append(item)
        scroll = 0
        // A full line lets the oldest photo fall off the far end. Only one: a
        // line hung on a wider screen keeps its length here instead of losing
        // several photos to a single capture.
        if liveCount > maxItems, let oldest = oldestLoose {
            letGo(oldest.id)
        }
        save()
        if !quietly { play("Tink", volume: 0.35) }
        return item.id
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((Pegged) -> Void)?

    /// Hold, from a photo's menu: the app takes it off the line.
    var onHold: ((UUID) -> Void)?
    /// A click on a held photo's faded trace: it comes back.
    var onHangBack: ((UUID) -> Void)?

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        selectedIDs.remove(id)
        onFall?(items[i])
        items[i].falling = true
        hitRects[id] = nil
        save()
        if !quietly { play("Pop", volume: 0.25) }
        lastFall = Date()
    }

    /// When the last photo started falling. A fallen photo keeps its empty
    /// place while the pointer stays on the line, so the next cross stays
    /// under it while discarding several in a row.
    private var lastFall = Date.distantPast

    /// The pointer left the line: the gaps close, once the last photo has
    /// finished falling.
    func closeGaps() {
        guard items.contains(where: { $0.falling }),
              Date().timeIntervalSince(lastFall) >= 0.6 else { return }
        sweepFallen()
    }

    /// The fallen photos leave their places and the rest close up.
    private func sweepFallen() {
        items.removeAll { $0.falling }
    }

    /// "Take everything down": every photo past the knot goes the way of its
    /// corner cross. What you hung by hand stays.
    func clear() {
        takeDown(items.filter { !$0.falling && !$0.kept && !$0.held })
    }

    /// The photos hung before (left) or after (right) this one.
    func neighbours(of id: UUID, toTheLeft: Bool) -> [Pegged] {
        let live = items.filter { !$0.falling }
        guard let i = live.firstIndex(where: { $0.id == id }) else { return [] }
        return (toTheLeft ? Array(live[..<i]) : Array(live[(i + 1)...])).filter { !$0.kept && !$0.held }
    }

    /// Takes down everything on one side of a photo. Each one goes the way
    /// of its own corner button: to the Trash from Tendedero's folder, and
    /// only off the line from anywhere else.
    func takeDown(_ id: UUID, toTheLeft: Bool) {
        takeDown(neighbours(of: id, toTheLeft: toTheLeft))
    }

    /// One after another, and only the first makes a sound. They are one
    /// step, so Put back brings them all back at once.
    private func takeDown(_ live: [Pegged]) {
        let step = UUID()
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.discard(item.id, quietly: n > 0, step: step)
            }
        }
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune() {
        for item in items where !item.falling && !FileManager.default.fileExists(atPath: item.url.path) {
            drop(item.id, quietly: true)
        }
    }

    // MARK: Selecting photos

    /// A selection follows the line's order, not the order of the clicks.
    var selectedItems: [Pegged] { actionItems(Array(selectedIDs)) }

    private func actionItems(_ ids: [UUID]) -> [Pegged] {
        let ids = Set(ids)
        return items.filter { ids.contains($0.id) && !$0.falling && !$0.held }
    }

    func toggleSelection(_ id: UUID) {
        guard !actionItems([id]).isEmpty else { return }
        if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
    }

    func clearSelection() { selectedIDs.removeAll() }

    // MARK: Actions on photos

    func copy(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id && !$0.falling }) else { return }
        copyPhotos([item])
    }

    func copy(_ ids: [UUID]) {
        copyPhotos(actionItems(ids))
    }

    private func copyPhotos(_ photos: [Pegged]) {
        guard !photos.isEmpty else { return }
        putOnClipboard(photos.map(\.url))

        copiedIDs = Set(photos.map(\.id))
        copyGeneration += 1
        let generation = copyGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copyGeneration == generation { self?.copiedIDs = [] }
        }
    }

    /// The files last put on the clipboard, and the clipboard's change count
    /// right after. While the count is the same, nothing else has been copied.
    private var onClipboard: (urls: [URL], change: Int)?

    private func putOnClipboard(_ urls: [URL]) {
        let entries = urls.map { url in
            let entry = NSPasteboardItem()
            // Each photo has its own image and file representation. Apps
            // that accept several files can paste the whole selection.
            if !isRecording(url), let png = pngData(url) { entry.setData(png, forType: .png) }
            entry.setString(url.absoluteString, forType: .fileURL)
            return entry
        }
        let pb = pasteboard
        pb.clearContents()
        pb.writeObjects(entries)
        onClipboard = (urls, pb.changeCount)
    }

    /// Apps like Finder or a chat window paste the copied file rather than the
    /// picture. When the file moves after a copy, to the Trash or the Desktop,
    /// the clipboard follows it, or those apps would find nothing to paste.
    private func clipboardFollows(_ url: URL, to moved: URL) {
        guard let onClipboard, onClipboard.urls.contains(url),
              onClipboard.change == pasteboard.changeCount else { return }
        putOnClipboard(onClipboard.urls.map { $0 == url ? moved : $0 })
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(item.url)
    }

    func open(_ ids: [UUID]) {
        for item in actionItems(ids) { NSWorkspace.shared.open(item.url) }
    }

    /// Pinned screenshots must be unpinned first, just as in their own menu.
    func canDiscard(_ ids: [UUID]) -> Bool {
        let photos = actionItems(ids)
        return !photos.isEmpty && photos.allSatisfy { !$0.kept || $0.byHand }
    }

    func discard(_ ids: [UUID]) {
        guard canDiscard(ids) else { NSSound.beep(); return }
        let photos = actionItems(ids)
        let step = UUID()
        // Finish the whole action before an undo can run. New arrivals are
        // not part of this snapshot, and failed removals stay selected.
        for (n, item) in photos.enumerated() {
            discard(item.id, quietly: n > 0, step: step)
        }
    }

    func pin(_ ids: [UUID]) {
        let step = UUID()
        for (n, item) in actionItems(ids).filter({ !$0.kept }).enumerated() {
            pin(item.id, quietly: n > 0, step: step)
        }
    }

    func unpin(_ ids: [UUID]) {
        let step = UUID()
        // Each photo joins the front of the loose ones, so work backwards.
        for item in actionItems(ids).reversed() { unpin(item.id, step: step) }
    }

    func canSaveToDesktop(_ ids: [UUID]) -> Bool {
        actionItems(ids).contains { canSaveToDesktop($0.id) }
    }

    func canSaveToDesktop(_ id: UUID) -> Bool {
        isInInbox(id) || isOnDesktop(id)
    }

    func saveToDesktop(_ ids: [UUID]) {
        // Inbox files move; files already on the Desktop get another copy.
        let photos = actionItems(ids).filter { canSaveToDesktop($0.id) }
        guard !photos.isEmpty else { return }
        let step = UUID()
        for item in photos { saveToDesktop(item.id, step: step) }
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    ///
    /// `step` is what Put back brings it back with. Nil when the line lets
    /// a photo go by itself, which is not undone.
    @discardableResult
    func trash(_ id: UUID, quietly: Bool = false, step: UUID? = UUID()) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        let index = liveIndex(of: id)
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashed)
            if let trashed { clipboardFollows(item.url, to: trashed as URL) }
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .public)")
            if soundOn && !quietly { Line.trashSound?.play() }
            drop(id, quietly: true)
            if let step, let index {
                remember(TakenDown(url: item.url, index: index, trashed: trashed as URL?, kept: item.kept, byHand: item.byHand), in: step)
            }
            return true
        } catch {
            log.error("Could not trash \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if !quietly { NSSound.beep() }
            return false
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in Tendedero's own folder. Those are discarded
    /// to the Trash, or the folder would fill up with forgotten screenshots.
    /// Files anywhere else, like the Desktop, stay where they are.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return item.url.standardizedFileURL.path.hasPrefix(Inbox.folder.standardizedFileURL.path + "/")
    }

    func isOnDesktop(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return item.url.deletingLastPathComponent().standardizedFileURL == desktop.standardizedFileURL
    }

    /// What the button in a photo's corner does.
    enum Corner {
        /// A file in Tendedero's folder: to the Trash.
        case trash
        /// A file anywhere else, or hung by hand: off the line, file untouched.
        case hide
        /// Pinned from the photos that come and go: back among them.
        case unpin
    }

    func corner(of id: UUID) -> Corner {
        guard let item = items.first(where: { $0.id == id }) else { return .hide }
        if item.kept { return item.byHand ? .hide : .unpin }
        return isInInbox(id) ? .trash : .hide
    }

    /// The button in the corner.
    func pressCorner(_ id: UUID) {
        if corner(of: id) == .unpin { unpin(id) } else { discard(id) }
    }

    /// The corner cross and "Take down" both end up here. A pinned photo is
    /// never sent to the Trash: it only leaves the line.
    func discard(_ id: UUID, quietly: Bool = false, step: UUID = UUID()) {
        if isInInbox(id), items.first(where: { $0.id == id })?.kept == false {
            trash(id, quietly: quietly, step: step)
        } else if let item = items.first(where: { $0.id == id && !$0.falling }), let index = liveIndex(of: id) {
            drop(id, quietly: quietly)
            remember(TakenDown(url: item.url, index: index, trashed: nil, kept: item.kept, byHand: item.byHand), in: step)
        }
    }

    /// Moves along a line that holds more than fit, from a scroll gesture.
    func scroll(by delta: CGFloat) {
        let most = CGFloat(max(0, items.count - visibleCount)) * Layout.spacing
        let next = min(most, max(0, scroll + delta))
        if next != scroll { scroll = next }
    }

    /// After Keep on line is lowered, the oldest photos past it go the way
    /// of a full line.
    func trim() {
        while liveCount > maxItems, let oldest = oldestLoose {
            letGo(oldest.id)
        }
        scroll = 0
    }

    /// The oldest photo falling off a full line. Like the cross, a file from
    /// Tendedero's folder goes to the Trash, or nothing would ever take it out
    /// of that folder. If the Trash refuses it, it still leaves the line.
    private func letGo(_ id: UUID) {
        if isInInbox(id), trash(id, quietly: true, step: nil) { return }
        drop(id, quietly: true)
    }

    /// An exported screenshot keeps its macOS tag. Desktop watchers must
    /// not mistake that saved file for a new capture, even after its undo expires.
    /// Identify the file too, so a later namesake is still picked up.
    private struct DesktopSave: Equatable {
        let volume: UInt64
        let file: UInt64
        let created: Date?

        init?(_ url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let volume = attributes[.systemNumber] as? NSNumber,
                  let file = attributes[.systemFileNumber] as? NSNumber else { return nil }
            self.volume = volume.uint64Value
            self.file = file.uint64Value
            created = attributes[.creationDate] as? Date
        }
    }

    private var desktopSaves: [URL: DesktopSave] = [:]

    func isDesktopSave(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        guard let saved = desktopSaves[url] else { return false }
        guard DesktopSave(url) == saved else {
            desktopSaves[url] = nil
            return false
        }
        return true
    }

    /// Move an inbox screenshot to the Desktop, or save another copy of a
    /// file already there. Every destination gets a name that is still free.
    func saveToDesktop(_ id: UUID, step: UUID = UUID()) {
        guard canSaveToDesktop(id),
              let item = items.first(where: { $0.id == id && !$0.falling }),
              let index = liveIndex(of: id) else { return }
        let copying = !isInInbox(id)
        let target = uniqueURL(in: desktop, for: item.url.lastPathComponent)
        do {
            if copying {
                try FileManager.default.copyItem(at: item.url, to: target)
            } else {
                try FileManager.default.moveItem(at: item.url, to: target)
                clipboardFollows(item.url, to: target)
            }
            let identity = DesktopSave(target)
            desktopSaves[target.standardizedFileURL] = identity
            drop(id, quietly: true)
            remember(TakenDown(url: item.url, index: index, trashed: nil,
                               kept: item.kept, byHand: item.byHand,
                               moved: copying ? nil : target, copied: copying ? target : nil,
                               copyIdentity: copying ? identity : nil), in: step)
        } catch {
            log.error("Could not save to Desktop: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Long press: open the photo in the system Markup editor. Markup does
    /// not edit video, so a recording opens in the trimming editor instead.
    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.isRecording {
            Trim.shared.edit(item.url, size: item.thumb.size)
        } else {
            Markup.shared.edit(item.url)
        }
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return }
        items[i].thumb = thumb
    }

    /// Quick Look on this photo, with the rest of the line a key press away.
    func quickLook(_ id: UUID) {
        let live = items.filter { !$0.falling }
        guard let index = live.firstIndex(where: { $0.id == id }) else { return }
        QuickLook.shared.show(live.map(\.url), at: index)
    }

    /// After a change of size, every photo is redrawn sharp at the new one.
    func reloadThumbnails() {
        for i in items.indices where !items[i].falling {
            if let thumb = makeThumbnail(items[i].url) { items[i].thumb = thumb }
        }
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func reveal(_ ids: [UUID]) {
        let urls = actionItems(ids).map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: Putting back

    /// A photo before an undoable action: its file, position, pin state,
    /// and where the file went if it was moved.
    private struct TakenDown {
        var url: URL
        let index: Int
        let trashed: URL?
        var kept = false
        var byHand = false
        var moved: URL?
        var copied: URL?
        var copyIdentity: DesktopSave?
        var pinChange = false
    }

    /// What was taken down, the latest last. A step holds everything one
    /// action took down. Only kept while the app runs.
    private var steps: [(id: UUID, photos: [TakenDown])] = []
    private static let maxSteps = 20

    var canPutBack: Bool { !steps.isEmpty }
    /// Keeps undo reachable where a menu action just finished, even below
    /// the photo band or after the last photo has been taken down.
    var onUndoableAction: (() -> Void)?

    private func remember(_ photo: TakenDown, in step: UUID) {
        if let i = steps.lastIndex(where: { $0.id == step }) {
            steps[i].photos.append(photo)
        } else {
            steps.append((step, [photo]))
            if steps.count > Self.maxSteps { steps.removeFirst() }
            onUndoableAction?()
        }
    }

    /// Put back, or ⌘Z: restore the previous positions and pin states, and
    /// bring files back from the Trash or Desktop if they were moved.
    func putBack() {
        guard let step = steps.popLast() else { return }
        var back: Set<UUID> = []
        // The last one taken down goes back first, so each finds its place.
        for photo in step.photos.reversed() {
            if photo.pinChange {
                guard let index = items.firstIndex(where: { $0.url == photo.url && !$0.falling }) else { continue }
                var item = items.remove(at: index)
                item.kept = photo.kept
                insert(item, atLiveIndex: photo.index)
                back.insert(item.id)
                continue
            }
            guard let url = restore(photo) else { continue }
            // A saved file may have been hung manually meanwhile. Remove
            // its card only if undo actually moved that file away.
            if let saved = photo.moved ?? photo.copied, !FileManager.default.fileExists(atPath: saved.path) {
                for item in items where item.url.standardizedFileURL == saved.standardizedFileURL && !item.falling {
                    drop(item.id, quietly: true)
                }
            }
            if let existing = items.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL && !$0.falling }) {
                back.insert(existing.id)
                continue
            }
            guard let thumb = makeThumbnail(url) else { continue }
            var item = Pegged(url: url, thumb: thumb)
            item.kept = photo.kept
            item.byHand = photo.byHand
            if let gap = items.firstIndex(where: { $0.falling && $0.url == photo.url }) {
                // Its empty place is still on the line: it hangs back there.
                items[gap] = item
            } else {
                insert(item, atLiveIndex: photo.index)
            }
            back.insert(item.id)
        }
        guard !back.isEmpty else {
            NSSound.beep()
            return
        }
        // As when something new hangs, a full line lets its oldest photo go,
        // never one that just came back or one you are holding.
        while liveCount > maxItems, let oldest = items.first(where: { !$0.falling && !$0.kept && !$0.held && !back.contains($0.id) }) {
            letGo(oldest.id)
        }
        keepKeptFirst()
        save()
        play("Tink", volume: 0.35)
    }

    private func insert(_ item: Pegged, atLiveIndex index: Int) {
        let live = items.filter { !$0.falling }
        if index < live.count, let i = items.firstIndex(where: { $0.id == live[index].id }) {
            items.insert(item, at: i)
        } else {
            items.append(item)
        }
    }

    /// The photo's file, where it was before. Nil when it is gone: the Trash
    /// was emptied, or the file was moved or deleted since.
    private func restore(_ photo: TakenDown) -> URL? {
        if let copied = photo.copied {
            // The original never moved. Undo removes only the copy we
            // created, not a different file later using that destination.
            if let identity = photo.copyIdentity, DesktopSave(copied) == identity {
                do {
                    var trashed: NSURL?
                    try FileManager.default.trashItem(at: copied, resultingItemURL: &trashed)
                    if let trashed { clipboardFollows(copied, to: trashed as URL) }
                    desktopSaves[copied.standardizedFileURL] = nil
                } catch {
                    log.error("Could not undo Desktop copy: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            return FileManager.default.fileExists(atPath: photo.url.path) ? photo.url : nil
        }
        guard let moved = photo.moved ?? photo.trashed else {
            return FileManager.default.fileExists(atPath: photo.url.path) ? photo.url : nil
        }
        let url = uniqueURL(in: photo.url.deletingLastPathComponent(), for: photo.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: moved, to: url)
            desktopSaves[moved.standardizedFileURL] = nil
            clipboardFollows(moved, to: url)
            // A newer namesake may force a different filename. Earlier
            // actions, such as pinning this photo, must follow that name.
            if url != photo.url {
                for step in steps.indices {
                    for i in steps[step].photos.indices where steps[step].photos[i].url == photo.url {
                        steps[step].photos[i].url = url
                    }
                }
            }
            log.notice("Put back \(url.lastPathComponent, privacy: .public)")
            return url
        } catch {
            log.error("Could not put back \(moved.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Where a photo hangs, counting only the photos still on the line.
    private func liveIndex(of id: UUID) -> Int? {
        items.filter { !$0.falling }.firstIndex { $0.id == id }
    }

    // MARK: Hanging by hand

    /// Kept photos hang left of the knot, the rest after it, each side in
    /// its own order.
    private func keepKeptFirst() {
        let kept = items.filter { $0.kept && !$0.falling }
        if items.prefix(kept.count).map(\.id) != kept.map(\.id) {
            items = kept + items.filter { !($0.kept && !$0.falling) }
        }
    }

    /// Pin: the photo joins the kept ones at the left end of the line.
    func pin(_ id: UUID, quietly: Bool = false, step: UUID = UUID()) {
        guard let i = items.firstIndex(where: { $0.id == id && !$0.falling && !$0.kept }),
              let index = liveIndex(of: id) else { return }
        var item = items.remove(at: i)
        let before = TakenDown(url: item.url, index: index, trashed: nil,
                               kept: item.kept, byHand: item.byHand, pinChange: true)
        item.kept = true
        items.insert(item, at: keptCount)
        save()
        remember(before, in: step)
        if !quietly { play("Tink", volume: 0.35) }
    }

    /// Unpin: it hangs loose again, first past the kept ones, so it is the
    /// next to fall from a full line.
    func unpin(_ id: UUID, step: UUID = UUID()) {
        guard let i = items.firstIndex(where: { $0.id == id && !$0.falling && $0.kept && !$0.byHand }),
              let index = liveIndex(of: id) else { return }
        var item = items.remove(at: i)
        let before = TakenDown(url: item.url, index: index, trashed: nil,
                               kept: item.kept, byHand: item.byHand, pinChange: true)
        item.kept = false
        items.insert(item, at: keptCount)
        save()
        remember(before, in: step)
    }

    /// An image hung from another app, with Hang on Tendedero. Like a
    /// photo from a watched folder, the line only shows the file where it
    /// is: taking it down leaves the file alone. What you hang yourself is
    /// pinned.
    @discardableResult
    func hangKept(_ url: URL) -> Bool {
        // Already on the line: it is pinned where it is.
        if let hanging = items.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL && !$0.falling }) {
            pin(hanging.id)
            return true
        }
        guard let id = hang(url),
              let i = items.firstIndex(where: { $0.id == id }) else { return false }
        var item = items.remove(at: i)
        item.kept = true
        item.byHand = true
        items.insert(item, at: keptCount)
        save()
        return true
    }

    // MARK: Holding

    /// Off the line and into your hand, or back onto its clip.
    func setHeld(_ id: UUID, _ held: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id && !$0.falling }) else { return }
        if held { selectedIDs.remove(id) }
        items[i].held = held
        if !held { items[i].flying = true }
    }

    // MARK: Breeze

    private var gustWork: DispatchWorkItem?

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget. Tucked away, it rests:
    /// ordering the panel out does not stop SwiftUI's animation work.
    private func scheduleGust() {
        guard revealed else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.revealed else { return }
            self.gustWork = nil
            if !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
        gustWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16), execute: work)
    }

    // MARK: Persistence

    private let keptKey = "kept"
    private let byHandKey = "byHand"

    private func save() {
        let live = items.filter { !$0.falling }
        UserDefaults.standard.set(live.map(\.url.path), forKey: storeKey)
        UserDefaults.standard.set(live.filter(\.kept).map(\.url.path), forKey: keptKey)
        UserDefaults.standard.set(live.filter(\.byHand).map(\.url.path), forKey: byHandKey)
    }

    /// Everything comes back as it was. This runs before the line knows its
    /// screen, so the capacity is still the default one: hanging through
    /// `hang` would let photos fall off a wide screen's line at every launch.
    private func restore() {
        let paths = UserDefaults.standard.stringArray(forKey: storeKey) ?? []
        let kept = Set(UserDefaults.standard.stringArray(forKey: keptKey) ?? [])
        let byHand = Set(UserDefaults.standard.stringArray(forKey: byHandKey) ?? [])
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            guard !items.contains(where: { $0.url == url }), let thumb = makeThumbnail(url) else { continue }
            var item = Pegged(url: url, thumb: thumb)
            item.byHand = byHand.contains(path)
            item.kept = kept.contains(path) || item.byHand
            items.append(item)
        }
        keepKeptFirst()
    }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Screen recordings, as macOS saves them.
func isRecording(_ url: URL) -> Bool {
    ["mov", "mp4"].contains(url.pathExtension.lowercased())
}

/// The default size covers a card at twice its size in points, as on a
/// Retina screen, and no more: every photo on the line keeps one in memory.
func makeThumbnail(_ url: URL, maxPixels: Int = Int(320 * Layout.size.scale)) -> NSImage? {
    if isRecording(url) { return firstFrame(url, maxPixels: maxPixels) }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// A recording shows its first frame.
private func firstFrame(_ url: URL, maxPixels: Int) -> NSImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
    guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
