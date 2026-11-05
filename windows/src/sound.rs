//! Short blips, synthesised once as WAV bytes and played from memory. No sound
//! files ship with the app, and nothing is decoded at play time.

use std::sync::OnceLock;
use windows::core::PCWSTR;
use windows::Win32::Media::Audio::{PlaySoundW, SND_ASYNC, SND_MEMORY, SND_NODEFAULT};

const RATE: u32 = 22_050;

static TINK: OnceLock<Vec<u8>> = OnceLock::new();
static POP: OnceLock<Vec<u8>> = OnceLock::new();

pub fn tink() {
    play(TINK.get_or_init(|| wav(2400.0, 2900.0, 0.12, 40.0, 0.35)));
}

pub fn pop() {
    play(POP.get_or_init(|| wav(320.0, 160.0, 0.10, 30.0, 0.40)));
}

fn play(bytes: &[u8]) {
    // SND_ASYNC keeps playing after this returns, so the buffer must stay
    // alive: it lives in a static above.
    unsafe {
        let _ = PlaySoundW(PCWSTR(bytes.as_ptr() as *const u16), None, SND_MEMORY | SND_ASYNC | SND_NODEFAULT);
    }
}

/// A mono 16-bit WAV: a sine that glides from `f0` to `f1` Hz, with an
/// exponential decay so it rings out like a clothespin tapping metal.
fn wav(f0: f32, f1: f32, seconds: f32, decay: f32, volume: f32) -> Vec<u8> {
    let n = (RATE as f32 * seconds) as usize;
    let mut pcm = Vec::with_capacity(n * 2);
    let mut phase = 0.0f32;
    for i in 0..n {
        let t = i as f32 / RATE as f32;
        let f = f0 + (f1 - f0) * (t / seconds);
        phase += std::f32::consts::TAU * f / RATE as f32;
        let env = (-decay * t).exp();
        let s = (phase.sin() * env * volume * i16::MAX as f32) as i16;
        pcm.extend_from_slice(&s.to_le_bytes());
    }
    let data_len = pcm.len() as u32;
    let mut out = Vec::with_capacity(44 + pcm.len());
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_len).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // mono
    out.extend_from_slice(&RATE.to_le_bytes());
    out.extend_from_slice(&(RATE * 2).to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    out.extend_from_slice(&pcm);
    out
}
