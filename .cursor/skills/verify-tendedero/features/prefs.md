# Prefs & quit

The remaining menu surface: Sounds, Open at login, Quit — plus the Ctrl+Opt+T hotkey and the promise that quitting restores the user's screenshot settings.

## Sub-features

- `sounds` — toggle peg/throw sound effects (checkmark, persists)
- `open-at-login` — SMAppService login item toggle (checkmark reflects real status)
- `hotkey` — Ctrl+Opt+T shows/hides the line from anywhere
- `quit` — menu "Quit Tendedero" (or ⌘Q) exits and restores `com.apple.screencapture`
- `welcome` — first launch shows the line briefly + the inbox offer once

## How to get to it (user POV)

All in the status menu; the hotkey works globally.

## Driving it with computer + shell

Preconditions: baseline green.

- `sounds`: menu → "Sounds" → `defaults read app.tendedero.Tendedero soundOn` flips (and the checkmark). Take a screenshot and hang another card — sound is audible, not assertable; checkmark + default is the proof.
- `open-at-login`: toggle → menu checkmark follows `SMAppService` status; cross-check `osascript -e 'tell application "System Events" to get the name of every login item'`.
- `hotkey`: `computer` key `ctrl+alt+t` → line shows/hides (screenshot pair).
- `quit`: menu → "Quit Tendedero" → `pgrep` empty AND `com.apple.screencapture` back to baseline — same assertion as `inbox.md` → `restore-on-quit`.

## Gotchas

- `open-at-login` may silently fail without a signed Developer-ID build — verify the checkmark reflects reality on the NEXT menu open, not the click.
- The hotkey is `control+option`, not `cmd` — `ctrl+alt+t` in xdotool syntax.
- "Quit Tendedero" is the ONLY right way to end a verification run mid-flow; `kill -9` leaves `com.apple.screencapture` diverted and poisons the next run's baseline.
- `welcomed` in defaults suppresses the first-run offer — a reused home won't re-ask; `defaults delete app.tendedero.Tendedero welcomed` only between runs, never while it runs.
