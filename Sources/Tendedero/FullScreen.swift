import AppKit

// The window server knows the type of the Space each display is showing.
// These calls are private but stable for a decade, need no permission, and
// are what window managers like yabai rely on. A full screen Space is type 4.
#if !APP_STORE
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray
#endif

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
        #if APP_STORE
        // The App Store allows no private calls. A full screen app is the
        // one whose window covers the whole display, menu bar included; the
        // window list gives every window's frame without any permission.
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let display = CGDisplayBounds(number)
        let me = ProcessInfo.processInfo.processIdentifier
        return windows.contains { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? pid_t) != me,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return abs(frame.minX - display.minX) < 1 && abs(frame.minY - display.minY) < 1
                && abs(frame.width - display.width) < 1 && abs(frame.height - display.height) < 1
        }
        #else
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
        #endif
    }

    private static func uuidString(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
