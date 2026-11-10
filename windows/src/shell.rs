//! Everything that talks to Windows outside the window: clipboard, drag-out to
//! other apps, Explorer, the Recycle Bin, the tray icon, start-at-login, and
//! checks for a full screen app.

use std::ffi::c_void;
use std::iter::once;
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use windows::core::{BOOL, HRESULT, PCWSTR, implement, w};
use windows::Win32::System::SystemServices::{MODIFIERKEYS_FLAGS};
use windows::Win32::Foundation::{DRAGDROP_S_CANCEL, DRAGDROP_S_DROP, DRAGDROP_S_USEDEFAULTCURSORS, HANDLE, HWND, RECT, S_OK};
use windows::Win32::Graphics::Gdi::{HMONITOR, MONITOR_DEFAULTTONEAREST, MonitorFromWindow};
use windows::Win32::System::Com::{CoTaskMemFree, IBindCtx, IDataObject};
use windows::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, OpenClipboard, RegisterClipboardFormatW, SetClipboardData};
use windows::Win32::System::Memory::{GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalUnlock};
use windows::Win32::System::Ole::{DROPEFFECT, DROPEFFECT_COPY, DROPEFFECT_LINK, DROPEFFECT_MOVE, IDropSource, IDropSource_Impl};
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, MONITORINFO};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use winreg::RegKey;
use winreg::enums::{HKEY_CURRENT_USER, KEY_READ, KEY_WRITE};

use crate::thumb;

pub const WM_TRAY: u32 = WM_APP + 2;
const TRAY_ID: u32 = 1;
const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_VALUE: &str = "Tendedero";

fn wide(s: impl AsRef<std::ffi::OsStr>) -> Vec<u16> {
    s.as_ref().encode_wide().chain(once(0)).collect()
}

/// The folder Windows saves screenshots to (Pictures\Screenshots), which is
/// where Win+PrtScn and the Snipping Tool put them. Created if missing.
pub fn screenshots_folder() -> PathBuf {
    let path = unsafe {
        SHGetKnownFolderPath(&FOLDERID_Screenshots, KF_FLAG_DEFAULT, None)
            .ok()
            .and_then(|pwstr| {
                let s = pwstr.to_string().ok();
                CoTaskMemFree(Some(pwstr.as_ptr() as *const c_void));
                s
            })
    };
    let folder = path
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("USERPROFILE").map(|p| PathBuf::from(p).join("Pictures").join("Screenshots")))
        .unwrap_or_else(|| PathBuf::from("."));
    let _ = std::fs::create_dir_all(&folder);
    folder
}

pub fn open(path: &Path) {
    let file = wide(path);
    unsafe {
        ShellExecuteW(None, w!("open"), PCWSTR(file.as_ptr()), PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL);
    }
}

/// Opens the file in Paint, the closest thing to macOS Markup on Windows.
/// Not every image type has an "edit" verb registered, so Paint is started
/// directly when the shell cannot.
pub fn markup(path: &Path) {
    let file = wide(path);
    unsafe {
        let result = ShellExecuteW(None, w!("edit"), PCWSTR(file.as_ptr()), PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL);
        // ShellExecute returns a value above 32 on success.
        if result.0 as isize <= 32 {
            // The path has spaces in it, so it is quoted for the command line.
            let args = wide(format!("\"{}\"", path.display()));
            ShellExecuteW(None, w!("open"), w!("mspaint.exe"), PCWSTR(args.as_ptr()), PCWSTR::null(), SW_SHOWNORMAL);
        }
    }
}

pub fn open_folder(path: &Path) {
    open(path);
}

pub fn reveal(path: &Path) {
    let args = wide(format!("/select,\"{}\"", path.display()));
    unsafe {
        ShellExecuteW(None, w!("open"), w!("explorer.exe"), PCWSTR(args.as_ptr()), PCWSTR::null(), SW_SHOWNORMAL);
    }
}

/// Moves a file to the Recycle Bin, so it can still be undone from there.
pub fn recycle(path: &Path) -> bool {
    // SHFileOperation wants a double-null-terminated list.
    let mut from = wide(path);
    from.push(0);
    let mut op = SHFILEOPSTRUCTW {
        wFunc: FO_DELETE,
        pFrom: PCWSTR(from.as_ptr()),
        fFlags: (FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT).0 as u16,
        ..Default::default()
    };
    unsafe { SHFileOperationW(&mut op) == 0 && !op.fAnyOperationsAborted.as_bool() }
}

/// Puts the image on the clipboard the way an image copy should look: as PNG
/// when the file is one, as a bitmap for everything else, and as the file
/// itself so Explorer can paste it.
pub fn copy_image(hwnd: HWND, path: &Path) -> bool {
    let Some(pixmap) = thumb::decode(path, 0) else { return false };
    let (w, h) = (pixmap.width(), pixmap.height());
    let mut dib = Vec::with_capacity(40 + (w * h * 4) as usize);
    dib.extend_from_slice(&40u32.to_le_bytes()); // biSize
    dib.extend_from_slice(&(w as i32).to_le_bytes());
    dib.extend_from_slice(&(-(h as i32)).to_le_bytes()); // top-down rows
    dib.extend_from_slice(&1u16.to_le_bytes()); // planes
    dib.extend_from_slice(&32u16.to_le_bytes()); // bits per pixel
    dib.extend_from_slice(&[0u8; 24]); // BI_RGB, sizes and palette left at zero
    for px in pixmap.data().chunks_exact(4) {
        dib.extend_from_slice(&[px[2], px[1], px[0], 255]);
    }
    let png = path
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("png"))
        .then(|| std::fs::read(path).ok())
        .flatten();

    let file_list = drop_files(path);
    unsafe {
        if OpenClipboard(Some(hwnd)).is_err() {
            return false;
        }
        let _ = EmptyClipboard();
        if let Some(png) = png {
            let format = RegisterClipboardFormatW(w!("PNG"));
            set_clipboard(format, &png);
        }
        set_clipboard(8 /* CF_DIB */, &dib);
        set_clipboard(15 /* CF_HDROP */, &file_list);
        let _ = CloseClipboard();
    }
    true
}

/// A DROPFILES block: the header, then one UTF-16 path and a terminating null.
fn drop_files(path: &Path) -> Vec<u8> {
    let mut bytes = vec![0u8; 20];
    bytes[0..4].copy_from_slice(&20u32.to_le_bytes()); // offset to the file list
    bytes[16..20].copy_from_slice(&1u32.to_le_bytes()); // file names are wide
    for unit in path.as_os_str().encode_wide().chain([0, 0]) {
        bytes.extend_from_slice(&unit.to_le_bytes());
    }
    bytes
}

unsafe fn set_clipboard(format: u32, bytes: &[u8]) {
    unsafe {
        let Ok(handle) = GlobalAlloc(GMEM_MOVEABLE, bytes.len()) else { return };
        let ptr = GlobalLock(handle) as *mut u8;
        if ptr.is_null() {
            return;
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr, bytes.len());
        let _ = GlobalUnlock(handle);
        // On success the clipboard owns the memory, so it must not be freed here.
        let _ = SetClipboardData(format, Some(HANDLE(handle.0)));
    }
}

/// Hands the file to whatever app it is dropped on, through the shell, so the
/// receiving app gets exactly what Explorer would give it. Returns the effect
/// the target chose: Move means the file was moved (into a folder, say), and
/// None means nothing accepted it.
pub fn drag_file(hwnd: HWND, path: &Path) -> DROPEFFECT {
    let file = wide(path);
    unsafe {
        let mut pidl = std::ptr::null_mut();
        if SHParseDisplayName(PCWSTR(file.as_ptr()), None::<&IBindCtx>, &mut pidl, 0, None).is_err() || pidl.is_null() {
            return DROPEFFECT(0);
        }
        let data: Option<IDataObject> = SHCreateDataObject(None, Some(&[pidl as *const _]), None::<&IDataObject>).ok();
        let effect = match data {
            Some(data) => {
                let source: IDropSource = DropSource.into();
                SHDoDragDrop(Some(hwnd), &data, &source, DROPEFFECT_COPY | DROPEFFECT_MOVE | DROPEFFECT_LINK)
                    .unwrap_or(DROPEFFECT(0))
            }
            None => DROPEFFECT(0),
        };
        CoTaskMemFree(Some(pidl as *const c_void));
        effect
    }
}

/// Ends the drag when the mouse button is released or Escape is pressed.
#[implement(IDropSource)]
struct DropSource;

impl IDropSource_Impl for DropSource_Impl {
    fn QueryContinueDrag(&self, fescapepressed: BOOL, _grfkeystate: MODIFIERKEYS_FLAGS) -> HRESULT {
        if fescapepressed.as_bool() {
            DRAGDROP_S_CANCEL
        } else if unsafe { GetAsyncKeyState(VK_LBUTTON.0 as i32) } >= 0 {
            DRAGDROP_S_DROP
        } else {
            S_OK
        }
    }

    fn GiveFeedback(&self, _dweffect: DROPEFFECT) -> HRESULT {
        DRAGDROP_S_USEDEFAULTCURSORS
    }
}

/// True when a full screen app covers the whole monitor, like a video, a game
/// or a browser in F11. The line stays out of its way. The desktop and the
/// taskbar do not count.
pub fn full_screen_on(monitor: HMONITOR, rect: RECT) -> bool {
    unsafe {
        let fg = GetForegroundWindow();
        // The desktop is never a full screen app, whatever its size.
        if fg.is_invalid() || fg == GetDesktopWindow() {
            return false;
        }
        let mut class = [0u16; 64];
        let len = GetClassNameW(fg, &mut class) as usize;
        let name = String::from_utf16_lossy(&class[..len]);
        if matches!(name.as_str(), "Progman" | "WorkerW" | "Shell_TrayWnd" | "Shell_SecondaryTrayWnd") {
            return false;
        }
        // A window with a title bar is not full screen, even when it is maximised
        // over a monitor whose taskbar auto-hides. Full screen windows drop it.
        let style = GetWindowLongPtrW(fg, GWL_STYLE) as u32;
        if style & WS_CAPTION.0 == WS_CAPTION.0 {
            return false;
        }
        let mut win = RECT::default();
        if GetWindowRect(fg, &mut win).is_err() {
            return false;
        }
        let fg_monitor = MonitorFromWindow(fg, MONITOR_DEFAULTTONEAREST);
        fg_monitor == monitor
            && (win.left - rect.left).abs() <= 1
            && (win.top - rect.top).abs() <= 1
            && (win.right - rect.right).abs() <= 1
            && (win.bottom - rect.bottom).abs() <= 1
    }
}

pub fn monitor_info(monitor: HMONITOR) -> Option<MONITORINFO> {
    let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
    unsafe { GetMonitorInfoW(monitor, &mut info).as_bool().then_some(info) }
}

pub fn start_at_login() -> bool {
    RegKey::predef(HKEY_CURRENT_USER)
        .open_subkey_with_flags(RUN_KEY, KEY_READ)
        .and_then(|k| k.get_value::<String, _>(RUN_VALUE))
        .is_ok()
}

pub fn set_start_at_login(on: bool) {
    let Ok(key) = RegKey::predef(HKEY_CURRENT_USER).open_subkey_with_flags(RUN_KEY, KEY_WRITE) else { return };
    if on {
        if let Some(exe) = crate::settings::exe_path() {
            let _ = key.set_value(RUN_VALUE, &format!("\"{}\"", exe.display()));
        }
    } else {
        let _ = key.delete_value(RUN_VALUE);
    }
}

pub fn add_tray(hwnd: HWND) {
    let mut nid = notify_data(hwnd);
    nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    nid.uCallbackMessage = WM_TRAY;
    nid.hIcon = app_icon();
    let tip = wide("Tendedero");
    nid.szTip[..tip.len().min(127)].copy_from_slice(&tip[..tip.len().min(127)]);
    unsafe {
        let _ = Shell_NotifyIconW(NIM_ADD, &nid);
    }
}

pub fn remove_tray(hwnd: HWND) {
    let nid = notify_data(hwnd);
    unsafe {
        let _ = Shell_NotifyIconW(NIM_DELETE, &nid);
    }
}

fn notify_data(hwnd: HWND) -> NOTIFYICONDATAW {
    NOTIFYICONDATAW {
        cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: hwnd,
        uID: TRAY_ID,
        ..Default::default()
    }
}

/// The app icon, compiled in as resource 1 by build.rs.
pub fn app_icon() -> windows::Win32::UI::WindowsAndMessaging::HICON {
    unsafe {
        let module = GetModuleHandleW(None).unwrap_or_default();
        LoadIconW(Some(windows::Win32::Foundation::HINSTANCE(module.0)), PCWSTR(1usize as *const u16)).unwrap_or_default()
    }
}

pub fn set_foreground(hwnd: HWND) {
    unsafe {
        let _ = SetForegroundWindow(hwnd);
    }
}
