import Foundation
import NaturalLanguage
import Vision

/// What Tendedero knows about one screenshot: the text on it, what it shows,
/// and vectors for searching by meaning. Everything is worked out on this Mac
/// with Vision, NaturalLanguage and MobileCLIP. Nothing is sent anywhere.
struct IndexedShot: Codable {
    let path: String
    let modified: Date
    let created: Date
    /// Recognised text, one line per row of text on screen.
    let text: String
    /// What Vision thinks the picture shows, like "dog" or "receipt".
    let labels: [String]
    /// The text split into short passages, each with a unit length vector.
    let chunks: [String]
    let vectors: [Data]
    /// MobileCLIP vectors of the picture itself, whole and in tiles. Missing
    /// in builds without the model, filled in once it is there.
    var clip: [Data]?
}

struct SearchHit: Identifiable {
    var id: String { url.path }
    let url: URL
    let date: Date
    let score: Double
    /// The line that matched, to show under the thumbnail.
    let snippet: String
}

/// A shot with its words prepared for matching. Kept in memory only.
private struct Entry {
    let shot: IndexedShot
    /// Folded words from the text, labels and file name.
    let words: [String]
    /// The folded text, for matching whole phrases.
    let folded: String

    init(_ shot: IndexedShot) {
        self.shot = shot
        folded = ScreenshotIndex.fold(shot.text)
        let name = (shot.path as NSString).lastPathComponent
        words = Array(Set(ScreenshotIndex.tokens(shot.text + " " + shot.labels.joined(separator: " ") + " " + name)))
    }

    /// Short words must match whole, longer ones may start a longer word,
    /// so "invoice" finds "invoices" but "in" does not find "Incognito".
    func has(_ word: String) -> Bool {
        word.count <= 3 ? words.contains(word) : words.contains { $0.hasPrefix(word) }
    }
}

/// A searchable index of every screenshot Tendedero can see: its own folder,
/// plus earlier screenshots on the Desktop and in the old save location.
/// Kept as one small file in Application Support.
final class ScreenshotIndex: @unchecked Sendable {
    private var shots: [String: Entry] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.tendedero.index", qos: .utility)
    private let store: URL
    /// Separate from the query embedding: NLEmbedding is not thread safe.
    private lazy var indexEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
    private let queryEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
    /// Loaded on the index queue: the models take a moment to load.
    private var clipModel: Clip?
    private var clip: Clip? { lock.withLock { clipModel } }
    /// Vectors of plain descriptions any screenshot partly fits, and how much
    /// each picture resembles them. Some pictures resemble everything; this
    /// is subtracted so they do not top every search. Used on the main thread.
    private var genericVectors: [[Float]]?
    private var bias: [String: (modified: Date, value: Double)] = [:]
    private static let genericCaptions = [
        "a screenshot", "a photo", "an image", "a website", "a document", "some text", "an app",
        "a computer screen", "a person", "a chart", "a chat", "a menu", "a form", "a video", "a page", "a picture",
    ]

    /// Reports (done, total) while indexing, on the main queue.
    var onProgress: ((Int, Int) -> Void)?

    init(store: URL, loadClip: @escaping @Sendable () -> Clip? = { nil }) {
        self.store = store
        queue.async { [self] in
            let model = loadClip()
            lock.withLock { clipModel = model }
            if model == nil { log.notice("MobileCLIP is not in this build; searching by text only") }
        }
        if let data = try? Data(contentsOf: store),
           let saved = try? PropertyListDecoder().decode([IndexedShot].self, from: data) {
            shots = Dictionary(saved.map { ($0.path, Entry($0)) }, uniquingKeysWith: { a, _ in a })
        }
    }

    var count: Int { lock.withLock { shots.count } }

    /// Blocks until queued indexing has finished.
    func waitUntilIdle() { queue.sync {} }

    // MARK: Indexing

    /// Indexes what is new or changed in these folders and forgets files
    /// that are gone. Folders flagged `onlyScreenshots` skip other images.
    func refresh(folders: [(url: URL, onlyScreenshots: Bool)]) {
        queue.async { [self] in
            let fm = FileManager.default
            var seen = Set<String>()
            var todo: [(URL, Date, Date)] = []
            var needClip: [String] = []
            let hasClip = clip != nil
            for folder in folders {
                let urls = (try? fm.contentsOfDirectory(
                    at: folder.url, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
                    options: [.skipsHiddenFiles])) ?? []
                for url in urls where Self.isImage(url) && (!folder.onlyScreenshots || isScreenCapture(url)) {
                    let path = url.standardizedFileURL.path
                    guard seen.insert(path).inserted else { continue }
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                    let modified = values?.contentModificationDate ?? .distantPast
                    let created = values?.creationDate ?? modified
                    let known = lock.withLock { shots[path]?.shot }
                    if known?.modified != modified {
                        todo.append((url, modified, created))
                    } else if hasClip && known?.clip == nil {
                        needClip.append(path)
                    }
                }
            }
            // Newest first, so recent screenshots are searchable soonest.
            todo.sort { $0.2 > $1.2 }

            // Forget files that were deleted or moved somewhere else.
            lock.withLock { shots = shots.filter { seen.contains($0.key) || fm.fileExists(atPath: $0.key) } }
            let total = todo.count + needClip.count
            for (n, (url, modified, created)) in todo.enumerated() {
                report(n, total)
                autoreleasepool {
                    if let shot = analyse(url, modified: modified, created: created) {
                        lock.withLock { shots[shot.path] = Entry(shot) }
                    }
                }
                if n % 20 == 19 { save() }
            }
            // Screenshots read before MobileCLIP was added only need its vectors.
            for (n, path) in needClip.enumerated() {
                report(todo.count + n, total)
                autoreleasepool {
                    guard var shot = lock.withLock({ shots[path]?.shot }) else { return }
                    shot.clip = clipVectors(URL(fileURLWithPath: path))
                    lock.withLock { shots[path] = Entry(shot) }
                }
                if n % 40 == 39 { save() }
            }
            report(total, total)
            if total > 0 { save() }
        }
    }

    /// Indexes one file right away, for example a capture that just landed.
    func add(_ url: URL) {
        queue.async { [self] in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let modified = values?.contentModificationDate ?? Date()
            if let shot = analyse(url, modified: modified, created: values?.creationDate ?? modified) {
                lock.withLock { shots[shot.path] = Entry(shot) }
                save()
            }
        }
    }

    private func report(_ done: Int, _ total: Int) {
        guard total > 0, let onProgress else { return }
        DispatchQueue.main.async { onProgress(done, total) }
    }

    private func analyse(_ url: URL, modified: Date, created: Date) -> IndexedShot? {
        let handler = VNImageRequestHandler(url: url)
        let ocr = VNRecognizeTextRequest()
        ocr.recognitionLevel = .accurate
        ocr.usesLanguageCorrection = true
        ocr.automaticallyDetectsLanguage = true
        let classify = VNClassifyImageRequest()
        do {
            try handler.perform([ocr, classify])
        } catch {
            log.error("Could not read \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let lines = (ocr.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let labels = (classify.results ?? [])
            .filter { $0.confidence >= 0.5 && !Self.genericLabels.contains($0.identifier) }
            .prefix(8)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }

        var chunks = Self.chunk(lines)
        if !labels.isEmpty { chunks.append(labels.joined(separator: ", ")) }
        var keptChunks: [String] = []
        var vectors: [Data] = []
        for chunk in chunks {
            guard let v = indexEmbedding?.vector(for: chunk) else { continue }
            keptChunks.append(chunk)
            vectors.append(Self.pack(v))
        }
        return IndexedShot(path: url.standardizedFileURL.path, modified: modified, created: created,
                           text: lines.joined(separator: "\n"), labels: labels,
                           chunks: keptChunks, vectors: vectors, clip: clipVectors(url))
    }

    private func clipVectors(_ url: URL) -> [Data]? {
        guard let clip else { return nil }
        return clip.embed(imageAt: url).map { v in v.withUnsafeBufferPointer { Data(buffer: $0) } }
    }

    private func save() {
        let all = lock.withLock { shots.values.map(\.shot) }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(all).write(to: store, options: .atomic)
        } catch {
            log.error("Could not save the search index: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Searching

    /// Ranks screenshots by how well they match the query. Words found in
    /// their text count most, rare words more than common ones, and
    /// closeness in meaning fills in the rest. An empty query lists
    /// everything, newest first.
    func search(_ query: String, limit: Int = 60) -> [SearchHit] {
        let all = lock.withLock { Array(shots.values) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return all.sorted { $0.shot.created > $1.shot.created }.prefix(limit).map {
                SearchHit(url: URL(fileURLWithPath: $0.shot.path), date: $0.shot.created, score: 0,
                          snippet: $0.shot.text.split(separator: "\n").first.map(String.init) ?? "")
            }
        }

        let words = Self.tokens(trimmed).filter { !Self.stopWords.contains($0) }
        let phrase = Self.fold(trimmed)
        let q = queryEmbedding?.vector(for: trimmed).map(Self.normalise)

        // How much each picture looks like the query, judged against how much
        // all the others do: a query always has some best match, so only
        // pictures standing clearly above the rest count.
        var looks: [String: Double] = [:]
        if let clip, let qc = clip.embed(text: trimmed) {
            if genericVectors == nil { genericVectors = Self.genericCaptions.compactMap { clip.embed(text: $0) } }
            for entry in all {
                guard let vectors = entry.shot.clip, !vectors.isEmpty else { continue }
                let raw = vectors.map { Self.dot(qc, $0) }.max() ?? 0
                guard raw >= Self.lookFloor else { continue }
                looks[entry.shot.path] = raw - generalLikeness(entry.shot, vectors)
            }
        }
        let lookValues = Array(looks.values)
        let lookMean = lookValues.isEmpty ? 0 : lookValues.reduce(0, +) / Double(lookValues.count)
        let lookSpread = lookValues.isEmpty ? 1
            : max(0.01, sqrt(lookValues.reduce(0) { $0 + ($1 - lookMean) * ($1 - lookMean) } / Double(lookValues.count)))

        // A word on every screenshot says little; a rare one says a lot.
        let n = Double(all.count)
        let weights = words.map { w in Foundation.log((n + 1) / (Double(all.filter { $0.has(w) }.count) + 0.5)) }
        let totalWeight = weights.reduce(0, +)

        var hits: [SearchHit] = []
        for entry in all {
            var keyword = 0.0
            if totalWeight > 0 {
                keyword = zip(words, weights).reduce(0) { $0 + (entry.has($1.0) ? $1.1 : 0) } / totalWeight
            }
            if words.count > 1 && entry.folded.contains(phrase) { keyword += 0.5 }

            var meaning = 0.0
            var bestChunk = ""
            if let q {
                for (chunk, data) in zip(entry.shot.chunks, entry.shot.vectors) {
                    let s = Self.dot(q, data)
                    if s > meaning { meaning = s; bestChunk = chunk }
                }
            }
            let semantic = max(0, meaning - Self.meaningFloor) / (1 - Self.meaningFloor)

            var visual = 0.0
            if let look = looks[entry.shot.path] {
                let z = (look - lookMean) / lookSpread
                visual = min(1, max(0, (z - Self.lookMinZ) / Self.lookZRange))
            }
            let score = keyword + Self.meaningWeight * semantic + Self.lookWeight * visual
            guard score > 0 else { continue }

            let snippet = Self.matchingLine(in: entry.shot.text, words: words)
                ?? (visual > semantic ? entry.shot.labels.joined(separator: ", ") : nil)
                ?? bestChunk.split(separator: "\n").first.map(String.init) ?? ""
            hits.append(SearchHit(url: URL(fileURLWithPath: entry.shot.path), date: entry.shot.created,
                                  score: score, snippet: snippet))
        }
        // Keep what is reasonably close to the best match, so a clear answer
        // is not followed by a page of loose ones.
        let best = hits.map(\.score).max() ?? 0
        return hits.filter { $0.score >= best * Self.relativeCutoff }
            .sorted { ($0.score, $0.date) > ($1.score, $1.date) }
            .prefix(limit).map { $0 }
    }

    /// Cosine similarity of unrelated passages sits around 0.3 to 0.4 with
    /// Apple's sentence embedding, so only what rises above that counts.
    static var meaningFloor = 0.4
    static var meaningWeight = 0.8
    static var relativeCutoff = 0.4
    /// MobileCLIP similarity of a real match rarely drops under this.
    static var lookFloor = 0.15
    /// How many spreads above the average a picture must stand to count,
    /// and over how many more it goes from counting a little to fully.
    static var lookMinZ = 1.5
    static var lookZRange = 2.0
    static var lookWeight = 1.0

    private func generalLikeness(_ shot: IndexedShot, _ vectors: [Data]) -> Double {
        if let cached = bias[shot.path], cached.modified == shot.modified { return cached.value }
        let generic = genericVectors ?? []
        guard !generic.isEmpty else { return 0 }
        let value = generic.map { g in vectors.map { Self.dot(g, $0) }.max() ?? 0 }.reduce(0, +) / Double(generic.count)
        bias[shot.path] = (shot.modified, value)
        return value
    }

    // MARK: Helpers

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]
    /// Labels nearly every screenshot gets, which would only add noise.
    private static let genericLabels: Set<String> = ["screenshot", "document", "text", "material"]

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Words for matching: folded, at least two characters.
    static func tokens(_ s: String) -> [String] {
        fold(s).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
    }

    private static let stopWords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "from", "with", "about", "and", "or", "by",
        "is", "are", "was", "my", "me", "it", "this", "that", "some", "any", "where", "what", "which",
        "screenshot", "screenshots", "screen", "shot", "pic", "picture", "image",
        "el", "la", "los", "las", "un", "una", "de", "del", "en", "con", "por", "para", "que", "y", "o", "captura",
    ]

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Groups lines into passages of about 30 words, the length sentence
    /// embeddings handle well.
    private static func chunk(_ lines: [String]) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var words = 0
        for line in lines {
            current.append(line)
            words += line.split(separator: " ").count
            if words >= 30 {
                chunks.append(current.joined(separator: "\n"))
                current = []
                words = 0
            }
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
    }

    /// The line that contains the most query words.
    private static func matchingLine(in text: String, words: [String]) -> String? {
        guard !words.isEmpty else { return nil }
        var best: (line: String, count: Int)?
        for line in text.split(separator: "\n") {
            let lineWords = tokens(String(line))
            let count = words.filter { w in lineWords.contains { w.count <= 3 ? $0 == w : $0.hasPrefix(w) } }.count
            if count > (best?.count ?? 0) { best = (String(line), count) }
        }
        return best?.line
    }

    private static func normalise(_ v: [Double]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { Float(norm > 0 ? $0 / norm : 0) }
    }

    private static func pack(_ v: [Double]) -> Data {
        normalise(v).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func dot(_ q: [Float], _ data: Data) -> Double {
        data.withUnsafeBytes { raw in
            let v = raw.bindMemory(to: Float.self)
            var sum: Float = 0
            for i in 0..<min(q.count, v.count) { sum += q[i] * v[i] }
            return Double(sum)
        }
    }
}

/// macOS tags real screenshots with an extended attribute, which tells them
/// apart from other images in shared folders like the Desktop.
func isScreenCapture(_ url: URL) -> Bool {
    url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return false }
        return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
    }
}
