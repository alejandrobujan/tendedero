import AppKit

// The window server knows the type of the Space each display is showing.
// These calls are private but stable for a decade, need no permission, and
// are what window managers like yabai rely on. A full screen Space is type 4.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray

enum FullScreen {
    private static let fullScreenSpaceType = 4

    /// Whether the line also comes down over full screen apps, so screenshots
    /// stay within reach while you work in one. Off unless turned on: a video
    /// or a presentation should not get a clothesline across the top.
    static var showLineOver: Bool {
        get { UserDefaults.standard.bool(forKey: "showOverFullScreen") }
        set { UserDefaults.standard.set(newValue, forKey: "showOverFullScreen") }
    }

    /// True when the line should keep away from the given screen.
    static func blocksLine(on screen: NSScreen) -> Bool {
        !showLineOver && isActive(on: screen)
    }

    /// True when the given screen is currently showing a full screen app,
    /// like a video or a presentation.
    static func isActive(on screen: NSScreen) -> Bool {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]],
              !displays.isEmpty else { return false }

        // With "Displays have separate Spaces" off there is a single entry
        // that covers every screen.
        let entry: [String: Any]?
        if displays.count == 1 {
            entry = displays.first
        } else {
            let uuid = uuidString(for: screen)
            entry = displays.first { ($0["Display Identifier"] as? String) == uuid }
        }
        let current = entry?["Current Space"] as? [String: Any]
        return (current?["type"] as? Int) == fullScreenSpaceType
    }

    private static func uuidString(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
