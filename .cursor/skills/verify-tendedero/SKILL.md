---
name: verify-tendedero
description: "Drive the Tendedero macOS menu-bar app the way a user does — click the status item, take screenshots, watch cards hang on the clothesline — and prove behavior with screenshots, ls, defaults, and os_log evidence. Reach for it whenever a change touches the line, the inbox (Handle screenshots), space reclaiming, or the status menu."
---

# Verify Tendedero

Tendedero is an LSUIElement menu-bar app (no windows, no Dock icon). The only user surfaces are: the status-bar menu, the clothesline itself (revealed by hovering the top of the screen), cards hanging on it, and the Ctrl+Opt+T hotkey. There is no scripting interface — driving means synthesizing user input (the `computer` tool for clicks, shell commands for file effects) and observing from outside (screenshots, `ls`, `defaults`, `log show`).

Evidence goes to `~/tendedero-verify/<run-name>/` — outside the repo, survives cleanup. Create it once per run and put everything there.

## Launch

```bash
cd <repo>
./scripts/build-app.sh                 # universal binary + ad-hoc sign → build/Tendedero.app
open -n build/Tendedero.app
```

Ready when BOTH are true (usually < 5 s):

- `pgrep -x Tendedero` prints exactly one PID
- A screenshot of the menu bar shows the t-shirt icon at the right edge (takes it with `screencapture -x ~/tendedero-verify/<run>/menubar.png` and look, or the `computer` tool's screenshot)

Never rebuild for a verify run: a rebuild produces a new ad-hoc cdhash and REVOKES the TCC Desktop-folder grant — the app then parks on its own prompt at launch (see below). When the artifact is already built and granted, prove the feature is inside it instead: `strings build/Tendedero.app/Contents/MacOS/Tendedero | grep -i "auto-clean"`. Rebuild only when the task explicitly asks to test a new build — and expect the prompt again.

Teardown: `kill -TERM <pid>` — never `killall`, never `-9` unless it is already wedged; TERM lets the app restore the user's `com.apple.screencapture` settings, which is itself part of what this harness verifies.

**First-launch gate (read before declaring the app dead):** the app synchronously lists ~/Desktop on the main thread inside `applicationDidFinishLaunching`. macOS holds that call until the Desktop-access prompt is answered — and the prompt may be rendered behind other windows. An ad-hoc rebuild invalidates the grant (new cdhash), so EVERY new binary asks again. Symptoms: process alive (`pgrep` OK, state `S`), no t-shirt icon, `sample <pid> 2` shows the main thread parked in `contentsOfDirectory` → `open` under `ScreenshotWatcher.start()`. Fix: find the "…would like to access files in your Desktop folder" alert (it hides behind other windows — look at the whole screen) and click Allow. Do not `open` again while one is parked: the second instance just queues behind its own prompt.

## Doctor

Read-only, run first whenever anything looks off:

```bash
pgrep -x Tendedero                              # exactly one PID; 0 = dead, 2+ = stacked instances
sample <pid> 2 2>/dev/null | grep -A3 "main-thread" | head -8   # parked in open()/contentsOfDirectory = TCC prompt waiting
defaults read app.tendedero.Tendedero           # inboxEnabled / inboxAutoCleanDays / welcomed / pegged
# `pegged` lists the paths that currently hold a card — the reliable card
# assertion: after a file is trashed, its path must drop out of `pegged`.
defaults read com.apple.screencapture           # location/location-screenshot present ⇒ inbox mode is applied
ls -la ~/Library/Application\ Support/Tendedero/Screenshots/    # the inbox folder
```

Healthy = one PID, icon visible, and `com.apple.screencapture` matches the `Handle screenshots` menu state (`inboxEnabled` ↔ `location` keys present).

## Drive

All driving starts from: built, launched, doctor green, one t-shirt icon.

- **Menu:** click the t-shirt icon with the `computer` tool (~x=871,y=9 in the 1024×768 space — confirm its exact position from a screenshot first; it drifts as other icons come and go). The menu is rebuilt in `menuNeedsUpdate` on every open, so item titles carry live state (checkmarks, sizes). Click an item; the menu closes itself.
- **Screenshots:** the real user path is Cmd+Shift+3 — in the harness use the system tool instead: `screencapture -x <file>` writes a real full-screen PNG and, when inbox mode is on, lands it in the inbox folder if you name the path there. In inbox mode ANY image file counts (no xattr filter — only Desktop watching filters on `kMDItemIsScreenCapture`); on the Desktop a plain `screencapture`/`cp` does NOT hang because the xattr is missing.
- **Clothesline:** revealed by hovering the cursor at the very top edge of the screen (y≈0–15), or via menu → "Show line". Cards are SwiftUI — they are not in the AX tree; verify them from screenshots only.
- **Cards:** `defaults read app.tendedero.Tendedero pegged` — paths on the line, no pixels needed.
- **State:** `defaults` for persistence, `ls`/`stat`/`SetFile -d` for files, `log show --last 5m --predicate 'process == "Tendedero"'` for its `log.notice` lines (subsystem `app.tendedero.Tendedero`).
- **Visible evidence:** pin the inbox and Trash Finder windows side by side before driving, so recordings show files vanish/appear live:
  ```bash
  open "$HOME/Library/Application Support/Tendedero/Screenshots"; open ~/.Trash
  osascript -e 'tell application "Finder"
    set bounds of window "Screenshots" to {15, 55, 500, 470}
    set bounds of window "Trash" to {520, 55, 1005, 470}
  end tell'
  ```

Never drive an instance the run did not start (`pgrep` before `open` — kill leftovers from previous runs first). Never mutate `com.apple.screencapture` directly: the app owns those keys while it lives; toggling goes through the menu item.

## Evidence

Per run, in `~/tendedero-verify/<run-name>/`:

- `build.log` — tail of `build-app.sh` (proves the artifact under test)
- `doctor.txt` — the doctor block above, before AND after the drive
- `menu-<n>.png` — screenshot of the open menu showing live item titles
- `line-<n>.png` — screenshot with cards on the line
- `files-<n>.txt` — `ls -la` of the inbox folder and the interesting `~/.Trash` entries
- `app.log` — `log show` grep for the run window

Proof standard: the user action AND the resulting state, side by side — a menu screenshot alone proves nothing without the `ls`/`defaults` that show what changed. A feature that moves files to the Trash is proven by the file being in `~/.Trash`, not by the menu item's title.

## Cleanup

`kill -TERM <pid>` then `pgrep -x Tendedero` until empty. Remove only fixtures the run created inside the inbox folder (files it did NOT trash itself). Leave `~/tendedero-verify/` alone — proof survives teardown. `com.apple.screencapture` should be back to whatever it was before the run (usually no `location*` keys); if not, the app was killed wrong — reopen it, toggle Handle screenshots off via the menu, quit, and recheck.

## Helpers

None yet — everything above is stock `/usr/bin` tools plus the `computer` tool.

## Feature map

`features/README.md` indexes the user-facing features and entry points. Drive one per run; the map is the contract for what "verified" means.
