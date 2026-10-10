import AppKit
import SwiftUI

/// Synchronous AppKit callbacks already run on the main thread. Swift 5.7
/// lacks assumeIsolated; assert the same contract before erasing isolation.
/// Never use this for callbacks delivered on an unspecified queue.
func onMainThread<T>(_ body: @MainActor () -> T) -> T {
    precondition(Thread.isMainThread)
    return withoutActuallyEscaping(body) { action in
        unsafeBitCast(action, to: (() -> T).self)()
    }
}

/// The panel sets its own frame. Monterey has no sizingOptions switch;
/// disable intrinsic sizing so SwiftUI cannot resize the transparent strip.
final class FixedHostingView<Content: View>: NSHostingView<Content> {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}
