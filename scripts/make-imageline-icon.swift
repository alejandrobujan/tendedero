// Original ImageLine artwork. Does not use Tendedero's excluded name/icon artwork.
import AppKit
let output = CommandLine.arguments[1]
let size = 1024
let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: 1)
}
color(21, 57, 64).setFill()
NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 208, yRadius: 208).fill()
color(68, 177, 155).setFill()
NSBezierPath(roundedRect: NSRect(x: 170, y: 285, width: 620, height: 474), xRadius: 72, yRadius: 72).fill()
color(241, 249, 244).setFill()
NSBezierPath(roundedRect: NSRect(x: 240, y: 212, width: 620, height: 474), xRadius: 72, yRadius: 72).fill()
let mountain = NSBezierPath()
mountain.move(to: NSPoint(x: 287, y: 276))
mountain.line(to: NSPoint(x: 464, y: 513))
mountain.line(to: NSPoint(x: 571, y: 382))
mountain.line(to: NSPoint(x: 660, y: 468))
mountain.line(to: NSPoint(x: 813, y: 276))
mountain.close()
color(21, 101, 94).setFill()
mountain.fill()
color(237, 156, 73).setFill()
NSBezierPath(ovalIn: NSRect(x: 648, y: 532, width: 90, height: 90)).fill()
// A short line joining the stacked pictures is the image-sharing metaphor.
let link = NSBezierPath()
link.move(to: NSPoint(x: 264, y: 822))
link.line(to: NSPoint(x: 760, y: 822))
link.lineWidth = 38
link.lineCapStyle = .round
color(241, 249, 244).setStroke()
link.stroke()
NSGraphicsContext.restoreGraphicsState()
try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
