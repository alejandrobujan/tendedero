import AppKit
import SwiftUI

/// Where copied text and links are kept: next to the screenshots folder, not
/// in it, so a note is known by where it lives and never mixed with captures.
enum NoteFolder {
    /// Fixed, so it stays put even if screenshots ever go somewhere else.
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Tendedero/Notes", isDirectory: true)

    static func contains(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == Self.url.standardizedFileURL.path
    }

}

/// What a copied text shows on the line: its first line as a title, the
/// rest as the body, or the whole of it as code, and when it was copied.
struct Note {
    var title: String
    var body: String
    var code: Bool
    var date: Date
    /// A copy that is just a web address hangs as a link: its site and path.
    var link: URL? = nil

    /// Read once per thumbnail and kept, so drawing the line never touches
    /// the disk.
    @MainActor private static var cache: [URL: Note] = [:]

    @MainActor static func cached(_ url: URL) -> Note? {
        if let note = cache[url] { return note }
        return reload(url)
    }

    @MainActor @discardableResult static func reload(_ url: URL) -> Note? {
        guard let note = read(url) else { return nil }
        cache[url] = note
        return note
    }

    private static func read(_ url: URL) -> Note? {
        var text: String
        var monospaced = false
        if url.pathExtension.lowercased() == "rtf" {
            guard let data = try? Data(contentsOf: url),
                  let rich = NSAttributedString(rtf: data, documentAttributes: nil) else { return nil }
            text = rich.string
            if rich.length > 0, let font = rich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                monospaced = font.isFixedPitch
            }
        } else {
            // Decoded whole, then cut: cutting the bytes first could split a
            // character in two and fail the whole note.
            guard let data = try? Data(contentsOf: url) else { return nil }
            text = String(decoding: data, as: UTF8.self)
        }
        text = String(text.prefix(4000))
        let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let link = webAddress(trimmed), let host = link.host {
            let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            return Note(title: site, body: trimmed, code: false, date: date, link: link)
        }
        if monospaced || looksLikeCode(trimmed) {
            return Note(title: "", body: trimmed, code: true, date: date)
        }
        let lines = trimmed.components(separatedBy: .newlines)
        let title = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        // A title is short. A long first line is the start of a paragraph,
        // as most copied text is: then it all reads as body.
        if title.count > titleLimit {
            return Note(title: "", body: trimmed, code: false, date: date)
        }
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Note(title: title, body: body, code: false, date: date)
    }

    /// About two lines of a card in bold.
    private static let titleLimit = 60

    /// The whole copy is one web address, and nothing else.
    static func webAddress(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.range.length == (text as NSString).length,
              let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// What follows the site, for the line under it: "/reel/DfhgD7X". The
    /// query is left out: it is mostly tracking. Copying and opening keep it.
    var linkPath: String {
        guard let path = link?.path, path != "/" else { return "" }
        return path
    }

    /// Several lines that are indented, end like code or are full of the
    /// symbols prose rarely uses.
    private static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return false }
        let codeLike = lines.filter { line in
            line.hasPrefix("  ") || line.hasPrefix("\t")
                || ["{", "}", ";", "\\", ")", "=>", "->"].contains { line.hasSuffix($0) }
        }
        let symbols = text.filter { "{}[]();=<>$#|\\".contains($0) }.count
        return codeLike.count * 2 >= lines.count || symbols * 12 >= text.count
    }

    /// "Today, 16:02", in the language the menus speak.
    var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }
}

/// A sheet from Notes: the yellow band, the perforation it was torn along,
/// the title in bold and the date in grey. It sits inside the same glass
/// frame as a photo, and follows the system's light or dark appearance.
struct NoteSheet: View {
    let note: Note
    let width: CGFloat
    /// The height the line gives it; none to take what the text needs.
    var height: CGFloat? = nil

    @Environment(\.colorScheme) private var scheme

    /// Everything is drawn for a card 136 points wide and scaled from there.
    private var u: CGFloat { width / 136 }
    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LinearGradient(colors: [Color(red: 1, green: 0.886, blue: 0.49), Color(red: 0.973, green: 0.788, blue: 0.235)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 9 * u)
            Line()
                .stroke(dark ? Color(white: 0.42) : Color(red: 0.78, green: 0.76, blue: 0.71),
                        style: StrokeStyle(lineWidth: 1.3 * u, lineCap: .round, dash: [0, 3.4 * u]))
                .frame(height: 1.3 * u)
                .padding(.horizontal, 6 * u)
                .padding(.top, 2.5 * u)
            VStack(alignment: .leading, spacing: 3 * u) {
                if note.link != nil {
                    HStack(spacing: 4 * u) {
                        Image(systemName: "link")
                            .font(.system(size: 9.5 * u, weight: .semibold))
                            .foregroundStyle(dark ? Color(red: 0.9, green: 0.706, blue: 0.133) : Color(red: 0.788, green: 0.604, blue: 0))
                        Text(note.title)
                            .font(.system(size: 11.5 * u, weight: .bold))
                            .foregroundStyle(dark ? Color(white: 0.96) : Color(white: 0.11))
                            .lineLimit(1)
                    }
                    .layoutPriority(1)
                    if !note.linkPath.isEmpty {
                        Text(note.linkPath)
                            .font(.system(size: 8.5 * u))
                            .foregroundStyle(dark ? Color.white.opacity(0.6) : Color(white: 0.45))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else if note.code {
                    Text(note.body)
                        .font(.system(size: 7.5 * u, design: .monospaced))
                        .foregroundStyle(dark ? Color(white: 0.96) : Color(white: 0.11))
                        .lineSpacing(1.2 * u)
                        // Code keeps its lines whole and is cut at the edge.
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: width - 28 * u, alignment: .leading)
                        .clipped()
                        .padding(5 * u)
                        .background(RoundedRectangle(cornerRadius: 4 * u, style: .continuous)
                            .fill(dark ? Color(white: 0.17) : Color(red: 0.95, green: 0.95, blue: 0.97)))
                        .layoutPriority(0)
                } else {
                    if !note.title.isEmpty {
                        Text(note.title)
                            .font(.system(size: (note.body.isEmpty ? 12.5 : 11) * u, weight: .bold))
                            .foregroundStyle(dark ? Color(white: 0.96) : Color(white: 0.11))
                            .lineLimit(3)
                            .layoutPriority(1)
                    }
                    if !note.body.isEmpty {
                        Text(linked(note.body))
                            // Without a title, the words are the note: a little bigger.
                            .font(.system(size: (note.title.isEmpty ? 9.5 : 8.5) * u))
                            .foregroundStyle(dark ? Color.white.opacity(0.75) : Color(white: 0.24))
                            .lineSpacing(1 * u)
                            .layoutPriority(0)
                    }
                }
                Spacer(minLength: 0)
                Text(note.dateText)
                    .font(.system(size: 7.5 * u))
                    .foregroundStyle(Color(red: 0.557, green: 0.557, blue: 0.576))
                    .lineLimit(1)
                    .layoutPriority(2)
            }
            .padding(.top, 5 * u)
            .padding(.horizontal, 9 * u)
            .padding(.bottom, 7 * u)
        }
        .frame(width: width, height: height, alignment: .top)
        .background(dark ? Color(white: 0.118) : Color.white)
    }

    /// Links in the yellow Notes uses for them.
    private func linked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].foregroundColor = dark ? Color(red: 0.9, green: 0.706, blue: 0.133) : Color(red: 0.788, green: 0.604, blue: 0)
            result[lower..<upper].underlineStyle = .single
        }
        return result
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        }
    }
}

/// The note as a picture, measured in pixels like a photo's thumbnail, with
/// the card's shape, for the line and the flight.
@MainActor func noteCard(_ url: URL, maxPixels: Int) -> NSImage? {
    guard let note = Note.reload(url) else { return nil }
    let width = Layout.cardWidth - 14
    let cap = Layout.photoMaxHeight
    let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let scheme: ColorScheme = dark ? .dark : .light
    let natural = ImageRenderer(content: NoteSheet(note: note, width: width).environment(\.colorScheme, scheme))
    natural.proposedSize = ProposedViewSize(width: width, height: nil)
    let height = min(cap, max(width * 0.42, natural.nsImage?.size.height ?? cap))
    let renderer = ImageRenderer(content: NoteSheet(note: note, width: width, height: height).environment(\.colorScheme, scheme))
    renderer.scale = max(1, CGFloat(maxPixels) / width)
    guard let cg = renderer.cgImage else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
