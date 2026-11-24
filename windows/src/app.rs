//! The app: one hidden-by-default layered window that hangs the line across
//! the top of the screen the pointer is on, plus the tray icon and the hot key.
//! Everything runs on the UI thread. Background threads only post events.

use std::ffi::c_void;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::{Duration, Instant, SystemTime};

use tiny_skia::Pixmap;
use windows::core::{PCWSTR, w};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::System::SystemServices::MK_LBUTTON;
use windows::Win32::System::Diagnostics::Debug::MessageBeep;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::i18n::t;
use crate::line::{Layout, Line, PANEL_H};
use crate::render::{Painter, Ui};
use crate::settings::Settings;
use crate::shell::{self, WM_TRAY};
use crate::watch::Event;
use crate::{sound, thumb, watch, WM_EVENT};

const CLASS: PCWSTR = w!("Tendedero.Line");
const TIMER_TICK: usize = 1;
const TIMER_ANIM: usize = 2;
const TIMER_LONG: usize = 3;
const TIMER_PRUNE: usize = 4;
const TIMER_WELCOME: usize = 5;
const HOTKEY_TOGGLE: i32 = 1;

const CMD_TOGGLE: u32 = 1;
const CMD_CLEAR: u32 = 2;
const CMD_FOLDER: u32 = 3;
const CMD_SOUND: u32 = 4;
const CMD_LOGIN: u32 = 5;
const CMD_QUIT: u32 = 6;
const CMD_COPY: u32 = 10;
const CMD_OPEN: u32 = 11;
const CMD_MARKUP: u32 = 12;
const CMD_REVEAL: u32 = 13;
const CMD_TAKE_DOWN: u32 = 14;
const CMD_TRASH: u32 = 15;

const WM_LONG_PRESS_MS: u32 = 450;

/// What a window message asks for once its handler has finished. These
/// start nested message loops (drag-out, popup menus), so they run after the
/// `&mut App` borrow has ended.
pub enum Deferred {
    None,
    Drag(HWND, PathBuf),
    Menu(MenuKind, POINT),
}

#[derive(Clone, Copy, PartialEq)]
pub enum MenuKind {
    Card,
    Tray,
}

#[derive(Clone, Copy)]
struct Press {
    id: u64,
    origin: (i32, i32),
    long: bool,
    dragged: bool,
}

struct Dib {
    hdc: HDC,
    bitmap: HBITMAP,
    old: HGDIOBJ,
    bits: *mut u8,
    w: i32,
    h: i32,
}

impl Dib {
    fn new(w: i32, h: i32) -> Option<Dib> {
        unsafe {
            let hdc = CreateCompatibleDC(None);
            let info = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: w,
                    biHeight: -h, // top-down
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                },
                bmiColors: [RGBQUAD::default()],
            };
            let mut bits: *mut c_void = std::ptr::null_mut();
            let bitmap = CreateDIBSection(Some(hdc), &info, DIB_RGB_COLORS, &mut bits, None, 0).ok()?;
            let old = SelectObject(hdc, bitmap.into());
            Some(Dib { hdc, bitmap, old, bits: bits as *mut u8, w, h })
        }
    }
}

impl Drop for Dib {
    fn drop(&mut self) {
        unsafe {
            SelectObject(self.hdc, self.old);
            let _ = DeleteObject(self.bitmap.into());
            let _ = DeleteDC(self.hdc);
        }
    }
}

pub struct App {
    hwnd: HWND,
    settings: Settings,
    line: Line,
    painter: Painter,
    dib: Option<Dib>,
    decode_tx: Sender<PathBuf>,
    events: Receiver<Event>,
    folder: PathBuf,

    // Where the line sits: the monitor it is on, in device pixels.
    monitor: HMONITOR,
    monitor_rect: RECT,
    work: RECT,
    scale: f32,

    // The state machine, as in the mac app.
    wanted: bool,
    present: bool,
    revealed: bool,
    pinned: bool,
    keep_open: bool,
    peek_until: Option<Instant>,
    hot_since: Option<Instant>,
    away_since: Option<Instant>,
    empty_since: Option<Instant>,
    band_suppressed: bool,
    buttons_were_down: bool,
    last_live: usize,

    // Animation: how far the line has slid down, 0 (hidden) to 1 (shown).
    slide: f32,
    shown: bool,
    anim_running: bool,
    dirty: bool,
    last_frame: Instant,

    hover: Option<u64>,
    pressed: Option<Press>,
    dragging: Option<u64>,
    menu_target: Option<u64>,
    hits: Vec<(u64, (i32, i32, i32, i32))>,
    hotkey: bool,
    /// Whether mouse input passes through the window. It does, except over a card.
    click_through: bool,
}

pub fn register_class(hinst: HINSTANCE) {
    unsafe {
        let class = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            style: CS_DBLCLKS,
            lpfnWndProc: Some(wndproc),
            hInstance: hinst,
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            lpszClassName: CLASS,
            ..Default::default()
        };
        RegisterClassExW(&class);
    }
}

impl App {
    /// Creates the window and the background threads. Returns a pointer that
    /// the caller owns and must free after the message loop ends.
    pub fn create() -> Option<*mut App> {
        unsafe {
            let hinst: HINSTANCE = GetModuleHandleW(None).ok()?.into();
            register_class(hinst);
            let hwnd = CreateWindowExW(
                WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                CLASS,
                w!("Tendedero"),
                WS_POPUP,
                0,
                0,
                1,
                1,
                None,
                None,
                Some(hinst),
                None,
            )
            .ok()?;
            let raw = hwnd.0 as isize;

            let folder = shell::screenshots_folder();
            let (tx, rx) = channel::<Event>();
            let decode_tx = thumb::spawn(raw, tx.clone());
            watch::spawn(folder.clone(), raw, tx);

            let settings = Settings::load();
            let monitor = MonitorFromPoint(cursor(), MONITOR_DEFAULTTONEAREST);

            let app = Box::new(App {
                hwnd,
                painter: Painter::new(&load_font_bytes(), 0),
                settings,
                line: Line::new(),
                dib: None,
                decode_tx,
                events: rx,
                folder,
                monitor,
                monitor_rect: RECT::default(),
                work: RECT::default(),
                scale: 1.0,
                wanted: false,
                present: false,
                revealed: false,
                pinned: false,
                keep_open: false,
                peek_until: None,
                hot_since: None,
                away_since: None,
                empty_since: None,
                band_suppressed: false,
                buttons_were_down: false,
                last_live: 0,
                slide: 0.0,
                shown: false,
                anim_running: false,
                dirty: false,
                last_frame: Instant::now(),
                hover: None,
                pressed: None,
                dragging: None,
                menu_target: None,
                hits: Vec::new(),
                hotkey: false,
                click_through: true,
            });
            let ptr = Box::into_raw(app);
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, ptr as isize);
            (*ptr).start();
            Some(ptr)
        }
    }

    /// Everything that needs the window to exist: hot key, tray, startup state.
    fn start(&mut self) {
        self.place(self.monitor);
        unsafe {
            self.hotkey = RegisterHotKey(Some(self.hwnd), HOTKEY_TOGGLE, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, 0x54).is_ok();
        }
        shell::add_tray(self.hwnd);

        // Cards from last time come back quietly. A card whose file is gone is skipped.
        let saved = std::mem::take(&mut self.settings.pegged);
        for path in saved {
            if path.is_file() {
                self.hang_quietly(path);
            }
        }
        self.last_live = self.line.live_count();
        self.wanted = self.last_live > 0;

        if !self.settings.welcomed {
            // First run: show the line for a few seconds so people see what it does.
            self.settings.welcomed = true;
            self.keep_open = true;
            self.wanted = true;
            self.refresh();
            self.reveal(true, 0.0);
            unsafe {
                SetTimer(Some(self.hwnd), TIMER_WELCOME, 5000, None);
            }
        }
        self.refresh();
        self.save();
        self.invalidate();
    }

    pub fn shutdown(&mut self) {
        self.save();
        unsafe {
            if self.hotkey {
                let _ = UnregisterHotKey(Some(self.hwnd), HOTKEY_TOGGLE);
            }
        }
        shell::remove_tray(self.hwnd);
    }

    // MARK: Window messages

    /// Handles one message. Returns what the window procedure should do next.
    fn on_message(&mut self, msg: u32, wp: WPARAM, lp: LPARAM) -> (LRESULT, Deferred) {
        let mut out = Deferred::None;
        let result = match msg {
            WM_EVENT => {
                self.drain_events();
                LRESULT(0)
            }
            WM_TIMER => {
                match wp.0 {
                    TIMER_TICK => self.tick(),
                    TIMER_ANIM => self.animate(),
                    TIMER_LONG => self.long_press(),
                    TIMER_PRUNE => self.prune(),
                    TIMER_WELCOME => {
                        unsafe {
                            let _ = KillTimer(Some(self.hwnd), TIMER_WELCOME);
                        }
                        if self.line.live_count() == 0 {
                            self.keep_open = false;
                            self.wanted = false;
                            self.refresh();
                        }
                    }
                    _ => {}
                }
                LRESULT(0)
            }
            WM_HOTKEY => {
                self.toggle();
                LRESULT(0)
            }
            WM_TRAY => {
                match (lp.0 & 0xFFFF) as u32 {
                    WM_LBUTTONUP => self.toggle(),
                    WM_RBUTTONUP => out = Deferred::Menu(MenuKind::Tray, cursor()),
                    _ => {}
                }
                LRESULT(0)
            }
            WM_COMMAND => {
                let id = (wp.0 & 0xFFFF) as u32;
                self.command(id);
                LRESULT(0)
            }
            WM_NCHITTEST => {
                let point = screen_point(lp);
                let client = self.to_client(point);
                if self.card_at(client).is_some() { LRESULT(HTCLIENT as isize) } else { LRESULT(HTTRANSPARENT as isize) }
            }
            WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
            WM_SETCURSOR => {
                let client = self.to_client(cursor());
                let hand = self.card_at(client).is_some();
                unsafe {
                    let icon = if hand { IDC_HAND } else { IDC_ARROW };
                    if let Ok(cursor) = LoadCursorW(None, icon) {
                        SetCursor(Some(cursor));
                    }
                }
                LRESULT(1)
            }
            WM_LBUTTONDOWN => {
                self.mouse_down(client_point(lp));
                LRESULT(0)
            }
            WM_LBUTTONDBLCLK => {
                let p = client_point(lp);
                if let Some(id) = self.card_at(p) {
                    if !self.is_cross(id, p) {
                        self.pressed = None;
                        self.open_card(id);
                    }
                }
                LRESULT(0)
            }
            WM_MOUSEMOVE => {
                out = self.mouse_move(client_point(lp), wp);
                LRESULT(0)
            }
            WM_LBUTTONUP => {
                self.mouse_up();
                LRESULT(0)
            }
            WM_RBUTTONUP => {
                let p = client_point(lp);
                if let Some(id) = self.card_at(p) {
                    self.menu_target = Some(id);
                    out = Deferred::Menu(MenuKind::Card, cursor());
                }
                LRESULT(0)
            }
            WM_PAINT => {
                unsafe {
                    let _ = ValidateRect(Some(self.hwnd), None);
                }
                LRESULT(0)
            }
            WM_DISPLAYCHANGE | WM_SETTINGCHANGE => {
                // Screens were added, removed or rescaled. Hang on the one under the pointer.
                self.place(unsafe { MonitorFromPoint(cursor(), MONITOR_DEFAULTTONEAREST) });
                LRESULT(0)
            }
            WM_DESTROY => {
                unsafe {
                    PostQuitMessage(0);
                }
                LRESULT(0)
            }
            m if m == taskbar_created() => {
                shell::add_tray(self.hwnd);
                LRESULT(0)
            }
            _ => unsafe { DefWindowProcW(self.hwnd, msg, wp, lp) },
        };
        (result, out)
    }

    /// Handles a deferred drag-out or menu, once no borrow is held.
    fn finish_deferred(&mut self, action: Deferred) -> Option<u32> {
        match action {
            Deferred::None => None,
            Deferred::Drag(hwnd, path) => {
                let effect = shell::drag_file(hwnd, &path);
                self.drag_ended(effect);
                None
            }
            Deferred::Menu(kind, at) => {
                let menu = self.build_menu(kind);
                let hwnd = self.hwnd;
                shell::set_foreground(hwnd);
                let cmd = unsafe {
                    TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD, at.x, at.y, None, hwnd, None).0 as u32
                };
                unsafe {
                    let _ = DestroyMenu(menu);
                    let _ = PostMessageW(Some(hwnd), WM_NULL, WPARAM(0), LPARAM(0));
                }
                (cmd != 0).then_some(cmd)
            }
        }
    }

    fn build_menu(&self, kind: MenuKind) -> HMENU {
        unsafe {
            let menu = CreatePopupMenu().unwrap_or_default();
            let add = |id: u32, text: &str, flags: MENU_ITEM_FLAGS| {
                let wide: Vec<u16> = text.encode_utf16().chain(Some(0)).collect();
                let _ = AppendMenuW(menu, flags | MF_STRING, id as usize, PCWSTR(wide.as_ptr()));
            };
            let sep = || {
                let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
            };
            match kind {
                MenuKind::Card => {
                    add(CMD_COPY, &t("Copy"), MF_ENABLED);
                    add(CMD_OPEN, &t("Open"), MF_ENABLED);
                    add(CMD_MARKUP, &t("Markup"), MF_ENABLED);
                    add(CMD_REVEAL, &t("Show in Finder"), MF_ENABLED);
                    sep();
                    add(CMD_TAKE_DOWN, &t("Take down"), MF_ENABLED);
                    add(CMD_TRASH, &t("Move to Trash"), MF_ENABLED);
                }
                MenuKind::Tray => {
                    add(CMD_TOGGLE, &format!("{}\tCtrl+Alt+T", if self.revealed { t("Hide line") } else { t("Show line") }), MF_ENABLED);
                    add(CMD_CLEAR, &t("Take everything down"), if self.line.live_count() > 0 { MF_ENABLED } else { MF_GRAYED });
                    add(CMD_FOLDER, &t("Open screenshots folder"), MF_ENABLED);
                    sep();
                    let check = |on: bool| if on { MF_CHECKED } else { MF_UNCHECKED };
                    add(CMD_SOUND, &t("Sounds"), check(self.settings.sound) | MF_ENABLED);
                    add(CMD_LOGIN, &t("Open at login"), check(shell::start_at_login()) | MF_ENABLED);
                    sep();
                    add(CMD_QUIT, &t("Quit Tendedero"), MF_ENABLED);
                }
            }
            menu
        }
    }

    fn command(&mut self, id: u32) {
        match id {
            CMD_TOGGLE => self.toggle(),
            CMD_CLEAR => self.clear(),
            CMD_FOLDER => shell::open_folder(&self.folder),
            CMD_SOUND => {
                self.settings.sound = !self.settings.sound;
                self.save();
            }
            CMD_LOGIN => shell::set_start_at_login(!shell::start_at_login()),
            CMD_QUIT => unsafe {
                let _ = DestroyWindow(self.hwnd);
            },
            _ => {
                let Some(target) = self.menu_target.take() else { return };
                let Some(path) = self.path_of(target) else { return };
                match id {
                    CMD_COPY => self.copy_card(target, &path),
                    CMD_OPEN => shell::open(&path),
                    CMD_MARKUP => shell::markup(&path),
                    CMD_REVEAL => shell::reveal(&path),
                    CMD_TAKE_DOWN => self.take_down(target),
                    CMD_TRASH => self.trash(target, &path),
                    _ => {}
                }
            }
        }
    }

    // MARK: Mouse on the cards

    fn mouse_down(&mut self, p: (i32, i32)) {
        let Some(id) = self.card_at(p) else { return };
        if self.is_cross(id, p) {
            self.take_down(id);
            return;
        }
        self.pressed = Some(Press { id, origin: p, long: false, dragged: false });
        unsafe {
            SetCapture(self.hwnd);
            SetTimer(Some(self.hwnd), TIMER_LONG, WM_LONG_PRESS_MS, None);
        }
        self.invalidate();
    }

    fn mouse_move(&mut self, p: (i32, i32), wp: WPARAM) -> Deferred {
        let held = wp.0 & MK_LBUTTON.0 as usize != 0;
        if let Some(press) = self.pressed {
            if held && !press.dragged && !press.long {
                let dx = (p.0 - press.origin.0).abs();
                let dy = (p.1 - press.origin.1).abs();
                let slop = unsafe { GetSystemMetrics(SM_CXDRAG) }.max(4);
                if dx.max(dy) > slop {
                    if let Some(path) = self.path_of(press.id) {
                        unsafe {
                            let _ = KillTimer(Some(self.hwnd), TIMER_LONG);
                            let _ = ReleaseCapture();
                        }
                        self.pressed = None;
                        self.dragging = Some(press.id);
                        self.invalidate();
                        return Deferred::Drag(self.hwnd, path);
                    }
                }
            }
        }
        let next = self.card_at(p);
        if next != self.hover {
            self.hover = next;
            self.invalidate();
        }
        Deferred::None
    }

    fn drag_ended(&mut self, effect: windows::Win32::System::Ole::DROPEFFECT) {
        self.dragging = None;
        // Dropped into a folder, the file was moved away. Check once the mover is done.
        if effect.0 & windows::Win32::System::Ole::DROPEFFECT_MOVE.0 != 0 {
            unsafe {
                SetTimer(Some(self.hwnd), TIMER_PRUNE, 700, None);
            }
        }
        self.invalidate();
    }

    fn mouse_up(&mut self) {
        let Some(press) = self.pressed.take() else { return };
        unsafe {
            let _ = KillTimer(Some(self.hwnd), TIMER_LONG);
            let _ = ReleaseCapture();
        }
        if !press.long && !press.dragged {
            if let Some(path) = self.path_of(press.id) {
                self.copy_card(press.id, &path);
            }
        }
        self.invalidate();
    }

    fn long_press(&mut self) {
        unsafe {
            let _ = KillTimer(Some(self.hwnd), TIMER_LONG);
        }
        let Some(press) = self.pressed.as_mut() else { return };
        press.long = true;
        let id = press.id;
        if let Some(path) = self.path_of(id) {
            shell::markup(&path);
        }
        self.pressed = None;
        unsafe {
            let _ = ReleaseCapture();
        }
        self.invalidate();
    }

    fn open_card(&mut self, id: u64) {
        if let Some(path) = self.path_of(id) {
            shell::open(&path);
        }
    }

    fn copy_card(&mut self, id: u64, path: &Path) {
        if shell::copy_image(self.hwnd, path) {
            if let Some(item) = self.line.items.iter_mut().find(|i| i.id == id) {
                item.copied = 1.2;
            }
            self.invalidate();
        }
    }

    fn trash(&mut self, id: u64, path: &Path) {
        if shell::recycle(path) {
            self.line.drop_card(id, 0.0);
            self.after_drop(false);
        } else {
            unsafe {
                let _ = MessageBeep(MB_ICONHAND);
            }
        }
    }

    fn take_down(&mut self, id: u64) {
        if self.line.drop_card(id, 0.0) {
            self.after_drop(true);
        }
    }

    fn clear(&mut self) {
        if self.line.drop_all() > 0 {
            self.after_drop(true);
        }
    }

    fn after_drop(&mut self, sound_on: bool) {
        if sound_on && self.settings.sound {
            sound::pop();
        }
        self.items_changed();
        self.invalidate();
    }

    /// The first card in the line, the cursor's card, or its path.
    fn path_of(&self, id: u64) -> Option<PathBuf> {
        self.line.items.iter().find(|i| i.id == id && !i.falling()).map(|i| i.path.clone())
    }

    fn card_at(&self, p: (i32, i32)) -> Option<u64> {
        self.hits
            .iter()
            .rev()
            .find(|(_, (l, t, r, b))| p.0 >= *l && p.0 < *r && p.1 >= *t && p.1 < *b)
            .map(|(id, _)| *id)
    }

    /// Like `card_at`, but a few pixels wider, so a pointer on a card's edge
    /// does not flicker between passing through and catching the click.
    fn card_at_padded(&self, p: (i32, i32)) -> bool {
        let pad = 4;
        self.hits.iter().any(|(_, (l, t, r, b))| p.0 >= l - pad && p.0 < r + pad && p.1 >= t - pad && p.1 < b + pad)
    }

    /// Lets mouse input through the window (true) or takes it for the cards (false).
    /// The window only changes when the value does.
    fn set_click_through(&mut self, on: bool) {
        if self.click_through == on {
            return;
        }
        self.click_through = on;
        unsafe {
            let ex = GetWindowLongPtrW(self.hwnd, GWL_EXSTYLE);
            let bit = WS_EX_TRANSPARENT.0 as isize;
            let next = if on { ex | bit } else { ex & !bit };
            SetWindowLongPtrW(self.hwnd, GWL_EXSTYLE, next);
            // Make the change take effect for hit testing straight away.
            let _ = SetWindowPos(
                self.hwnd,
                None,
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED,
            );
        }
        // A layered window's input shape is refreshed when it is presented.
        self.invalidate();
    }

    /// The discard cross: the top-left 26 points of the card.
    fn is_cross(&self, id: u64, p: (i32, i32)) -> bool {
        let Some((_, (l, t, _, _))) = self.hits.iter().find(|(i, _)| *i == id) else { return false };
        let size = (26.0 * self.scale) as i32;
        p.0 < l + size && p.1 < t + size
    }

    // MARK: Events from the watcher and the decoder

    fn drain_events(&mut self) {
        let mut changed = false;
        while let Ok(event) = self.events.try_recv() {
            match event {
                Event::New(paths) => {
                    let mut paths = paths;
                    paths.sort_by_key(|p| p.metadata().and_then(|m| m.modified()).unwrap_or(SystemTime::UNIX_EPOCH));
                    for path in paths {
                        if self.line.contains_path(&path) {
                            continue;
                        }
                        self.hang(path);
                        changed = true;
                    }
                }
                Event::Modified(path) => {
                    let mtime = path.metadata().and_then(|m| m.modified()).ok();
                    if let Some(item) = self.line.items.iter_mut().find(|i| i.path == path && !i.falling()) {
                        item.mtime = mtime;
                        let _ = self.decode_tx.send(path);
                    }
                }
                Event::Thumb(path, pixmap) => {
                    let mut dead = Vec::new();
                    for item in self.line.items.iter_mut().filter(|i| i.path == path && !i.falling()) {
                        match &pixmap {
                            Some(p) => {
                                item.thumb = Some(p.clone());
                                item.sprite = None;
                            }
                            None => dead.push(item.id),
                        }
                    }
                    for id in dead {
                        self.line.drop_card(id, 0.0);
                        changed = true;
                    }
                }
                Event::Scanned => {
                    if self.folder.is_dir() {
                        let gone = self.line.prune_missing(|p| p.exists());
                        changed |= !gone.is_empty();
                    }
                }
            }
        }
        if changed {
            self.items_changed();
        }
        self.invalidate();
    }

    /// A new screenshot hangs on the line. It drops in and the line shows itself for a moment.
    fn hang(&mut self, path: PathBuf) {
        let mtime = path.metadata().and_then(|m| m.modified()).ok();
        let layout = self.layout();
        self.line.hang(path.clone(), mtime, &layout);
        let _ = self.decode_tx.send(path);
        self.line.trim(layout.max_items());
        if self.settings.sound {
            sound::tink();
        }
        // The line comes down on the screen the pointer is on, where the capture was taken.
        let mut point = POINT::default();
        unsafe {
            let _ = GetCursorPos(&mut point);
        }
        let here = unsafe { MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST) };
        if here != self.monitor {
            self.place(here);
        }
        self.wanted = true;
        self.refresh();
        self.reveal(false, 2.5);
    }

    fn hang_quietly(&mut self, path: PathBuf) {
        let mtime = path.metadata().and_then(|m| m.modified()).ok();
        let layout = self.layout();
        self.line.hang(path.clone(), mtime, &layout);
        let _ = self.decode_tx.send(path);
    }

    /// Keeps the saved list, the empty-line rule and the hot-zone state in step with the cards.
    fn items_changed(&mut self) {
        let live = self.line.live_count();
        if live == 0 && !self.keep_open {
            self.empty_since.get_or_insert_with(Instant::now);
        } else {
            self.empty_since = None;
        }
        self.last_live = live;
        self.save();
    }

    fn prune(&mut self) {
        unsafe {
            let _ = KillTimer(Some(self.hwnd), TIMER_PRUNE);
        }
        let gone = self.line.prune_missing(|p| p.exists());
        if !gone.is_empty() {
            self.items_changed();
            self.invalidate();
        }
    }

    fn save(&mut self) {
        self.settings.pegged = self.line.items.iter().filter(|i| !i.falling()).map(|i| i.path.clone()).collect();
        self.settings.save();
    }

    // MARK: Showing and hiding

    fn toggle(&mut self) {
        if self.revealed {
            self.set_revealed(false);
            if self.line.live_count() == 0 {
                self.keep_open = false;
                self.wanted = false;
                self.refresh();
            }
        } else {
            self.keep_open = true;
            self.wanted = true;
            let mut point = POINT::default();
            unsafe {
                let _ = GetCursorPos(&mut point);
            }
            let here = unsafe { MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST) };
            self.place(here);
            self.refresh();
            self.reveal(true, 0.0);
        }
    }

    /// Decides whether the line may be shown at all: something to show, and no full screen app on this screen.
    fn refresh(&mut self) {
        let blocked = shell::full_screen_on(self.monitor, self.monitor_rect);
        if self.wanted && !blocked {
            self.present = true;
        } else {
            self.dismiss();
        }
        self.update_tick();
        self.invalidate();
    }

    fn dismiss(&mut self) {
        if self.present {
            self.present = false;
            self.set_revealed(false);
        }
    }

    fn reveal(&mut self, pinned: bool, peek_seconds: f32) {
        if !self.present {
            return;
        }
        if pinned {
            self.pinned = true;
        }
        if peek_seconds > 0.0 {
            self.peek_until = Some(Instant::now() + Duration::from_secs_f32(peek_seconds));
        }
        self.away_since = None;
        self.set_revealed(true);
    }

    fn set_revealed(&mut self, on: bool) {
        let on = on && self.present;
        if on == self.revealed {
            return;
        }
        self.revealed = on;
        if !on {
            self.pinned = false;
            self.peek_until = None;
            self.set_click_through(true);
        }
        self.update_tick();
        self.invalidate();
    }

    /// The cursor is polled while there is something to show, and not at all
    /// otherwise. Faster while the line is down, so it tucks away promptly.
    fn update_tick(&mut self) {
        unsafe {
            if self.wanted {
                let ms = if self.revealed { 50 } else { 100 };
                SetTimer(Some(self.hwnd), TIMER_TICK, ms, None);
            } else {
                let _ = KillTimer(Some(self.hwnd), TIMER_TICK);
            }
        }
    }

    /// Watches the cursor: the top edge brings the line down, and leaving it tucks the line away.
    fn tick(&mut self) {
        let now = Instant::now();
        let point = cursor();
        let here = unsafe { MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST) };
        let Some(info) = shell::monitor_info(here) else { return };
        let on_top_row = point.y <= info.rcMonitor.top;
        let down = unsafe { GetAsyncKeyState(VK_LBUTTON.0 as i32) < 0 || GetAsyncKeyState(VK_RBUTTON.0 as i32) < 0 };
        let panel_bottom = self.work.top + (PANEL_H * self.scale) as i32;
        let inside_x = point.x >= self.work.left && point.x < self.work.right;
        if !on_top_row {
            self.band_suppressed = false;
        }

        // A click on the top edge puts the line away, like a click on the mac menu bar.
        // Clicks lower down go through to whatever is underneath.
        let edge = down && !self.buttons_were_down;
        self.buttons_were_down = down;
        if self.revealed && edge && on_top_row && inside_x && self.card_at(self.to_client(point)).is_none() && self.dragging.is_none() {
            self.pinned = false;
            self.band_suppressed = true;
            self.set_revealed(false);
        }

        if !self.revealed {
            // Resting on the top edge brings the line down, after a short pause.
            let ready = self.wanted && on_top_row && !self.band_suppressed && !down && !shell::full_screen_on(here, info.rcMonitor);
            if ready {
                let since = *self.hot_since.get_or_insert(now);
                if now.duration_since(since) >= Duration::from_millis(250) {
                    self.hot_since = None;
                    if here != self.monitor {
                        self.place(here);
                    }
                    self.refresh();
                    self.reveal(false, 0.0);
                }
            } else {
                self.hot_since = None;
            }
        } else {
            let inside = point.x >= self.work.left
                && point.x < self.work.right
                && point.y >= self.monitor_rect.top
                && point.y < panel_bottom;
            if inside && self.pinned {
                self.pinned = false;
            }
            let peeking = self.peek_until.is_some_and(|t| now < t);
            let busy = self.pinned || self.dragging.is_some() || self.pressed.is_some() || peeking;
            if inside || busy {
                self.away_since = None;
            } else {
                let since = *self.away_since.get_or_insert(now);
                if now.duration_since(since) >= Duration::from_millis(500) {
                    self.away_since = None;
                    self.set_revealed(false);
                }
            }
            let client = self.to_client(point);
            let hover = if inside { self.card_at(client) } else { None };
            if hover != self.hover {
                self.hover = hover;
                self.invalidate();
            }
            // Only take the mouse while it is on a card. Not while a card is being pressed or dragged.
            if self.pressed.is_none() && self.dragging.is_none() {
                let over_card = inside && self.card_at_padded(client);
                self.set_click_through(!over_card);
            }
        }

        // An empty line goes away once the last card has fallen.
        if let Some(since) = self.empty_since {
            if now.duration_since(since) >= Duration::from_millis(700) && self.line.live_count() == 0 && !self.keep_open {
                self.empty_since = None;
                self.wanted = false;
                self.refresh();
            }
        }

        if self.line.gust_if_due(now) {
            self.invalidate();
        }
    }

    /// Schedules a redraw on the next animation frame. Also keeps the line
    /// animating until everything settles.
    fn invalidate(&mut self) {
        self.dirty = true;
        if !self.anim_running {
            unsafe {
                SetTimer(Some(self.hwnd), TIMER_ANIM, 16, None);
            }
            self.anim_running = true;
            self.last_frame = Instant::now();
        }
    }

    /// One animation frame: move the springs, slide the line, redraw, and stop once everything is at rest.
    fn animate(&mut self) {
        let now = Instant::now();
        let dt = now.duration_since(self.last_frame).as_secs_f32().min(0.05);
        self.last_frame = now;
        let layout = self.layout();
        self.line.ensure_sprites(self.scale);
        let pressed = self.pressed.map(|p| p.id);
        let moving = self.line.step(dt, now, &layout, self.hover, pressed);

        let target = if self.revealed { 1.0 } else { 0.0 };
        let before = self.slide;
        let rate = if target > self.slide { 14.0 } else { 18.0 };
        self.slide += (target - self.slide) * (1.0 - (-dt * rate).exp());
        if (target - self.slide).abs() < 0.002 {
            self.slide = target;
        }
        let sliding = self.slide != before;

        if self.slide > 0.001 {
            if self.dirty || moving || sliding {
                self.redraw(&layout);
            }
            self.set_shown(true);
        } else {
            self.set_shown(false);
        }
        self.dirty = false;

        if !(moving || sliding) {
            unsafe {
                let _ = KillTimer(Some(self.hwnd), TIMER_ANIM);
            }
            self.anim_running = false;
        }
    }

    fn set_shown(&mut self, on: bool) {
        if on == self.shown {
            return;
        }
        self.shown = on;
        unsafe {
            if on {
                let _ = ShowWindow(self.hwnd, SW_SHOWNOACTIVATE);
                let _ = SetWindowPos(self.hwnd, Some(HWND_TOPMOST), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            } else {
                let _ = ShowWindow(self.hwnd, SW_HIDE);
            }
        }
    }

    /// Draws the whole line into the layered window.
    fn redraw(&mut self, layout: &Layout) {
        let ui = Ui { hover: self.hover, dragging: self.dragging };
        let hint = t("Take a screenshot and it will hang here");
        let hint_visible = self.line.items.is_empty();
        let Some(frame) = self.painter.compose(&self.line.items, layout, &ui, &hint, hint_visible) else { return };
        self.hits = frame.hits;
        self.present_frame(&frame.canvas);
    }

    fn present_frame(&mut self, canvas: &Pixmap) {
        let (w, h) = (canvas.width() as i32, canvas.height() as i32);
        if self.dib.as_ref().is_none_or(|d| d.w != w || d.h != h) {
            self.dib = Dib::new(w, h);
        }
        let Some(dib) = self.dib.as_ref() else { return };
        // The canvas is premultiplied RGBA; the layered window wants premultiplied BGRA.
        unsafe {
            let dst = std::slice::from_raw_parts_mut(dib.bits, (w * h * 4) as usize);
            for (out, px) in dst.chunks_exact_mut(4).zip(canvas.data().chunks_exact(4)) {
                out[0] = px[2];
                out[1] = px[1];
                out[2] = px[0];
                out[3] = px[3];
            }
        }
        let origin = POINT { x: self.work.left, y: self.window_top() };
        let size = SIZE { cx: w, cy: h };
        let source = POINT::default();
        let blend = BLENDFUNCTION {
            BlendOp: AC_SRC_OVER as u8,
            BlendFlags: 0,
            SourceConstantAlpha: 255,
            AlphaFormat: AC_SRC_ALPHA as u8,
        };
        unsafe {
            let _ = UpdateLayeredWindow(
                self.hwnd,
                None,
                Some(&origin),
                Some(&size),
                Some(dib.hdc),
                Some(&source),
                COLORREF(0),
                Some(&blend),
                ULW_ALPHA,
            );
        }
    }

    /// The top of the window: at the top of the work area when shown, and
    /// above it while the line is tucked away.
    fn window_top(&self) -> i32 {
        let h = PANEL_H * self.scale;
        self.work.top + ((self.slide - 1.0) * h).round() as i32
    }

    /// Puts the line on a monitor, at that monitor's scale.
    fn place(&mut self, monitor: HMONITOR) {
        let Some(info) = shell::monitor_info(monitor) else { return };
        let mut dx = 0u32;
        let mut dy = 0u32;
        let scale = unsafe {
            if GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut dx, &mut dy).is_ok() && dx > 0 {
                dx as f32 / 96.0
            } else {
                1.0
            }
        };
        self.monitor = monitor;
        self.monitor_rect = info.rcMonitor;
        self.work = info.rcWork;
        self.scale = scale;
        self.invalidate();
    }

    fn layout(&self) -> Layout {
        Layout { s: self.scale, width: (self.work.right - self.work.left) as f32 }
    }

    fn to_client(&self, p: POINT) -> (i32, i32) {
        (p.x - self.work.left, p.y - self.window_top())
    }

}

fn cursor() -> POINT {
    let mut p = POINT::default();
    unsafe {
        let _ = GetCursorPos(&mut p);
    }
    p
}

fn client_point(lp: LPARAM) -> (i32, i32) {
    let x = (lp.0 & 0xFFFF) as i16 as i32;
    let y = ((lp.0 >> 16) & 0xFFFF) as i16 as i32;
    (x, y)
}

fn screen_point(lp: LPARAM) -> POINT {
    let (x, y) = client_point(lp);
    POINT { x, y }
}

fn taskbar_created() -> u32 {
    use std::sync::OnceLock;
    static MSG: OnceLock<u32> = OnceLock::new();
    *MSG.get_or_init(|| unsafe { RegisterWindowMessageW(w!("TaskbarCreated")) })
}

/// The first font that can be read, from the system fonts folder. Segoe UI
/// ships with Windows; Microsoft YaHei covers Chinese text.
fn load_font_bytes() -> Vec<u8> {
    let windir = std::env::var("WINDIR").unwrap_or_else(|_| r"C:\Windows".into());
    let fonts = PathBuf::from(windir).join("Fonts");
    let names: &[&str] = if crate::i18n::is_chinese() {
        &["msyh.ttc", "segoeui.ttf", "arial.ttf"]
    } else {
        &["segoeui.ttf", "arial.ttf"]
    };
    names.iter().find_map(|n| std::fs::read(fonts.join(n)).ok()).unwrap_or_default()
}

/// The window procedure. It gets the app from the window's user data and
/// runs the handler; any nested message loop is run after the handler returns.
unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut App;
        if ptr.is_null() {
            return DefWindowProcW(hwnd, msg, wp, lp);
        }
        let (result, action) = (*ptr).on_message(msg, wp, lp);
        match action {
            Deferred::None => result,
            Deferred::Drag(..) | Deferred::Menu(..) => {
                // The handler's borrow has ended; run the nested loop now.
                let command = (*ptr).finish_deferred(action);
                if let Some(id) = command {
                    (*ptr).command(id);
                }
                LRESULT(0)
            }
        }
    }
}
