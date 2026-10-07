import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import ImageIO

/// Apple's MobileCLIP, run on this Mac with Core ML. It places pictures and
/// sentences in the same space, so "a pink dress" lands near screenshots
/// showing one even when no text on them says so.
///
/// The models are not in the repository. `scripts/build-app.sh` bundles
/// them when they are in `Models/`. Without them search still works, by text.
final class Clip: @unchecked Sendable {
    private let imageModel: MLModel
    private let textModel: MLModel
    private let tokenizer: ClipTokenizer
    private let lock = NSLock()

    static let side = 256

    /// Loads the models from a folder holding the compiled models and the
    /// tokenizer files. Nil when they are missing.
    init?(folder: URL) {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let image = try? MLModel(contentsOf: folder.appendingPathComponent("mobileclip_s2_image.mlmodelc"), configuration: config),
              let text = try? MLModel(contentsOf: folder.appendingPathComponent("mobileclip_s2_text.mlmodelc"), configuration: config),
              let tokenizer = ClipTokenizer(vocab: folder.appendingPathComponent("clip-vocab.json"),
                                            merges: folder.appendingPathComponent("clip-merges.txt"))
        else { return nil }
        imageModel = image
        textModel = text
        self.tokenizer = tokenizer
    }

    /// The bundled models, if this build has them.
    static func bundled() -> Clip? {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("CLIP") else { return nil }
        return Clip(folder: folder)
    }

    /// Unit length vectors for a screenshot. CLIP sees a square, so a wide
    /// screenshot is seen whole (letterboxed) and as square tiles along its
    /// length, so small things on either side are not lost.
    func embed(imageAt url: URL) -> [[Float]] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1024,
              ] as CFDictionary)
        else { return [] }

        let w = CGFloat(image.width), h = CGFloat(image.height)
        let long = max(w, h), short = min(w, h)
        // Slivers and long strips are mostly padding to CLIP and end up
        // resembling every query. Their text is searchable anyway.
        guard short >= 120, long / short <= 4 else { return [] }
        var views: [CGRect?] = [nil]
        if long / short > 1.3 {
            let tiles = min(3, Int((long / short).rounded(.up)))
            for i in 0..<tiles {
                let offset = (long - short) * CGFloat(i) / CGFloat(tiles - 1)
                views.append(w >= h ? CGRect(x: offset, y: 0, width: short, height: short)
                                    : CGRect(x: 0, y: offset, width: short, height: short))
            }
        }
        return views.compactMap { crop in
            guard let buffer = Self.pixelBuffer(image, crop: crop) else { return nil }
            return predict(imageModel, ["image": MLFeatureValue(pixelBuffer: buffer)])
        }
    }

    /// A unit length vector for a search query.
    func embed(text: String) -> [Float]? {
        let ids = tokenizer.encode(text)
        guard let array = try? MLMultiArray(shape: [1, 77], dataType: .int32) else { return nil }
        for i in 0..<77 { array[i] = NSNumber(value: i < ids.count ? ids[i] : 0) }
        return predict(textModel, ["text": MLFeatureValue(multiArray: array)])
    }

    private func predict(_ model: MLModel, _ inputs: [String: MLFeatureValue]) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: inputs),
              let output = try? model.prediction(from: provider),
              let array = output.featureValue(for: "final_emb_1")?.multiArrayValue else { return nil }
        let v = (0..<array.count).map { Float(truncating: array[$0]) }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : nil
    }

    /// Draws the image, or the cropped part of it, into the 256 pixel square
    /// the model expects. Uncropped, it is fitted on a neutral gray.
    private static func pixelBuffer(_ image: CGImage, crop: CGRect?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGImageCompatibilityKey: true,
                             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        let s = CGFloat(side)
        if let crop, let part = image.cropping(to: crop) {
            context.draw(part, in: CGRect(x: 0, y: 0, width: s, height: s))
        } else {
            context.setFillColor(gray: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: s, height: s))
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let scale = s / max(w, h)
            let fit = CGRect(x: (s - w * scale) / 2, y: (s - h * scale) / 2, width: w * scale, height: h * scale)
            context.draw(image, in: fit)
        }
        return buffer
    }
}

/// CLIP's byte pair encoding tokenizer, the one the text model was trained
/// with: lower case, split into words, each word into learned sub-word pieces.
final class ClipTokenizer {
    private let vocab: [String: Int32]
    private let ranks: [String: Int]
    private let byteToUnicode: [UInt8: Character]
    private var cache: [String: [String]] = [:]
    private let pattern = try! NSRegularExpression(
        pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
        options: [.caseInsensitive])

    static let start: Int32 = 49406
    static let end: Int32 = 49407
    static let context = 77

    init?(vocab vocabURL: URL, merges mergesURL: URL) {
        guard let data = try? Data(contentsOf: vocabURL),
              let vocab = try? JSONDecoder().decode([String: Int32].self, from: data),
              let merges = try? String(contentsOf: mergesURL, encoding: .utf8) else { return nil }
        self.vocab = vocab
        // CLIP uses the first 48,894 merges after the version line.
        let lines = merges.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().prefix(49152 - 256 - 2)
        var ranks: [String: Int] = [:]
        for (i, line) in lines.enumerated() { ranks[String(line)] = i }
        self.ranks = ranks
        byteToUnicode = Self.makeByteToUnicode()
    }

    func encode(_ text: String) -> [Int32] {
        let clean = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var ids: [Int32] = [Self.start]
        let range = NSRange(clean.startIndex..., in: clean)
        for match in pattern.matches(in: clean, range: range) {
            guard let r = Range(match.range, in: clean) else { continue }
            let word = String(String(clean[r]).utf8.compactMap { byteToUnicode[$0] })
            for piece in bpe(word) {
                if let id = vocab[piece] { ids.append(id) }
            }
        }
        ids = Array(ids.prefix(Self.context - 1))
        ids.append(Self.end)
        return ids
    }

    /// Merges the characters of a word, best ranked pair first, until no
    /// learned merge applies. The last piece carries the end of word mark.
    private func bpe(_ word: String) -> [String] {
        if let cached = cache[word] { return cached }
        var parts = word.map(String.init)
        guard !parts.isEmpty else { return [] }
        parts[parts.count - 1] += "</w>"
        while parts.count > 1 {
            var best: (rank: Int, index: Int)?
            for i in 0..<(parts.count - 1) {
                if let rank = ranks[parts[i] + " " + parts[i + 1]], rank < (best?.rank ?? .max) {
                    best = (rank, i)
                }
            }
            guard let best else { break }
            let first = parts[best.index], second = parts[best.index + 1]
            var merged: [String] = []
            var i = 0
            while i < parts.count {
                if i < parts.count - 1 && parts[i] == first && parts[i + 1] == second {
                    merged.append(first + second)
                    i += 2
                } else {
                    merged.append(parts[i])
                    i += 1
                }
            }
            parts = merged
        }
        cache[word] = parts
        return parts
    }

    /// GPT-2's reversible map from bytes to printable characters.
    private static func makeByteToUnicode() -> [UInt8: Character] {
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var chars = bytes
        var n = 0
        for b in 0..<256 where !bytes.contains(b) {
            bytes.append(b)
            chars.append(256 + n)
            n += 1
        }
        var map: [UInt8: Character] = [:]
        for (b, c) in zip(bytes, chars) { map[UInt8(b)] = Character(Unicode.Scalar(c)!) }
        return map
    }
}
