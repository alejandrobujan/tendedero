import AppKit
import QuartzCore
import SwiftUI

/// A mouse-transparent photo that stays up only while its card is held.
/// Its window is separate from Markup's host so fading it cannot hide the editor.
@MainActor
final class PhotoPreview {
    static let slideDistance: CGFloat = 128

    let screen: NSScreen
    let imageFrame: NSRect

    private let window: NSPanel
    private let appearance = PreviewAppearance()
    private var dismissing = false

    init?(url: URL, fallback: NSImage?, on screen: NSScreen) {
        let area = screen.visibleFrame
        let pixels = Int(max(area.width, area.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(url, maxPixels: pixels) ?? fallback,
              image.size.width > 0, image.size.height > 0 else { return nil }
        self.screen = screen
        let maxWidth = max(1, min(area.width * 0.74, area.width - 240))
        let maxHeight = max(1, min(area.height * 0.78, area.height - 100))
        let scale = min(maxWidth / image.size.width, maxHeight / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        imageFrame = NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                            width: size.width, height: size.height)
        let frame = imageFrame.insetBy(dx: -120, dy: -44)
        window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = [.stationary, .ignoresCycle]
        let host = NSHostingView(rootView: PreviewContent(image: image, imageSize: size, appearance: appearance))
        host.sizingOptions = []
        window.contentView = host
        window.setFrame(frame, display: false)
    }

    func show() {
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.13
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func updateSlide(_ distance: CGFloat) {
        appearance.progress = max(0, min(1, distance / Self.slideDistance))
    }

    func prepareForMarkup() {
        appearance.committing = true
    }

    func dismiss() {
        guard !dismissing else { return }
        dismissing = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.11
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            MainActor.assumeIsolated { window.orderOut(nil) }
        })
    }
}

private final class PreviewAppearance: ObservableObject {
    @Published var progress: CGFloat = 0
    @Published var committing = false
}

private struct PreviewContent: View {
    let image: NSImage
    let imageSize: NSSize
    @ObservedObject var appearance: PreviewAppearance
    @State private var hinting = false
    // The pink at the end of the app icon's gradient (#FFBEC4).
    private let pink = Color(red: 1, green: 190.0 / 255, blue: 196.0 / 255)

    var body: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: imageSize.width, height: imageSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 0.75)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.3), lineWidth: 2)
                        .blur(radius: 6)
                )
                .shadow(color: .white.opacity(0.1), radius: 14)
                .shadow(color: .black.opacity(0.22), radius: 28, y: 14)

            Image(systemName: "arrow.right")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(pink)
                .frame(width: 64, height: 48)
                .background(pink.opacity(0.16), in: Capsule())
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.15)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.75)
                )
                .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                .offset(x: imageSize.width / 2 + 56 + (hinting ? 8 : 0) + appearance.progress * 12)
                .opacity(appearance.committing ? 0 : 1)
                .animation(.easeOut(duration: 0.12), value: appearance.committing)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        hinting = true
                    }
                }
        }
        .frame(width: imageSize.width + 240, height: imageSize.height + 88)
        .allowsHitTesting(false)
    }
}
