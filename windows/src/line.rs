//! The line itself: which photos hang on it, where they sit, and how they
//! move. Physics is a damped spring per value, stepped in small fixed
//! substeps so it stays stable whatever the frame rate.

use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime};

use tiny_skia::Pixmap;

use crate::render::{Sprite, card_sprite};

/// Logical sizes, in the same proportions as the mac app. Multiply by the
/// display scale for device pixels.
pub const PANEL_H: f32 = 210.0;
pub const PIN_ABOVE: f32 = 9.5;
const SPACING: f32 = 174.0;
const ROPE_TOP: f32 = 10.0;
pub const FALL_TIME: f32 = 0.55;

/// Device-pixel layout for one monitor.
pub struct Layout {
    pub s: f32,
    pub width: f32,
}

impl Layout {
    /// How far the rope sags between its two ends.
    pub fn sag(&self) -> f32 {
        (30.0 * self.s).min(self.width * 0.018)
    }

    /// The rope is a parabola from edge to edge of the screen.
    pub fn rope_y(&self, x: f32) -> f32 {
        if self.width <= 0.0 {
            return ROPE_TOP * self.s;
        }
        let f = x / self.width;
        ROPE_TOP * self.s + 4.0 * self.sag() * f * (1.0 - f)
    }

    /// Where the card at `index` hangs when `count` cards are on the line.
    pub fn slot_x(&self, index: usize, count: usize) -> f32 {
        let total = count.saturating_sub(1) as f32 * SPACING * self.s;
        self.width / 2.0 - total / 2.0 + index as f32 * SPACING * self.s
    }

    /// How many cards fit across the screen, with room left at the edges.
    pub fn max_items(&self) -> usize {
        let usable = self.width - 200.0 * self.s;
        ((usable / (SPACING * self.s)).floor().max(3.0) as usize).min(12)
    }
}

/// A value that chases a target with a spring. `k` is stiffness and `c` is
/// damping, in the same units the mac app's SwiftUI springs use.
#[derive(Clone, Copy)]
pub struct Spring {
    pub x: f32,
    pub v: f32,
    pub target: f32,
    k: f32,
    c: f32,
}

impl Spring {
    fn new(x: f32, k: f32, c: f32) -> Self {
        Spring { x, v: 0.0, target: x, k, c }
    }

    /// A spring from a SwiftUI-style response (seconds) and damping ratio.
    fn responsive(x: f32, response: f32, damping: f32) -> Self {
        let omega = std::f32::consts::TAU / response;
        Spring::new(x, omega * omega, 2.0 * damping * omega)
    }

    fn step(&mut self, dt: f32) {
        let substeps = (dt / (1.0 / 120.0)).ceil().max(1.0) as u32;
        let h = dt / substeps as f32;
        for _ in 0..substeps {
            let a = -self.k * (self.x - self.target) - self.c * self.v;
            self.v += a * h;
            self.x += self.v * h;
        }
    }

    fn at_rest(&self) -> bool {
        (self.x - self.target).abs() < 0.001 && self.v.abs() < 0.01
    }
}

pub struct Item {
    pub id: u64,
    pub path: PathBuf,
    /// Last write time seen, so an edit by another app can refresh the photo.
    pub mtime: Option<SystemTime>,
    /// The card's resting tilt in degrees.
    pub tilt: f32,
    pub thumb: Option<Pixmap>,
    pub sprite: Option<Sprite>,
    pub sprite_scale: f32,
    pub x: Spring,
    /// 0 while the card is still dropping onto the line, 1 once it has landed.
    pub arrive: Spring,
    /// Sway, in degrees.
    pub swing: Spring,
    /// Eased towards 1.035 on hover and 0.95 while pressed.
    pub scale: f32,
    /// Seconds since it started falling. Negative means it waits its turn.
    pub fall: Option<f32>,
    /// Seconds left on the "Copied" label.
    pub copied: f32,
}

impl Item {
    pub fn falling(&self) -> bool {
        self.fall.is_some()
    }
}

pub struct Line {
    pub items: Vec<Item>,
    next_id: u64,
    rng: u64,
    next_gust: Instant,
    gust_back: Option<Instant>,
}

impl Line {
    pub fn new() -> Self {
        let seed = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(1);
        let mut line = Line { items: Vec::new(), next_id: 1, rng: seed | 1, next_gust: Instant::now(), gust_back: None };
        line.next_gust = Instant::now() + Duration::from_secs_f32(line.random(7.0, 16.0));
        line
    }

    fn random(&mut self, lo: f32, hi: f32) -> f32 {
        // xorshift: plenty for tilts and breezes, no dependency needed.
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 7;
        self.rng ^= self.rng << 17;
        let unit = (self.rng >> 11) as f32 / (1u64 << 53) as f32;
        lo + (hi - lo) * unit
    }

    pub fn live_count(&self) -> usize {
        self.items.iter().filter(|i| !i.falling()).count()
    }

    pub fn contains_path(&self, path: &std::path::Path) -> bool {
        self.items.iter().any(|i| i.path == path && !i.falling())
    }

    /// Hangs a new photo at the end of the line. Its thumbnail arrives later.
    pub fn hang(&mut self, path: PathBuf, mtime: Option<SystemTime>, layout: &Layout) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        let tilt = self.random(-2.5, 2.5);
        let start_x = layout.slot_x(self.live_count(), self.live_count() + 1);
        let mut item = Item {
            id,
            path,
            mtime,
            tilt,
            thumb: None,
            sprite: None,
            sprite_scale: 0.0,
            x: Spring::responsive(start_x, 0.55, 0.78),
            arrive: Spring::responsive(0.0, 0.42, 0.72),
            swing: Spring::new(16.0, 46.0, 2.6),
            scale: 1.0,
            fall: None,
            copied: 0.0,
        };
        item.arrive.target = 1.0;
        item.swing.target = 0.0;
        self.items.push(item);
        id
    }

    /// Starts the fall of one card. `delay` staggers a clear-all.
    pub fn drop_card(&mut self, id: u64, delay: f32) -> bool {
        match self.items.iter_mut().find(|i| i.id == id) {
            Some(item) if !item.falling() => {
                item.fall = Some(-delay);
                true
            }
            _ => false,
        }
    }

    /// Lets go of every card, one after another.
    pub fn drop_all(&mut self) -> usize {
        let mut n = 0;
        for item in self.items.iter_mut().filter(|i| !i.falling()) {
            item.fall = Some(-0.06 * n as f32);
            n += 1;
        }
        n
    }

    /// Cards that are not falling, and whose file is still there.
    pub fn prune_missing(&mut self, exists: impl Fn(&std::path::Path) -> bool) -> Vec<u64> {
        let gone: Vec<u64> = self
            .items
            .iter()
            .filter(|i| !i.falling() && !exists(&i.path))
            .map(|i| i.id)
            .collect();
        for id in &gone {
            self.drop_card(*id, 0.0);
        }
        gone
    }

    /// Lets the oldest cards fall until the line is no longer over capacity.
    pub fn trim(&mut self, max: usize) -> Vec<u64> {
        let mut dropped = Vec::new();
        while self.live_count() > max {
            let Some(oldest) = self.items.iter().find(|i| !i.falling()).map(|i| i.id) else { break };
            self.drop_card(oldest, 0.0);
            dropped.push(oldest);
        }
        dropped
    }

    /// Removes cards whose fall has finished.
    fn sweep(&mut self) {
        self.items.retain(|i| i.fall.is_none_or(|t| t < FALL_TIME));
    }

    /// A breeze: every card sways out, then settles back.
    pub fn gust_if_due(&mut self, now: Instant) -> bool {
        if self.items.is_empty() || now < self.next_gust {
            return false;
        }
        let count = self.items.len();
        let angles: Vec<f32> = (0..count).map(|_| self.random(1.6, 3.4)).collect();
        for (item, angle) in self.items.iter_mut().zip(angles) {
            item.swing.target = angle;
        }
        self.gust_back = Some(now + Duration::from_millis(300));
        self.next_gust = now + Duration::from_secs_f32(self.random(7.0, 16.0));
        true
    }

    /// Advances every animation by `dt`. Returns true while anything still moves.
    pub fn step(&mut self, dt: f32, now: Instant, layout: &Layout, hover: Option<u64>, pressed: Option<u64>) -> bool {
        if self.gust_back.is_some_and(|t| now >= t) {
            self.gust_back = None;
            for item in &mut self.items {
                item.swing.target = 0.0;
            }
        }
        let count = self.live_count();
        let mut slot = 0;
        let mut moving = false;
        for item in &mut self.items {
            if !item.falling() {
                item.x.target = layout.slot_x(slot, count);
                slot += 1;
            }
            item.x.step(dt);
            item.arrive.step(dt);
            item.swing.step(dt);
            let goal = if pressed == Some(item.id) {
                0.95
            } else if hover == Some(item.id) {
                1.035
            } else {
                1.0
            };
            // Eased, not springy: it only needs to feel attentive.
            item.scale += (goal - item.scale) * (1.0 - (-dt * 14.0).exp());
            if let Some(t) = item.fall.as_mut() {
                *t += dt;
            }
            if item.copied > 0.0 {
                item.copied = (item.copied - dt).max(0.0);
            }
            moving |= !item.x.at_rest()
                || !item.arrive.at_rest()
                || !item.swing.at_rest()
                || (item.scale - goal).abs() > 0.001
                || item.fall.is_some()
                || item.copied > 0.0;
        }
        self.sweep();
        moving || self.gust_back.is_some()
    }

    /// Makes sure every visible card has its sprite at the current scale.
    pub fn ensure_sprites(&mut self, s: f32) {
        for item in &mut self.items {
            let stale = item.sprite.is_none() || (item.sprite_scale - s).abs() > f32::EPSILON;
            if stale {
                if let Some(thumb) = &item.thumb {
                    item.sprite = card_sprite(thumb, s);
                    item.sprite_scale = s;
                }
            }
        }
    }
}
