import AppKit
import SwiftUI

/// Bridges each photo to AppKit's drag and drop, so it can be dragged into
/// any app as a real file. Each destination means one thing:
///
/// - An app gets a copy, and the photo stays on the line.
/// - A folder or the Desktop keeps the file, and the photo leaves the line.
/// - The Trash discards it.
/// - Nowhere that accepts it: the photo flies back to the line.
///
/// Click copies, double click opens, press and hold opens Markup, the corner
/// cross discards.
struct GrabArea: NSViewRepresentable {
    let item: Pegged
    let line: Line

    func makeNSView(context: Context) -> GrabView {
        let view = GrabView()
        configure(view)
        return view
    }

    func updateNSView(_ view: GrabView, context: Context) {
        configure(view)
    }

    private func configure(_ view: GrabView) {
        let id = item.id
        let line = line
        let isRecording = item.isRecording
        view.url = item.url
        view.dragImage = item.thumb
        view.isHeld = item.held
        view.toolTip = L("Shift-click to select photos")
        view.onSelect = { line.toggleSelection(id) }
        // Pressing a selected photo keeps the selection, so it can be
        // dragged as a group; a plain click on it clears it when released.
        view.onPlainPress = { if !line.selectedIDs.contains(id) { line.clearSelection() } }
        view.onPlainClick = { line.clearSelection() }
        view.onHangBack = { line.onHangBack?(id) }
        view.onClick = { line.copy(id) }
        view.onDoubleClick = { line.open(id) }
        view.onDragStart = { line.draggingID = id }
        view.onDragEnd = {
            line.draggingID = nil
            // Moved into a folder: it is saved where you wanted it.
            line.prune()
        }
        // A photo selected with others drags them all, and they go to the
        // Trash together.
        let inGroup = { line.selectedIDs.contains(id) && line.selectedIDs.count > 1 }
        view.dragGroup = { inGroup() ? line.selectedItems.map { ($0.url, $0.thumb) } : [] }
        view.onTrash = {
            if inGroup() { line.trash(line.selectedItems.map(\.id)) } else { line.trash(id) }
        }
        view.onDiscard = { line.pressCorner(id) }
        view.onLongPress = { line.markup(id) }
        view.onForceClick = { line.quickLook(id) }
        view.onPressChange = { pressed in line.pressedID = pressed ? id : nil }
        view.menuProvider = { [weak view] in
            if line.selectedIDs.contains(id) {
                return selectionMenu(line.selectedItems, from: view)
            }
            line.clearSelection()
            let menu = NSMenu()
            // Items say themselves whether they can be used.
            menu.autoenablesItems = false
            menu.addItem(ClosureMenuItem(L("Copy")) { line.copy(id) })
            menu.addItem(ClosureMenuItem(L("Open")) { line.openFile(id) })
            if isText(item.url), Note.cached(item.url)?.link != nil {
                menu.addItem(ClosureMenuItem(L("Open Link")) { line.openLink(id) })
            }
            menu.addItem(ClosureMenuItem(L("Quick Look")) { line.quickLook(id) })
            if !isRecording {
                menu.addItem(ClosureMenuItem(L("Hold")) { line.onHold?(id) })
            }
            if !isRecording && !isText(item.url) {
                menu.addItem(ClosureMenuItem(L("Markup")) { line.markup(id) })
            }
            menu.addItem(ClosureMenuItem(L("Show in Finder")) { line.reveal(id) })
            if let view, let url = view.url, let window = view.window {
                // Sending it away is a section of its own.
                menu.addItem(.separator())
                let card = window.convertToScreen(view.convert(view.bounds, to: nil))
                // Once the menu has closed, so the panel opens on its own.
                let share = ClosureMenuItem(L("Share…")) {
                    DispatchQueue.main.async { Share.shared.show(url, from: card) }
                }
                // The icon macOS uses for Share everywhere.
                share.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
                menu.addItem(share)
                menu.addItem(.separator())
            }
            let item = line.items.first(where: { $0.id == id })
            let kept = item?.kept == true
            if !kept {
                menu.addItem(ClosureMenuItem(L("Pin")) { line.pin(id) })
            } else if item?.byHand == false {
                menu.addItem(ClosureMenuItem(L("Unpin")) { line.unpin(id) })
            }
            let inInbox = line.isInInbox(id)
            menu.addItem(saveToDesktopItem([id]))
            menu.addItem(.separator())
            if kept {
                // A pinned photo never goes to the Trash from here. One hung
                // by hand comes down; one pinned from the line is unpinned above.
                if item?.byHand == true {
                    menu.addItem(ClosureMenuItem(L("Take down")) { line.discard(id) })
                }
            } else if inInbox {
                menu.addItem(ClosureMenuItem(L("Discard")) { line.discard(id) })
            } else {
                menu.addItem(ClosureMenuItem(L("Take down")) { line.discard(id) })
                menu.addItem(ClosureMenuItem(L("Move to Trash")) { line.trash(id) })
            }
            let left = ClosureMenuItem(L("Take down everything to the left")) { line.takeDown(id, toTheLeft: true) }
            left.isEnabled = !line.neighbours(of: id, toTheLeft: true).isEmpty
            menu.addItem(left)
            let right = ClosureMenuItem(L("Take down everything to the right")) { line.takeDown(id, toTheLeft: false) }
            right.isEnabled = !line.neighbours(of: id, toTheLeft: false).isEmpty
            menu.addItem(right)
            return menu
        }
    }

    /// A menu captures the selection when it opens. New photos arriving
    /// while it is open cannot become part of an action by accident.
    private func selectionMenu(_ photos: [Pegged], from view: GrabView?) -> NSMenu {
        let ids = photos.map(\.id)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let count = NSMenuItem(title: String(format: L("%d selected"), photos.count), action: nil, keyEquivalent: "")
        count.isEnabled = false
        menu.addItem(count)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Copy")) { line.copy(ids) })
        menu.addItem(ClosureMenuItem(L("Open")) { line.open(ids) })
        menu.addItem(ClosureMenuItem(L("Show in Finder")) { line.reveal(ids) })
        if let view, let window = view.window {
            let card = window.convertToScreen(view.convert(view.bounds, to: nil))
            menu.addItem(.separator())
            let share = ClosureMenuItem(L("Share…")) {
                DispatchQueue.main.async { Share.shared.show(photos.map(\.url), from: card) }
            }
            share.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
            menu.addItem(share)
        }
        menu.addItem(.separator())
        if photos.contains(where: { !$0.kept }) {
            menu.addItem(ClosureMenuItem(L("Pin")) { line.pin(ids) })
        }
        if photos.contains(where: { $0.kept && !$0.byHand }) {
            menu.addItem(ClosureMenuItem(L("Unpin")) { line.unpin(ids) })
        }
        menu.addItem(saveToDesktopItem(ids))
        menu.addItem(.separator())
        let inInbox = photos.allSatisfy { !$0.kept && line.isInInbox($0.id) }
        let discard = ClosureMenuItem(inInbox ? L("Discard") : L("Take down")) { line.discard(ids) }
        discard.isEnabled = line.canDiscard(ids)
        menu.addItem(discard)
        return menu
    }

    /// Keep the action discoverable for a single photo too, and explain
    /// why other source folders are not handled by this action.
    private func saveToDesktopItem(_ ids: [UUID]) -> NSMenuItem {
        // Preserve the single-photo action, including a photo held in hand.
        let single = ids.count == 1 ? ids.first : nil
        let enabled = single.map { line.canSaveToDesktop($0) } ?? line.canSaveToDesktop(ids)
        let title = enabled ? L("Save to Desktop") : L("Save to Desktop (inbox or Desktop only)")
        let item = ClosureMenuItem(title) {
            if let single { line.saveToDesktop(single) } else { line.saveToDesktop(ids) }
        }
        item.isEnabled = enabled
        return item
    }
}

final class GrabView: NSView, NSDraggingSource {
    static var isDragging = false
    /// A photo's menu is open. It reaches past the line, so the line waits.
    static var isShowingMenu = false

    var url: URL?
    var dragImage: NSImage?
    /// Every photo that drags along with this one, when it is selected with
    /// others. Empty for a drag of its own.
    var dragGroup: () -> [(URL, NSImage)] = { [] }
    /// Held in your hand: only its faded trace is on the line, and a click
    /// on it is all it answers, to bring the photo back.
    var isHeld = false
    var onHangBack: () -> Void = {}
    var onSelect: () -> Void = {}
    var onPlainPress: () -> Void = {}
    var onPlainClick: () -> Void = {}
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onTrash: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onForceClick: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    var menuProvider: () -> NSMenu = { NSMenu() }

    private var downPoint: NSPoint?
    private var downTime: TimeInterval = 0
    private var startedDrag = false
    private var holdTimer: Timer?
    private var didLongPress = false
    private var pressedCross = false
    /// A brief wait lets a quick double click open without copying. A slower
    /// double click may arrive after the first click has already copied.
    private static var clickTimer: Timer?

    /// How long you hold before Markup opens. Long enough not to fire on a
    /// slow click, short enough to feel deliberate.
    private static let holdDuration: TimeInterval = 0.45

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The discard cross drawn in the top left corner of the card. It is
    /// handled here because this view sits on top of the SwiftUI card.
    static let crossHitSize: CGFloat = 26

    private func isInCross(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        let corner = NSRect(x: 0, y: isFlipped ? 0 : bounds.height - Self.crossHitSize,
                            width: Self.crossHitSize, height: Self.crossHitSize)
        return corner.contains(p)
    }

    override func mouseDown(with event: NSEvent) {
        Self.clickTimer?.invalidate()
        Self.clickTimer = nil
        pressedCross = false
        if event.modifierFlags.contains(.shift) {
            downPoint = nil
            endPress()
            if !isHeld { onSelect() }
            return
        }
        onPlainPress()
        if isHeld {
            downPoint = nil
            onHangBack()
            return
        }
        if isInCross(event) {
            downPoint = nil
            pressedCross = true
            return
        }
        if event.clickCount == 2 {
            downPoint = nil
            onDoubleClick()
            return
        }
        downPoint = event.locationInWindow
        downTime = event.timestamp
        startedDrag = false
        didLongPress = false
        onPressChange(true)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.downPoint != nil, !self.startedDrag else { return }
                self.didLongPress = true
                self.onPressChange(false)
                self.onLongPress()
            }
        }
    }

    /// A force click on a trackpad opens Quick Look, as it does in Finder.
    /// It counts instead of the click and of a long press.
    override func pressureChange(with event: NSEvent) {
        guard event.stage == 2, downPoint != nil, !startedDrag, !didLongPress else { return }
        didLongPress = true
        endPress()
        onForceClick()
    }

    private func endPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        onPressChange(false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !startedDrag, let url else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4, !didLongPress else { return }
        startedDrag = true
        endPress()

        let group = dragGroup()
        let items: [NSDraggingItem]
        if group.count > 1 {
            // A small pile, each with its own picture, set off a little.
            let base = imageFrame()
            items = group.enumerated().map { n, member in
                let item = NSDraggingItem(pasteboardWriter: Self.dragWriter(for: member.0))
                item.setDraggingFrame(base.offsetBy(dx: CGFloat(n) * 6, dy: CGFloat(-n) * 6), contents: member.1)
                return item
            }
        } else {
            let item = NSDraggingItem(pasteboardWriter: Self.dragWriter(for: url))
            item.setDraggingFrame(imageFrame(), contents: dragImage)
            items = [item]
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        if items.count > 1 { session.draggingFormation = .pile }
        // Released where nothing accepts it: it flies back to the line.
        session.animatesToStartingPositionsOnCancelOrFail = true
        GrabView.isDragging = true
        onDragStart()
    }

    /// A photo drags as its file. A note drags as its words for apps, styled
    /// when it has a style, and as its file for Finder.
    private static func dragWriter(for url: URL) -> NSPasteboardWriting {
        guard isText(url) else { return url as NSURL }
        let item = NSPasteboardItem()
        if url.pathExtension.lowercased() == "rtf", let data = try? Data(contentsOf: url),
           let rich = NSAttributedString(rtf: data, documentAttributes: nil) {
            item.setString(rich.string, forType: .string)
            item.setData(data, forType: .rtf)
        } else if let data = try? Data(contentsOf: url) {
            item.setString(String(decoding: data, as: UTF8.self), forType: .string)
        }
        item.setString(url.absoluteString, forType: .fileURL)
        return item
    }

    override func mouseUp(with event: NSEvent) {
        endPress()
        if pressedCross {
            pressedCross = false
            downPoint = nil
            if isInCross(event) { onDiscard() }
            return
        }
        if downPoint != nil && !startedDrag && !didLongPress && event.clickCount == 1 {
            onPlainClick()
            // Count time already spent pressing, but never make a single click
            // wait more than 200 ms after release for a possible second click.
            let elapsed = max(0, event.timestamp - downTime)
            let remaining = min(0.20, max(0, NSEvent.doubleClickInterval - elapsed))
            Self.clickTimer?.invalidate()
            // The copy goes ahead even if the line redraws this view meanwhile.
            let copy = onClick
            let timer = Timer(timeInterval: remaining, repeats: false) { _ in
                MainActor.assumeIsolated {
                    Self.clickTimer = nil
                    copy()
                }
            }
            // Keeps time while a menu or a drag runs the loop in another mode.
            RunLoop.main.add(timer, forMode: .common)
            Self.clickTimer = timer
        }
        downPoint = nil
        didLongPress = false
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !isHeld else { return }
        Self.clickTimer?.invalidate()
        Self.clickTimer = nil
        endPress()
        // The menu runs until it closes, and the line stays down meanwhile.
        GrabView.isShowingMenu = true
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
        GrabView.isShowingMenu = false
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Apps pick copy. Finder picks move, so a folder or the Desktop keeps
        // the file. Delete is what lets the Dock's Trash accept it.
        context == .outsideApplication ? [.copy, .move, .delete] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        GrabView.isDragging = false
        startedDrag = false
        downPoint = nil
        log.notice("Drag ended with operation \(operation.rawValue, privacy: .public)")
        // Dropped on the Trash: macOS only tells us, we move the file.
        if operation.contains(.delete) {
            onDragEnd()
            onTrash()
            return
        }
        onDragEnd()
        // Finder finishes a move a moment later. Check again then, so a photo
        // saved into a folder leaves the line.
        if operation.contains(.move) {
            let done = onDragEnd
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done() }
        }
    }

    /// The drag preview keeps the photo's aspect ratio inside the card.
    private func imageFrame() -> NSRect {
        guard let size = dragImage?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
