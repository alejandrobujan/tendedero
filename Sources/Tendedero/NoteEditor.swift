import AppKit
import SwiftUI

/// The small window a note is written in: a square of paper you type on,
/// the colours below it, and a button that hangs it. ⌘↩ hangs it too and
/// Escape closes the window without changing anything.
@MainActor
final class NoteEditor: NSObject, NSWindowDelegate {
    static let shared = NoteEditor()

    /// A new note was written and saved; it is ready to hang.
    var onCreated: (URL) -> Void = { _ in }
    /// A note on the line was rewritten.
    var onSaved: (URL) -> Void = { _ in }

    private var window: NSWindow?

    func new() {
        show(nil, text: "", color: Notes.lastColor)
    }

    func edit(_ url: URL) {
        show(url, text: Notes.text(of: url), color: Notes.color(of: url))
    }

    private func show(_ url: URL?, text: String, color: NoteColor) {
        window?.close()
        let draft = NoteDraft(text: text, color: color)
        let view = NoteEditorView(
            draft: draft, isNew: url == nil,
            onDone: { [weak self] in self?.finish(url, draft) },
            onCancel: { [weak self] in self?.window?.close() })

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = url == nil ? L("New Note") : L("Edit Note")
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// An empty note is never saved: a new one is simply not hung, and an
    /// existing one keeps what it said.
    private func finish(_ url: URL?, _ draft: NoteDraft) {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        window?.close()
        guard !text.isEmpty else { return }
        Notes.lastColor = draft.color
        if let url {
            if Notes.write(text, color: draft.color, to: url) { onSaved(url) }
        } else if let url = Notes.create(text, color: draft.color) {
            onCreated(url)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        window = nil
    }
}

final class NoteDraft: ObservableObject {
    @Published var text: String
    @Published var color: NoteColor

    init(text: String, color: NoteColor) {
        self.text = text
        self.color = color
    }
}

struct NoteEditorView: View {
    @ObservedObject var draft: NoteDraft
    let isNew: Bool
    let onDone: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    private static let side: CGFloat = 250

    private var isEmpty: Bool {
        draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            paper
            HStack(spacing: 10) {
                ForEach(NoteColor.allCases, id: \.self) { color in
                    swatch(color)
                }
                Spacer()
                Button(L("Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? L("Hang") : L("Save"), action: onDone)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(isEmpty)
            }
            .frame(width: Self.side)
        }
        .padding(.horizontal, 26)
        .padding(.top, 36)
        .padding(.bottom, 22)
        .onAppear { focused = true }
    }

    /// Typed on directly, in the same handwriting as on the line. It stays
    /// light in dark mode, like paper does.
    private var paper: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: draft.color.paper)
            if draft.text.isEmpty {
                Text(L("Write something…"))
                    .font(.custom(Notes.fontName, size: 20))
                    .foregroundStyle(Color.black.opacity(0.32))
                    .padding(.horizontal, 19)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $draft.text)
                .font(.custom(Notes.fontName, size: 20))
                .foregroundStyle(Color.black.opacity(0.85))
                .scrollContentBackground(.hidden)
                .padding(14)
                .focused($focused)
        }
        .environment(\.colorScheme, .light)
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 9, y: 5)
        .animation(.easeOut(duration: 0.2), value: draft.color)
    }

    private func swatch(_ color: NoteColor) -> some View {
        let selected = draft.color == color
        return Button { draft.color = color } label: {
            Circle()
                .fill(Color(nsColor: color.paper))
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(Color.black.opacity(0.15), lineWidth: 0.5))
                .padding(3)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: selected ? 2 : 0))
        }
        .buttonStyle(.plain)
        .help(color.name)
        .accessibilityLabel(color.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
