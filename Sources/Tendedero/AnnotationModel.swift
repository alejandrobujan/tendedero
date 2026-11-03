import AppKit
import CoreImage

enum AnnotationTool: CaseIterable {
    case select, rectangle, ellipse, line, arrow, pen, highlighter, mosaic, text, eraser
}

/// One mark on the picture. Points are in image pixels, y growing downward,
/// so a mark means the same thing in the editor window and in the saved file.
struct Annotation {
    let id = UUID()

    enum Kind { case rectangle, ellipse, line, arrow, pen, highlighter, mosaic, text }

    var kind: Kind
    var points: [CGPoint]
    var color: NSColor
    /// Stroke width, in image pixels.
    var width: CGFloat
    var filled = false
    var text = ""
    var fontSize: CGFloat = 0

    mutating func translate(by delta: CGPoint) {
        points = points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
    }
}

/// The picture being marked up, the marks on it, and their history.
/// The original is never touched: marks are drawn over it, and only the
/// export flattens them. A document with no marks has nothing to save.
@MainActor
final class AnnotationDocument {
    let image: CGImage
    let pixelSize: CGSize
    /// Dots per inch of the source file, kept when the result is written.
    let dpi: (CGFloat, CGFloat)?

    private(set) var items: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    /// One screenshot point, in image pixels, as a unit for sizing marks
    /// so they look alike on a small image and on a large one.
    let unit: CGFloat

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasMarks: Bool { !items.isEmpty }

    func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    /// The three stroke widths, and the text size that goes with each.
    var widths: [CGFloat] { [2 * unit, 4 * unit, 7 * unit] }
    var fontSizes: [CGFloat] { [14 * unit, 20 * unit, 30 * unit] }

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        // Asking for a thumbnail as large as the picture is how ImageIO applies
        // the file's orientation, so the pixels match what the line shows.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pixelWidth, pixelHeight, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        self.image = image
        pixelSize = CGSize(width: image.width, height: image.height)
        unit = max(1, CGFloat(max(image.width, image.height)) / 1400)
        if let x = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue,
           let y = (properties?[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue {
            dpi = (CGFloat(x), CGFloat(y))
        } else {
            dpi = nil
        }
    }

    // MARK: History

    /// Applies a change to the marks, remembering how they were.
    func change(_ edit: (inout [Annotation]) -> Void) {
        let before = items
        edit(&items)
        undoStack.append(before)
        redoStack.removeAll()
    }

    /// Changes the marks as part of the step the last change began.
    func amend(_ edit: (inout [Annotation]) -> Void) {
        edit(&items)
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(items)
        items = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
    }

    // MARK: Mosaic

    /// The whole picture pixelated, made once, the first time a mosaic needs
    /// it. A mosaic mark shows the part of it under its rectangle, so what
    /// the file ends up with is the picture's own pixels, blocked.
    private(set) lazy var pixelated: CGImage? = {
        let input = CIImage(cgImage: image)
        let block = max(8, CGFloat(max(image.width, image.height)) / 70)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(block, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage else { return nil }
        let extent = input.extent
        return CIContext().createCGImage(output.cropped(to: extent), from: extent)
    }()

    // MARK: Drawing

    /// Draws the picture and the marks into a context whose origin is the
    /// picture's top left corner and whose units are image pixels.
    func draw(in graphics: NSGraphicsContext, extra: Annotation? = nil, hiding: UUID? = nil) {
        let cg = graphics.cgContext
        let height = pixelSize.height
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        cg.saveGState()
        cg.translateBy(x: 0, y: height)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: CGRect(origin: .zero, size: pixelSize))
        cg.restoreGState()

        for item in items + (extra.map { [$0] } ?? []) where item.id != hiding {
            draw(item, in: graphics)
        }
    }

    private func draw(_ a: Annotation, in graphics: NSGraphicsContext) {
        let cg = graphics.cgContext
        cg.saveGState()
        defer { cg.restoreGState() }

        switch a.kind {
        case .rectangle, .ellipse:
            guard a.points.count >= 2 else { return }
            let rect = Annotation.rect(a.points[0], a.points[1])
            let path = a.kind == .rectangle ? NSBezierPath(rect: rect) : NSBezierPath(ovalIn: rect)
            if a.filled {
                a.color.setFill()
                path.fill()
            } else {
                path.lineWidth = a.width
                path.lineJoinStyle = .round
                a.color.setStroke()
                path.stroke()
            }

        case .line:
            guard a.points.count >= 2 else { return }
            let path = NSBezierPath()
            path.move(to: a.points[0])
            path.line(to: a.points[1])
            path.lineWidth = a.width
            path.lineCapStyle = .round
            a.color.setStroke()
            path.stroke()

        case .arrow:
            guard a.points.count >= 2 else { return }
            drawArrow(from: a.points[0], to: a.points[1], width: a.width, color: a.color)

        case .pen:
            let path = Annotation.smoothPath(a.points)
            path.lineWidth = a.width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            a.color.setStroke()
            path.stroke()

        case .highlighter:
            cg.setBlendMode(.multiply)
            let path = Annotation.smoothPath(a.points)
            path.lineWidth = a.width * 3
            path.lineCapStyle = .butt
            path.lineJoinStyle = .round
            a.color.withAlphaComponent(0.45).setStroke()
            path.stroke()

        case .mosaic:
            guard a.points.count >= 2 else { return }
            let rect = Annotation.rect(a.points[0], a.points[1])
                .intersection(CGRect(origin: .zero, size: pixelSize))
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
            cg.clip(to: rect)
            cg.translateBy(x: 0, y: pixelSize.height)
            cg.scaleBy(x: 1, y: -1)
            if let pixelated {
                cg.draw(pixelated, in: CGRect(origin: .zero, size: pixelSize))
            } else {
                cg.setFillColor(NSColor.gray.cgColor)
                cg.fill(CGRect(origin: .zero, size: pixelSize))
            }

        case .text:
            guard let origin = a.points.first, !a.text.isEmpty else { return }
            NSAttributedString(string: a.text, attributes: Annotation.textAttributes(size: a.fontSize, color: a.color))
                .draw(at: origin)
        }
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, width: CGFloat, color: NSColor) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }
        let head = min(length, width * 3.5 + 10 * unit)
        let angle = atan2(dy, dx)
        let spread: CGFloat = .pi / 7
        // The shaft stops inside the head, so it cannot poke out of the tip.
        let base = CGPoint(x: end.x - cos(angle) * head * 0.7, y: end.y - sin(angle) * head * 0.7)

        let shaft = NSBezierPath()
        shaft.move(to: start)
        shaft.line(to: base)
        shaft.lineWidth = width
        shaft.lineCapStyle = .round
        color.setStroke()
        shaft.stroke()

        let tip = NSBezierPath()
        tip.move(to: end)
        tip.line(to: CGPoint(x: end.x - cos(angle - spread) * head, y: end.y - sin(angle - spread) * head))
        tip.line(to: CGPoint(x: end.x - cos(angle + spread) * head, y: end.y - sin(angle + spread) * head))
        tip.close()
        color.setFill()
        tip.fill()
    }

    // MARK: Hit testing

    /// The marks under a point, topmost first, for the eraser.
    func topmost(at point: CGPoint, tolerance: CGFloat) -> Int? {
        items.indices.reversed().first { items[$0].hits(point, tolerance: tolerance, unit: unit) }
    }

    // MARK: Export

    /// The picture with every mark on it, at the picture's own pixel size.
    func flattened() -> CGImage? {
        let colorSpace: CGColorSpace
        if let own = image.colorSpace, own.model == .rgb {
            colorSpace = own
        } else {
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        }
        guard let cg = CGContext(data: nil, width: image.width, height: image.height,
                                 bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // y down, like the editor, so marks are drawn by the same code.
        cg.translateBy(x: 0, y: pixelSize.height)
        cg.scaleBy(x: 1, y: -1)
        cg.interpolationQuality = .high
        draw(in: NSGraphicsContext(cgContext: cg, flipped: true))
        return cg.makeImage()
    }
}

// MARK: - Geometry

extension Annotation {
    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func textAttributes(size: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color]
    }

    /// A pen stroke through its points, rounded off by curving through the
    /// midpoints between them.
    static func smoothPath(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            // A tap leaves a dot.
            path.line(to: CGPoint(x: first.x + 0.01, y: first.y))
            return path
        }
        var current = first
        if points.count > 2 {
            for i in 1..<(points.count - 1) {
                let control = points[i]
                let end = CGPoint(x: (control.x + points[i + 1].x) / 2, y: (control.y + points[i + 1].y) / 2)
                // A quadratic curve written as the cubic that draws the same line.
                path.curve(to: end,
                           controlPoint1: CGPoint(x: current.x + (control.x - current.x) * 2 / 3,
                                                  y: current.y + (control.y - current.y) * 2 / 3),
                           controlPoint2: CGPoint(x: end.x + (control.x - end.x) * 2 / 3,
                                                  y: end.y + (control.y - end.y) * 2 / 3))
                current = end
            }
        }
        path.line(to: points[points.count - 1])
        return path
    }

    func bounds(unit: CGFloat) -> CGRect {
        switch kind {
        case .text:
            guard let origin = points.first else { return .null }
            let size = (text as NSString).size(withAttributes: Annotation.textAttributes(size: fontSize, color: color))
            return CGRect(origin: origin, size: size)
        default:
            return points.dropFirst().reduce(CGRect(origin: points.first ?? .zero, size: .zero)) {
                $0.union(CGRect(origin: $1, size: .zero))
            }
        }
    }

    func hits(_ point: CGPoint, tolerance: CGFloat, unit: CGFloat) -> Bool {
        let reach = tolerance + (kind == .highlighter ? width * 1.5 : width / 2)
        switch kind {
        case .rectangle:
            guard points.count >= 2 else { return false }
            let rect = Annotation.rect(points[0], points[1])
            if filled { return rect.insetBy(dx: -reach, dy: -reach).contains(point) }
            return rect.insetBy(dx: -reach, dy: -reach).contains(point)
                && !rect.insetBy(dx: reach, dy: reach).contains(point)
        case .ellipse:
            guard points.count >= 2 else { return false }
            let rect = Annotation.rect(points[0], points[1])
            func inside(_ r: CGRect) -> Bool {
                guard r.width > 0, r.height > 0 else { return false }
                let nx = (point.x - r.midX) / (r.width / 2), ny = (point.y - r.midY) / (r.height / 2)
                return nx * nx + ny * ny <= 1
            }
            if filled { return inside(rect.insetBy(dx: -reach, dy: -reach)) }
            return inside(rect.insetBy(dx: -reach, dy: -reach)) && !inside(rect.insetBy(dx: reach, dy: reach))
        case .line, .arrow:
            guard points.count >= 2 else { return false }
            return Annotation.distance(from: point, toSegment: points[0], points[1]) <= reach
        case .pen, .highlighter:
            if points.count == 1 { return hypot(point.x - points[0].x, point.y - points[0].y) <= reach }
            return zip(points, points.dropFirst()).contains {
                Annotation.distance(from: point, toSegment: $0, $1) <= reach
            }
        case .mosaic:
            guard points.count >= 2 else { return false }
            return Annotation.rect(points[0], points[1]).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .text:
            return bounds(unit: unit).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let squared = dx * dx + dy * dy
        guard squared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / squared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
