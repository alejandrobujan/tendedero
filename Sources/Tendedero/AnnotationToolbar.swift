import SwiftUI

/// The two rows above the picture: the tools, undo and redo; then the
/// stroke width, fill and colours.
struct AnnotationToolbar: View {
    @ObservedObject var state: EditorState

    static let height: CGFloat = 84

    private struct Entry: Identifiable {
        let tool: AnnotationTool
        let symbol: String
        let title: String
        var id: String { symbol }
    }

    private let tools: [Entry] = [
        Entry(tool: .rectangle, symbol: "rectangle", title: L("Rectangle")),
        Entry(tool: .ellipse, symbol: "circle", title: L("Ellipse")),
        Entry(tool: .line, symbol: "line.diagonal", title: L("Line")),
        Entry(tool: .arrow, symbol: "arrow.up.right", title: L("Arrow")),
        Entry(tool: .pen, symbol: "pencil", title: L("Pen")),
        Entry(tool: .highlighter, symbol: "highlighter", title: L("Highlighter")),
        Entry(tool: .mosaic, symbol: "checkerboard.rectangle", title: L("Mosaic")),
        Entry(tool: .text, symbol: "textformat", title: L("Text")),
        Entry(tool: .eraser, symbol: "eraser", title: L("Eraser")),
    ]

    private let dots: [CGFloat] = [3, 6, 10]

    private static let palette: [[UInt32]] = [
        [0x000000, 0x6B7B8C, 0x006400, 0x2020F0, 0x800000, 0xFF69B4, 0xFF8C00, 0x00FFFF],
        [0xFFFFFF, 0x9A9A9A, 0x4CD04C, 0x0A9AEA, 0xFF0000, 0xFFC0CB, 0xFFFF00, 0x00E000],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                ForEach(tools) { entry in
                    iconButton(entry.symbol, selected: state.tool == entry.tool, help: entry.title) {
                        state.tool = entry.tool
                    }
                }
                Divider().frame(height: 22).padding(.horizontal, 6)
                iconButton("arrow.uturn.backward", selected: false, help: L("Undo"), enabled: state.canUndo) {
                    state.onUndo()
                }
                iconButton("arrow.uturn.forward", selected: false, help: L("Redo"), enabled: state.canRedo) {
                    state.onRedo()
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Button { state.widthIndex = index } label: {
                        Circle().fill(Color.primary).frame(width: dots[index], height: dots[index])
                            .frame(width: 32, height: 28)
                            .background(state.widthIndex == index ? Color.accentColor.opacity(0.25) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help(L("Width"))
                }
                iconButton("square.fill", selected: state.filled, help: L("Fill")) {
                    state.filled.toggle()
                }
                Divider().frame(height: 22).padding(.horizontal, 6)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: state.color))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.5), lineWidth: 1))
                    .frame(width: 28, height: 28)
                    .padding(.trailing, 4)
                VStack(spacing: 2) {
                    ForEach(0..<Self.palette.count, id: \.self) { row in
                        HStack(spacing: 2) {
                            ForEach(Self.palette[row], id: \.self) { hex in swatch(hex) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: Self.height)
        .background(.bar)
    }

    private func iconButton(_ symbol: String, selected: Bool, help: String, enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 32, height: 28)
                .background(selected ? Color.accentColor.opacity(0.25) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private func swatch(_ hex: UInt32) -> some View {
        let color = NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                            green: CGFloat((hex >> 8) & 0xFF) / 255,
                            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        return Button { state.color = color } label: {
            Rectangle().fill(Color(nsColor: color))
                .frame(width: 20, height: 20)
                .overlay(Rectangle().stroke(Color.primary.opacity(0.4), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
