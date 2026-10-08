import AppKit

// SMLoginItemSetEnabled keeps this tiny, windowless helper alive. Open the
// containing app once at login, unless it is already running.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let parent = (0..<4).reduce(Bundle.main.bundleURL) { url, _ in url.deletingLastPathComponent() }
let parentID = "app.tendedero.Tendedero"
if NSRunningApplication.runningApplications(withBundleIdentifier: parentID).isEmpty {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    NSWorkspace.shared.openApplication(at: parent, configuration: configuration) { _, error in
        if let error { NSLog("Tendedero login helper: %@", error.localizedDescription) }
    }
}
app.run()
