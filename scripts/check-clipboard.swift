// Read a unique test pasteboard after its provider process has terminated.
// Usage: swift scripts/check-clipboard.swift BOARD_NAME EXPECTED_PNG_PATH
import AppKit
import ImageIO

precondition(CommandLine.arguments.count == 3)
let board = NSPasteboard(name: NSPasteboard.Name(CommandLine.arguments[1]))
defer { board.releaseGlobally() }
let expected = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
guard let actual = board.data(forType: .png) else { fatalError("PNG promise was lost when the provider exited") }
precondition(actual == expected, "Clipboard contents differ from the copied PNG")
let source = CGImageSourceCreateWithData(actual as CFData, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
print("Clipboard survived provider exit: \(actual.count) bytes, \(image.width) x \(image.height) pixels")
