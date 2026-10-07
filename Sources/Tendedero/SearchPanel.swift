import AppKit
import SwiftUI

/// Search every screenshot by the words on it or what it shows. Opens with
/// Control Option F as a floating panel, like Spotlight, over any app and
/// any Space. Results work like photos on the line: click to copy, double
/// click to open, press and hold to mark up, drag into an app to send it.
@MainActor
final class SearchController {
    let model: SearchModel
    private let panel: SearchPanel
    /// The app you were in, which gets the focus back when search closes.
    private var previousApp: NSRunningApplication?

    init(index: ScreenshotIndex, line: Line, folders: @escaping () -> [(url: URL, onlyScreenshots: Bool)]) {
        model = SearchModel(index: index, line: line, folders: folders)
        panel = SearchPanel(content: NSHostingView(rootView: SearchView(model: model)))
        model.onClose = { [weak self] restoreFocus in self?.hide(restoringFocus: restoreFocus) }
        // Clicking anywhere else closes search. That app already has the focus.
        panel.onResignKey = { [weak self] in self?.hide(restoringFocus: false) }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        model.refreshIndex()
        model.runSearch(resetSelection: true)
        panel.placeOnScreen(LinePanel.screenUnderPointer())
        // Typing needs Tendedero to be the active app for a moment. The panel
        // joins every Space, so this does not leave a full screen app.
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        model.focusToken += 1
    }

    /// Closes search. After copying, the app you came from gets the focus
    /// back so you can paste straight away.
    func hide(restoringFocus: Bool = true) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if restoringFocus && NSApp.isActive { previousApp?.activate() }
        previousApp = nil
    }
}

/// A panel that takes typing without activating the app, so it opens over a
/// full screen app without switching Spaces, and goes away when you click
/// somewhere else.
final class SearchPanel: NSPanel {
    static let size = NSSize(width: 800, height: 560)

    init(content: NSView) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onResignKey: () -> Void = {}

    override func resignKey() {
        super.resignKey()
        onResignKey()
    }

    /// Centred, a little above the middle, where Spotlight sits.
    func placeOnScreen(_ screen: NSScreen?) {
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(x: visible.midX - Self.size.width / 2,
                             y: visible.minY + visible.height * 0.62 - Self.size.height / 2)
        setFrame(NSRect(origin: origin, size: Self.size), display: false)
    }
}

// MARK: Model

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    @Published private(set) var results: [SearchHit] = []
    @Published var selection = 0
    /// Set when the keyboard moves the selection, to scroll it into view.
    @Published private(set) var scrollTarget: String?
    @Published private(set) var status = ""
    @Published private(set) var indexing: (done: Int, total: Int)?
    @Published private(set) var copiedID: String?
    @Published var focusToken = 0

    static let columns = 4

    let index: ScreenshotIndex
    private let line: Line
    private let folders: () -> [(url: URL, onlyScreenshots: Bool)]
    var onClose: (_ restoreFocus: Bool) -> Void = { _ in }
    private var pending: DispatchWorkItem?

    init(index: ScreenshotIndex, line: Line, folders: @escaping () -> [(url: URL, onlyScreenshots: Bool)]) {
        self.index = index
        self.line = line
        self.folders = folders
        index.onProgress = { [weak self] done, total in
            MainActor.assumeIsolated { self?.progress(done, total) }
        }
    }

    func refreshIndex() {
        index.refresh(folders: folders())
    }

    private func progress(_ done: Int, _ total: Int) {
        indexing = done < total ? (done, total) : nil
        // Show new matches as they are read, without redoing it every file.
        if done == total || done % 10 == 0 { runSearch(resetSelection: false) } else { updateStatus() }
    }

    private func scheduleSearch() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.runSearch(resetSelection: true) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func runSearch(resetSelection: Bool) {
        results = index.search(query)
        if resetSelection { selection = 0 }
        selection = min(selection, max(0, results.count - 1))
        updateStatus()
    }

    private func updateStatus() {
        if let indexing {
            status = L("Reading \(indexing.done + 1) of \(indexing.total)…", "Leyendo \(indexing.done + 1) de \(indexing.total)…")
        } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
            status = L("\(index.count) screenshots", "\(index.count) capturas")
        } else {
            status = results.count == 1 ? L("1 match", "1 resultado")
                                        : L("\(results.count) matches", "\(results.count) resultados")
        }
    }

    // MARK: Actions

    func move(by delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(0, selection + delta), results.count - 1)
        scrollTarget = results[selection].id
    }

    func copy(_ hit: SearchHit) {
        Line.copyToPasteboard(hit.url)
        copiedID = hit.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == hit.id { self?.copiedID = nil }
        }
    }

    /// Return: copy the selected screenshot and get out of the way, ready to paste.
    func copySelectionAndClose() {
        guard results.indices.contains(selection) else { return }
        copy(results[selection])
        onClose(true)
    }

    // Opening something elsewhere closes search and leaves the focus there.

    func open(_ hit: SearchHit) {
        onClose(false)
        NSWorkspace.shared.open(hit.url)
    }

    func markup(_ hit: SearchHit) {
        onClose(false)
        Markup.shared.edit(hit.url)
    }

    func reveal(_ hit: SearchHit) {
        onClose(false)
        NSWorkspace.shared.activateFileViewerSelecting([hit.url])
    }

    func hang(_ hit: SearchHit) {
        line.hang(hit.url)
    }

    func trash(_ hit: SearchHit) {
        do {
            try FileManager.default.trashItem(at: hit.url, resultingItemURL: nil)
            results.removeAll { $0.id == hit.id }
            line.prune()
            refreshIndex()
        } catch {
            log.error("Could not trash \(hit.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    /// After a drag that may have moved the file into a folder.
    func dragEnded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.results.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
            self.refreshIndex()
        }
    }
}

// MARK: Views

struct SearchView: View {
    @ObservedObject var model: SearchModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(L("Search screenshots", "Buscar capturas"), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($fieldFocused)
                    .onSubmit { model.copySelectionAndClose() }
                    .onKeyPress(.downArrow) { model.move(by: SearchModel.columns); return .handled }
                    .onKeyPress(.upArrow) { model.move(by: -SearchModel.columns); return .handled }
                    .onKeyPress(.tab) { model.move(by: 1); return .handled }
                    .onKeyPress(.escape) { model.onClose(true); return .handled }
                Text(model.status)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            if model.results.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .frame(width: SearchPanel.size.width, height: SearchPanel.size.height)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .onChange(of: model.focusToken) { _, _ in fieldFocused = true }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: SearchModel.columns),
                          alignment: .leading, spacing: 18) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { i, hit in
                        ResultCell(hit: hit, model: model, selected: i == model.selection)
                            .id(hit.id)
                            .onHover { inside in if inside { model.selection = i } }
                    }
                }
                .padding(16)
            }
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            if let indexing = model.indexing {
                ProgressView(value: Double(indexing.done), total: Double(max(indexing.total, 1)))
                    .frame(width: 220)
                Text(L("Reading the text on your screenshots…", "Leyendo el texto de tus capturas…"))
                    .foregroundStyle(.secondary)
            } else if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(L("No screenshots yet", "Aún no hay capturas"))
                    .foregroundStyle(.secondary)
            } else {
                Text(L("Nothing matches “\(model.query)”", "Nada coincide con «\(model.query)»"))
                    .foregroundStyle(.secondary)
                Text(L("Try words that appear on the screenshot, or what it shows.",
                       "Prueba con palabras que aparezcan en la captura, o lo que muestra."))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct ResultCell: View {
    let hit: SearchHit
    @ObservedObject var model: SearchModel
    let selected: Bool
    @State private var thumb: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        .padding(8)
                }
                if model.copiedID == hit.id {
                    Text(L("Copied", "Copiado"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .transition(.opacity)
                }
            }
            .frame(height: 124)
            .overlay(ResultGrab(hit: hit, model: model, image: thumb))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5)
            )
            .animation(.easeOut(duration: 0.15), value: model.copiedID)

            Text(hit.snippet.isEmpty ? hit.url.lastPathComponent : hit.snippet)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.tail)
            Text(hit.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .task(id: hit.id) { thumb = await Thumbnails.load(hit.url) }
    }
}

/// The same click, hold and drag handling as photos on the line.
struct ResultGrab: NSViewRepresentable {
    let hit: SearchHit
    let model: SearchModel
    let image: NSImage?

    func makeNSView(context: Context) -> GrabView {
        let view = GrabView()
        view.hasCross = false
        configure(view)
        return view
    }

    func updateNSView(_ view: GrabView, context: Context) {
        configure(view)
    }

    private func configure(_ view: GrabView) {
        let hit = hit
        let model = model
        view.url = hit.url
        view.dragImage = image
        view.onClick = { model.copy(hit) }
        view.onDoubleClick = { model.open(hit) }
        view.onLongPress = { model.markup(hit) }
        view.onTrash = { model.trash(hit) }
        view.onDragEnd = { model.dragEnded() }
        view.menuProvider = {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(L("Copy", "Copiar")) { model.copy(hit) })
            menu.addItem(ClosureMenuItem(L("Open", "Abrir")) { model.open(hit) })
            menu.addItem(ClosureMenuItem(L("Markup", "Marcación")) { model.markup(hit) })
            menu.addItem(ClosureMenuItem(L("Hang on the line", "Colgar en el tendedero")) { model.hang(hit) })
            menu.addItem(ClosureMenuItem(L("Show in Finder", "Mostrar en Finder")) { model.reveal(hit) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Move to Trash", "Mover a la Papelera")) { model.trash(hit) })
            return menu
        }
    }
}

/// Small thumbnails for the results, made off the main thread and kept.
@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func load(_ url: URL) async -> NSImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let cg = await Task.detached(priority: .userInitiated, operation: {
            makeThumbnailImage(url, maxPixels: 420)
        }).value else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key)
        return image
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
