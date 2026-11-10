import AppKit
import SwiftUI

/// A closer look without clicking: resting the pointer on a photo opens a
/// larger copy of it just below the line. Moving along the line, it follows
/// the pointer from one card to the next at once; leaving the line closes
/// it. It is drawn in its own window, because the line's strip is only as
/// tall as the cards, and it never takes a click.
///
/// Ported from upstream PR #65 by Denis Mennesson, without the sticky notes
/// it was built on.
@MainActor
final class Zoom {
    /// Zoom on hover, from the menu bar. Off until chosen.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "zoomOn") }
        set { UserDefaults.standard.set(newValue, forKey: "zoomOn") }
    }

    /// How long the pointer rests on a card before it opens. Long enough
    /// that sweeping across the line does not set it off.
    private static let delay: TimeInterval = 0.35
    /// Crossing the gap between two cards does not close it.
    private static let grace: TimeInterval = 0.15
    /// Room around the card for its shadow.
    private static let margin: CGFloat = 40
    /// Below the card, clear of the Copied label.
    private static let gap: CGFloat = 34
    private static let maxSize = CGSize(width: 560, height: 420)

    private let window: NSPanel
    private let host = NSHostingView(rootView: ZoomView(image: nil, size: .zero))

    private var shownID: UUID?
    private var shownThumb: NSImage?
    private var candidate: UUID?
    private var candidateSince = Date.distantPast
    private var lostSince: Date?
    /// Changes each time it opens, so it grows in again then, and only then.
    private var generation = 0

    init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        host.sizingOptions = []
        window.contentView = host
    }

    /// Called many times a second with the card under the pointer, if any,
    /// and its frame in screen coordinates.
    func update(_ item: Pegged?, card: CGRect?, on screen: NSScreen?) {
        let now = Date()
        guard let item, let card, let screen else {
            candidate = nil
            guard shownID != nil else { return }
            let since = lostSince ?? now
            lostSince = since
            if now.timeIntervalSince(since) >= Self.grace { hide() }
            return
        }
        lostSince = nil
        if let shown = shownID {
            // Still the same card: follow it if the line scrolls.
            if shown == item.id {
                show(item, card: card, on: screen)
                return
            }
            // Another card: close this one and wait again, as for the first.
            hide()
        }
        if candidate != item.id {
            candidate = item.id
            candidateSince = now
        } else if now.timeIntervalSince(candidateSince) >= Self.delay {
            show(item, card: card, on: screen)
        }
    }

    func hide() {
        candidate = nil
        lostSince = nil
        guard shownID != nil else { return }
        shownID = nil
        shownThumb = nil
        window.orderOut(nil)
    }

    private func show(_ item: Pegged, card: CGRect, on screen: NSScreen) {
        let visible = screen.visibleFrame
        // The free space under the line, the same whichever card it is.
        let top = screen.frame.maxY - Layout.panelHeight - Self.gap
        let room = CGSize(width: min(Self.maxSize.width, visible.width - 32),
                          height: min(Self.maxSize.height, top - visible.minY - 32))
        guard room.width > 120, room.height > 120 else { return hide() }

        // A photo in its glass frame, as on the line, never past its own size.
        let photo = item.thumb.size
        guard photo.width > 0, photo.height > 0 else { return hide() }
        let inner = CGSize(width: room.width - Frame.inset * 2, height: room.height - Frame.inset * 2)
        let scale = min(inner.width / photo.width, inner.height / photo.height)
        let size = CGSize(width: photo.width * scale + Frame.inset * 2, height: photo.height * scale + Frame.inset * 2)

        // Always in the middle of the screen, so it does not move from card
        // to card. Lower only on a screen so small it would cover the line.
        let content = CGRect(x: visible.midX - size.width / 2,
                             y: min(visible.midY - size.height / 2, top - size.height),
                             width: size.width, height: size.height)
        let frame = content.insetBy(dx: -Self.margin, dy: -Self.margin).integral

        if item.id != shownID || item.thumb !== shownThumb {
            if shownID == nil { generation += 1 }
            // Drawn again at the larger size, so it stays sharp.
            let pixels = Int(max(size.width, size.height) * screen.backingScaleFactor)
            let image = makeThumbnail(item.url, maxPixels: pixels) ?? item.thumb
            host.rootView = ZoomView(image: image, size: size, generation: generation)
            shownID = item.id
            shownThumb = item.thumb
        }
        if window.frame != frame { window.setFrame(frame, display: true) }
        if !window.isVisible { window.orderFrontRegardless() }
    }
}

struct ZoomView: View {
    let image: NSImage?
    let size: CGSize
    var generation = 0

    var body: some View {
        if let image {
            Grown(generation: generation) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width - Frame.inset * 2, height: size.height - Frame.inset * 2)
                    .clipShape(RoundedRectangle(cornerRadius: Frame.radius - Frame.inset, style: .continuous))
                    .padding(Frame.inset)
                    .glassFrame(cornerRadius: Frame.radius)
                    .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Grows in from the card above it when it opens.
private struct Grown<Content: View>: View {
    let generation: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        Inner(content: content).id(generation)
    }

    private struct Inner: View {
        let content: () -> Content
        @State private var shown = false

        var body: some View {
            content()
                .scaleEffect(shown ? 1 : 0.9, anchor: .top)
                .opacity(shown ? 1 : 0)
                .onAppear {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) { shown = true }
                }
        }
    }
}
