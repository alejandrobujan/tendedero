import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Thumbnails are the only image data retained on the line. Decode at the
/// largest connected display's scale so moving the line never needs a reload.
@MainActor
func makeThumbnail(_ url: URL, maxPixels: Int? = nil) -> NSImage? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
    let budget: Int
    if let maxPixels {
        guard maxPixels > 0 else { return nil }
        budget = maxPixels
    } else {
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        var height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) { swap(&width, &height) }
        let maxWidth = Layout.cardWidth - 14
        if width > 0, height > 0 {
            let fit = min(maxWidth / width, 104 / height)
            budget = max(1, Int(ceil(max(width, height) * fit * scale)))
        } else {
            budget = max(1, Int(ceil(maxWidth * scale)))
        }
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: budget,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// Keep PNG originals compressed. Other formats are decoded once and encoded
/// straight to PNG, without allocating a TIFF and decoding it again.
func pngData(_ url: URL) -> Data? {
    if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url, options: .mappedIfSafe) }
    guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    if orientation == 1 {
        // Transcode from the source directly instead of creating an additional
        // full-size thumbnail or AppKit bitmap representation.
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(dest, source, 0, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
    let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: sourcePixelSize(source),
    ] as CFDictionary)
    guard let image else { return nil }
    return pngData(image)
}

private func sourcePixelSize(_ source: CGImageSource) -> Int {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
    let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
    return max(1, max(width, height))
}

func pngData(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

/// Markup saves straight to a temporary file, then replaces the original.
/// This avoids retaining a second, encoded copy of a large edited image.
@MainActor
func writePNG(_ image: NSImage, to target: URL) throws {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try writeAtomically(to: target) { temporary in
        guard let dest = CGImageDestinationCreateWithURL(temporary as CFURL,
                UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}

func replaceFileContents(from source: URL, to target: URL) throws {
    try writeAtomically(to: target) { temporary in
        try FileManager.default.copyItem(at: source.resolvingSymlinksInPath(), to: temporary)
    }
}

private func writeAtomically(to target: URL, write: (URL) throws -> Void) throws {
    let fm = FileManager.default
    let temporary = target.deletingLastPathComponent().appendingPathComponent(".tendedero-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: temporary) }
    try write(temporary)
    if fm.fileExists(atPath: target.path) {
        _ = try fm.replaceItemAt(target, withItemAt: temporary)
    } else {
        try fm.moveItem(at: temporary, to: target)
    }
}
