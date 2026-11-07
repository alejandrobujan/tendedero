import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Compiled with the production views and model, without AppDelegate or
// Inbox's screenshot-settings code. All files and preferences are isolated;
// copying uses a private pasteboard. Nothing watches the user's screenshots.
enum Inbox { static var folder: URL! }

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
        let desktop = root.appendingPathComponent("desktop", isDirectory: true)
        try! FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let line = Line(pasteboard: pasteboard, desktop: desktop)
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
        try check(["Copy", "Open", "Show in Finder", "Share…", "Pin", "Save to Desktop (inbox only)", "Take down"].allSatisfy(titles.contains),
                  "Selection menu exposes the requested batch actions")
        try check(["Quick Look", "Hold", "Markup", "Move to Trash", "Take down everything to the left"].allSatisfy { !titles.contains($0) },
                  "Single-photo editors and unrelated removal actions are absent from the selection menu")
        try check(menu.items.first { $0.title == "Save to Desktop (inbox only)" }?.isEnabled == false, "External originals cannot be moved by Save to Desktop")
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
        try check(line.canPutBack, "Undoing removal leaves the earlier pin actions available")

        let restored = Line(pasteboard: pasteboard)
        try check(restored.selectedIDs.isEmpty && restored.items.map(\.url) == [a, c, b, d], "Order persists but transient selection does not")
        line.putBack()
        try check(line.items.filter(\.kept).map(\.url) == [a, c], "One undo restores the whole batch's pinned state")
        line.putBack()
        try check(line.keptCount == 0 && line.items.filter { !$0.falling }.map(\.url) == [a, b, c, d],
                  "Undoing batch pin restores positions after a later discard and undo")
        try check(!line.canPutBack, "Each batch uses one undo step")
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
        var undoActions = 0
        trashLine.onUndoableAction = { undoActions += 1 }
        trashLine.discard(ids)
        try check(undoActions == 1, "A batch acquires the undo interaction once, not again for each file")
        try check(!FileManager.default.fileExists(atPath: i1.path) && !FileManager.default.fileExists(atPath: i2.path)
                  && FileManager.default.fileExists(atPath: a.path), "Mixed removal trashes inbox copies and preserves external originals")
        try check(copiedURLs.count == 3 && copiedURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                  "Moving copied photos to Trash keeps every clipboard file URL valid")
        trashLine.putBack()
        try check(try Data(contentsOf: i1) == originalData[0] && Data(contentsOf: i2) == originalData[1], "Undo restores both trashed files byte for byte")
        try check(copiedURLs == [i1, i2, a] && trashLine.items.filter { !$0.falling }.map(\.url) == [i1, i2, a], "Undo restores batch clipboard URLs and order")

        let saveLine = self.line()
        let s1 = try png("Save 1.png", in: Inbox.folder), s2 = try png("Save 2.png", in: Inbox.folder)
        let s1ID = saveLine.hang(s1, quietly: true)!, s2ID = saveLine.hang(s2, quietly: true)!
        _ = saveLine.hang(a, quietly: true)
        saveLine.pin(s1ID)
        let savedBytes = [try Data(contentsOf: s1), try Data(contentsOf: s2)]
        let desktop = root.appendingPathComponent("desktop", isDirectory: true)
        let saved1 = desktop.appendingPathComponent(s1.lastPathComponent)
        let saved2 = desktop.appendingPathComponent(s2.lastPathComponent)
        // An unrelated namesake on the Desktop must never be overwritten.
        let unrelated = Data("already on Desktop".utf8)
        try unrelated.write(to: saved1)
        let renamed1 = desktop.appendingPathComponent("Save 1 2.png")
        saveLine.copy([s1ID, s2ID])
        saveLine.saveToDesktop([s1ID, s2ID])
        try check(saveLine.liveCount == 1 && copiedURLs == [renamed1, saved2], "Batch save records the actual destinations and updates clipboard URLs")
        try check(try Data(contentsOf: saved1) == unrelated, "Saving never overwrites an existing Desktop file")
        // Simulate the Desktop watcher noticing the moved screenshot.
        _ = saveLine.hang(renamed1, quietly: true)
        saveLine.putBack()
        try check(try Data(contentsOf: s1) == savedBytes[0] && Data(contentsOf: s2) == savedBytes[1],
                  "One undo moves both saved files back byte for byte")
        try check(saveLine.items.filter { !$0.falling }.map(\.url) == [s1, s2, a] && saveLine.keptCount == 1,
                  "Undoing save restores pin state and order without a duplicate Desktop card")
        try check(copiedURLs == [s1, s2] && !FileManager.default.fileExists(atPath: renamed1.path)
                  && !FileManager.default.fileExists(atPath: saved2.path), "Undoing save removes only the moved copies and repairs clipboard URLs")
        saveLine.putBack()
        try check(!saveLine.canPutBack && saveLine.keptCount == 0, "Undo history continues to the pin action before saving")

        let singleID = saveLine.items.first { $0.url == s2 && !$0.falling }!.id
        saveLine.pin(singleID)
        saveLine.saveToDesktop(singleID)
        let replacement = try png("Save 2.png", in: Inbox.folder, red: 0.1)
        let replacementBytes = try Data(contentsOf: replacement)
        saveLine.putBack()
        let restored2 = Inbox.folder.appendingPathComponent("Save 2 2.png")
        try check(try Data(contentsOf: replacement) == replacementBytes && Data(contentsOf: restored2) == savedBytes[1],
                  "Undoing a single save preserves a newer file at the original path")
        try check(saveLine.canPutBack && saveLine.liveCount == 3, "Single save also creates exactly one undo step")
        saveLine.putBack()
        try check(!saveLine.canPutBack && saveLine.keptCount == 0,
                  "Earlier pin undo follows a restored file's new name without touching its namesake")

        let noChange = self.line()
        let noChangeID = noChange.hang(a, quietly: true)!
        noChange.unpin([noChangeID])
        noChange.saveToDesktop([noChangeID])
        try check(!noChange.canPutBack, "Disabled and no-op batch actions do not create undo records")

        let mixed = self.line()
        let m1 = try png("Mixed inbox 1.png", in: Inbox.folder)
        let m2 = try png("Mixed inbox 2.png", in: Inbox.folder)
        let alreadySaved = try png("Already on Desktop.png", in: desktop)
        let mixedURLs = [m1, alreadySaved, m2, b]
        let mixedBytes = try mixedURLs.map { try Data(contentsOf: $0) }
        let mixedIDs = mixedURLs.map { mixed.hang($0, quietly: true)! }
        mixedIDs.forEach(mixed.toggleSelection)
        show(mixed)
        let mixedMenu = try grab(m1).menuProvider()
        try check(mixedMenu.items.first { $0.title == "Save to Desktop" }?.isEnabled == true,
                  "Desktop and external photos do not disable saving selected inbox photos")
        mixed.copy(mixedIDs)
        try fire("Save to Desktop", in: mixedMenu)
        let moved1 = desktop.appendingPathComponent(m1.lastPathComponent)
        let moved2 = desktop.appendingPathComponent(m2.lastPathComponent)
        try check(mixed.items.filter { !$0.falling }.map(\.url) == [alreadySaved, b]
                  && copiedURLs == [moved1, alreadySaved, moved2, b],
                  "Mixed save moves only inbox photos and keeps other selected originals in place")
        try check(try Data(contentsOf: alreadySaved) == mixedBytes[1] && Data(contentsOf: b) == mixedBytes[3]
                  && !FileManager.default.fileExists(atPath: desktop.appendingPathComponent("Already on Desktop 2.png").path),
                  "Mixed save neither moves external originals nor duplicates a photo already on Desktop")
        mixed.putBack()
        try check(try mixedURLs.map { try Data(contentsOf: $0) } == mixedBytes
                  && mixed.items.filter { !$0.falling }.map(\.url) == mixedURLs && !mixed.canPutBack,
                  "One undo restores the mixed save's moved files, bytes and order")
        mixed.clearSelection()
        mixed.toggleSelection(mixedIDs[1])
        mixed.toggleSelection(mixedIDs[3])
        let savedOnlyMenu = try grab(alreadySaved).menuProvider()
        mixed.saveToDesktop([mixedIDs[1], mixedIDs[3]])
        mixed.saveToDesktop(mixedIDs[1])
        try check(savedOnlyMenu.items.first { $0.title == "Save to Desktop (inbox only)" }?.isEnabled == false
                  && !mixed.canPutBack && copiedURLs == mixedURLs,
                  "A selection with no inbox photos is a no-op and preserves clipboard URLs")

        mixed.clearSelection()
        // Start the single-photo menu checks with a fresh host: this
        // synchronous runner can retain the outgoing cards from undo.
        show(mixed)
        try check(try grab(alreadySaved).menuProvider().items.first { $0.title == "Save to Desktop (already there)" }?.isEnabled == false,
                  "A single Desktop photo shows why saving is unavailable instead of hiding the action")
        try check(try grab(b).menuProvider().items.first { $0.title == "Save to Desktop (inbox only)" }?.isEnabled == false,
                  "A single external photo shows the inbox restriction and preserves its original")
        try check(try grab(m1).menuProvider().items.first { $0.title == "Save to Desktop" }?.isEnabled == true,
                  "A single inbox photo still offers Save to Desktop")
        mixed.toggleSelection(mixedIDs[1])
        try check(try grab(alreadySaved).menuProvider().items.first { $0.title == "Save to Desktop (already there)" }?.isEnabled == false,
                  "Single-photo and selection menus explain an existing Desktop file consistently")
        mixed.clearSelection()
        let heldInboxID = mixed.items.first { $0.url == m1 && !$0.falling }!.id
        mixed.setHeld(heldInboxID, true)
        show(mixed)
        try fire("Save to Desktop", in: try grab(m1).menuProvider())
        try check(FileManager.default.fileExists(atPath: moved1.path) && !FileManager.default.fileExists(atPath: m1.path),
                  "The existing single-photo save still works for an inbox photo held in hand")
        mixed.putBack()

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
    }

    /// Exercise real directory events, delayed file checks, and overlapping
    /// watchers. The earlier menu-only checks could not catch a saved image
    /// being picked up again by the Desktop safety watcher.
    func checkDesktopWatchers() async throws {
        // Folder listings can use /private/var where the test root uses
        // /var. Compare standardized URLs, as the production gate does.
        func canonical(_ url: URL) -> URL { url.standardizedFileURL }
        let fm = FileManager.default
        let desktop = root.appendingPathComponent("watched-desktop", isDirectory: true)
        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: "pegged")
        let line = Line(pasteboard: pasteboard, desktop: desktop)
        line.maxItems = 100
        let first = try png("Watched 1.png", in: Inbox.folder)
        let second = try png("Watched 2.png", in: Inbox.folder)
        let bytes = try [first, second].map { try Data(contentsOf: $0) }
        let ids = [line.hang(first, quietly: true)!, line.hang(second, quietly: true)!]
        var reports: [URL] = []
        var changes = 0
        let watchers = (0..<2).map { _ in
            ScreenshotWatcher(folder: desktop, anyImage: true, onNew: { url in
                reports.append(url)
                // The same gate used by AppDelegate.hangCapture, before
                // either hanging the photo or starting its flight.
                guard !line.isDesktopSave(url) else { return }
                _ = line.hang(url, quietly: true)
            }, onChange: { changes += 1; line.prune() })
        }
        defer { watchers.forEach { $0.stop() } }
        watchers.forEach { $0.start() }
        try await Task.sleep(nanoseconds: 800_000_000)
        line.saveToDesktop(ids)
        let targets = [first, second].map { desktop.appendingPathComponent($0.lastPathComponent) }
        let deadline = Date().addingTimeInterval(5)
        while reports.count < 4 && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        try check(targets.allSatisfy { target in reports.filter { canonical($0) == canonical(target) }.count >= 2 },
                  "Both live folder watchers observe both exported screenshots")
        try check(line.liveCount == 0 && targets.allSatisfy(line.isDesktopSave),
                  "Saved screenshots stay off the line after asynchronous and overlapping watcher callbacks")
        try check(try targets.map { try Data(contentsOf: $0) } == bytes,
                  "Suppressing re-hang preserves both saved files byte for byte")

        let newCapture = try png("New capture.png", in: desktop)
        let newDeadline = Date().addingTimeInterval(5)
        while line.liveCount == 0 && Date() < newDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
        try check(line.items.filter { !$0.falling }.map { canonical($0.url) } == [canonical(newCapture)],
                  "A genuine new image is still picked up exactly once by overlapping watchers")
        line.putBack()
        try await Task.sleep(nanoseconds: 800_000_000)
        try check(try [first, second].map { try Data(contentsOf: $0) } == bytes,
                  "Undo after watcher callbacks restores the exported files byte for byte")
        try check(line.items.filter { !$0.falling }.map { canonical($0.url) } == [first, second, newCapture].map(canonical)
                  && targets.allSatisfy { !line.isDesktopSave($0) },
                  "Undo clears export suppression and restores the original order beside new arrivals")

        let firstID = line.items.first { canonical($0.url) == canonical(first) && !$0.falling }!.id
        line.saveToDesktop(firstID)
        try await Task.sleep(nanoseconds: 800_000_000)
        let changeCount = changes
        let parked = root.appendingPathComponent("Previously exported.png")
        try fm.moveItem(at: targets[0], to: parked)
        let removedDeadline = Date().addingTimeInterval(5)
        while changes == changeCount && Date() < removedDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
        try await Task.sleep(nanoseconds: 400_000_000)
        let replacement = try png(first.lastPathComponent, in: desktop, red: 0.9)
        let replacedDeadline = Date().addingTimeInterval(5)
        while !line.items.contains(where: { canonical($0.url) == canonical(replacement) && !$0.falling }) && Date() < replacedDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
        try check(line.items.contains { canonical($0.url) == canonical(replacement) && !$0.falling } && !line.isDesktopSave(replacement),
                  "A different file reusing an exported filename is accepted as a new image")
        try check(try Data(contentsOf: parked) == bytes[0],
                  "A later namesake never changes the earlier exported file")

        let secondID = line.items.first { canonical($0.url) == canonical(second) && !$0.falling }!.id
        line.saveToDesktop(secondID)
        let newID = line.items.first { canonical($0.url) == canonical(newCapture) && !$0.falling }!.id
        for _ in 0..<11 { line.pin(newID); line.unpin(newID) }
        try await Task.sleep(nanoseconds: 800_000_000)
        try check(line.isDesktopSave(targets[1]) && !line.items.contains { canonical($0.url) == canonical(targets[1]) && !$0.falling },
                  "Saved files remain suppressed after their bounded undo history expires")
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
        // Watcher callbacks arrive on DispatchQueue.main. Yield between
        // checks inside the application loop so delivery does not depend
        // on reentrant RunLoop draining in a synchronous main-actor call.
        Task { @MainActor in
            do {
                try await checks.checkDesktopWatchers()
                print("\(checks.passed) selection checks passed")
                checks.cleanUp()
                exit(0)
            } catch {
                print("FAIL: \(error)")
                checks.cleanUp()
                exit(1)
            }
        }
        NSApp.run()
    }
}
