//! Decodes screenshots with Windows Imaging Component. It runs on a worker
//! thread, so a big file never stalls the line.

use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Sender, channel};
use std::thread;
use std::time::Duration;

use tiny_skia::{IntSize, Pixmap};
use windows::core::PCWSTR;
use windows::Win32::Graphics::Imaging::*;
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx};

use crate::watch::{Event, post};

/// Longest side of a card's photo. Cards are never drawn bigger than this,
/// even on a 200% display, so there is no point keeping more pixels.
pub const THUMB_SIDE: u32 = 480;

/// Starts the decode thread. Requests go in through the returned sender, and
/// results come back as `Event::Thumb` plus a wake-up message to the window.
pub fn spawn(hwnd: isize, events: Sender<Event>) -> Sender<PathBuf> {
    let (tx, rx) = channel::<PathBuf>();
    thread::spawn(move || {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        }
        for path in rx {
            // A file the system is still writing can fail to decode. Retry a
            // few times before giving up on it.
            let pixmap = (0..4).find_map(|attempt| {
                if attempt > 0 {
                    thread::sleep(Duration::from_millis(150));
                }
                decode(&path, THUMB_SIDE)
            });
            if events.send(Event::Thumb(path, pixmap)).is_ok() {
                post(hwnd);
            }
        }
    });
    tx
}

/// Decodes the first frame of an image into premultiplied RGBA, scaled so its
/// longest side is at most `max_side` (0 keeps the full size).
pub fn decode(path: &Path, max_side: u32) -> Option<Pixmap> {
    unsafe {
        let factory: IWICImagingFactory =
            CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER).ok()?;
        let wide: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        let decoder = factory
            .CreateDecoderFromFilename(PCWSTR(wide.as_ptr()), None, windows::Win32::Foundation::GENERIC_READ, WICDecodeMetadataCacheOnDemand)
            .ok()?;
        let frame = decoder.GetFrame(0).ok()?;
        let (mut w, mut h) = (0u32, 0u32);
        frame.GetSize(&mut w, &mut h).ok()?;
        if w == 0 || h == 0 {
            return None;
        }
        let converter = factory.CreateFormatConverter().ok()?;
        converter
            .Initialize(&frame, &GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, None, 0.0, WICBitmapPaletteTypeCustom)
            .ok()?;

        let (tw, th) = fit(w, h, max_side);
        let source: IWICBitmapSource = if (tw, th) != (w, h) {
            let scaler = factory.CreateBitmapScaler().ok()?;
            scaler.Initialize(&converter, tw, th, WICBitmapInterpolationModeFant).ok()?;
            windows::core::Interface::cast(&scaler).ok()?
        } else {
            windows::core::Interface::cast(&converter).ok()?
        };

        let stride = tw * 4;
        let mut buf = vec![0u8; (stride * th) as usize];
        source.CopyPixels(std::ptr::null(), stride, &mut buf).ok()?;
        // WIC hands out premultiplied BGRA; tiny-skia wants premultiplied RGBA.
        for px in buf.chunks_exact_mut(4) {
            px.swap(0, 2);
        }
        Pixmap::from_vec(buf, IntSize::from_wh(tw, th)?)
    }
}

fn fit(w: u32, h: u32, max_side: u32) -> (u32, u32) {
    if max_side == 0 || w.max(h) <= max_side {
        return (w, h);
    }
    let s = max_side as f32 / w.max(h) as f32;
    (((w as f32 * s).round() as u32).max(1), ((h as f32 * s).round() as u32).max(1))
}
