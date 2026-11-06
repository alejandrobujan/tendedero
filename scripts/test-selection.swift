import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Compiled with the production views and model, without AppDelegate or
// Inbox's screenshot-settings code. All files and preferences are isolated;
// copying uses a private pasteboard. Nothing watches the user's screenshots.
@MainActor enum Inbox { static var folder: URL! }

struct CheckFailed: Error { let message: String }

@MainActor final class SelectionChecks {
    let root: URL
    let pasteboard = NSPasteboard.withUniqueName()
    var passed = 0
    var window: NSWindow!

    init(root: URL) { self.root = root }

    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckFailed(message: message) }
        passed += 1
        print("PASS \(passed): \(message)")
    }

    func pump(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func png(_ name: String, in folder: URL? = nil, red: CGFloat = 0.3) throws -> URL {
        let url = (folder ?? root).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 240, height: 140, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 140))
        let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(output) else { throw CheckFailed(message: "Could not write fixture") }
        return url
    }

    func line() -> Line {
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
        UserDefaults.standard.set(true, forKey: "soundOff")
        let line = Line(pasteboard: pasteboard)
        line.maxItems = 100
        line.visibleCount = 8
        line.revealed = true
        return line
    }

    func show(_ line: Line) {
        window?.orderOut(nil)
        window = NSWindow(contentRect: NSRect(x: 80, y: 200, width: 1100, height: 250),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Tendedero selection checks — synthetic images"
        window.contentView = NSHostingView(rootView: LineView(line: line))
        window.orderFront(nil)
        pump(0.7)
    }

    func grab(_ url: URL) throws -> GrabView {
        func all(_ view: NSView) -> [GrabView] {
            (view as? GrabView).map { [$0] } ?? view.subviews.flatMap(all)
        }
        guard let view = all(window.contentView!).first(where: { $0.url == url }) else {
            throw CheckFailed(message: "No native card for \(url.lastPathComponent)")
        }
        return view
    }

    func click(_ view: GrabView, shift: Bool = false, count: Int = 1) {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: shift ? [.shift] : [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
                                          context: nil, eventNumber: 1, clickCount: count, pressure: 1)!
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    func fire(_ title: String, in menu: NSMenu) throws {
        guard let item = menu.items.first(where: { $0.title == title }), item.isEnabled, let action = item.action else {
            throw CheckFailed(message: "Missing enabled menu action: \(title)")
        }
        NSApp.sendAction(action, to: item.target, from: item)
        pump()
    }

    var copiedURLs: [URL] {
        (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:)) }
    }

    func run() throws {
        Inbox.folder = root.appendingPathComponent("inbox", isDirectory: true)
        let a = try png("A.png"), b = try png("B.png", red: 0.7), c = try png("C.png", red: 0.9)
        let line = line()
        let aID = line.hang(a, quietly: true)!, bID = line.hang(b, quietly: true)!, cID = line.hang(c, quietly: true)!
        show(line)
        pasteboard.clearContents()
        pasteboard.setString("untouched", forType: .string)
        let before = pasteboard.changeCount
        click(try grab(c), shift: true)
        click(try grab(a), shift: true)
        pump(0.65)
        try check(line.selectedItems.map(\.id) == [aID, cID], "Shift toggles individual photos in line order and survives release")
        try check(pasteboard.changeCount == before, "Shift selection does not copy or open a long-press editor")
        click(try grab(c), shift: true)
        try check(line.selectedIDs == [aID], "Shift-clicking a selected photo removes it")
        click(try grab(c), shift: true)

        let menu = try grab(a).menuProvider()
        let titles = menu.items.map(\.title)
        try check(titles.contains("2 selected"), "Selection menu states how many photos it affects")
        try check(["Copy", "Open", "Show in Finder", "Share…", "Pin", "Save to Desktop", "Take down"].allSatisfy(titles.contains),
                  "Selection menu exposes the requested batch actions")
        try check(["Quick Look", "Hold", "Markup", "Move to Trash", "Take down everything to the left"].allSatisfy { !titles.contains($0) },
                  "Single-photo editors and unrelated removal actions are absent from the selection menu")
        try check(menu.items.first { $0.title == "Save to Desktop" }?.isEnabled == false, "External originals cannot be moved by Save to Desktop")
        line.clearSelection()
        line.toggleSelection(bID)
        try fire("Copy", in: menu)
        try check(copiedURLs == [a, c], "An open menu acts on its captured selection, not later changes")
        try check(pasteboard.pasteboardItems?.allSatisfy { $0.data(forType: .png) != nil } == true,
                  "Every copied photo has both PNG and file representations")
        try check(line.copiedIDs == [aID, cID], "Copy feedback covers every copied photo")
        pump(1.3)
        try check(line.copiedIDs.isEmpty, "Batch copy feedback expires")

        line.clearSelection()
        click(try grab(a))
        click(try grab(c), shift: true)
        let pending = pasteboard.changeCount
        pump(0.65)
        try check(pasteboard.changeCount == pending, "Starting selection cancels a pending copy on another card")
        click(try grab(b))
        pump(0.65)
        try check(line.selectedIDs.isEmpty && copiedURLs == [b], "An ordinary click clears selection and still copies one photo")

        let gestures = GrabView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        var singles = 0, doubles = 0, holds = 0, toggles = 0
        gestures.onClick = { singles += 1 }
        gestures.onDoubleClick = { doubles += 1 }
        gestures.onLongPress = { holds += 1 }
        gestures.onSelect = { toggles += 1 }
        click(gestures, shift: true)
        click(gestures, shift: true, count: 2)
        pump(0.65)
        try check(toggles == 2 && singles == 0 && doubles == 0 && holds == 0, "Rapid Shift clicks never copy, open or mark up")
        click(gestures)
        click(gestures, count: 2)
        pump(0.65)
        try check(doubles == 1 && singles == 0, "Ordinary double-click still opens once without copying")

        line.toggleSelection(cID)
        line.toggleSelection(aID)
        try fire("Pin", in: try grab(a).menuProvider())
        try check(line.items.filter { !$0.falling }.map(\.id) == [aID, cID, bID], "Batch pin keeps the selected photos' relative order")
        try check(!line.canDiscard([aID, cID]), "Pinned screenshots are protected from batch discard")
        let pinnedMenu = try grab(a).menuProvider()
        try check(pinnedMenu.items.first { $0.title == "Take down" }?.isEnabled == false, "Pinned selection disables Take down")
        try fire("Unpin", in: pinnedMenu)
        try check(line.items.map(\.id) == [aID, cID, bID] && line.keptCount == 0, "Batch unpin preserves relative order")
        let d = try png("D.png")
        let savedMenu = try grab(a).menuProvider()
        let dID = line.hang(d, quietly: true)!
        try fire("Take down", in: savedMenu)
        try check(line.items.filter { !$0.falling }.map(\.id) == [bID, dID], "Batch removal does not include new arrivals")
        try check(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: c.path), "Taking down external photos preserves both originals")
        try check(line.selectedIDs.isEmpty, "Removed photos leave the selection immediately")
        line.putBack()
        try check(line.items.filter { !$0.falling }.map(\.url) == [a, c, b, d], "One undo restores the whole batch in its original order")
        try check(!line.canPutBack, "The batch consumes only one undo step")

        let restored = Line(pasteboard: pasteboard)
        try check(restored.selectedIDs.isEmpty && restored.items.map(\.url) == [a, c, b, d], "Order persists but transient selection does not")
        line.clearSelection()
        line.toggleSelection(bID)
        _ = try grab(d).menuProvider()
        try check(line.selectedIDs.isEmpty, "Right-clicking an unselected photo returns to its single-photo menu")
        line.toggleSelection(bID)
        line.setHeld(bID, true)
        line.toggleSelection(bID)
        try check(line.selectedIDs.isEmpty, "Held photos cannot remain selected or be selected through their faded trace")
        line.copy(bID)
        try check(copiedURLs == [b], "Copy from a held photo still works")

        let trashLine = self.line()
        defer { if trashLine.canPutBack { trashLine.putBack() } }
        let i1 = try png("Inbox 1.png", in: Inbox.folder), i2 = try png("Inbox 2.png", in: Inbox.folder)
        let ids = [trashLine.hang(i1, quietly: true)!, trashLine.hang(i2, quietly: true)!, trashLine.hang(a, quietly: true)!]
        ids.forEach(trashLine.toggleSelection)
        trashLine.copy(ids)
        let originalData = [try Data(contentsOf: i1), try Data(contentsOf: i2)]
        trashLine.discard(ids)
        try check(!FileManager.default.fileExists(atPath: i1.path) && !FileManager.default.fileExists(atPath: i2.path)
                  && FileManager.default.fileExists(atPath: a.path), "Mixed removal trashes inbox copies and preserves external originals")
        try check(copiedURLs.count == 3 && copiedURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                  "Moving copied photos to Trash keeps every clipboard file URL valid")
        trashLine.putBack()
        try check(try Data(contentsOf: i1) == originalData[0] && Data(contentsOf: i2) == originalData[1], "Undo restores both trashed files byte for byte")
        try check(copiedURLs == [i1, i2, a] && trashLine.items.filter { !$0.falling }.map(\.url) == [i1, i2, a], "Undo restores batch clipboard URLs and order")

        let handLine = self.line()
        _ = handLine.hangKept(a)
        let hand = handLine.items[0].id
        handLine.toggleSelection(hand)
        handLine.unpin([hand])
        try check(handLine.items[0].kept, "Photos hung by hand remain pinned when unpinning a batch")
        handLine.discard([hand])
        try check(FileManager.default.fileExists(atPath: a.path) && handLine.liveCount == 0, "Taking down a manually hung photo preserves its file")
        handLine.putBack()

        let eviction = self.line()
        eviction.maxItems = 2
        let oldest = eviction.hang(a, quietly: true)!
        _ = eviction.hang(b, quietly: true)
        eviction.toggleSelection(oldest)
        _ = eviction.hang(c, quietly: true)
        try check(eviction.selectedIDs.isEmpty && FileManager.default.fileExists(atPath: a.path), "Capacity eviction clears stale selection without deleting an external file")
        print("\(passed) selection checks passed")
    }

    func cleanUp() {
        window?.orderOut(nil)
        pasteboard.releaseGlobally()
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
    }
}

@main struct RunSelectionChecks {
    @MainActor static func main() {
        guard Bundle.main.bundleIdentifier == "local.tendedero.selection-checks", CommandLine.arguments.count == 2 else {
            fatalError("Run with scripts/test-selection.sh")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let checks = SelectionChecks(root: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        defer { checks.cleanUp() }
        do { try checks.run() }
        catch {
            print("FAIL: \(error)")
            checks.cleanUp()
            exit(1)
        }
    }
}
