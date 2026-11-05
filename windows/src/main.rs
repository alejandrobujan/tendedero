//! Tendedero for Windows: screenshots hang on a line across the top of the
//! screen, so you can copy, drag or discard them without leaving what you were doing.

#![windows_subsystem = "windows"]

mod app;
mod i18n;
mod line;
mod render;
mod settings;
mod shell;
mod sound;
mod thumb;
mod watch;

use windows::Win32::Foundation::{ERROR_ALREADY_EXISTS, GetLastError};
use windows::Win32::System::Com::{COINIT_APARTMENTTHREADED, CoInitializeEx};
use windows::Win32::System::Ole::OleInitialize;
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::WindowsAndMessaging::{DispatchMessageW, GetMessageW, MSG, TranslateMessage, WM_APP};
use windows::core::w;

/// Posted to the window when a background thread has something for the UI.
pub const WM_EVENT: u32 = WM_APP + 1;

fn main() {
    unsafe {
        // Only one line per user session. A second launch just exits.
        let _mutex = CreateMutexW(None, true, w!("Local\\Tendedero.SingleInstance"));
        if GetLastError() == ERROR_ALREADY_EXISTS {
            return;
        }
        // The UI thread is a single-threaded apartment, which OLE drag-and-drop and the clipboard need.
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let _ = OleInitialize(None);
    }

    let Some(app) = app::App::create() else { return };

    let mut msg = MSG::default();
    unsafe {
        while GetMessageW(&mut msg, None, 0, 0).0 > 0 {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        let mut app = Box::from_raw(app);
        app.shutdown();
    }
}
