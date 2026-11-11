import AppKit
import Vision

/// The words on what hangs, so the line can be searched. A screenshot's are
/// read once with the system's text recognition when it hangs, on this Mac
/// and in the background, and kept on disk with the date of the file they
/// came from. A note's or a link's are its own, read as they are.
///
/// Recognition settings follow JOHN-AMAO's search in #3.
@MainActor
final class SearchIndex {
    private struct Entry: Codable {
        var modified: Double
        var text: String
    }

    private var entries: [String: Entry] = [:]
    private var reading: Set<String> = []
    private var saveWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "app.tendedero.read-text", qos: .utility)
    /// Called when new words arrive, so a search under way sees them.
    var onChange: () -> Void = {}

    private static let defaultFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Tendedero/SearchIndex.json")
    private let file: URL

    init(file: URL? = nil) {
        self.file = file ?? Self.defaultFile
        if let data = try? Data(contentsOf: self.file),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    /// Keeps the words of exactly what hangs: reads what is new or changed,
    /// forgets what left. Cheap when nothing changed.
    func update(_ urls: [URL]) {
        let live = Set(urls.map(\.path))
        let before = entries.count
        entries = entries.filter { live.contains($0.key) }
        if entries.count != before { scheduleSave() }
        for url in urls where !isText(url) { read(url) }
    }

    private func read(_ url: URL) {
        let path = url.path
        guard !reading.contains(path), let modified = Note.modificationDate(url)?.timeIntervalSince1970 else { return }
        if entries[path]?.modified == modified { return }
        reading.insert(path)
        queue.async { [weak self] in
            let text = Self.recognize(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reading.remove(path)
                    self.entries[path] = Entry(modified: modified, text: Self.fold(text ?? ""))
                    self.scheduleSave()
                    self.onChange()
                }
            }
        }
    }

    /// The text in a picture, or in a recording's first frame.
    nonisolated private static func recognize(_ url: URL) -> String? {
        guard let image = makeThumbnail(url, maxPixels: 2400)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return nil
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Whether an item has every word of the search, ignoring case, accents
    /// and width: "menu" finds "Menú".
    func matches(_ url: URL, _ words: [String]) -> Bool {
        let text: String
        if isText(url) {
            guard let note = Note.cached(url) else { return false }
            var parts = [note.title, note.body]
            if let link = note.link { parts += [link.host ?? "", link.path] }
            text = Self.fold(parts.joined(separator: "\n"))
        } else {
            text = entries[url.path]?.text ?? ""
        }
        return words.allSatisfy { text.contains($0) }
    }

    /// The words of a search, folded the same way as what is searched.
    static func words(_ query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Written a moment after the last change, private to the user, like the
    /// screenshots it comes from.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let data = try? JSONEncoder().encode(self.entries) else { return }
            try? FileManager.default.createDirectory(at: self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: self.file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.file.path)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
