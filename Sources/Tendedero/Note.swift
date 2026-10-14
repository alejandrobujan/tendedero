import AppKit

/// Sticky notes: a few words hung on the line next to the screenshots.
/// Each one is a plain text file in Tendedero's own folder, so everything the
/// line does with a file (Quick Look, Show in Finder, a drag to a folder, the
/// Trash) works on notes too. The colour travels with the file, in an
/// extended attribute.
enum Notes {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tendedero/Notes", isDirectory: true)
    }()

    /// Handwriting, as on a real note. Falls back to the system font.
    static let fontName = "Noteworthy-Bold"

    /// Nothing else on the line is text: the watchers only pick up images
    /// and recordings.
    static func isNote(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "txt"
    }

    static func text(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The colour new notes start with: the one used last.
    static var lastColor: NoteColor {
        get { NoteColor(rawValue: UserDefaults.standard.string(forKey: "noteColor") ?? "") ?? .yellow }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "noteColor") }
    }

    /// A new file named after the moment it was written, like a screenshot.
    static func create(_ text: String, color: NoteColor) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Note \(formatter.string(from: Date()))"
        var url = folder.appendingPathComponent(base).appendingPathExtension("txt")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension("txt")
            n += 1
        }
        return write(text, color: color, to: url) ? url : nil
    }

    /// An atomic write replaces the file, and its attributes with it, so the
    /// colour is set afterwards.
    @discardableResult
    static func write(_ text: String, color: NoteColor, to url: URL) -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log.error("Could not save note: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return false
        }
        setColor(color, of: url)
        return true
    }

    // MARK: Colour

    private static let colorAttribute = "app.tendedero.note-color"

    static func color(of url: URL) -> NoteColor {
        let raw: String? = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            var buffer = [UInt8](repeating: 0, count: 32)
            let read = getxattr(path, colorAttribute, &buffer, buffer.count, 0, 0)
            return read > 0 ? String(decoding: buffer[..<read], as: UTF8.self) : nil
        }
        return raw.flatMap(NoteColor.init(rawValue:)) ?? .yellow
    }

    static func setColor(_ color: NoteColor, of url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            let bytes = Array(color.rawValue.utf8)
            return setxattr(path, colorAttribute, bytes, bytes.count, 0, 0)
        }
    }

    // MARK: Drawing

    /// The note as it hangs: a square of coloured paper, a little darker
    /// towards the bottom, with the text written on it as large as it fits.
    static func render(_ text: String, color: NoteColor, pixels: Int) -> NSImage? {
        let side = max(64, pixels)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        let s = CGFloat(side)
        let paper = NSRect(x: 0, y: 0, width: s, height: s)
        NSGradient(starting: color.paper.blended(withFraction: 0.18, of: .white) ?? color.paper,
                   ending: color.paper.blended(withFraction: 0.07, of: .black) ?? color.paper)?
            .draw(in: paper, angle: -90)
        // The glued strip along the top, a shade deeper, where the clip grips.
        (color.paper.blended(withFraction: 0.07, of: .white) ?? color.paper).setFill()
        NSRect(x: 0, y: s * 0.86, width: s, height: s * 0.14).fill()

        let string = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return image(rep) }

        // Below the clip, with a margin all round.
        let box = NSRect(x: s * 0.09, y: s * 0.08, width: s * 0.82, height: s * 0.74)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        func attributes(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
            [.font: NSFont(name: fontName, size: size) ?? .systemFont(ofSize: size, weight: .medium),
             .foregroundColor: NSColor(white: 0.13, alpha: 0.9),
             .paragraphStyle: paragraph]
        }
        func measure(_ size: CGFloat) -> NSRect {
            (string as NSString).boundingRect(with: NSSize(width: box.width, height: .greatestFiniteMagnitude),
                                              options: [.usesLineFragmentOrigin],
                                              attributes: attributes(size))
        }
        // A few words are written big; a longer note shrinks to fit, and past
        // the smallest size its end is cut off.
        var size = s * 0.2
        var bounds = measure(size)
        while size > s * 0.075 && bounds.height > box.height {
            size *= 0.92
            bounds = measure(size)
        }
        let height = min(bounds.height, box.height)
        let rect = NSRect(x: box.minX, y: box.midY - height / 2, width: box.width, height: height)
        (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: attributes(size))
        return image(rep)
    }

    private static func image(_ rep: NSBitmapImageRep) -> NSImage {
        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        image.addRepresentation(rep)
        return image
    }
}

/// The colours of the paper, the usual ones of sticky notes.
enum NoteColor: String, CaseIterable {
    case yellow, pink, blue, green

    var paper: NSColor {
        switch self {
        case .yellow: NSColor(srgbRed: 1.00, green: 0.91, blue: 0.47, alpha: 1)
        case .pink: NSColor(srgbRed: 1.00, green: 0.73, blue: 0.81, alpha: 1)
        case .blue: NSColor(srgbRed: 0.69, green: 0.85, blue: 1.00, alpha: 1)
        case .green: NSColor(srgbRed: 0.75, green: 0.92, blue: 0.60, alpha: 1)
        }
    }

    var name: String {
        switch self {
        case .yellow: L("Yellow")
        case .pink: L("Pink")
        case .blue: L("Blue")
        case .green: L("Green")
        }
    }
}
