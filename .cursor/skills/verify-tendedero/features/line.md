# Clothesline

The core loop: every screenshot the user takes flies onto a rope pinned to the top edge of the screen. The line is a borderless panel that reveals on hover or on demand, and it only ever VIEWS files — it never moves or deletes them on its own.

## Sub-features

- `hang` — a new screenshot lands on the line with a peg animation
- `reveal` — hover at the top edge slides the line down; moving away tucks it back
- `show-hide` — menu "Show line"/"Hide line" and Ctrl+Opt+T pin/unpin it
- `capacity` — past ~12 cards the oldest drops off (file stays on disk)
- `prune` — deleting a hung file in Finder drops its card
- `wind` — idle cards sway slightly (visual only)

## How to get to it (user POV)

- Take a screenshot with the usual system shortcut (Cmd+Shift+3/4), or drop an image into the screenshots folder while Handle screenshots is on.
- Hover the mouse at the very top edge of the screen, or open the status menu → "Show line" / press Ctrl+Opt+T.

## Driving it with computer + shell

Preconditions: baseline green; inbox mode ON (menu → "Handle screenshots" checked) so `screencapture` output is accepted without the xattr question.

- `hang`: `screencapture -x ~/Library/Application\ Support/Tendedero/Screenshots/proof-<n>.png` → within ~1 s a screenshot shows a new card pinned at top center of the screen; the file exists in the inbox (`ls` before/after in `files-<n>.txt`).
- `reveal`: `computer` move mouse to (512, 2), wait ~1 s → screenshot shows the full line with all cards; move to (512, 400), wait → line retracted (only card tops peek, or nothing).
- `show-hide`: menu → "Show line" (title flips to "Hide line") → screenshot with line visible without hovering.
- `prune`: `rm` or `trashItem` a hung file → its card disappears without the line being touched.
- `capacity`: hang >12 files rapidly (`for i in $(seq 1 14); do screencapture -x <inbox>/cap-$i.png; done`) → screenshot shows ≤12 cards; `ls` still shows all files.

## Gotchas

- On the Desktop (inbox OFF) a `screencapture`/copied file does NOT hang — no `kMDItemIsScreenCapture` xattr. Drive `hang` in inbox mode.
- Files older than app launch never hang (`launchDate` gate) — "why didn't my pre-seeded file hang" is by design.
- The watcher debounces ~0.2 s; rapid `screencapture` bursts are fine but assert after ≥1 s.
- Card positions depend on where the screenshot was taken from; assert on COUNT and presence, not pixel coordinates.
- `screencapture -x` writes synchronously but the OS may still finish metadata async — `sleep 1` before screenshotting the line.

- Menu → Show line reveals but can still tuck itself away after ~a minute of inactivity or when another app takes focus (not a hard pin). If cards vanish mid-run, hover (512,3) to re-reveal; assert state via `pegged`/`ls`, not the visible line.
