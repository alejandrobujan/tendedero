# Reclaim space

The screenshots folder can grow without bound — cards drop off the line but files stay. Two menu entries give the space back, both Trash-only (nothing is erased permanently):

## Sub-features

- `size-in-title` — "Empty screenshots folder (NN KB/MB)" shows the live folder size, recomputed every time the menu opens
- `empty-folder` — clicking it moves every file in the inbox to the Trash; disabled when the folder is empty
- `auto-clean-toggle` — "Auto-clean after 7 days" is a checkable item (off by default)
- `auto-clean-run` — when on: a pass a few seconds after launch, then daily, trashes files older than 7 days; re-enabling also runs a pass immediately
- `cards-follow` — trashed files drop their hanging cards via the normal file-vanished prune

## How to get to it (user POV)

Status menu → the two items sit directly under "Open screenshots folder", above the separator.

## Driving it with computer + shell

Preconditions: baseline green; inbox folder contains files you made (see fixtures below). NEVER point it at the user's real screenshots.

- `size-in-title`: seed files, open the menu → screenshot shows "Empty screenshots folder (X MB)" matching `du`/`ls` of the folder. Observed on macOS 26.5.2: ByteCountFormatter is decimal — 2,513,108 bytes renders "(2.5 MB)", two such files "(5 MB)", empty "(Zero KB)" + disabled.
- `empty-folder`: click it → `ls` of the inbox is empty AND the files appear in `~/.Trash` (pair both in `files-<n>.txt`); reopen menu → item disabled, "(Zero KB)". If files were hanging, screenshot shows the cards gone.
- `auto-clean-toggle`: click it → `defaults read app.tendedero.Tendedero inboxAutoCleanDays` = 7 and the menu shows the checkmark; click again → 0, checkmark gone.
- `auto-clean-run` (immediate pass): with the toggle ON, create a fixture with a back-dated CREATION date: `cp <png> <inbox>/old.png && SetFile -d "MM/DD/YYYY HH:MM:SS" <inbox>/old.png` (≥8 days ago) → toggle off then on → `log show` has "Auto-clean moved N old screenshot(s) to the Trash" and `old.png` is in `~/.Trash`; a fresh file in the same folder is untouched.
- `auto-clean-run` (launch pass): fixture as above, `kill -TERM` the app, `open -n` it again → within ~8 s the file is trashed (log + `ls`).

## Gotchas

- `touch -t` is the wrong tool — it sets mtime; `clean` reads CREATION date (`SetFile -d` sets it).
- `cp` preserves xattrs: a decoy copied onto the Desktop from a `screencapture`-derived PNG carries `kMDItemIsScreenCapture` and WILL hang a card — normal watcher behavior, not the feature touching it. Assert the decoy FILE survives; to keep it cardless strip the tag: `xattr -d com.apple.metadata:kMDItemIsScreenCapture <file>`.
- Card assertions read `defaults read app.tendedero.Tendedero pegged`: a trashed file's path must drop out (line.prune runs after every empty/clean).
- Both actions move files to `~/.Trash`, never delete — assert presence in Trash, not just absence in inbox.
- Only the inbox folder is affected: seed a decoy image on the Desktop and assert it survives in `files-<n>.txt`.
- A file whose creation date can't be read is left alone by design — don't "fix" this.
- The launch pass fires ~5 s after `applicationDidFinishLaunching` — if the Desktop TCC prompt is up, the pass waits behind it; answer the prompt first.
- Menu titles are per-open: a file seeded while the menu is open only shows in the NEXT open's size.
- The empty-state string is literally "(Zero KB)", not "0 KB".
