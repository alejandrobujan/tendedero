import AppKit
import ApplicationServices

/// The stretches of the menu bar where nothing sits: between the menus on
/// the left and the status items on the right. Resting the pointer there
/// brings the line down; resting it over a menu or an icon does not.
///
/// Recent macOS composites the whole bar into one window, so menus and
/// icons cannot be told apart in the window list. With Accessibility, the
/// menus of the front app are read directly, and every running app is
/// asked for the status items it owns: the leftmost one marks where the
/// cluster begins. The bar repeats itself on every display, so that one
/// distance from the right edge holds for all of them. System icons hang
/// off Control Center at the right end and never sit left of the mark.
/// Without Accessibility nothing is measured: the line comes down from a
/// fixed stretch in the middle of the bar, a quarter of the screen wide.
@MainActor
final class MenuBarSpace {

    static let shared = MenuBarSpace()

    /// A gap has to be this wide to rest the pointer in.
    private static let minimumGap: CGFloat = 32
    /// Idle space always keeps this much distance from the menus and icons
    /// on either side of it.
    private static let edgeInset: CGFloat = 4
    /// One step of the clearance setting until the first sweep answers:
    /// room for two status items and the space between them, so reaching
    /// for the gap without landing exactly in it does not bring the line
    /// down. The sweep then measures the real span, from the leftmost item
    /// to the third one, and that takes over.
    private static let fallbackClearanceUnit: CGFloat = NSStatusItem.squareLength * 2 + 8

    /// How many steps of clearance the idle stretches keep on either side,
    /// from the menu bar's "Bring the line down" menu. One step is two
    /// icons and the space between them; two, the default, is four.
    static var clearanceSteps: Int {
        get {
            guard let stored = UserDefaults.standard.object(forKey: "menuBarClearance") as? Int else { return 2 }
            return min(max(stored, 0), 3)
        }
        set { UserDefaults.standard.set(min(max(newValue, 0), 3), forKey: "menuBarClearance") }
    }
    /// Without a reading, where the menus are assumed to end and where the
    /// status items are assumed to begin, as a fraction of the screen.
    private static let fallbackMenusEdge: CGFloat = 0.45
    private static let fallbackClusterStart: CGFloat = 0.65

    /// An Accessibility call is a round trip to another process, so the
    /// menus are read at most this often.
    private static let readInterval: TimeInterval = 1
    /// Status items move rarely, so the sweep over every running app runs
    /// at most this often, and off the main thread: an app that answers
    /// slowly must not hold the line's tick.
    private static let sweepInterval: TimeInterval = 2

    /// Where the menus of the front app end, in points from the left edge
    /// of the menu bar. nil when they cannot be read.
    private var menusEdge: CGFloat?
    /// Where the status items begin, in points from the right edge of the
    /// screen that hosts them: the leftmost mark known, own item or sweep.
    /// nil when neither has a reading yet.
    private var clusterFromRight: CGFloat?
    /// The sweep's own reading, kept apart so a wide one wins over a
    /// narrower own item without losing either.
    private var sweptClusterFromRight: CGFloat?
    /// The sweep's measure of one clearance step: the span from the leftmost
    /// status item to the third one. nil until a sweep sees three items.
    private var sweptUnit: CGFloat?

    private var lastMenusRead = Date.distantPast
    private var lastMenusApp: pid_t = 0
    private var lastSweep = Date.distantPast
    private var sweepInFlight = false
    /// Whether the idle stretches are measured at all. Without the
    /// Accessibility grant the line falls back to the fixed middle stretch.
    private var accessibilityGranted = false

    private static let sweepQueue = DispatchQueue(label: "MenuBarSpace", qos: .utility)

    /// Freshens the three measurements. The bar repeats itself on every
    /// display, so distances from the edges of one screen hold for all of
    /// them, whatever their width.
    func refresh(statusItemWindow: NSWindow?) {
        accessibilityGranted = AXIsProcessTrusted()
        var fromRight: CGFloat?
        if let window = statusItemWindow, let screen = window.screen {
            fromRight = screen.frame.maxX - window.frame.minX
        }
        if let swept = sweptClusterFromRight { fromRight = max(fromRight ?? 0, swept) }
        clusterFromRight = fromRight

        if accessibilityGranted { sweepClusterIfNeeded() }

        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0
        guard pid != lastMenusApp || Date().timeIntervalSince(lastMenusRead) >= Self.readInterval else { return }
        lastMenusRead = Date()
        lastMenusApp = pid
        menusEdge = accessibilityGranted ? app.flatMap(Self.menuTitlesRightEdge(of:)) : nil
    }

    /// The idle stretches of a screen's menu bar, as ranges of points from
    /// the left edge of the screen. Everything else in the bar is menus or
    /// icons, and resting there does not bring the line down.
    func idleRanges(width: CGFloat) -> [ClosedRange<CGFloat>] {
        // Without Accessibility, the old behaviour: one fixed stretch in
        // the middle of the bar, a quarter of the screen wide.
        guard accessibilityGranted else { return [(width * 0.375) ... (width * 0.625)] }
        let menusEnd = min(menusEdge ?? width * Self.fallbackMenusEdge, width)
        let clusterStart = clusterFromRight.map { max(width - $0, 0) } ?? width * Self.fallbackClusterStart

        // The menus run from the left edge and the status items to the right
        // edge; a crowded bar leaves nothing in between.
        var runs: [ClosedRange<CGFloat>] = [0 ... menusEnd]
        if clusterStart < width { runs.append(clusterStart ... width) }
        runs.sort { $0.lowerBound < $1.lowerBound }

        // Runs that touch, like menus long enough to reach the icons, merge
        // into one and take their gap with them.
        var merged: [ClosedRange<CGFloat>] = []
        for run in runs {
            if let last = merged.last, run.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound ... max(last.upperBound, run.upperBound)
            } else {
                merged.append(run)
            }
        }

        let unit = sweptUnit ?? Self.fallbackClearanceUnit
        let clearance = Self.edgeInset + CGFloat(Self.clearanceSteps) * unit
        return zip(merged, merged.dropFirst()).compactMap { before, after in
            let gap = (before.upperBound + clearance) ... (after.lowerBound - clearance)
            return gap.upperBound - gap.lowerBound >= Self.minimumGap ? gap : nil
        }
    }

    /// Sends one sweep off the main thread. It reads AXExtrasMenuBar of
    /// every app that can own one, accessory apps included, and the
    /// leftmost item it finds is where the cluster begins. Control Center
    /// does not answer, and its icons sit at the right end anyway.
    private func sweepClusterIfNeeded() {
        guard !sweepInFlight, Date().timeIntervalSince(lastSweep) >= Self.sweepInterval else { return }
        lastSweep = Date()
        sweepInFlight = true
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .map(\.processIdentifier)
        Self.sweepQueue.async {
            let reading = Self.statusItemReading(pids: pids)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sweepInFlight = false
                guard let reading,
                      let host = NSScreen.screens.first(where: { $0.frame.minX <= reading.leftmost && reading.leftmost < $0.frame.maxX }) else { return }
                self.sweptClusterFromRight = host.frame.maxX - reading.leftmost
                if let unit = reading.unit, unit > 0 { self.sweptUnit = unit }
            }
        }
    }

    /// The leftmost status item across every running app that owns one, in
    /// global points, and the span from it to the third one — two icons and
    /// the spaces between — or nil when none can be read.
    private nonisolated static func statusItemReading(pids: [pid_t]) -> (leftmost: CGFloat, unit: CGFloat?)? {
        var lefts: [CGFloat] = []
        for pid in pids {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.3)
            var extras: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, "AXExtrasMenuBar" as CFString, &extras) == .success,
                  let extras else { continue }
            for item in statusItems(in: extras) {
                guard let frame = frame(of: item) else { continue }
                lefts.append(frame.minX)
            }
        }
        guard let leftmost = lefts.min() else { return nil }
        let sorted = lefts.sorted()
        let unit = sorted.count >= 3 ? sorted[2] - sorted[0] : nil
        return (leftmost, unit)
    }

    /// AXExtrasMenuBar holds the items directly on older macOS, and
    /// hands over a group that holds them on macOS 27.
    private nonisolated static func statusItems(in value: CFTypeRef) -> [AXUIElement] {
        if CFGetTypeID(value) == CFArrayGetTypeID() {
            let array = value as! CFArray
            return (0 ..< CFArrayGetCount(array)).map { unsafeBitCast(CFArrayGetValueAtIndex(array, $0), to: AXUIElement.self) }
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return [] }
        let container = value as! AXUIElement
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(container, kAXChildrenAttribute as CFString, &children) == .success,
              let children, CFGetTypeID(children) == CFArrayGetTypeID() else { return [] }
        let array = children as! CFArray
        return (0 ..< CFArrayGetCount(array)).map { unsafeBitCast(CFArrayGetValueAtIndex(array, $0), to: AXUIElement.self) }
    }

    /// The right edge of the front app's menus, or nil when they cannot be
    /// read: no Accessibility, no menu bar, or the app did not answer.
    private static func menuTitlesRightEdge(of app: NSRunningApplication) -> CGFloat? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        var menuBar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &menuBar) == .success,
              let menuBar else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return nil }
        var right = CGFloat.zero
        for item in items {
            guard let frame = frame(of: item) else { continue }
            right = max(right, frame.maxX)
        }
        return right > 0 ? right : nil
    }

    /// The frame of an Accessibility element, in global points, top left
    /// origin: the same horizontal scale the menu bar is drawn in.
    private nonisolated static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
