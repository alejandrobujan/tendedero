import SwiftUI

enum Layout {
    static let panelHeight: CGFloat = 210
    static let ropeTop: CGFloat = 10
    static let spacing: CGFloat = 174
    static let cardWidth: CGFloat = 150
    static let pinAbove: CGFloat = 9.5

    /// The rope hangs as a parabola from edge to edge of the screen.
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = x / width
        return ropeTop + 4 * sag(width: width) * f * (1 - f)
    }

    static func x(index: Int, count: Int, width: CGFloat) -> CGFloat {
        let total = CGFloat(max(count - 1, 0)) * spacing
        return width / 2 - total / 2 + CGFloat(index) * spacing
    }
}

struct LineView: View {
    @ObservedObject var line: Line

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                Rope(width: width)

                if line.items.isEmpty {
                    Hint()
                        .position(x: width / 2, y: Layout.ropeY(x: width / 2, width: width) + 34)
                        .transition(.opacity)
                }

                if line.liveCount > 0 {
                    // Past the last card even on a full line: capacity keeps
                    // the cards clear of the last 100 points of the screen.
                    let x = width - 64
                    ClearAllButton { line.discardAll() }
                        .position(x: x, y: Layout.ropeY(x: x, width: width) + 22)
                        .transition(.opacity)
                }

                ForEach(Array(line.items.enumerated()), id: \.element.id) { index, item in
                    let x = Layout.x(index: index, count: line.items.count, width: width)
                    let ropeY = Layout.ropeY(x: x, width: width)
                    PeggedView(item: item, line: line)
                        .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                        .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: line.items.map(\.id))
            .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
            .animation(.easeInOut(duration: 0.2), value: line.liveCount > 0)
            // Tucked away, the whole line waits above the top edge and slides
            // out from under the menu bar, the way an auto-hiding Dock does.
            .offset(y: line.revealed ? 0 : -(Layout.panelHeight + 12))
            .animation(line.revealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                     : .easeIn(duration: 0.22), value: line.revealed)
        }
        .onPreferenceChange(HitRectsKey.self) { rects in
            line.hitRects = rects
        }
    }
}

private struct Hint: View {
    var body: some View {
        Text(L("Take a screenshot and it will hang here"))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

/// Takes everything off the line in one click.
private struct ClearAllButton: View {
    /// Not a photo, but listed with them so the panel lets clicks through to it.
    static let hitID = UUID()
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Label(L("Clear all"), systemImage: "xmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassFrame(capsule: true)
            .scaleEffect(hovering ? 1.05 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .overlay(ClickArea(action: action))
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: HitRectsKey.self, value: [Self.hitID: g.frame(in: .global)])
                }
            )
            .help(L("Take everything down"))
    }
}

/// Clicks on a panel that never becomes key: like the photos, it takes the
/// first click instead of swallowing it.
private struct ClickArea: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> ClickView { ClickView() }
    func updateNSView(_ view: ClickView, context: Context) { view.action = action }

    final class ClickView: NSView {
        var action: () -> Void = {}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
        }
    }
}

/// A thin, neutral line: a mid gray core with a faint highlight and a soft
/// shadow, so it reads on light and dark backgrounds alike. It fades out at
/// both ends so it seems to come from beyond the screen.
struct Rope: View {
    let width: CGFloat

    private var path: Path {
        Path { p in
            let top = Layout.ropeTop
            p.move(to: CGPoint(x: -20, y: top))
            p.addQuadCurve(
                to: CGPoint(x: width + 20, y: top),
                control: CGPoint(x: width / 2, y: top + 2 * Layout.sag(width: width)))
        }
    }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}

struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
