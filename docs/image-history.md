# Scrollable image history

The line keeps images newest first, anchored 24 points from the left edge.
It does not discard older cards when the screen fills. Mouse-wheel vertical
movement and trackpad horizontal movement browse the same bounded horizontal
offset. A slider provides a visible scroll control. A new capture returns the
offset to zero; display-size changes and removals clamp it to valid bounds.
The same coordinates are used for hit-testing and capture/fall animations.
Wheel handling is local to the line's panel, not a global event monitor.

## Retention

The menu offers 1, 3, 7, 15 and 30 days, defaulting to 30 for missing or invalid
preferences. Entries store their capture time, so editing an image or
restarting the app does not renew it. Reducing retention applies immediately.
Expiry runs at launch, on watched-folder changes and hourly while running.

History metadata lives in the existing preferences domain (`imageHistoryV1`
and `historyRetentionDays`). The previous `pegged` list is migrated and kept
current for rollback. On the first migration, generated clipboard images
left in the inbox by the old capacity limit can rejoin history. Deliberately
removed entries are not re-imported on subsequent launches.

Expiry deletes only regular, non-symlink PNG files named `Clipboard <UUID>.png`
directly inside the app's own screenshots folder. It never follows symlinks
or deletes external originals, arbitrary inbox images or nested files. Removed
cards' orphaned clipboard files also expire by creation date. Storage errors
are logged without file paths; later sweeps retry orphan-file cleanup.
Expiry is local and does not touch the system clipboard. Retention is an
age limit, not a disk-space quota or secure-erasure guarantee.

## Memory and tests

History entries keep paths and timestamps. The model decodes thumbnails only
for the viewport and one neighboring card on either side; off-screen views
are not constructed. Original images stay on disk until expiry or removal.

`bash scripts/test-history.sh` uses Apple's compiler and a small assertion
adapter when Command Line Tools has no XCTest module. The same test methods
are available to `swift test` with XCTest. Tests inject isolated preferences,
temporary files and a clock; they do not inspect the user's clipboard/history
or modify macOS screenshot settings. The panel wheel test sends a synthetic
event directly to its own window and never posts it to other applications.

This change works independently of clipboard capture; captured clipboard
images from PR #42 use the same line and ownership naming convention.
