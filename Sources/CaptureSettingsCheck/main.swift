import CaptureSettings
import Foundation

/// Checks ThirdPartyCapture against a stand-in preference domain, so a real
/// screenshot app is never touched. scripts/build-app.sh runs this target
/// and stops the build when a check fails. Prints one line per check.

let domain = "com.tendedero.third-party-capture.check"
let key = "screenshotSaveDirectory" as CFString
let promptKey = "askSaveLocation" as CFString
let domainCF = domain as CFString
let app = ThirdPartyCapture.App(
    id: domain, name: "Stand-in",
    preference: .archivedURL(key: "screenshotSaveDirectory"))

/// A second stand-in in the same domain, shaped like Snapzy: a plain string
/// path with a bookmark beside it. It never names a real app's domain.
let pathKey = "exportLocation" as CFString
let bookmarkKey = "exportLocation.bookmark" as CFString
let stringApp = ThirdPartyCapture.App(
    id: domain, name: "String stand-in",
    preference: .stringPath(key: "exportLocation", bookmarkKey: "exportLocation.bookmark"))

func fail(_ message: String) -> Never {
    fputs("FAIL \(message)\n", stderr)
    exit(1)
}

func archive(_ folder: URL) -> Data {
    guard let data = try? NSKeyedArchiver.archivedData(
        withRootObject: folder as NSURL, requiringSecureCoding: true) else {
        fail("could not archive \(folder.path)")
    }
    return data
}

func stored() -> Data? {
    CFPreferencesCopyAppValue(key, domainCF) as? Data
}

func storedString() -> String? {
    CFPreferencesCopyAppValue(pathKey, domainCF) as? String
}

func storedBookmark() -> Data? {
    CFPreferencesCopyAppValue(bookmarkKey, domainCF) as? Data
}

@main
enum CheckThirdParty {
    static func main() throws {
        try run()
    }
}

private func run() throws {
let own = FileManager.default.temporaryDirectory
    .appendingPathComponent("tendedero-own-\(UUID().uuidString)", isDirectory: true)
defer {
    CFPreferencesSetAppValue(key, nil, domainCF)
    CFPreferencesSetAppValue(pathKey, nil, domainCF)
    CFPreferencesSetAppValue(bookmarkKey, nil, domainCF)
    CFPreferencesSetAppValue(promptKey, nil, domainCF)
    CFPreferencesSetAppValue("plainPath" as CFString, nil, domainCF)
    CFPreferencesAppSynchronize(domainCF)
    try? FileManager.default.removeItem(at: own)
    UserDefaults.standard.removeObject(forKey: "thirdPartyCaptureSaved")
}
try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: Inbox.folder, withIntermediateDirectories: true)
CFPreferencesSetAppValue(key, nil, domainCF)
CFPreferencesAppSynchronize(domainCF)
UserDefaults.standard.removeObject(forKey: "thirdPartyCaptureSaved")

// A folder the app already had comes back unchanged, not re-archived.
let before = archive(own)
CFPreferencesSetAppValue(key, before as CFData, domainCF)
CFPreferencesAppSynchronize(domainCF)
ThirdPartyCapture.apply(to: app)
if ThirdPartyCapture.saveDirectory(of: app)?.standardizedFileURL != Inbox.folder.standardizedFileURL {
    fail("apply did not point the app at Tendedero")
}
ThirdPartyCapture.restore(app)
if stored() != before { fail("restore changed the folder the app had") }
print("restore keeps the previous folder")

// No key means the app's own default. Turning the option off removes the key.
CFPreferencesSetAppValue(key, nil, domainCF)
CFPreferencesAppSynchronize(domainCF)
UserDefaults.standard.removeObject(forKey: "thirdPartyCaptureSaved")
ThirdPartyCapture.apply(to: app)
if ThirdPartyCapture.saveDirectory(of: app)?.standardizedFileURL != Inbox.folder.standardizedFileURL {
    fail("apply did not point an unset app at Tendedero")
}
ThirdPartyCapture.restore(app)
if stored() != nil { fail("restore left Tendedero's folder where none was set") }
print("restore clears a folder that was never set")

// A folder the user picks while the option is on is left alone.
UserDefaults.standard.removeObject(forKey: "thirdPartyCaptureSaved")
ThirdPartyCapture.apply(to: app)
let moved = archive(own)
CFPreferencesSetAppValue(key, moved as CFData, domainCF)
CFPreferencesAppSynchronize(domainCF)
ThirdPartyCapture.restore(app)
if stored() != moved { fail("restore overwrote a folder the user chose") }
print("restore leaves a folder the user moved")

// A plain string path comes back as that exact string, and its bookmark
// bytes come back with it. Nothing is re-archived.
let previous = own.path
let bookmark = Data("bookmark-bytes".utf8)
CFPreferencesSetAppValue(pathKey, previous as CFString, domainCF)
CFPreferencesSetAppValue(bookmarkKey, bookmark as CFData, domainCF)
CFPreferencesAppSynchronize(domainCF)
UserDefaults.standard.removeObject(forKey: "thirdPartyCaptureSaved")
ThirdPartyCapture.apply(to: stringApp)
if ThirdPartyCapture.saveDirectory(of: stringApp)?.standardizedFileURL != Inbox.folder.standardizedFileURL {
    fail("apply did not point the string app at Tendedero")
}
if storedBookmark() != nil { fail("apply left the stale bookmark in place") }
ThirdPartyCapture.restore(stringApp)
if storedString() != previous { fail("restore changed the string path the app had") }
if storedBookmark() != bookmark { fail("restore changed the bookmark the app had") }
print("restore keeps the previous string path and bookmark")

// An unset string key is the app's own default, so it is removed again.
CFPreferencesSetAppValue(pathKey, nil, domainCF)
CFPreferencesSetAppValue(bookmarkKey, nil, domainCF)
CFPreferencesAppSynchronize(domainCF)
UserDefaults.standard.removeObject(forKey: "thirdPartyCaptureSaved")
ThirdPartyCapture.apply(to: stringApp)
if storedString() == nil { fail("apply did not set a string path") }
ThirdPartyCapture.restore(stringApp)
if storedString() != nil { fail("restore left a string path where none was set") }
if storedBookmark() != nil { fail("restore left a bookmark where none was set") }
print("restore clears a string path that was never set")

// A path the user picks while the option is on is left alone.
UserDefaults.standard.removeObject(forKey: "thirdPartyCaptureSaved")
ThirdPartyCapture.apply(to: stringApp)
let chosen = own.appendingPathComponent("chosen").path
CFPreferencesSetAppValue(pathKey, chosen as CFString, domainCF)
CFPreferencesAppSynchronize(domainCF)
ThirdPartyCapture.restore(stringApp)
if storedString() != chosen { fail("restore overwrote a string path the user chose") }
print("restore leaves a string path the user moved")

// A snapshot that was lost must not delete the folder the app still has.
let kept = archive(own)
CFPreferencesSetAppValue(key, kept as CFData, domainCF)
CFPreferencesAppSynchronize(domainCF)
UserDefaults.standard.set([domain: ["present": true]], forKey: "thirdPartyCaptureSaved")
ThirdPartyCapture.restore(app)
if stored() != kept { fail("restore deleted a folder whose snapshot was lost") }
print("restore keeps a folder when the snapshot is missing")

let keptPath = own.path
let keptBookmark = Data("kept-bookmark".utf8)
CFPreferencesSetAppValue(pathKey, keptPath as CFString, domainCF)
CFPreferencesSetAppValue(bookmarkKey, keptBookmark as CFData, domainCF)
CFPreferencesAppSynchronize(domainCF)
UserDefaults.standard.set([domain: ["present": true]], forKey: "thirdPartyCaptureSaved")
ThirdPartyCapture.restore(stringApp)
if storedString() != keptPath { fail("restore deleted a string path whose snapshot was lost") }
if storedBookmark() != keptBookmark { fail("restore deleted a bookmark whose snapshot was lost") }
print("restore keeps a string path when the snapshot is missing")

// A plain path with no bookmark beside it, which is how Clip stores its
// folder. What lands is the path as a string, never an archived URL, and the
// empty bookmark key is never written.
let plainKey = "plainPath" as CFString
let plainApp = ThirdPartyCapture.App(
    id: domain, name: "Plain stand-in",
    preference: .stringPath(key: "plainPath", bookmarkKey: ""))
let plainBefore = own.appendingPathComponent("plain").path
CFPreferencesSetAppValue(plainKey, plainBefore as CFString, domainCF)
CFPreferencesAppSynchronize(domainCF)
UserDefaults.standard.removeObject(forKey: "thirdPartyCaptureSaved")
ThirdPartyCapture.apply(to: plainApp)
if !(CFPreferencesCopyAppValue(plainKey, domainCF) is String) {
    fail("apply wrote something other than a plain string path")
}
if ThirdPartyCapture.saveDirectory(of: plainApp)?.standardizedFileURL != Inbox.folder.standardizedFileURL {
    fail("apply did not point the plain-path app at Tendedero")
}
if CFPreferencesCopyAppValue("" as CFString, domainCF) != nil {
    fail("apply wrote a value under the empty bookmark key")
}
ThirdPartyCapture.restore(plainApp)
if CFPreferencesCopyAppValue(plainKey, domainCF) as? String != plainBefore {
    fail("restore changed the plain path the app had")
}
print("a plain path with no bookmark round-trips as a string")

// The prompt that keeps screenshots out of a file is turned off, and the
// answer the app had comes back, including when there was none.
let prompted = ThirdPartyCapture.App(
    id: domain, name: "Prompted stand-in",
    preference: .stringPath(key: "plainPath", bookmarkKey: ""), promptKey: "askSaveLocation")
CFPreferencesSetAppValue(plainKey, plainBefore as CFString, domainCF)
CFPreferencesSetAppValue(promptKey, true as CFBoolean, domainCF)
CFPreferencesAppSynchronize(domainCF)
UserDefaults.standard.removeObject(forKey: "thirdPartyCaptureSaved")
ThirdPartyCapture.apply(to: prompted)
if CFPreferencesCopyAppValue(promptKey, domainCF) as? Bool != false {
    fail("apply left the save prompt on")
}
ThirdPartyCapture.restore(prompted)
if CFPreferencesCopyAppValue(promptKey, domainCF) as? Bool != true {
    fail("restore did not put the save prompt back on")
}
print("restore puts the save prompt back")

CFPreferencesSetAppValue(plainKey, plainBefore as CFString, domainCF)
CFPreferencesSetAppValue(promptKey, nil, domainCF)
CFPreferencesAppSynchronize(domainCF)
UserDefaults.standard.removeObject(forKey: "thirdPartyCaptureSaved")
ThirdPartyCapture.apply(to: prompted)
if CFPreferencesCopyAppValue(promptKey, domainCF) as? Bool != false {
    fail("apply did not turn off a save prompt that was unset")
}
ThirdPartyCapture.restore(prompted)
if CFPreferencesCopyAppValue(promptKey, domainCF) != nil {
    fail("restore left a save prompt where none was set")
}
print("restore clears a save prompt that was never set")

// A snapshot from before the prompt was remembered must not delete the
// answer the app still has.
CFPreferencesSetAppValue(promptKey, true as CFBoolean, domainCF)
CFPreferencesAppSynchronize(domainCF)
UserDefaults.standard.set([domain: ["present": true, "path": plainBefore]], forKey: "thirdPartyCaptureSaved")
ThirdPartyCapture.restore(prompted)
if CFPreferencesCopyAppValue(promptKey, domainCF) as? Bool != true {
    fail("restore deleted a save prompt whose snapshot never recorded it")
}
print("restore keeps a save prompt the snapshot did not record")

// A user-added app round-trips through its own JSON file, never the real one.
let json = FileManager.default.temporaryDirectory
    .appendingPathComponent("tendedero-apps-\(UUID().uuidString).json")
defer { try? FileManager.default.removeItem(at: json) }
if ThirdPartyCapture.add(id: "not a bundle id", directoryKey: "saveFolder", bookmarkKey: nil, to: json) == nil {
    fail("a bundle id without segments was accepted")
}
if ThirdPartyCapture.add(id: "com.example.sample", directoryKey: "save folder", bookmarkKey: nil, to: json) == nil {
    fail("a preference key with a space was accepted")
}
if ThirdPartyCapture.add(id: "com.example.sample", directoryKey: "saveFolder", bookmarkKey: nil, to: json) != nil {
    fail("a valid app was rejected")
}
let added = ThirdPartyCapture.userApps(in: json)
if added.count != 1 || added[0].id != "com.example.sample" || added[0].name != "Sample" {
    fail("the added app did not round-trip: \(added.map(\.name))")
}
if case .archivedURL(let key) = added[0].preference {
    if key != "saveFolder" { fail("the preference key came back as \(key)") }
} else {
    fail("the app came back with the wrong preference shape")
}
// A plain string path with no bookmark stays a string path, not an archive.
if ThirdPartyCapture.add(id: "com.example.plain", directoryKey: "saveFolder", bookmarkKey: "", to: json) != nil {
    fail("a plain path with an empty bookmark was rejected")
}
let plain = ThirdPartyCapture.userApps(in: json).first { $0.id == "com.example.plain" }
if case .stringPath(let key, let bookmark) = plain?.preference {
    if key != "saveFolder" || bookmark != "" { fail("the plain path came back changed") }
} else {
    fail("an empty bookmark was stored as an archived URL")
}
if ThirdPartyCapture.add(id: "com.example.bad", directoryKey: "saveFolder", bookmarkKey: "bad key", to: json) == nil {
    fail("a bookmark key with a space was accepted")
}
ThirdPartyCapture.remove(id: "com.example.sample", from: json)
ThirdPartyCapture.remove(id: "com.example.plain", from: json)
if !ThirdPartyCapture.userApps(in: json).isEmpty { fail("the removed app is still stored") }
print("a user-added app round-trips through the JSON file")

print("ok")
}
