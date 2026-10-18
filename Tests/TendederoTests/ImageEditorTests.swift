import XCTest
import AppKit
@testable import Tendedero

final class ImageEditorTests: XCTestCase {
    @MainActor
    func testSelectionWindowsUseEachDisplaysGlobalFrame() {
        _ = NSApplication.shared
        for screen in NSScreen.screens {
            let window = CaptureSelectionWindow(on: screen)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            XCTAssertFalse(window.isVisible)
            XCTAssertEqual(window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                           screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            XCTAssertEqual(window.frame.origin.x, screen.frame.origin.x, accuracy: 1)
            XCTAssertEqual(window.frame.origin.y, screen.frame.origin.y, accuracy: 1)
            XCTAssertEqual(window.frame.size.width, screen.frame.size.width, accuracy: 1)
            XCTAssertEqual(window.frame.size.height, screen.frame.size.height, accuracy: 1)
        }
    }

    @MainActor
    func testTallImageInitiallyFitsAndIsCentred() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tall-fit.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 2000, bitsPerComponent: 8,
            bytesPerRow: 2400, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        try ImageEditing.png(try XCTUnwrap(context.makeImage())).write(to: url)
        ImageEditor.shared.edit(url, present: false)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title.contains("tall-fit.png") })
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(content.subviews.first { $0 is NSScrollView } as? NSScrollView)
        let canvas = try XCTUnwrap(scroll.documentView)
        XCTAssertLessThanOrEqual(scroll.magnification * canvas.frame.height, scroll.contentSize.height)
        XCTAssertEqual(scroll.contentView.bounds.midX, canvas.frame.midX, accuracy: 1)
        XCTAssertEqual(scroll.contentView.bounds.midY, canvas.frame.midY, accuracy: 1)
    }

    @MainActor
    func testQuitRespectsCancelDiscardAndSaveCopyForUnsavedCut() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quit-fixture.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        try ImageEditing.png(try XCTUnwrap(context.makeImage())).write(to: url)
        let editor = ImageEditor.shared
        let oldPrompt = editor.closingPrompt
        let oldSaved = editor.onSaved
        var saved: URL?
        defer {
            editor.closingPrompt = oldPrompt
            editor.onSaved = oldSaved
            if let saved { try? FileManager.default.removeItem(at: saved) }
        }
        editor.edit(url, present: false)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title.contains("quit-fixture.png") })
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(content.subviews.first { $0 is NSScrollView } as? NSScrollView)
        let canvas = try XCTUnwrap(scroll.documentView)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, NSPoint(x: 0, y: 0)))
        canvas.mouseUp(with: try event(.leftMouseUp, NSPoint(x: 0, y: 2)))
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        let cut = try XCTUnwrap(buttons(in: content).first { $0.title == L("Cut") })
        XCTAssertTrue(cut.isEnabled)
        cut.performClick(nil)
        XCTAssertTrue(try XCTUnwrap(buttons(in: content).first { $0.keyEquivalent == "s" }).isEnabled)
        let delegate: NSApplicationDelegate = AppDelegate()
        var prompts = 0
        for (response, expected) in [
            (NSApplication.ModalResponse.alertThirdButtonReturn, NSApplication.TerminateReply.terminateCancel),
            (.alertSecondButtonReturn, .terminateNow),
            (.alertFirstButtonReturn, .terminateNow),
        ] {
            editor.closingPrompt = { alert in
                XCTAssertEqual(alert.buttons.map(\.title), [L("Save Copy"), L("Discard"), L("Cancel")])
                prompts += 1
                return response
            }
            editor.onSaved = { copy, source in saved = copy; XCTAssertEqual(source, url) }
            XCTAssertEqual(delegate.applicationShouldTerminate?(NSApp), expected)
        }
        XCTAssertEqual(prompts, 3)
        let output = try XCTUnwrap(ImageEditing.load(try XCTUnwrap(saved)))
        XCTAssertEqual(output.height, 2)
        XCTAssertEqual(ImageEditing.load(url)?.height, 4)
    }

    @MainActor
    func testEditorShortcutsRequireCommandModifier() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("keyboard-fixture.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        try ImageEditing.png(image).write(to: url)
        ImageEditor.shared.edit(url, present: false)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title.contains("keyboard-fixture.png") })
        defer { window.close() }
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        let shortcuts = buttons(in: try XCTUnwrap(window.contentView)).filter { ["z", "c", "s"].contains($0.keyEquivalent) }
        XCTAssertEqual(Set(shortcuts.map(\.keyEquivalent)), Set(["z", "c", "s"]))
        for button in shortcuts {
            XCTAssertEqual(button.keyEquivalentModifierMask, [.command], button.title)
        }
    }
}
