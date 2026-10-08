// Renders every image in the README, in light and dark:
//   hero-*.png   headline and the line hanging under the menu bar
//   demo-*.gif   the reveal: pointer to the top edge, line slides down, a
//                click copies, the pointer leaves and the line tucks away
//   bento-*.png  four gestures as tiles with SF Symbols
// Usage: swift scripts/make-readme-art.swift [language] [folder]
// English goes to docs/images, any other language to docs/images/<language>.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let language = CommandLine.arguments.dropFirst().first ?? "en"
let outDir = CommandLine.arguments.dropFirst(2).first ?? (language == "en" ? "docs/images" : "docs/images/\(language)")
try! FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// MARK: Words

// The words drawn into the images, keyed by the English text.
let translations: [String: [String: String]] = [
    "es": [
        "Screenshots, hung out to dry.": "Tus capturas, tendidas.",
        "Copied": "Copiado",
        "Click to copy.": "Clic para copiar.",
        "Paste it anywhere, instantly.": "Pégala donde quieras, al momento.",
        "Hold to mark up.": "Mantén para anotar.",
        "Annotate, crop or sign in place.": "Anota, recorta o firma ahí mismo.",
        "Drag to share.": "Arrastra para compartir.",
        "Apps get a copy. Folders keep it.": "Las apps reciben una copia. Las carpetas, el original.",
        "Let it go.": "Y olvídate.",
        "The cross or the Trash. That\u{2019}s it.": "La cruz o la Papelera. Nada más.",
    ],
]

func T(_ english: String) -> String {
    if language == "en" { return english }
    guard let words = translations[language] else { fatalError("No words for \(language)") }
    guard let word = words[english] else { fatalError("No \(language) for \"\(english)\"") }
    return word
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// MARK: Themes

struct Theme {
    let name: String
    let page: NSColor          // README background behind everything
    let ink: NSColor
    let secondaryInk: NSColor
    let wallpaper: [NSColor]
    let glow: NSColor
    let menuBar: NSColor
    let menuInk: NSColor
    let line: NSColor
    let glassFill: NSColor
    let edgeTop: NSColor
    let edgeBottom: NSColor
    let shadow: NSColor
    let tile: NSColor
    let tileInk: NSColor
}

let light = Theme(
    name: "light",
    page: color(255, 255, 255), ink: color(29, 29, 31), secondaryInk: color(110, 110, 115),
    wallpaper: [color(214, 224, 255), color(232, 222, 252), color(255, 226, 222)],
    glow: color(255, 255, 255, 0.35),
    menuBar: color(255, 255, 255, 0.55), menuInk: color(30, 32, 48, 0.5),
    line: color(120, 124, 145), glassFill: color(255, 255, 255, 0.5),
    edgeTop: color(255, 255, 255, 0.95), edgeBottom: color(255, 255, 255, 0.35),
    shadow: color(40, 40, 80, 0.22),
    tile: color(245, 245, 247), tileInk: color(29, 29, 31))

let dark = Theme(
    name: "dark",
    page: color(13, 17, 23), ink: color(245, 245, 247), secondaryInk: color(161, 161, 166),
    wallpaper: [color(22, 26, 52), color(40, 30, 72), color(70, 36, 70)],
    glow: color(140, 120, 255, 0.22),
    menuBar: color(20, 20, 30, 0.55), menuInk: color(255, 255, 255, 0.5),
    line: color(150, 154, 175), glassFill: color(255, 255, 255, 0.12),
    edgeTop: color(255, 255, 255, 0.45), edgeBottom: color(255, 255, 255, 0.08),
    shadow: color(0, 0, 0, 0.5),
    tile: color(28, 28, 30), tileInk: color(245, 245, 247))

// MARK: Canvas

func makeBitmap(_ w: CGFloat, _ h: CGFloat, scale: CGFloat) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

func draw(_ rep: NSBitmapImageRep, scale: CGFloat, _ body: (CGContext) -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)
    body(ctx)
    NSGraphicsContext.restoreGraphicsState()
}

func savePNG(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func shadow(_ t: Theme, _ alpha: CGFloat, blur: CGFloat, y: CGFloat) {
    let s = NSShadow()
    s.shadowColor = t.shadow.withAlphaComponent(t.shadow.alphaComponent * alpha)
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: y)
    s.set()
}

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
          tracking: CGFloat = 0, centerX: CGFloat, baselineY: CGFloat, rounded: Bool = false) {
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if rounded, let d = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: d, size: size) ?? font }
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: tracking]
    let s = NSAttributedString(string: string, attributes: attrs)
    let w = s.size().width
    s.draw(at: NSPoint(x: centerX - w / 2, y: baselineY + font.descender))
}

func leftText(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
              tracking: CGFloat = 0, x: CGFloat, baselineY: CGFloat, maxWidth: CGFloat = .infinity) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let s = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: tracking])
    if s.size().width > maxWidth { fatalError("\"\(string)\" is too long: \(Int(s.size().width)) of \(Int(maxWidth)) points") }
    s.draw(at: NSPoint(x: x, y: baselineY + font.descender))
}

func textWidth(_ string: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
    NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).size().width
}

// MARK: The scene

struct Frame { let x: CGFloat; let w: CGFloat; let h: CGFloat; let tilt: CGFloat; let kind: Int }

struct SceneState {
    var reveal: CGFloat = 1            // 0 tucked away, 1 down
    var swing: [CGFloat] = [0, 0, 0]   // extra degrees per photo
    var cursor: NSPoint? = nil
    var hover: Int? = nil
    var pressed: CGFloat = 0
    var copied: CGFloat = 0            // 0...1 opacity of the Copied label
}

func drawScene(_ ctx: CGContext, _ t: Theme, rect: NSRect, frames: [Frame], state: SceneState, cornerRadius: CGFloat) {
    ctx.saveGState()
    let W = rect.width, H = rect.height
    ctx.translateBy(x: rect.minX, y: rect.minY)
    let canvas = NSRect(x: 0, y: 0, width: W, height: H)
    NSBezierPath(roundedRect: canvas, xRadius: cornerRadius, yRadius: cornerRadius).addClip()

    NSGradient(colors: t.wallpaper, atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: canvas, angle: -35)
    NSGradient(colors: [t.glow, t.glow.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: W * 0.5, y: H * 0.45), radius: 0,
              toCenter: NSPoint(x: W * 0.5, y: H * 0.45), radius: W * 0.6, options: [])

    let barH: CGFloat = 26
    // The line lives under the menu bar and slides out from beneath it.
    let hidden: CGFloat = 260
    let dy = (1 - state.reveal) * hidden
    let top = H - barH - 20 + dy
    let sag: CGFloat = 22
    func lineY(_ x: CGFloat) -> CGFloat { let f = x / W; return top - 4 * sag * f * (1 - f) }

    ctx.saveGState()
    NSRect(x: 0, y: 0, width: W, height: H - barH).clip()
    let linePath = NSBezierPath()
    linePath.move(to: NSPoint(x: -10, y: top))
    let c = NSPoint(x: W / 2, y: top - 2 * sag)
    linePath.curve(to: NSPoint(x: W + 10, y: top),
                   controlPoint1: NSPoint(x: -10 + (c.x + 10) * 2 / 3, y: top + (c.y - top) * 2 / 3),
                   controlPoint2: NSPoint(x: W + 10 + (c.x - W - 10) * 2 / 3, y: top + (c.y - top) * 2 / 3))
    ctx.saveGState(); shadow(t, 0.8, blur: 3, y: -2)
    linePath.lineWidth = 1.8; t.line.setStroke(); linePath.stroke()
    ctx.restoreGState()

    for (i, f) in frames.enumerated() {
        let hover = state.hover == i
        let scale: CGFloat = hover ? (1.03 - 0.06 * state.pressed) : 1
        ctx.saveGState()
        ctx.translateBy(x: f.x, y: lineY(f.x) + 7)
        ctx.rotate(by: (f.tilt + state.swing[i]) * .pi / 180)
        ctx.scaleBy(x: scale, y: scale)
        drawGlassPhoto(ctx, t, w: f.w, h: f.h, kind: f.kind, lift: hover)
        if hover && state.copied > 0 {
            drawCopied(ctx, t, y: -f.h - 18, alpha: state.copied)
        }
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // Menu bar on top of everything.
    t.menuBar.setFill()
    NSRect(x: 0, y: H - barH, width: W, height: barH).fill()
    t.menuInk.setFill()
    NSBezierPath(ovalIn: NSRect(x: 18, y: H - barH / 2 - 5, width: 10, height: 10)).fill()
    for (i, w) in [CGFloat(46), 32, 28, 40, 34].enumerated() {
        let x = 42 + CGFloat(i) * 52
        NSBezierPath(roundedRect: NSRect(x: x, y: H - barH / 2 - 3.5, width: w, height: 7), xRadius: 3.5, yRadius: 3.5).fill()
    }
    for i in 0..<4 {
        NSBezierPath(roundedRect: NSRect(x: W - 34 - CGFloat(i) * 30, y: H - barH / 2 - 5, width: 16, height: 10), xRadius: 3, yRadius: 3).fill()
    }

    if let p = state.cursor { drawCursor(ctx, t, at: NSPoint(x: p.x, y: min(p.y, H - 1))) }
    ctx.restoreGState()
}

func drawGlassPhoto(_ ctx: CGContext, _ t: Theme, w: CGFloat, h: CGFloat, kind: Int, lift: Bool) {
    let radius: CGFloat = 16, inset: CGFloat = 4.5
    let frame = NSRect(x: -w / 2, y: -h, width: w, height: h)
    let path = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
    ctx.saveGState(); shadow(t, lift ? 1.3 : 1, blur: lift ? 30 : 22, y: lift ? -16 : -12)
    t.glassFill.setFill(); path.fill()
    ctx.restoreGState()

    let photo = frame.insetBy(dx: inset, dy: inset)
    ctx.saveGState()
    NSBezierPath(roundedRect: photo, xRadius: radius - inset, yRadius: radius - inset).addClip()
    drawContent(kind, photo)
    ctx.restoreGState()

    ctx.saveGState()
    let ring = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
    ring.append(NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: radius - 1, yRadius: radius - 1))
    ring.windingRule = .evenOdd
    ring.addClip()
    NSGradient(colors: [t.edgeTop, t.edgeBottom])!.draw(in: frame, angle: -90)
    ctx.restoreGState()

    let clip = NSRect(x: -4.5, y: -15, width: 9, height: 25)
    let clipPath = NSBezierPath(roundedRect: clip, xRadius: 3.5, yRadius: 3.5)
    ctx.saveGState(); shadow(t, 0.9, blur: 3, y: -1.5)
    color(200, 200, 205).setFill(); clipPath.fill()
    ctx.restoreGState()
    NSGradient(colors: [color(178, 179, 186), color(238, 239, 243), color(209, 210, 216), color(158, 159, 166)],
               atLocations: [0, 0.35, 0.65, 1], colorSpace: .sRGB)!.draw(in: clipPath, angle: 0)
    color(30, 30, 40, 0.35).setFill()
    NSBezierPath(roundedRect: NSRect(x: -2.5, y: -0.7, width: 5, height: 1.4), xRadius: 0.7, yRadius: 0.7).fill()
}

func drawContent(_ kind: Int, _ r: NSRect) {
    switch kind {
    case 0:
        color(250, 250, 252).setFill(); r.fill()
        let bar = NSRect(x: r.minX, y: r.maxY - 20, width: r.width, height: 20)
        color(236, 237, 242).setFill(); bar.fill()
        for (i, c) in [color(255, 95, 87), color(254, 188, 46), color(40, 200, 64)].enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.minX + 8 + CGFloat(i) * 11, y: bar.midY - 3, width: 6.5, height: 6.5)).fill()
        }
        color(98, 120, 255).setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX + 12, y: bar.minY - 24, width: r.width * 0.45, height: 9), xRadius: 3, yRadius: 3).fill()
        color(214, 217, 226).setFill()
        for i in 0..<6 {
            let y = bar.minY - 42 - CGFloat(i) * 14
            if y < r.minY + 8 { break }
            let w = r.width * [0.8, 0.62, 0.72, 0.5, 0.66, 0.58][i]
            NSBezierPath(roundedRect: NSRect(x: r.minX + 12, y: y, width: w, height: 5.5), xRadius: 2.75, yRadius: 2.75).fill()
        }
    case 1:
        NSGradient(colors: [color(255, 156, 96), color(255, 108, 132), color(118, 88, 204)])!.draw(in: r, angle: 90)
        color(255, 232, 166).setFill()
        let s = r.height * 0.26
        NSBezierPath(ovalIn: NSRect(x: r.midX - s / 2, y: r.minY + r.height * 0.3, width: s, height: s)).fill()
        let hills = NSBezierPath()
        hills.move(to: NSPoint(x: r.minX, y: r.minY + r.height * 0.3))
        hills.curve(to: NSPoint(x: r.maxX, y: r.minY + r.height * 0.2),
                    controlPoint1: NSPoint(x: r.minX + r.width * 0.3, y: r.minY + r.height * 0.55),
                    controlPoint2: NSPoint(x: r.minX + r.width * 0.62, y: r.minY + r.height * 0.05))
        hills.line(to: NSPoint(x: r.maxX, y: r.minY)); hills.line(to: NSPoint(x: r.minX, y: r.minY)); hills.close()
        color(66, 48, 128).setFill(); hills.fill()
    default:
        color(24, 26, 36).setFill(); r.fill()
        let bars: [CGFloat] = [0.35, 0.55, 0.42, 0.7, 0.6, 0.85, 0.74]
        let bw = (r.width - 36) / CGFloat(bars.count)
        for (i, v) in bars.enumerated() {
            (i == bars.count - 2 ? color(120, 140, 255) : color(120, 140, 255, 0.45)).setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX + 18 + CGFloat(i) * bw + 3, y: r.minY + 16,
                                             width: bw - 6, height: (r.height - 42) * v), xRadius: 3, yRadius: 3).fill()
        }
        color(255, 255, 255, 0.7).setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX + 18, y: r.maxY - 18, width: 54, height: 5.5), xRadius: 2.75, yRadius: 2.75).fill()
    }
}

func drawCopied(_ ctx: CGContext, _ t: Theme, y: CGFloat, alpha: CGFloat) {
    let label = "\u{2713}  " + T("Copied")
    // Wide enough for the English label; longer words widen the pill.
    let w = max(84, (textWidth(label, size: 11.5, weight: .semibold) + 26).rounded(.up)), h: CGFloat = 24
    let r = NSRect(x: -w / 2, y: y - h / 2 + (1 - alpha) * 4, width: w, height: h)
    let p = NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2)
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.saveGState(); shadow(t, 0.8, blur: 10, y: -4)
    (t.name == "light" ? color(255, 255, 255, 0.92) : color(50, 50, 60, 0.92)).setFill(); p.fill()
    ctx.restoreGState()
    text(label, size: 11.5, weight: .semibold, color: t.ink, centerX: 0, baselineY: r.midY - 4)
    ctx.restoreGState()
}

func drawCursor(_ ctx: CGContext, _ t: Theme, at p: NSPoint) {
    let a = NSBezierPath()
    a.move(to: p)
    a.line(to: NSPoint(x: p.x, y: p.y - 20))
    a.line(to: NSPoint(x: p.x + 5, y: p.y - 15.5))
    a.line(to: NSPoint(x: p.x + 8.6, y: p.y - 23.5))
    a.line(to: NSPoint(x: p.x + 11.8, y: p.y - 22.1))
    a.line(to: NSPoint(x: p.x + 8.2, y: p.y - 14.1))
    a.line(to: NSPoint(x: p.x + 14.5, y: p.y - 14.1))
    a.close()
    ctx.saveGState(); shadow(t, 0.9, blur: 3, y: -1.5)
    NSColor.black.setFill(); a.fill()
    ctx.restoreGState()
    a.lineWidth = 1.3; NSColor.white.setStroke(); a.stroke()
}

// MARK: Hero

func hero(_ t: Theme) {
    let W: CGFloat = 1200, H: CGFloat = 640, s: CGFloat = 2
    let rep = makeBitmap(W, H, scale: s)
    draw(rep, scale: s) { ctx in
        t.page.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
        text("Tendedero", size: 84, weight: .semibold, color: t.ink, tracking: -2.4, centerX: W / 2, baselineY: H - 128)
        text(T("Screenshots, hung out to dry."), size: 30, weight: .regular, color: t.secondaryInk,
             tracking: -0.4, centerX: W / 2, baselineY: H - 182)
        let frames = [Frame(x: 290, w: 250, h: 172, tilt: 2.5, kind: 0),
                      Frame(x: 560, w: 270, h: 186, tilt: -1.2, kind: 1),
                      Frame(x: 830, w: 220, h: 160, tilt: 3, kind: 2)]
        let scene = NSRect(x: 60, y: 40, width: W - 120, height: 330)
        ctx.saveGState(); shadow(t, 0.6, blur: 40, y: -18)
        t.page.setFill(); NSBezierPath(roundedRect: scene, xRadius: 26, yRadius: 26).fill()
        ctx.restoreGState()
        drawScene(ctx, t, rect: scene,
                  frames: frames.map { Frame(x: $0.x - 60 + 60, w: $0.w, h: $0.h, tilt: $0.tilt, kind: $0.kind) },
                  state: SceneState(cursor: NSPoint(x: 690, y: 330)), cornerRadius: 26)
    }
    savePNG(rep, "\(outDir)/hero-\(t.name).png")
}

// MARK: Demo loop

func easeInOut(_ x: CGFloat) -> CGFloat { let x = max(0, min(1, x)); return x * x * (3 - 2 * x) }
func lerp(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat { a + (b - a) * x }
func lerp(_ a: NSPoint, _ b: NSPoint, _ x: CGFloat) -> NSPoint { NSPoint(x: lerp(a.x, b.x, x), y: lerp(a.y, b.y, x)) }

func demo(_ t: Theme) {
    let W: CGFloat = 960, H: CGFloat = 340, s: CGFloat = 1
    let fps: CGFloat = 25, duration: CGFloat = 5.2
    let frames = [Frame(x: 250, w: 210, h: 146, tilt: 2.5, kind: 0),
                  Frame(x: 480, w: 230, h: 158, tilt: -1.2, kind: 1),
                  Frame(x: 705, w: 190, h: 136, tilt: 3, kind: 2)]
    let rest = NSPoint(x: 620, y: 90), edge = NSPoint(x: 560, y: H), onPhoto = NSPoint(x: 492, y: 175)
    let away = NSPoint(x: 760, y: 70)

    let url = URL(fileURLWithPath: "\(outDir)/demo-\(t.name).gif")
    let count = Int(fps * duration)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil)!
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps,
                                                      kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary

    for i in 0..<count {
        let time = CGFloat(i) / fps
        var st = SceneState(reveal: 0)

        // Pointer travels to the top edge and rests there.
        if time < 1.0 { st.cursor = lerp(rest, edge, easeInOut((time - 0.2) / 0.8)) }
        else if time < 1.9 { st.cursor = edge }
        else if time < 2.7 { st.cursor = lerp(edge, onPhoto, easeInOut((time - 1.9) / 0.8)) }
        else if time < 3.9 { st.cursor = onPhoto }
        else { st.cursor = lerp(onPhoto, away, easeInOut((time - 3.9) / 0.7)) }

        // The line slides down with a soft spring, photos swing as it lands.
        let downAt: CGFloat = 1.25, upAt: CGFloat = 4.75
        if time >= downAt && time < upAt {
            let d = time - downAt
            st.reveal = 1 - exp(-7 * d) * cos(9 * d)
            for k in 0..<3 {
                let dk = max(0, d - 0.05 * CGFloat(k))
                st.swing[k] = 9 * exp(-2.6 * dk) * sin(8.5 * dk + 0.6) * (k % 2 == 0 ? 1 : -1)
            }
        } else if time >= upAt {
            st.reveal = 1 - easeInOut((time - upAt) / 0.28)
        }

        // Hover, press and copy on the middle photo.
        if time >= 2.55 && time < 4.0 { st.hover = 1 }
        if time >= 2.95 && time < 3.15 { st.pressed = easeInOut((time - 2.95) / 0.1) * (1 - easeInOut((time - 3.05) / 0.1)) }
        if time >= 3.1 && time < 4.0 { st.copied = min(1, (time - 3.1) / 0.15) * (time > 3.8 ? max(0, 1 - (time - 3.8) / 0.2) : 1) }

        let rep = makeBitmap(W, H, scale: s)
        draw(rep, scale: s) { ctx in
            t.page.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
            drawScene(ctx, t, rect: NSRect(x: 0, y: 0, width: W, height: H), frames: frames, state: st, cornerRadius: 22)
        }
        CGImageDestinationAddImage(dest, rep.cgImage!, frameProps)
    }
    CGImageDestinationFinalize(dest)
}

// MARK: Bento

func bento(_ t: Theme) {
    let W: CGFloat = 1200, H: CGFloat = 700, s: CGFloat = 2, gap: CGFloat = 20
    let tiles: [(String, String, String)] = [
        ("doc.on.doc", T("Click to copy."), T("Paste it anywhere, instantly.")),
        ("pencil.tip.crop.circle", T("Hold to mark up."), T("Annotate, crop or sign in place.")),
        ("arrow.up.forward.app", T("Drag to share."), T("Apps get a copy. Folders keep it.")),
        ("xmark.circle", T("Let it go."), T("The cross or the Trash. That\u{2019}s it.")),
    ]
    let rep = makeBitmap(W, H, scale: s)
    draw(rep, scale: s) { ctx in
        t.page.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
        let tw = (W - gap * 3) / 2, th = (H - gap * 3) / 2
        for (i, tile) in tiles.enumerated() {
            let col = CGFloat(i % 2), row = CGFloat(1 - i / 2)
            let r = NSRect(x: gap + col * (tw + gap), y: gap + row * (th + gap), width: tw, height: th)
            t.tile.setFill()
            NSBezierPath(roundedRect: r, xRadius: 28, yRadius: 28).fill()

            let config = NSImage.SymbolConfiguration(pointSize: 46, weight: .regular)
                .applying(.init(paletteColors: [color(98, 120, 255)]))
            if let symbol = NSImage(systemSymbolName: tile.0, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let sz = symbol.size
                symbol.draw(in: NSRect(x: r.minX + 44, y: r.maxY - 52 - sz.height, width: sz.width, height: sz.height))
            }
            leftText(tile.1, size: 36, weight: .semibold, color: t.tileInk, tracking: -0.8, x: r.minX + 44, baselineY: r.minY + 92, maxWidth: r.width - 88)
            leftText(tile.2, size: 21, weight: .regular, color: t.secondaryInk, tracking: -0.2, x: r.minX + 44, baselineY: r.minY + 52, maxWidth: r.width - 88)
        }
    }
    savePNG(rep, "\(outDir)/bento-\(t.name).png")
}

for t in [light, dark] {
    hero(t)
    bento(t)
    demo(t)
}
