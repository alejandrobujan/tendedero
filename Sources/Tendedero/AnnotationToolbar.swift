import SwiftUI

extension AnnotationTool {
    /// Whether the tool draws with a chosen width. For text it is the size.
    var usesWidth: Bool { self != .mosaic && self != .eraser }
    var usesFill: Bool { self == .rectangle || self == .ellipse }
    var usesColor: Bool { usesWidth }
}

/// The tools, in a panel of their own beside the picture. Width, fill and
/// colour show only for the tools that use them.
struct AnnotationToolbar: View {
    @ObservedObject var state: EditorState

    static let width: CGFloat = 136

    private struct Entry: Identifiable {
        let tool: AnnotationTool
        let symbol: String
        let title: String
        var id: String { symbol }
    }

    private let rows: [[Entry]] = [
        [Entry(tool: .rectangle, symbol: "rectangle", title: L("Rectangle")),
         Entry(tool: .ellipse, symbol: "circle", title: L("Ellipse")),
         Entry(tool: .line, symbol: "line.diagonal", title: L("Line"))],
        [Entry(tool: .arrow, symbol: "arrow.up.right", title: L("Arrow")),
         Entry(tool: .pen, symbol: "pencil", title: L("Pen")),
         Entry(tool: .highlighter, symbol: "highlighter", title: L("Highlighter"))],
        [Entry(tool: .mosaic, symbol: "checkerboard.rectangle", title: L("Mosaic")),
         Entry(tool: .text, symbol: "textformat", title: L("Text")),
         Entry(tool: .eraser, symbol: "eraser", title: L("Eraser"))],
    ]

    private let dots: [CGFloat] = [3, 6, 10]

    private static let palette: [[UInt32]] = [
        [0x000000, 0x6B7B8C, 0x006400, 0x2020F0],
        [0x800000, 0xFF69B4, 0xFF8C00, 0x00FFFF],
        [0xFFFFFF, 0x9A9A9A, 0x4CD04C, 0x0A9AEA],
        [0xFF0000, 0xFFC0CB, 0xFFFF00, 0x00E000],
    ]

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 4) {
                ForEach(0..<rows.count, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(rows[row]) { entry in
                            iconButton(entry.symbol, selected: state.tool == entry.tool, help: entry.title) {
                                state.tool = entry.tool
                            }
                        }
                    }
                }
                HStack(spacing: 4) {
                    iconButton("arrow.uturn.backward", selected: false, help: L("Undo"), enabled: state.canUndo) {
                        state.onUndo()
                    }
                    iconButton("arrow.uturn.forward", selected: false, help: L("Redo"), enabled: state.canRedo) {
                        state.onRedo()
                    }
                    Spacer(minLength: 0)
                }
            }

            if state.tool.usesWidth {
                Divider()
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Button { state.widthIndex = index } label: {
                            Circle().fill(Color.primary).frame(width: dots[index], height: dots[index])
                                .frame(width: 36, height: 28)
                                .background(state.widthIndex == index ? Color.accentColor.opacity(0.25) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .help(L("Width"))
                    }
                }
                if state.tool.usesFill {
                    HStack(spacing: 4) {
                        iconButton("square.fill", selected: state.filled, help: L("Fill")) {
                            state.filled.toggle()
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            if state.tool.usesColor {
                VStack(spacing: 4) {
                    ForEach(0..<Self.palette.count, id: \.self) { row in
                        HStack(spacing: 4) {
                            ForEach(Self.palette[row], id: \.self) { hex in swatch(hex) }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: Self.width)
        .background(.regularMaterial)
    }

    private func iconButton(_ symbol: String, selected: Bool, help: String, enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 36, height: 28)
                .background(selected ? Color.accentColor.opacity(0.25) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private func swatch(_ hex: UInt32) -> some View {
        let color = EditorState.color(hex)
        return Button { state.color = color } label: {
            Rectangle().fill(Color(nsColor: color))
                .frame(width: 26, height: 22)
                .overlay(Rectangle().stroke(Color.primary.opacity(0.4), lineWidth: 0.5))
                .overlay(Rectangle().stroke(Color.accentColor, lineWidth: state.color == color ? 2 : 0))
        }
        .buttonStyle(.plain)
    }
}
