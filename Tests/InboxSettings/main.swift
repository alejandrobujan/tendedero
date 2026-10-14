import Foundation

// Synthetic preferences and temporary directories only: never reads or writes
// com.apple.screencapture or the user's Tendedero defaults.
final class Fixture {
    let root: URL
    let defaults: UserDefaults
    let suite = "app.tendedero.tests.\(UUID().uuidString)"
    var values: [String: Any] = [:]
    var writes = 0
    lazy var settings = makeSettings()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeSettings() -> InboxSettings {
        InboxSettings(defaultFolder: root.appendingPathComponent("Temporary"), defaults: defaults,
                      read: { [unowned self] in self.values[$0] },
                      write: { [unowned self] key, value in
                          self.values[key] = value
                          self.writes += 1
                      })
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

func samePreferences(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
    NSDictionary(dictionary: lhs).isEqual(to: rhs)
}

var passed = 0
func check(_ name: String, _ body: (Fixture) throws -> Void) throws {
    let fixture = try Fixture()
    try body(fixture)
    passed += 1
    print("PASS: \(name)")
}

try check("selecting a custom folder while off does not change screenshot settings") { f in
    f.values = ["location": "/Original", "show-thumbnail": true]
    let original = f.values
    let chosen = f.root.appendingPathComponent("Archive")
    try f.settings.selectFolder(chosen)
    require(f.settings.folder.path == chosen.path, "Selection was not saved")
    require(FileManager.default.fileExists(atPath: chosen.path), "Folder was not created")
    require(f.writes == 0 && samePreferences(f.values, original), "Off mode changed system settings")
    require(f.makeSettings().folder.path == chosen.path, "Selection did not survive a restart")
}

try check("switching directories and resetting preserve the original settings") { f in
    f.values = ["location": "/Original", "location-screenshot": "/OriginalShots",
                "location-screenrecording": "/OriginalVideos", "show-thumbnail": true,
                "target": "clipboard", "target-screenshot": "preview", "target-screenrecording": "file"]
    let original = f.values
    try f.settings.apply()
    f.settings.isEnabled = true
    try f.settings.selectFolder(f.root.appendingPathComponent("Archive A"))
    try f.settings.selectFolder(f.root.appendingPathComponent("Archive B"))
    try f.settings.selectFolder(nil)
    require(f.settings.customFolder == nil, "Reset did not select the default")
    f.settings.restore()
    require(samePreferences(f.values, original), "A managed directory replaced the original settings")
    require(f.defaults.object(forKey: "inboxSavedSettings") == nil, "Restore did not clear its snapshot")
}

try check("restoration removes screenshot keys which were originally absent") { f in
    try f.settings.apply()
    f.settings.restore()
    require(f.values.isEmpty, "Restore did not remove originally absent keys")
}

try check("restarting while applied does not snapshot the app's own destination") { f in
    f.values = ["location": "/Original", "target": "clipboard"]
    let original = f.values
    try f.settings.selectFolder(f.root.appendingPathComponent("Archive"))
    try f.settings.apply()
    f.settings.isEnabled = true
    let restarted = f.makeSettings()
    try restarted.apply()
    restarted.restore()
    require(samePreferences(f.values, original), "Restart lost the original settings")
}

try check("invalid destination leaves the active destination and snapshot untouched") { f in
    f.values = ["location": "/Original"]
    try f.settings.apply()
    f.settings.isEnabled = true
    let original = f.values
    let saved = f.defaults.dictionary(forKey: "inboxSavedSettings")!
    let chosen = f.settings.folder
    let occupied = f.root.appendingPathComponent("Not a folder")
    try Data([1]).write(to: occupied)
    var rejected = false
    do { try f.settings.selectFolder(occupied) } catch { rejected = true }
    require(rejected, "Accepted a regular file as a directory")
    require(f.settings.folder == chosen && samePreferences(f.values, original), "Failure changed the destination")
    require(samePreferences(f.defaults.dictionary(forKey: "inboxSavedSettings")!, saved), "Failure changed the snapshot")
}

try check("user changes outside the app are not overwritten on quit") { f in
    try f.settings.apply()
    f.values["location"] = "/ChangedOutside"
    f.values["location-screenshot"] = "/ChangedOutside"
    let changed = f.values
    f.settings.restore()
    require(samePreferences(f.values, changed), "Quit overwrote an external change")
}

try check("external changes to each capture location key are preserved") { f in
    for key in ["location", "location-screenshot", "location-screenrecording"] {
        f.values = ["location": "/Original"]
        try f.settings.apply()
        f.values[key] = "/ChangedOutside"
        let changed = f.values
        f.settings.restore()
        require(samePreferences(f.values, changed), "Quit overwrote an external change to \(key)")
    }
}

try check("legacy saved settings restore after changing to a custom folder") { f in
    let temporary = f.settings.defaultFolder.path
    f.values = ["location": temporary, "show-thumbnail": false]
    f.defaults.set(["location": "/Original", "thumbnail": true], forKey: "inboxSavedSettings")
    f.settings.isEnabled = true
    try f.settings.selectFolder(f.root.appendingPathComponent("Archive"))
    f.settings.restore()
    require(f.values["location"] as? String == "/Original", "Legacy location was not restored")
    require(f.values["show-thumbnail"] as? Bool == true, "Legacy thumbnail setting was not restored")
}

try check("custom captures remain outside temporary-file cleanup after directory switches") { f in
    let temporary = f.settings.defaultFolder.appendingPathComponent("old.png")
    let archiveA = f.root.appendingPathComponent("Archive A")
    let archiveB = f.root.appendingPathComponent("Archive B")
    try f.settings.selectFolder(archiveA)
    require(f.settings.isTemporaryFile(temporary), "Old default captures lost temporary ownership")
    require(!f.settings.isTemporaryFile(archiveA.appendingPathComponent("kept.png")), "Custom capture became temporary")
    try f.settings.selectFolder(archiveB)
    require(!f.settings.isTemporaryFile(archiveA.appendingPathComponent("kept.png")), "Old custom capture became temporary")
    try f.settings.selectFolder(nil)
    require(!f.settings.isTemporaryFile(archiveB.appendingPathComponent("kept.png")), "Reset made custom captures temporary")
    require(!f.settings.isTemporaryFile(f.root.appendingPathComponent("Temporary-other/file.png")), "Path-prefix sibling was treated as temporary")
}

try check("reject custom destinations inside the temporary folder, including symlinks") { f in
    try f.settings.apply()
    let nested = f.settings.defaultFolder.appendingPathComponent("Archive")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let alias = f.root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
    for destination in [nested, alias] {
        var rejected = false
        do { try f.settings.selectFolder(destination) } catch { rejected = true }
        require(rejected && f.settings.customFolder == nil, "Accepted a custom folder inside temporary storage")
    }
}

print("\(passed) inbox checks passed")
