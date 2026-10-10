# Tendedero feature map

The maintained index of what a user can do, and where each verification must look. Drive one feature per run, from the baseline in `../SKILL.md` (build → launch → doctor green → one t-shirt icon).

| Feature | File | One-line scope |
|---|---|---|
| Clothesline | `line.md` | screenshots hang, hover reveals, capacity & prune |
| Cards | `cards.md` | click=copy, hold=annotate, drag=share/save, ×=discard |
| Inbox mode | `inbox.md` | redirect screenshots to the hidden folder; restore on quit |
| Reclaim space | `reclaim-space.md` | Empty folder (size shown) + Auto-clean after 7 days |
| Prefs & quit | `prefs.md` | Sounds, Open at login, hotkey, settings restore |

## Baseline preconditions

- `scripts/build-app.sh` produced `build/Tendedero.app` in THIS run — never verify a binary from an earlier checkout.
- Launched via `open -n build/Tendedero.app`; doctor (see SKILL.md) green. The Desktop-access TCC prompt is answered — an unanswered prompt parks the whole app before the status item exists.
- No other `Tendedero` process: `pgrep -x Tendedero` returns one PID. Kill leftovers from earlier runs first (`kill -TERM`).
- Tools on PATH: `screencapture`, `defaults`, `SetFile` (Xcode CLT), `log`. The `computer` tool for input.
- Evidence dir `~/tendedero-verify/<run-name>/` created before driving.

## Driving conventions

- Menu titles are live (rebuilt per open): read them from a screenshot of the open menu, not from memory of the source.
- A real "screenshot lands" event = `screencapture -x <inbox-or-Desktop>/name.png`. In inbox mode any image file works; on the Desktop only files carrying `com.apple.metadata:kMDItemIsScreenCapture` hang — a plain `cp` to the Desktop is NOT equivalent.
- Back-dating a file's AGE for reclaim tests: `SetFile -d "MM/DD/YYYY HH:MM:SS" <file>` sets creation date (what `clean` reads); `touch -t` only changes mtime and does NOT age a file.
- Cards are not accessible elements — their proof is pixels in a screenshot.
- Never `defaults write com.apple.screencapture` while the app runs; drive Handle screenshots through its menu item.
- Cleanup removes the run's process and fixtures, never `~/tendedero-verify/` artifacts.

## Proof and skip reporting

- Pair every action with its resulting state: menu click → `defaults`/`ls` delta → screenshot of the visible effect. One without the other is a claim, not a proof.
- `log show --last <window> --predicate 'process == "Tendedero"'` lines under subsystem `app.tendedero.Tendedero` corroborate file moves but do not replace them.
- If an entry point is unreachable (e.g. the × button only exists on hover), record the attempted input and the missing precondition — never mark the sub-feature verified via another path.
