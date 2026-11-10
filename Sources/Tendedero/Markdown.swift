import AppKit
import SwiftUI

/// Markdown in a note: headings, lists, checkboxes, quotes, code blocks and,
/// within a line, bold, italic, code, strikethrough and links. The file keeps
/// the Markdown as written, so copying the note gives it back unchanged; only
/// the sheet shows it formatted.
enum Markdown {
    struct Block {
        enum Kind: Equatable {
            case heading(Int)
            case bullet
            case number(String)
            case check(Bool)
            case quote
            case code
            case paragraph
        }
        var kind: Kind
        /// How far a list item is nested.
        var level: Int
        var text: String
    }

    // MARK: Telling it apart

    /// Whether copied text reads as Markdown: some structure, or several
    /// inline marks. A stray asterisk or hash is not enough.
    static func looks(_ text: String) -> Bool {
        var blocks = 0
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.range(of: #"^#{1,6}\s+\S"#, options: .regularExpression) != nil || t.hasPrefix("```") {
                blocks += 2
            } else if t.range(of: #"^([-*+]|\d+[.)])\s+\S"#, options: .regularExpression) != nil
                        || t.range(of: #"^>\s"#, options: .regularExpression) != nil {
                blocks += 1
            }
        }
        let inline = [#"\*\*[^*\n]+\*\*"#, #"__[^_\n]+__"#, #"`[^`\n]+`"#, #"\[[^\]\n]+\]\([^)\s]+\)"#]
            .map { pattern in (try? NSRegularExpression(pattern: pattern))?
                .numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) ?? 0 }
            .reduce(0, +)
        return blocks >= 2 || (blocks >= 1 && inline >= 1) || inline >= 2
    }

    /// A heading's words, when the line is one: "# Shopping" gives "Shopping".
    static func heading(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: #"^#{1,6}\s+"#, options: .regularExpression) else { return nil }
        return String(t[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
    }

    /// Whether a line starts a block that cannot be a title: a list item, a
    /// quote or a code fence.
    static func startsBlock(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("```") || t.hasPrefix(">")
            || t.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) != nil
    }

    // MARK: Reading

    static func blocks(_ text: String) -> [Block] {
        var result: [Block] = []
        var inCode = false
        for raw in text.components(separatedBy: .newlines) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { inCode.toggle(); continue }
            if inCode { result.append(Block(kind: .code, level: 0, text: raw)); continue }
            if t.isEmpty { continue }
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let level = min(indent / 2, 4)
            if let r = t.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let level = t[r].filter { $0 == "#" }.count
                result.append(Block(kind: .heading(level), level: 0, text: String(t[r.upperBound...])))
            } else if let r = t.range(of: #"^[-*+]\s+\[([ xX])\]\s+"#, options: .regularExpression) {
                let done = t[r].contains("x") || t[r].contains("X")
                result.append(Block(kind: .check(done), level: level, text: String(t[r.upperBound...])))
            } else if let r = t.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                result.append(Block(kind: .bullet, level: level, text: String(t[r.upperBound...])))
            } else if let r = t.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                let number = t[r].trimmingCharacters(in: .whitespaces)
                result.append(Block(kind: .number(number), level: level, text: String(t[r.upperBound...])))
            } else if let r = t.range(of: #"^>\s?"#, options: .regularExpression) {
                result.append(Block(kind: .quote, level: 0, text: String(t[r.upperBound...])))
            } else {
                result.append(Block(kind: .paragraph, level: 0, text: t))
            }
        }
        return result
    }

    /// The words of a line with its inline marks read by the system.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// What goes before a block's words: a bullet, a number, a box.
    static func marker(_ block: Block) -> String {
        let indent = String(repeating: "\u{2003}", count: block.level)
        switch block.kind {
        case .bullet: return indent + "•\u{00A0}"
        case .number(let n): return indent + n + "\u{00A0}"
        case .check(let done): return indent + (done ? "☑\u{00A0}" : "☐\u{00A0}")
        case .quote: return "▍\u{00A0}"
        default: return ""
        }
    }

    // MARK: Drawing

    /// For the sheet on the line, at a base size in points.
    static func swiftUI(_ text: String, size: CGFloat, ink: Color, soft: Color, link: Color) -> AttributedString {
        var out = AttributedString()
        for (i, block) in blocks(text).enumerated() {
            if i > 0 { out += AttributedString("\n") }
            var size = size, weight = Font.Weight.regular, color = soft, design = Font.Design.default, italic = false
            switch block.kind {
            case .heading(let level): size *= level == 1 ? 1.3 : level == 2 ? 1.15 : 1.05; weight = .bold; color = ink
            case .code: design = .monospaced; size *= 0.9
            case .quote: italic = true
            default: break
            }
            var marker = AttributedString(marker(block))
            marker.font = .system(size: size, weight: weight, design: design)
            marker.foregroundColor = block.kind == .check(true) ? link : color
            out += marker
            var words = block.kind == .code ? AttributedString(block.text) : inline(block.text)
            for run in words.runs {
                let intent = run.inlinePresentationIntent ?? []
                var font = Font.system(size: size,
                                       weight: intent.contains(.stronglyEmphasized) ? .bold : weight,
                                       design: intent.contains(.code) ? .monospaced : design)
                if italic || intent.contains(.emphasized) { font = font.italic() }
                words[run.range].font = font
                words[run.range].foregroundColor = run.link != nil ? link : color
                if run.link != nil { words[run.range].underlineStyle = .single }
                if intent.contains(.strikethrough) || block.kind == .check(true) {
                    words[run.range].strikethroughStyle = .single
                }
            }
            out += words
        }
        return out
    }

    /// For a note held in front of you: real text that can be selected,
    /// with links that open.
    static func appKit(_ text: String, size: CGFloat, ink: NSColor, soft: NSColor, link: NSColor,
                       lineSpacing: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, block) in blocks(text).enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            var size = size, bold = false, color = soft, mono = false, italic = false
            switch block.kind {
            case .heading(let level): size *= level == 1 ? 1.3 : level == 2 ? 1.15 : 1.05; bold = true; color = ink
            case .code: mono = true; size *= 0.9
            case .quote: italic = true
            default: break
            }
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            style.paragraphSpacingBefore = block.kind == .heading(1) || block.kind == .heading(2) ? size * 0.4 : 0
            let markerText = marker(block)
            // List items wrap under their words, not under the bullet.
            if !markerText.isEmpty {
                let width = (markerText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width
                style.headIndent = width
            }
            func font(bold: Bool, italic: Bool, mono: Bool) -> NSFont {
                var f = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
                             : NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
                if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                return f
            }
            out.append(NSAttributedString(string: markerText, attributes: [
                .font: font(bold: bold, italic: false, mono: mono),
                .foregroundColor: block.kind == .check(true) ? link : color, .paragraphStyle: style]))
            let words = block.kind == .code ? AttributedString(block.text) : inline(block.text)
            for run in words.runs {
                let intent = run.inlinePresentationIntent ?? []
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font(bold: bold || intent.contains(.stronglyEmphasized),
                                italic: italic || intent.contains(.emphasized),
                                mono: mono || intent.contains(.code)),
                    .foregroundColor: color, .paragraphStyle: style,
                ]
                if let url = run.link { attributes[.link] = url }
                if intent.contains(.strikethrough) || block.kind == .check(true) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                out.append(NSAttributedString(string: String(words[run.range].characters), attributes: attributes))
            }
        }
        return out
    }
}
