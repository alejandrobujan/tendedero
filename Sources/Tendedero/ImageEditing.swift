import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Lossless pixel operations shared by cut-out and scrolling capture.
enum ImageEditing {
    static let maxPixels = 80_000_000
    static let maxDimension = 32_768

    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              validSize(width: width, height: height) else { return nil }
        // Decode upright files directly: the thumbnail API can reduce 16-bit
        // PNGs to 8 bits even when no resizing or orientation is required.
        if (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1 {
            return CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldAllowFloat: true] as CFDictionary)
        }
        // Apply EXIF orientation before working in top-left pixel coordinates.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func validSize(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maxDimension && height <= maxDimension
            && width <= maxPixels / height
    }

    static func cut(_ image: CGImage, axis: CutAxis, band: CutBand) -> CGImage? {
        let extent = axis == .horizontal ? image.height : image.width
        guard band.start >= 0, band.end <= extent, band.length > 0, band.length < extent else { return nil }
        let width = image.width - (axis == .vertical ? band.length : 0)
        let height = image.height - (axis == .horizontal ? band.length : 0)
        guard let context = context(width: width, height: height, matching: image) else { return nil }
        context.interpolationQuality = .none
        if axis == .horizontal {
            if band.start > 0 {
                guard let top = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: band.start)) else { return nil }
                context.draw(top, in: CGRect(x: 0, y: height - band.start, width: width, height: band.start))
            }
            let remaining = image.height - band.end
            if remaining > 0 {
                guard let bottom = image.cropping(to: CGRect(x: 0, y: band.end, width: image.width, height: remaining)) else { return nil }
                context.draw(bottom, in: CGRect(x: 0, y: 0, width: width, height: remaining))
            }
        } else {
            if band.start > 0 {
                guard let left = image.cropping(to: CGRect(x: 0, y: 0, width: band.start, height: image.height)) else { return nil }
                context.draw(left, in: CGRect(x: 0, y: 0, width: band.start, height: height))
            }
            let remaining = image.width - band.end
            if remaining > 0 {
                guard let right = image.cropping(to: CGRect(x: band.end, y: 0, width: remaining, height: image.height)) else { return nil }
                context.draw(right, in: CGRect(x: band.start, y: 0, width: remaining, height: height))
            }
        }
        return context.makeImage()
    }

    /// Pieces arrive in reading order and are drawn without resampling.
    static func join(_ pieces: [CGImage], axis: ScrollAxis = .vertical) -> CGImage? {
        guard let first = pieces.first else { return nil }
        let vertical = axis == .vertical
        guard pieces.allSatisfy({ vertical ? $0.width == first.width : $0.height == first.height }) else { return nil }
        let width = vertical ? first.width : pieces.reduce(0) { $0 + $1.width }
        let height = vertical ? pieces.reduce(0) { $0 + $1.height } : first.height
        guard let context = context(width: width, height: height, matching: first) else { return nil }
        context.interpolationQuality = .none
        var top = height
        var left = 0
        for piece in pieces {
            top -= piece.height
            context.draw(piece, in: CGRect(x: vertical ? 0 : left, y: vertical ? top : 0,
                                          width: piece.width, height: piece.height))
            left += piece.width
        }
        return context.makeImage()
    }

    static func annotate(_ image: CGImage, from start: CGPoint, to end: CGPoint,
                         rectangle: Bool, color: CGColor) -> CGImage? {
        guard let context = context(width: image.width, height: image.height, matching: image) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let a = CGPoint(x: start.x, y: CGFloat(image.height) - start.y)
        let b = CGPoint(x: end.x, y: CGFloat(image.height) - end.y)
        let stroke = max(3, CGFloat(min(image.width, image.height)) / 180)
        context.setStrokeColor(color)
        context.setLineWidth(stroke)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if rectangle {
            context.stroke(CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                  width: abs(a.x - b.x), height: abs(a.y - b.y)))
        } else {
            context.move(to: a)
            context.addLine(to: b)
            let angle = atan2(b.y - a.y, b.x - a.x)
            let length = min(hypot(b.x - a.x, b.y - a.y) / 3, stroke * 5)
            for turn in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                context.move(to: CGPoint(x: b.x - length * cos(angle + turn),
                                        y: b.y - length * sin(angle + turn)))
                context.addLine(to: b)
            }
            context.strokePath()
        }
        return context.makeImage()
    }

    static func pixels(_ image: CGImage) -> CapturePixels? {
        guard let context = context(width: image.width, height: image.height), let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        return CapturePixels(width: image.width, height: image.height, rgba: bytes)
    }

    /// CGImage.cropping can retain the whole viewport's backing buffer. Copy
    /// the new rows into their own small bitmap before keeping many of them.
    static func compactCrop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        guard let cropped = image.cropping(to: rect),
              let context = context(width: cropped.width, height: cropped.height, matching: image) else { return nil }
        context.interpolationQuality = .none
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return context.makeImage()
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    /// New images use a private file in the inbox, even when inbox mode is off.
    /// The watcher ignores the temporary dotfile until its atomic rename.
    static func saveCopy(_ image: CGImage, name: String) throws -> URL {
        try savePNG(png(image), name: name)
    }

    static func savePNG(_ data: Data, name: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: Inbox.folder, withIntermediateDirectories: true)
        let url = Inbox.folder.appendingPathComponent("\(name) \(UUID().uuidString).png")
        let temporary = Inbox.folder.appendingPathComponent(".image-\(UUID().uuidString).png")
        defer { try? fm.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try fm.moveItem(at: temporary, to: url)
        return url
    }

    private static func context(width: Int, height: Int, matching image: CGImage? = nil) -> CGContext? {
        guard validSize(width: width, height: height) else { return nil }
        if let image {
            guard let space = image.colorSpace else { return nil }
            if space.model == .indexed {
                // Palette entries are 8-bit colours in the base profile;
                // expand their indices before drawing into an editable bitmap.
                guard let base = space.baseColorSpace else { return nil }
                return CGContext(data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: 0, space: base,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            }
            if let exact = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: image.bitsPerComponent, bytesPerRow: 0,
                space: space, bitmapInfo: image.bitmapInfo.rawValue) { return exact }
            // Decoded RGB PNGs can use packed RGB or straight alpha, which
            // Quartz cannot draw into. Retain their profile and component
            // precision in a supported premultiplied layout.
            guard space.model == .rgb || space.model == .monochrome else { return nil }
            let alpha = CGImageAlphaInfo.premultipliedLast.rawValue
            let format = image.bitmapInfo.intersection([.floatComponents, .byteOrderMask]).rawValue | alpha
            return CGContext(data: nil, width: width, height: height,
                bitsPerComponent: max(8, image.bitsPerComponent), bytesPerRow: 0,
                space: space, bitmapInfo: format)
        }
        // Only matching samples are normalized to 8-bit sRGB; saved edits use
        // the source profile and precision above.
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    }
}
