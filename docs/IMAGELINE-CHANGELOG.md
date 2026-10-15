# ImageLine changes

ImageLine is an independently named and illustrated local fork of [Tendedero](https://github.com/alejandrobujan/tendedero), based on upstream commit `2c3ffd95f173585260aa198e85d3ea62a878f688` and the 1.5.0 codebase. It is not endorsed by the original author.

## 1.0.5 — 2026-10-15

- Reduce the idle/unarmed rim from 4 to 1.5 points, retaining the 5.5-point armed rim.
- Use 5% fill before the threshold and 20% once armed, with a heavier armed chevron.
- Inspect both cached states and pass the existing all-photo-size layout check.

## 1.0.4 — 2026-10-15

- Position the pull ring at 80% of the usable screen width, one fifth from the right edge.
- Double the visible ring diameter from 22 to 44 points and enlarge its native drag target to 64×64 points.
- Add an accent-colored thick rim, contrasting background, shadow and downward chevron. Increase the hint weight and move it beside the ring.
- Pass all 24 tests, including native hit testing, drag routing and all photo sizes; check the ring's 80% position and max-pull visibility.

## 1.0.3 — 2026-10-15

- Fix the visible Clear All button passing clicks through: its SwiftUI preference hit rectangle was zero. Native AppKit controls now use their actual bounds, accept the first click without focus, and receive events directly from the non-key panel.
- Intersect native control bounds with their visible region; SwiftUI may report a visible region larger than the control itself.
- Add a ring on the right end of the rope. Pull down 52 points and release to clear; short pulls, pulling back up, cancellation, and hiding the panel preserve the pictures.
- Bend the rope and move the hanging pictures with the pull, then spring back and drop the snapshot in a short ripple. Keep new arrivals, and prevent duplicate clears while the action runs.
- Respect Reduce Motion for spring and falling feedback. Keep the button, menu command and accessibility press as alternatives to dragging.
- Pass 24 tests, including native window hit regions, drag/release routing and all three photo sizes. The isolated application button was clicked successfully through the UI tool; a subsequent tool connection failure prevented physical drag verification.

## 1.0.2 — 2026-10-15

- Add a visible Clear All button at the lower right of the line; hide it when empty and keep the menu command available.
- Include the button in the floating panel's mouse hit testing without enlarging the photo scroll band.
- Reuse removal behavior: internal copies go to the Trash and external files stay in place.
- Ignore already removed items in queued bulk removal, including repeated clicks.

## 1.0.1 — 2026-10-14

- Deduplicate using normalized sRGB pixel content, image dimensions and alpha. Encoded PNG bytes are unsuitable because macOS-generated ICC profiles can change between conversions.
- Rebuild the duplicate index from pictures already hanging after a restart or clipboard-watching toggle.
- Remove redundant internal clipboard copies left by earlier builds, preserving screenshots and external source files.
- Permit copying again after the previous picture has been taken down, or when the source image content changes.
- Preserve the user's previously enabled launch-at-login choice when migrating from the original application.
- Validate 17 unit tests and 13 installed-application clipboard/watcher checks, including repeated JPEG conversion, restart and cross-format duplication.

## 1.0.0 — 2026-10-14

- Import copied local image files, including multiple Finder file URLs and legacy filename lists.
- Read the real image file rather than its file icon; create an independent PNG for all existing screenshot actions.
- Handle image data through ImageIO, apply orientation, and reject folders, non-images, invalid and oversized inputs.
- Filter plain text, RTF/RTFD/HTML previews, private or transient copies, and our own copy marker.
- Keep screenshot, preview, markup, dragging and removal behavior on the existing pipeline.
- Introduce ImageLine name, bundle identifier, menu symbol and original application icon.

Version 1.0.0 had an encoded-byte deduplication defect. Use 1.0.1.
