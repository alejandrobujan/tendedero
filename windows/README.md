# Tendedero for Windows

Your screenshots hang on a line across the top of the screen. Copy, drag or
discard them without leaving what you were doing.

This is the Windows version. It is a native Win32 app written in Rust: one
small exe with no runtime to install, no background web view, and almost no
CPU when idle.

## Install

Download one of these from the Releases page, or build them yourself with
`scripts/package.sh` (the output goes to `dist/`):

- **`Tendedero-Setup-1.0.0.exe`**: the installer. It installs for your user
  only (no administrator rights), adds a Start Menu entry, and can be removed
  from *Settings → Apps*.
- **`Tendedero-1.0.0-portable.exe`**: no install. Put it anywhere and run it.

Requires Windows 10 or Windows 11, 64-bit. Fully verified on Windows 11 x64.

Both files are not code-signed, so Windows SmartScreen may warn you the first
time. Choose **More info → Run anyway**.

## How to use it

Take screenshots the way you already do. Tendedero watches your screenshot
folder (`Pictures\Screenshots`, where **Win+PrtScn** and the Snipping Tool save
files) and hangs each new image on the line.

| To | Do this |
|---|---|
| Show or hide the line | Rest the pointer on the very top edge of the screen, or press **Ctrl+Alt+T**, or click the tray icon |
| Copy an image | Click it. It goes to the clipboard as an image, and as the file itself |
| Open it | Double-click it |
| Edit it | Press and hold it. It opens in Paint |
| Keep it | Drag it into a folder. If Windows moves the file (usually on the same drive), it leaves the line |
| Give it to an app | Drag it into the app. It stays on the line |
| Take it down | Click the cross in its top-left corner, or use *Take down* in the right-click menu. Nothing is deleted |
| Delete it | Right-click → *Move to Recycle Bin* |
| Show it in Explorer | Right-click → *Show in File Explorer* |
| Take everything down | Tray icon → *Take everything down* |

The tray icon menu also has *Sounds* and *Open at login*. Your line is kept
between sessions.

## What is different from the Mac app

- **No "Handle screenshots" mode.** The Mac app changes a macOS setting to send
  screenshots to its own folder. Tendedero does not change any Windows setting.
  It watches `Pictures\Screenshots` instead.
- **Clipboard-only captures.** A capture that only goes to the clipboard
  (Win+Shift+S) is only seen if the Snipping Tool also saves a file to
  `Pictures\Screenshots`. Check the Snipping Tool's settings for an automatic
  save option if captures are missing.
- **No frosted glass.** Windows cannot blur what is behind a layered window
  cheaply, so the card frames are a clean translucent white.
- **No flight animation.** New cards drop onto the line rather than flying in
  from where they were captured, because Windows does not record that.
- **Markup opens Paint**, the closest thing Windows has.

## Performance notes

- Each card is painted once into a cached sprite. Swaying and dropping only
  place those sprites again.
- Thumbnails are decoded with Windows Imaging Component on a worker thread,
  and capped at 480 px.
- The cursor is only polled while there is a line, and the redraw loop stops
  as soon as the cards are still.
- The window is hidden entirely while the line is tucked away, so Windows
  stops compositing it.
- The release build uses fat LTO, one codegen unit, `panic = "abort"` and
  stripped symbols. The exe is about 0.9 MB and statically linked.

## Build from source

You need [rustup](https://rustup.rs). The target-specific settings in
`.cargo/config.toml` make the build use the static C runtime.

**On Windows** (MSVC toolchain, the default):

```
cargo build --release
```

The exe is then at `target\release\tendedero.exe`.

**Cross-building from Linux** (for example Debian or Ubuntu):

```
sudo apt install mingw-w64 nsis
rustup target add x86_64-pc-windows-gnu
./scripts/package.sh
```

`scripts/package.sh` writes the portable exe and the installer to `../dist`.

The translations come from the macOS app's `Localizable.strings`, so the
English, Spanish and Simplified Chinese text stays the same. The Windows
differences (for example "File Explorer" instead of "Finder") live in
`strings/`.

## Layout

| File | What it does |
|---|---|
| `src/app.rs` | The window, the line's state machine, mouse and tray handling |
| `src/line.rs` | Which cards hang where, and their springs (drop, sway, layout) |
| `src/render.rs` | Paints the rope, the cards and the labels with tiny-skia |
| `src/watch.rs` | Watches the screenshot folder for new and changed images |
| `src/thumb.rs` | Decodes images with WIC on a worker thread |
| `src/shell.rs` | Clipboard, drag-out, Recycle Bin, Explorer, login startup, full-screen check |
| `src/i18n.rs` | Loads the translations and picks the language |
| `installer/tendedero.nsi` | The per-user NSIS installer |
