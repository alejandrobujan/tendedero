//! Watches the screenshot folder and reports new and changed images to the
//! window. Changes are read with ReadDirectoryChangesW, so the thread sleeps
//! until the folder is actually touched.

use std::collections::HashMap;
use std::ffi::c_void;
use std::fs;
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::thread;
use std::time::{Duration, SystemTime};

use windows::core::PCWSTR;
use windows::Win32::Foundation::{HANDLE, HWND, LPARAM, WPARAM};
use windows::Win32::Storage::FileSystem::*;
use windows::Win32::UI::WindowsAndMessaging::PostMessageW;

use crate::WM_EVENT;

pub enum Event {
    /// Images that appeared since the last scan.
    New(Vec<PathBuf>),
    /// Known images whose contents changed, for example after an edit.
    Modified(PathBuf),
    /// Every scan ends with this, so the line can drop files that were removed.
    Scanned,
    /// A decoded thumbnail, or None if the file could not be read.
    Thumb(PathBuf, Option<tiny_skia::Pixmap>),
}

/// Wakes the window so it drains the event queue.
pub fn post(hwnd: isize) {
    unsafe {
        let _ = PostMessageW(Some(HWND(hwnd as *mut c_void)), WM_EVENT, WPARAM(0), LPARAM(0));
    }
}

const IMAGE_EXTENSIONS: &[&str] = &["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "bmp"];

pub fn spawn(folder: PathBuf, hwnd: isize, events: Sender<Event>) {
    thread::spawn(move || {
        let _ = fs::create_dir_all(&folder);
        // Whatever is already in the folder at launch is not new.
        let mut known = listing(&folder);
        let Some(handle) = open_folder(&folder) else { return };
        let mut buf = vec![0u32; 16 * 1024];
        loop {
            let mut returned = 0u32;
            let watched = unsafe {
                ReadDirectoryChangesW(
                    handle,
                    buf.as_mut_ptr() as *mut c_void,
                    (buf.len() * 4) as u32,
                    false,
                    FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_SIZE,
                    Some(&mut returned),
                    None,
                    None,
                )
            };
            if watched.is_err() {
                thread::sleep(Duration::from_secs(1));
                continue;
            }
            // A screenshot is written in pieces. Give the writer a moment before reading it.

            let now = listing(&folder);
            let new: Vec<PathBuf> = now.keys().filter(|p| !known.contains_key(*p)).cloned().collect();
            let modified: Vec<PathBuf> = now
                .iter()
                .filter(|(p, m)| known.get(*p).is_some_and(|old| old != *m))
                .map(|(p, _)| p.clone())
                .collect();
            known = now;

            if !new.is_empty() {
                let _ = events.send(Event::New(new));
            }
            for path in modified {
                let _ = events.send(Event::Modified(path));
            }
            let _ = events.send(Event::Scanned);
            post(hwnd);
        }
    });
}

/// Image files in the folder, with their last write time.
fn listing(folder: &Path) -> HashMap<PathBuf, Option<SystemTime>> {
    let mut out = HashMap::new();
    let Ok(entries) = fs::read_dir(folder) else { return out };
    for entry in entries.flatten() {
        let path = entry.path();
        let is_image = path
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| IMAGE_EXTENSIONS.contains(&e.to_ascii_lowercase().as_str()));
        if is_image && entry.file_type().is_ok_and(|t| t.is_file()) {
            let modified = entry.metadata().and_then(|m| m.modified()).ok();
            out.insert(path, modified);
        }
    }
    out
}

fn open_folder(folder: &Path) -> Option<HANDLE> {
    let wide: Vec<u16> = folder.as_os_str().encode_wide().chain(Some(0)).collect();
    unsafe {
        CreateFileW(
            PCWSTR(wide.as_ptr()),
            FILE_LIST_DIRECTORY.0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            None,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS,
            None,
        )
        .ok()
    }
}
