# Inbox mode (Handle screenshots)

The opt-in takeover: Tendedero writes `location`/`location-screenshot`/`show-thumbnail` into `com.apple.screencapture` so screenshots skip the Desktop and the floating thumbnail, land in `~/Library/Application Support/Tendedero/Screenshots`, and hang instantly. Quitting the app restores whatever the settings were before.

## Sub-features

- `offer` — first launch asks once ("Let Tendedero handle your screenshots?")
- `enable` — menu toggle redirects screenshots to the inbox folder
- `instant-hang` — in inbox mode a new screenshot hangs without touching the Desktop
- `disable` — toggling off restores the previous save location live
- `restore-on-quit` — quit (menu Quit or kill -TERM) restores system settings
- `survive-kill9` — a force-killed app leaves screenshots diverted until next launch (known trade-off, not a verification target)

## How to get to it (user POV)

Status menu → "Handle screenshots" (checkmark = on). First launch may show the consent alert instead.

## Driving it with computer + shell

Preconditions: baseline green; `defaults read com.apple.screencapture` captured BEFORE toggling (baseline keys, usually none — record in `doctor.txt`).

- `enable`: menu → "Handle screenshots" → `defaults read app.tendedero.Tendedero inboxEnabled` = 1 AND `defaults read com.apple.screencapture` now shows `location`/`location-screenshot` pointing at the inbox path plus `show-thumbnail` = 0. Pair with menu screenshot.
- `instant-hang`: `screencapture -x ~/Library/Application\ Support/Tendedero/Screenshots/inbox-<n>.png` → file lands directly in the folder (`ls` before/after) AND a new card is on the line (screenshot).
- `disable`: toggle off → `com.apple.screencapture` loses the injected keys (back to baseline read).
- `restore-on-quit`: with inbox ON, `kill -TERM <pid>` → process exits AND `com.apple.screencapture` is back to baseline — proves the dispatch-source restore path, not just graceful Cmd+Q.

## Gotchas

- Never `defaults write com.apple.screencapture` yourself — the app snapshots the user's prior values; polluting them makes "restore" restore garbage.
- macOS 27 uses `location-screenshot`; older releases use `location`. Check both keys.
- The toggle also re-runs the watcher setup — assert after ~1 s, not instantly.
- If the app is force-killed (-9) while inbox is on, screenshots keep diverting to the hidden folder — document it, don't paper over it: the fix is launching the app once more.
- Files pre-existing in the inbox before launch do NOT hang (launchDate gate) — only files created after do.
