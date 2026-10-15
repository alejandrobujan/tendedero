import AppKit
import Darwin

/// NSCursor.set() alone only changes the app's cursor while our accessory app
/// is inactive. Allow WindowServer updates only while we own a rope interaction.
@MainActor
final class RopeCursor {
    private let setBackground: (Bool) -> Bool
    private var ownsCursor = false
    private var enabledBackground = false

    init(setBackground: @escaping (Bool) -> Bool = BackgroundCursorAccess.setEnabled) {
        self.setBackground = setBackground
    }

    func set(_ cursor: NSCursor) {
        if !ownsCursor { enabledBackground = setBackground(true) }
        ownsCursor = true
        cursor.set()
    }

    func reset() {
        guard ownsCursor else { return }
        // Restore the visible cursor before returning control to the front app.
        NSCursor.arrow.set()
        if enabledBackground { _ = setBackground(false) }
        enabledBackground = false
        ownsCursor = false
    }
}

/// This WindowServer property is undocumented. Resolve it at runtime so a
/// future OS removing it leaves ordinary AppKit cursors and dragging working,
/// rather than preventing the app from launching. No activation or event tap.
private enum BackgroundCursorAccess {
    typealias Connection = @convention(c) () -> Int32
    typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    private static let functions: (Connection, SetProperty)? = {
        guard let library = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let connection = dlsym(library, "CGSMainConnectionID"),
              let property = dlsym(library, "CGSSetConnectionProperty") else { return nil }
        return (unsafeBitCast(connection, to: Connection.self),
                unsafeBitCast(property, to: SetProperty.self))
    }()

    static func setEnabled(_ enabled: Bool) -> Bool {
        guard let (connection, property) = functions else { return false }
        let cid = connection()
        return property(cid, cid, "SetsCursorInBackground" as CFString,
                        enabled ? kCFBooleanTrue! : kCFBooleanFalse!) == 0
    }
}
