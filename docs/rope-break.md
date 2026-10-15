# Pulling the rope to take everything down

Hover an empty section of rope to show an open hand, then drag down. The rope stretches and frays near the pointer. Releasing beyond the threshold breaks it at the grab point; photos slide toward the two broken ends and fall offscreen in sequence. Releasing early, pulling back below the threshold, or pressing Escape cancels. No new button or on-screen text is added.

## Implementation

- `RopePull` snapshots the current item IDs on mouse-down. `Line.discardForRope` applies the existing inbox-to-Trash / external-file-detach policy to that snapshot, including offscreen items. Failed deletions remain live and persisted. New captures wait until the gesture finishes.
- `RopeMotion` computes the stretch, fraying, broken ends, slides and falls. Resistance limits the effective pull to 152 points; 92 effective points arms the gesture (about 104 points of pointer travel). Only release can commit a clear.
- `RopeHostingView` and `LinePanel` route rope events while retaining photo interactions and scrolling. The hit band extends nine points above and below the rope and excludes photo hit regions. Hover does not make the panel key. During a drag, the nonactivating panel becomes key to receive Escape.
- A transparent, click-through panel covers the display during the gesture so falling cards are not clipped to the original strip. A common-mode timer advances the release animation. Rope ends fade over 180 ms, starting 120 ms after the last card leaves them. Reduce Motion skips the release animation. Display/Space changes and hiding cancel an uncommitted drag.

## Background cursor compatibility

Calling `NSCursor.set()` while this accessory app is inactive can update `NSCursor.current` without changing the cursor actually displayed by WindowServer. `RopeCursor` temporarily enables the undocumented `SetsCursorInBackground` connection property during rope hover/drag, restores the visible cursor, and then disables that access on exit, release, cancellation, hide or quit. It neither activates the app on hover nor installs an event tap.

`CGSMainConnectionID` and `CGSSetConnectionProperty` are resolved dynamically. If a system version removes the symbols or rejects the property, ordinary AppKit cursor handling and dragging remain available, but inactive hover may show an arrow again. This dependency needs review by the maintainer and retesting on future macOS releases; it is not appropriate for Mac App Store distribution.

## Validation

`swift test` covers anchored endpoints, pullback cancellation, continuity into a fall, snapshot deletion, offscreen items, persistence, trash failures, native drag/release/Escape routing, hover focus, and cursor access cleanup/fallback. Tests use temporary images and isolated history preferences.

An optional system-cursor test places the real rope view under the stationary pointer and captures small screen regions with the cursor included. Run it separately, away from screen edges, on a Mac with screen-capture access for the test host:

```sh
mkdir -p /tmp/tendedero-cursor-proof
TENDEDERO_CURSOR_PROOF=/tmp/tendedero-cursor-proof \
swift test --filter captureSystemCursorOverNativeRope
```

Inspect the resulting PNGs: AppKit-only negative control, open hand on hover, closed hand while held, restoration on release, re-entry, click-through, and hide. The test checks that the foreground application stays unchanged; visual correctness requires inspecting the captures, not just `NSCursor.current`.

Manual checks: cancel with Escape or a short pull; release beyond the threshold at different rope positions; use more items than fit on screen; capture during a drag; change display/Space; check Reduce Motion and multiple monitors. Physical drag feel and multi-monitor behavior are not automated.
