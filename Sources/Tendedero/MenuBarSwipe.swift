import AppKit
import CoreGraphics

/// Two-finger swipe down or up while the pointer is in the menu bar. Needs
/// no Accessibility permission: it only watches scroll events, the way the
/// line already watches clicks in the menu bar.
@MainActor
final class MenuBarSwipe {
    enum Direction { case down, up }

    /// When false, events are ignored.
    var isEnabled: () -> Bool = { true }
    /// The screen whose menu bar the pointer was in when the swipe began.
    var onSwipe: ((Direction, NSScreen) -> Void)?

    private var monitors: [Any] = []
    /// Positive is fingers down, negative is fingers up.
    private var accum: CGFloat = 0
    private var tracking = false
    private var fired = false
    private var startScreen: NSScreen?

    /// About a short flick. Small jitter on a resting hand does not reach it.
    private static let threshold: CGFloat = 40
    private static let popupMenuLevel = 101

    func start() {
        stop()
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        reset()
    }

    private func reset() {
        accum = 0
        tracking = false
        fired = false
        startScreen = nil
    }

    private func handle(_ event: NSEvent) {
        guard isEnabled() else {
            reset()
            return
        }
        // Mouse wheels have no gesture phase. Leftover inertia after a
        // page-scroll is momentum, not a swipe of its own.
        guard event.hasPreciseScrollingDeltas,
              !event.phase.isEmpty,
              event.momentumPhase.isEmpty else { return }

        let phase = event.phase
        if phase.contains(.ended) || phase.contains(.cancelled) {
            reset()
            return
        }

        if !tracking, phase.contains(.began) || phase.contains(.changed) {
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, AppDelegate.menuBarBand(of: $0), false) }) {
                tracking = true
                fired = false
                accum = 0
                startScreen = screen
            }
        }

        guard tracking, !fired, phase.contains(.began) || phase.contains(.changed) else { return }
        guard !Self.popupMenuIsOpen() else { return }
        guard abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else { return }

        // scrollingDeltaY follows content scrolling. Natural scrolling
        // inverts it, so undo that to get the way the fingers moved.
        var physicalY = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { physicalY = -physicalY }
        // physicalY < 0: fingers moved down. Net down is positive accum.
        accum += -physicalY

        guard let screen = startScreen else { return }
        if accum >= Self.threshold {
            fired = true
            onSwipe?(.down, screen)
        } else if accum <= -Self.threshold {
            fired = true
            onSwipe?(.up, screen)
        }
    }

    /// A dropped menu lives at the popup-menu window level. Swiping while
    /// one is open would drop the line over it.
    private static func popupMenuIsOpen() -> Bool {
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return info.contains { ($0[kCGWindowLayer as String] as? Int) == popupMenuLevel }
    }
}
