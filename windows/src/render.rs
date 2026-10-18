//! Drawing the line. Each card is painted once into a sprite (shadow, glass
//! frame, photo, clothespin). Every frame then only places those sprites with
//! a rotation, a scale and an opacity, plus the rope and any labels. Nothing
//! is re-rendered while the cards sway.

use std::collections::HashMap;

use tiny_skia::{
    Color, FillRule, FilterQuality, GradientStop, LinearGradient, Mask, Paint, PathBuilder, PixmapPaint,
    Pixmap, Point, SpreadMode, Stroke, Transform, Path, Shader,
};

use crate::line::{Item, Layout, PANEL_H, PIN_ABOVE};

pub struct Sprite {
    pub pix: Pixmap,
    /// Where the clothespin's top centre sits inside the sprite.
    pub pivot: (f32, f32),
    /// The card's rectangle inside the sprite (x, y, width, height).
    pub card: (f32, f32, f32, f32),
}

/// Pixels of empty space around a card, so shadows and tilts are never cut.
fn margin(s: f32) -> f32 {
    (24.0 * s).ceil()
}

/// Paints a card at device scale `s` from its photo.
pub fn card_sprite(thumb: &Pixmap, s: f32) -> Option<Sprite> {
    let inset = 4.0 * s;
    let radius = 16.0 * s;
    let (pw, ph) = fit(thumb.width() as f32, thumb.height() as f32, 136.0 * s, 104.0 * s);
    let card_w = pw + inset * 2.0;
    let card_h = ph + inset * 2.0;
    let m = margin(s);
    let sw = (card_w + m * 2.0).ceil() as u32;
    let sh = (m + 14.0 * s + card_h + m).ceil() as u32;
    let cx = sw as f32 / 2.0;
    let x0 = cx - card_w / 2.0;
    let y0 = m + 14.0 * s;

    let mut pix = Pixmap::new(sw, sh)?;

    // Soft shadows: the card (offset 5, blur 10) and the clip (offset 1.5, blur 2).
    let mut shadow = Pixmap::new(sw, sh)?;
    fill_rrect(&mut shadow, x0, y0 + 5.0 * s, card_w, card_h, radius, solid(0, 0, 0, 0.18));
    box_blur(&mut shadow, (5.0 * s).round().max(1.0) as usize);
    let mut clip_shadow = Pixmap::new(sw, sh)?;
    fill_rrect(&mut clip_shadow, cx - 4.5 * s, m + 1.5 * s, 9.0 * s, 26.0 * s, 3.5 * s, solid(0, 0, 0, 0.30));
    box_blur(&mut clip_shadow, (2.0 * s).round().max(1.0) as usize);
    draw_layer(&mut pix, &shadow, 0, 0);
    draw_layer(&mut pix, &clip_shadow, 0, 0);

    // Glass frame: a light translucent fill, since Windows cannot blur what is
    // behind a layered window, so the frame reads as a clean pane instead.
    fill_rrect(&mut pix, x0, y0, card_w, card_h, radius, solid(255, 255, 255, 0.74));

    // The photo, cropped to the rounded inner corners.
    let mut photo = Pixmap::new(pw.round().max(1.0) as u32, ph.round().max(1.0) as u32)?;
    let mask = rrect_mask(photo.width(), photo.height(), radius - inset)?;
    let scale = Transform::from_scale(pw / thumb.width() as f32, ph / thumb.height() as f32);
    photo.draw_pixmap(
        0,
        0,
        thumb.as_ref(),
        &PixmapPaint { quality: FilterQuality::Bilinear, ..Default::default() },
        scale,
        Some(&mask),
    );
    draw_layer(&mut pix, &photo, (x0 + inset).round() as i32, (y0 + inset).round() as i32);
    stroke_rrect(&mut pix, x0 + inset, y0 + inset, pw, ph, radius - inset, 0.5 * s, solid(255, 255, 255, 0.18));

    // Edge highlight: brighter at the top, fading out at the bottom.
    let edge = vertical_gradient(y0, y0 + card_h, (255, 255, 255, 0.55), (255, 255, 255, 0.12));
    stroke_rrect(&mut pix, x0 + 0.375 * s, y0 + 0.375 * s, card_w - 0.75 * s, card_h - 0.75 * s, radius - 0.375 * s, 0.75 * s, edge);

    // The clothespin: brushed metal with a slot where it grips the line.
    let clip_x = cx - 4.5 * s;
    let metal = metal_gradient(clip_x, clip_x + 9.0 * s);
    fill_rrect(&mut pix, clip_x, m, 9.0 * s, 26.0 * s, 3.5 * s, metal);
    stroke_rrect(&mut pix, clip_x, m, 9.0 * s, 26.0 * s, 3.5 * s, 0.6 * s, solid(255, 255, 255, 0.7));
    fill_rrect(&mut pix, cx - 2.5 * s, m + 8.5 * s, 5.0 * s, 1.4 * s, 0.7 * s, solid(0, 0, 0, 0.32));

    Some(Sprite { pix, pivot: (cx, m), card: (x0, y0, card_w, card_h) })
}

/// Fits (w, h) inside (max_w, max_h), keeping the aspect ratio.
fn fit(w: f32, h: f32, max_w: f32, max_h: f32) -> (f32, f32) {
    if w <= 0.0 || h <= 0.0 {
        return (max_w, max_h);
    }
    let k = (max_w / w).min(max_h / h);
    ((w * k).round().max(1.0), (h * k).round().max(1.0))
}

/// What one frame needs besides the cards: the card under the pointer, and
/// the card being dragged out, which is drawn faded.
pub struct Ui {
    pub hover: Option<u64>,
    pub dragging: Option<u64>,
}

pub struct Frame {
    pub canvas: Pixmap,
    /// Each visible card's unrotated rectangle, for hit testing.
    pub hits: Vec<(u64, (i32, i32, i32, i32))>,
}

/// Owns the font and the cached label images.
pub struct Painter {
    /// None when no system font could be read. The line still works without text.
    font: Option<fontdue::Font>,
    labels: HashMap<String, Pixmap>,
}

impl Painter {
    pub fn new(bytes: &[u8], collection_index: u32) -> Painter {
        let settings = fontdue::FontSettings { collection_index, ..Default::default() };
        let font = fontdue::Font::from_bytes(bytes, settings).ok();
        Painter { font, labels: HashMap::new() }
    }

    /// Text rendered once and reused. The key is the text, the size and the colour.
    fn label(&mut self, text: &str, px: f32, rgb: (u8, u8, u8)) -> Option<&Pixmap> {
        let key = format!("{text}|{px:.2}|{rgb:?}");
        if !self.labels.contains_key(&key) {
            let pix = rasterize(self.font.as_ref()?, text, px, rgb)?;
            self.labels.insert(key.clone(), pix);
        }
        self.labels.get(&key)
    }

    /// Draws the rope, the cards and the hint into a fresh frame.
    pub fn compose(&mut self, items: &[Item], layout: &Layout, ui: &Ui, hint: &str, hint_visible: bool) -> Option<Frame> {
        let s = layout.s;
        let w = layout.width.round().max(1.0) as u32;
        let h = (PANEL_H * s).round().max(1.0) as u32;
        let mut canvas = Pixmap::new(w, h)?;
        draw_rope(&mut canvas, layout);

        let mut hits = Vec::new();
        for item in items {
            let Some(sprite) = item.sprite.as_ref() else { continue };
            let pivot_x = item.x.x;
            let arrive = item.arrive.x.clamp(0.0, 1.0);
            let mut pivot_y = layout.rope_y(pivot_x) - PIN_ABOVE * s - 46.0 * s * (1.0 - arrive);
            let mut angle = item.tilt + item.swing.x;
            let mut alpha = arrive;

            // A falling card tilts further, sinks and fades out over 0.55 s.
            let fall = item.fall.filter(|t| *t >= 0.0).map(|t| (t / FALL_TIME).min(1.0).powi(3));
            if let Some(e) = fall {
                angle += (item.tilt * 7.0 + 20.0) * e;
                pivot_y += 520.0 * s * e;
                alpha *= 1.0 - e;
            }
            if ui.dragging == Some(item.id) {
                alpha *= 0.45;
            }
            let hovered = ui.hover == Some(item.id) && ui.dragging.is_none() && fall.is_none();
            let transform = card_transform(sprite, pivot_x, pivot_y, angle, item.scale);

            let mut paint = PixmapPaint { opacity: alpha, ..Default::default() };
            paint.quality = FilterQuality::Bilinear;
            canvas.draw_pixmap(0, 0, sprite.pix.as_ref(), &paint, transform, None);

            if hovered {
                draw_cross(&mut canvas, sprite, s, transform, alpha);
            }
            if item.copied > 0.0 {
                let fade = (item.copied / 0.2).clamp(0.0, 1.0) * alpha;
                if let Some(label) = self.label(&crate::i18n::t("Copied"), 11.0 * s, (30, 30, 30)) {
                    draw_copied(&mut canvas, sprite, s, transform, label, fade);
                }
            }

            if fall.is_none() && arrive > 0.5 {
                let (x0, y0, cw, ch) = sprite.card;
                let left = pivot_x - sprite.pivot.0 + x0;
                let top = pivot_y - sprite.pivot.1 + y0;
                hits.push((item.id, (left.round() as i32, top.round() as i32, (left + cw).round() as i32, (top + ch).round() as i32)));
            }
        }

        if hint_visible {
            let center_x = layout.width / 2.0;
            let center_y = layout.rope_y(center_x) + 34.0 * s;
            if let Some(text) = self.label(hint, 12.0 * s, (90, 90, 96)) {
                draw_hint(&mut canvas, center_x, center_y, text, s);
            }
        }

        Some(Frame { canvas, hits })
    }
}

const FALL_TIME: f32 = 0.55;

fn card_transform(sprite: &Sprite, x: f32, y: f32, angle_deg: f32, scale: f32) -> Transform {
    // Rotation and scale happen about the clothespin's top centre, like SwiftUI's
    // rotationEffect with a top anchor.
    Transform::from_translate(-sprite.pivot.0, -sprite.pivot.1)
        .post_rotate(angle_deg)
        .post_scale(scale, scale)
        .post_translate(x, y)
}

fn draw_rope(canvas: &mut Pixmap, layout: &Layout) {
    let s = layout.s;
    let w = layout.width;
    let top = 10.0 * s;
    let sag = layout.sag();
    let mut pb = PathBuilder::new();
    pb.move_to(-20.0 * s, top);
    pb.quad_to(w / 2.0, top + 2.0 * sag, w + 20.0 * s, top);
    let Some(path) = pb.finish() else { return };
    // Shadow, core and highlight, faded out at both ends, like the mac rope.
    stroke_path(canvas, &path, rope_paint(w, (0, 0, 0), 0.20), 2.2 * s, Transform::from_translate(0.0, 1.0 * s));
    stroke_path(canvas, &path, rope_paint(w, (140, 140, 140), 1.0), 1.2 * s, Transform::identity());
    stroke_path(canvas, &path, rope_paint(w, (255, 255, 255), 0.45), 0.4 * s, Transform::from_translate(0.0, -0.35 * s));
}

fn rope_paint(width: f32, rgb: (u8, u8, u8), alpha: f32) -> Paint<'static> {
    let stops = vec![
        GradientStop::new(0.0, Color::from_rgba8(rgb.0, rgb.1, rgb.2, 0)),
        GradientStop::new(0.08, Color::from_rgba8(rgb.0, rgb.1, rgb.2, (alpha * 255.0) as u8)),
        GradientStop::new(0.92, Color::from_rgba8(rgb.0, rgb.1, rgb.2, (alpha * 255.0) as u8)),
        GradientStop::new(1.0, Color::from_rgba8(rgb.0, rgb.1, rgb.2, 0)),
    ];
    let shader = LinearGradient::new(Point::from_xy(0.0, 0.0), Point::from_xy(width, 0.0), stops, SpreadMode::Pad, Transform::identity())
        .unwrap_or(Shader::SolidColor(Color::TRANSPARENT));
    Paint { shader, anti_alias: true, ..Default::default() }
}

fn draw_cross(canvas: &mut Pixmap, sprite: &Sprite, s: f32, transform: Transform, alpha: f32) {
    let (x0, y0, _, _) = sprite.card;
    let (cx, cy) = (x0 + 13.0 * s, y0 + 13.0 * s);
    if let Some(circle) = rrect_path(cx - 10.0 * s, cy - 10.0 * s, 20.0 * s, 20.0 * s, 10.0 * s) {
        let mut paint = solid(255, 255, 255, 0.72 * alpha);
        paint.anti_alias = true;
        canvas.fill_path(&circle, &paint, FillRule::Winding, transform, None);
    }
    let mut pb = PathBuilder::new();
    let d = 3.5 * s;
    pb.move_to(cx - d, cy - d);
    pb.line_to(cx + d, cy + d);
    pb.move_to(cx + d, cy - d);
    pb.line_to(cx - d, cy + d);
    if let Some(path) = pb.finish() {
        stroke_path(canvas, &path, solid(0, 0, 0, 0.85 * alpha), 1.6 * s, transform);
    }
}

fn draw_copied(canvas: &mut Pixmap, sprite: &Sprite, s: f32, transform: Transform, label: &Pixmap, alpha: f32) {
    let (x0, y0, cw, ch) = sprite.card;
    let w = label.width() as f32 + 20.0 * s;
    draw_pill(canvas, x0 + cw / 2.0, y0 + ch + 4.0 * s, w, 24.0 * s, solid(255, 255, 255, 0.85 * alpha), label, transform, alpha);
}

/// A pill with a label centred on (cx, cy), drawn in the given transform.
fn draw_pill(canvas: &mut Pixmap, cx: f32, cy: f32, w: f32, h: f32, fill: Paint<'static>, label: &Pixmap, transform: Transform, alpha: f32) {
    if let Some(path) = rrect_path(cx - w / 2.0, cy - h / 2.0, w, h, h / 2.0) {
        canvas.fill_path(&path, &fill, FillRule::Winding, transform, None);
    }
    let paint = PixmapPaint { opacity: alpha, ..Default::default() };
    let lx = (cx - label.width() as f32 / 2.0).round() as i32;
    let ly = (cy - label.height() as f32 / 2.0).round() as i32;
    canvas.draw_pixmap(lx, ly, label.as_ref(), &paint, transform, None);
}

/// The hint on an empty line: a pill with the text centred on (cx, cy).
fn draw_hint(canvas: &mut Pixmap, cx: f32, cy: f32, label: &Pixmap, s: f32) {
    let w = label.width() as f32 + 24.0 * s;
    let h = label.height() as f32 + 12.0 * s;
    draw_pill(canvas, cx, cy, w, h, solid(255, 255, 255, 0.82), label, Transform::identity(), 1.0);
}

// MARK: Shapes and paints

fn solid(r: u8, g: u8, b: u8, a: f32) -> Paint<'static> {
    let mut paint = Paint { anti_alias: true, ..Default::default() };
    paint.set_color(Color::from_rgba8(r, g, b, (a.clamp(0.0, 1.0) * 255.0).round() as u8));
    paint
}

fn vertical_gradient(top: f32, bottom: f32, a: (u8, u8, u8, f32), b: (u8, u8, u8, f32)) -> Paint<'static> {
    let stops = vec![
        GradientStop::new(0.0, Color::from_rgba8(a.0, a.1, a.2, (a.3 * 255.0) as u8)),
        GradientStop::new(1.0, Color::from_rgba8(b.0, b.1, b.2, (b.3 * 255.0) as u8)),
    ];
    let shader = LinearGradient::new(Point::from_xy(0.0, top), Point::from_xy(0.0, bottom), stops, SpreadMode::Pad, Transform::identity())
        .unwrap_or(Shader::SolidColor(Color::TRANSPARENT));
    Paint { shader, anti_alias: true, ..Default::default() }
}

/// Brushed aluminium, lit from the left: the same four stops as the mac clip.
fn metal_gradient(x0: f32, x1: f32) -> Paint<'static> {
    let stops = vec![
        GradientStop::new(0.0, Color::from_rgba8(179, 179, 179, 255)),
        GradientStop::new(0.35, Color::from_rgba8(237, 237, 237, 255)),
        GradientStop::new(0.65, Color::from_rgba8(209, 209, 209, 255)),
        GradientStop::new(1.0, Color::from_rgba8(158, 158, 158, 255)),
    ];
    let shader = LinearGradient::new(Point::from_xy(x0, 0.0), Point::from_xy(x1, 0.0), stops, SpreadMode::Pad, Transform::identity())
        .unwrap_or(Shader::SolidColor(Color::TRANSPARENT));
    Paint { shader, anti_alias: true, ..Default::default() }
}

fn rrect_path(x: f32, y: f32, w: f32, h: f32, r: f32) -> Option<Path> {
    let r = r.clamp(0.0, (w.min(h)) / 2.0);
    let k = 0.552_284_8 * r;
    let mut pb = PathBuilder::new();
    pb.move_to(x + r, y);
    pb.line_to(x + w - r, y);
    pb.cubic_to(x + w - r + k, y, x + w, y + r - k, x + w, y + r);
    pb.line_to(x + w, y + h - r);
    pb.cubic_to(x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h);
    pb.line_to(x + r, y + h);
    pb.cubic_to(x + r - k, y + h, x, y + h - r + k, x, y + h - r);
    pb.line_to(x, y + r);
    pb.cubic_to(x, y + r - k, x + r - k, y, x + r, y);
    pb.close();
    pb.finish()
}

fn fill_rrect(pix: &mut Pixmap, x: f32, y: f32, w: f32, h: f32, r: f32, paint: Paint<'static>) {
    if let Some(path) = rrect_path(x, y, w, h, r) {
        pix.fill_path(&path, &paint, FillRule::Winding, Transform::identity(), None);
    }
}

fn stroke_rrect(pix: &mut Pixmap, x: f32, y: f32, w: f32, h: f32, r: f32, width: f32, paint: Paint<'static>) {
    if let Some(path) = rrect_path(x, y, w, h, r) {
        stroke_path(pix, &path, paint, width, Transform::identity());
    }
}

fn stroke_path(canvas: &mut Pixmap, path: &Path, paint: Paint<'static>, width: f32, transform: Transform) {
    let stroke = Stroke { width, ..Default::default() };
    canvas.stroke_path(path, &paint, &stroke, transform, None);
}

/// A mask of a rounded rectangle, used to crop the photo to its corners.
fn rrect_mask(w: u32, h: u32, r: f32) -> Option<Mask> {
    let mut mask = Mask::new(w, h)?;
    let path = rrect_path(0.0, 0.0, w as f32, h as f32, r)?;
    mask.fill_path(&path, FillRule::Winding, true, Transform::identity());
    Some(mask)
}

fn draw_layer(dst: &mut Pixmap, layer: &Pixmap, x: i32, y: i32) {
    dst.draw_pixmap(x, y, layer.as_ref(), &PixmapPaint::default(), Transform::identity(), None);
}

/// Three passes of a box blur approximate a Gaussian, which is what a shadow
/// is. Works straight on the premultiplied RGBA bytes.
fn box_blur(pix: &mut Pixmap, radius: usize) {
    let (w, h) = (pix.width() as usize, pix.height() as usize);
    let mut tmp = vec![0u8; w * h * 4];
    let data = pix.data_mut();
    for _ in 0..3 {
        blur_axis(data, &mut tmp, w, h, radius, true);
        blur_axis(&tmp, data, w, h, radius, false);
    }
}

fn blur_axis(src: &[u8], dst: &mut [u8], w: usize, h: usize, r: usize, horizontal: bool) {
    let (lines, len) = if horizontal { (h, w) } else { (w, h) };
    let index = |line: usize, p: usize| -> usize {
        if horizontal { (line * w + p) * 4 } else { (p * w + line) * 4 }
    };
    let window = (2 * r + 1) as u32;
    for line in 0..lines {
        for c in 0..4 {
            let at = |p: isize| -> u32 {
                if p < 0 || p >= len as isize { 0 } else { src[index(line, p as usize) + c] as u32 }
            };
            let mut sum: u32 = (0..=r as isize).map(at).sum();
            for p in 0..len {
                dst[index(line, p) + c] = (sum / window) as u8;
                sum += at((p + r + 1) as isize);
                sum -= at(p as isize - r as isize);
            }
        }
    }
}

/// Renders a string as a premultiplied RGBA image, one glyph at a time.
fn rasterize(font: &fontdue::Font, text: &str, px: f32, rgb: (u8, u8, u8)) -> Option<Pixmap> {
    let lines = font.horizontal_line_metrics(px)?;
    let glyphs: Vec<(fontdue::Metrics, Vec<u8>)> = text.chars().map(|c| font.rasterize(c, px)).collect();
    let advance: f32 = glyphs.iter().map(|(m, _)| m.advance_width).sum();
    let width = advance.ceil() as u32 + 4;
    let height = (lines.ascent - lines.descent).ceil() as u32 + 4;
    let mut pix = Pixmap::new(width, height)?;
    let baseline = lines.ascent.ceil() + 2.0;
    let data = pix.data_mut();

    let mut pen = 2.0f32;
    for (m, bitmap) in &glyphs {
        let left = (pen + m.xmin as f32).round() as i32;
        let top = (baseline - (m.ymin as f32 + m.height as f32)).round() as i32;
        for row in 0..m.height {
            for col in 0..m.width {
                let coverage = bitmap[row * m.width + col] as f32 / 255.0;
                if coverage <= 0.0 {
                    continue;
                }
                let x = left + col as i32;
                let y = top + row as i32;
                if x < 0 || y < 0 || x >= width as i32 || y >= height as i32 {
                    continue;
                }
                let i = (y as usize * width as usize + x as usize) * 4;
                // Source-over blend of a premultiplied colour.
                let (sr, sg, sb) = (rgb.0 as f32 * coverage, rgb.1 as f32 * coverage, rgb.2 as f32 * coverage);
                let inv = 1.0 - coverage;
                data[i] = (sr + data[i] as f32 * inv).round().min(255.0) as u8;
                data[i + 1] = (sg + data[i + 1] as f32 * inv).round().min(255.0) as u8;
                data[i + 2] = (sb + data[i + 2] as f32 * inv).round().min(255.0) as u8;
                data[i + 3] = (coverage * 255.0 + data[i + 3] as f32 * inv).round().min(255.0) as u8;
            }
        }
        pen += m.advance_width;
    }
    Some(pix)
}

