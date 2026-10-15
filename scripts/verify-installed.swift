// End-to-end check of the installed app. Clipboard backup stays in memory only.
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin

let project = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let artifacts = project.appendingPathComponent("04_交付物/ImageLine")
let fixtures = artifacts.appendingPathComponent("验证素材")
try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
let domain = "com.baiyuff001.imageline" as CFString
let originalKeep = CFPreferencesCopyAppValue("keepOnLine" as CFString, domain)
let inbox = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ImageLine/Screenshots")
let pb = NSPasteboard.general
let originalClipboard: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { old in
    let saved = NSPasteboardItem()
    for type in old.types { if let data = old.data(forType: type) { saved.setData(data, forType: type) } }
    return saved
}
var lastTestCount = pb.changeCount
var testFiles = Set<URL>()
var results = [String: Bool]()
var finderTypes = [String]()
var fixturePixels = Set<String>()
func pixelFingerprint(_ data: Data) -> String? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width >= 97, image.width <= 102, image.height == 64,
          let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
              bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let bytes = context.data else { return nil }
    return SHA256.hash(data: Data(bytes: bytes, count: image.width * image.height * 4)).map { String(format: "%02x", $0) }.joined()
}
func isFixture(_ url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url), let hash = pixelFingerprint(data) else { return false }
    return fixturePixels.contains(hash)
}
func paths() -> [String] {
    CFPreferencesAppSynchronize(domain)
    return CFPreferencesCopyAppValue("pegged" as CFString, domain) as? [String] ?? []
}
func run(_ args: [String]) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: args[0]); process.arguments = Array(args.dropFirst())
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "ImageLineVerification", code: Int(process.terminationStatus)) }
}
func restartInstalledApp() throws {
    try run(["/usr/bin/pkill", "-TERM", "-f", "^/Applications/ImageLine.app/Contents/MacOS/ImageLine$"])
    Thread.sleep(forTimeInterval: 0.5)
    try run(["/usr/bin/open", "/Applications/ImageLine.app"])
    Thread.sleep(forTimeInterval: 0.5)
}
func waitForNew(_ previous: Set<String>, expected: Int) throws -> [URL] {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        let new = paths().filter { !previous.contains($0) }.map { URL(fileURLWithPath: $0) }.filter(isFixture)
        if new.count >= expected {
            testFiles.formUnion(new)
            guard new.count == expected else { throw NSError(domain: "Unexpected extra images", code: new.count) }
            return new
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    throw NSError(domain: "ImageLine did not hang the test image", code: 1)
}
func unchanged(_ before: Set<String>) throws {
    Thread.sleep(forTimeInterval: 1.1)
    guard !paths().contains(where: { !before.contains($0) && isFixture(URL(fileURLWithPath: $0)) }) else {
        throw NSError(domain: "Unexpected image import", code: 1)
    }
}
func replaceClipboard(_ items: [NSPasteboardItem]) {
    pb.clearContents(); pb.writeObjects(items); lastTestCount = pb.changeCount
}
func imageData(_ type: UTType = .png, variant: Int) throws -> Data {
    let width = 96 + variant, height = 64
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 0.1 + Double(variant)/10, green: 0.6, blue: 0.5, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "Fixture encoding", code: 1) }
    let result = data as Data
    if let hash = pixelFingerprint(result) { fixturePixels.insert(hash) }
    return result
}
func fileItem(_ url: URL) -> NSPasteboardItem {
    let item = NSPasteboardItem(); item.setString(url.absoluteString, forType: .fileURL); return item
}
let finderFile = fixtures.appendingPathComponent("Finder CmdC_中文测试图.png")
let finderBytes = try imageData(variant: 1)
try finderBytes.write(to: finderFile)
let jpegFile = fixtures.appendingPathComponent("多图复制测试.jpg")
try imageData(.jpeg, variant: 2).write(to: jpegFile)
// Do not let test captures push the user's existing pictures off the line.
try run(["/usr/bin/pkill", "-TERM", "-f", "^/Applications/ImageLine.app/Contents/MacOS/ImageLine$"])
Thread.sleep(forTimeInterval: 0.5)
CFPreferencesSetAppValue("keepOnLine" as CFString, NSNumber(value: 100), domain)
CFPreferencesAppSynchronize(domain)
try run(["/usr/bin/open", "/Applications/ImageLine.app"])
Thread.sleep(forTimeInterval: 0.5)
let baseline = Set(paths())
var failure: Error?
let usesNativeFinder = CommandLine.arguments.contains("--native-finder")
if usesNativeFinder {
    print("READY_FOR_FINDER: \(finderFile.path)")
    fflush(stdout)
    guard readLine() == "copied" else { print("Missing Finder copy signal; no clipboard changes were made"); exit(1) }
} else {
    // NSURL supplies the same modern and legacy file-reference types Finder does.
    pb.clearContents(); pb.writeObjects([finderFile as NSURL])
}
lastTestCount = pb.changeCount
do {
    finderTypes = (pb.types ?? []).map(\.rawValue)
    let imported = try waitForNew(baseline, expected: 1)
    guard imported[0].deletingLastPathComponent() == inbox,
          imported[0] != finderFile,
          try Data(contentsOf: imported[0]) == finderBytes,
          try Data(contentsOf: finderFile) == finderBytes else { throw NSError(domain: "Finder copy did not preserve the original", code: 1) }
    results["finder_file_reference_imports_original_pixels_into_independent_copy"] = true
    var before = Set(paths())
    replaceClipboard([fileItem(finderFile)])
    try unchanged(before)
    results["repeat_copy_does_not_duplicate"] = true
    replaceClipboard([fileItem(finderFile), fileItem(jpegFile)])
    _ = try waitForNew(before, expected: 1)
    results["multi_file_copy_imports_new_image_and_skips_duplicate"] = true
    before = Set(paths())
    replaceClipboard([fileItem(jpegFile)]); try unchanged(before)
    results["repeated_jpeg_conversion_does_not_duplicate"] = true
    try restartInstalledApp()
    replaceClipboard([fileItem(jpegFile)]); try unchanged(before)
    results["duplicate_detection_survives_app_restart"] = true
    let samePixelsTIFF = NSPasteboardItem()
    let source = CGImageSourceCreateWithData(finderBytes as CFData, nil)!
    let tiffBytes = NSMutableData()
    let tiff = CGImageDestinationCreateWithData(tiffBytes, UTType.tiff.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(tiff, CGImageSourceCreateImageAtIndex(source, 0, nil)!, nil)
    guard CGImageDestinationFinalize(tiff) else { throw NSError(domain:"TIFF encoding",code:1) }
    samePixelsTIFF.setData(tiffBytes as Data, forType:.tiff)
    replaceClipboard([samePixelsTIFF]); try unchanged(before)
    results["same_image_in_a_different_clipboard_format_does_not_duplicate"] = true
    try imageData(.jpeg, variant: 5).write(to: jpegFile)
    replaceClipboard([fileItem(jpegFile)]); _ = try waitForNew(before, expected: 1)
    results["same_file_with_changed_image_content_can_be_imported"] = true
    before = Set(paths())
    try FileManager.default.removeItem(at: imported[0])
    replaceClipboard([fileItem(finderFile)]); _ = try waitForNew(before, expected: 1)
    results["removed_image_can_be_copied_again"] = true
    before = Set(paths())
    let office = NSPasteboardItem(); office.setData(finderBytes, forType: .png)
    office.setString("{\\rtf1 Plain text}", forType: .rtf)
    replaceClipboard([office]); try unchanged(before)
    results["office_text_with_picture_preview_is_ignored"] = true
    let own = NSPasteboardItem(); own.setData(finderBytes, forType: .png)
    own.setString(imported[0].absoluteString, forType: .fileURL)
    own.setString("ImageLine", forType: .init("com.baiyuff001.imageline.own-copy"))
    replaceClipboard([own]); try unchanged(before)
    results["app_copy_does_not_reimport"] = true
    let folderIcon = NSPasteboardItem(); folderIcon.setData(finderBytes, forType: .png)
    folderIcon.setString(fixtures.absoluteString, forType: .fileURL)
    replaceClipboard([folderIcon]); try unchanged(before)
    results["folder_icon_is_ignored"] = true
    let direct = NSPasteboardItem(); direct.setData(try imageData(variant: 3), forType: .png)
    replaceClipboard([direct]); _ = try waitForNew(before, expected: 1)
    results["direct_image_clipboard_still_works"] = true
    before = Set(paths())
    let screenshot = inbox.appendingPathComponent("ImageLine-验证截图-\(UUID().uuidString).png")
    let screenBytes = try imageData(variant: 4)
    try screenBytes.write(to: fixtures.appendingPathComponent("截图流程测试.png"))
    testFiles.insert(screenshot)
    try screenBytes.write(to: screenshot)
    _ = try waitForNew(before, expected: 1)
    results["existing_screenshot_folder_pipeline_still_works"] = true
    print("INTEGRATION_PASS: \(results.count) checks")
} catch { failure = error; print("INTEGRATION_FAILURE: \(error)") }

// Stop before restoring the clipboard so it is not treated as a fresh copy.
try run(["/usr/bin/pkill", "-TERM", "-f", "^/Applications/ImageLine.app/Contents/MacOS/ImageLine$"])
Thread.sleep(forTimeInterval: 0.5)
let current = paths().filter { !testFiles.contains(URL(fileURLWithPath: $0)) }
CFPreferencesSetAppValue("pegged" as CFString, current as CFArray, domain)
CFPreferencesSetAppValue("keepOnLine" as CFString, originalKeep, domain)
CFPreferencesAppSynchronize(domain)
for url in testFiles where url.deletingLastPathComponent() == inbox { try? FileManager.default.removeItem(at: url) }
let clipboardWasRestored = pb.changeCount == lastTestCount
if clipboardWasRestored { pb.clearContents(); pb.writeObjects(originalClipboard) }
try run(["/usr/bin/open", "/Applications/ImageLine.app"])
let report: [String: Any] = ["checks":results,"finder_clipboard_types":finderTypes,
    "native_finder_cmd_c_performed":usesNativeFinder,
    "test_images_removed_from_line":true,"clipboard_restored":clipboardWasRestored,
    "private_clipboard_backup_written_to_disk":false,"passed":failure == nil,
    "error":failure.map { String(describing:$0) } ?? ""]
let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
try json.write(to: artifacts.appendingPathComponent("验证记录/运行中应用验证.json"))
if failure != nil { exit(1) }
