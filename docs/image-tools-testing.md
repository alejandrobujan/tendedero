# Testing scrolling capture and image editing

Run `bash scripts/test-image-tools.sh` on macOS 14 or later and
`swift scripts/check-strings.swift`. Native tests cover image coordinates, strip
removal, pixel order, transparency, colour profiles, PNG output, initial image
fitting, keyboard equivalents, closing decisions, and overlap matching.
On Linux, the test script exercises the production geometry and matcher only.

The PNGs in `Tests/TendederoTests/Fixtures` are synthetic numbered documents
for sparse-text overlap regressions. They contain no personal screen content,
and SwiftPM includes them in the test bundle only.

The following checklist requires a real Mac and relevant capture permissions.
It describes checks to perform, rather than claiming every scenario has passed.

1. Choose **Scrolling Capture…**, deny Screen Recording once, and verify the
   settings explanation. Grant access and reopen the app if macOS requests it.
2. Select content on a Retina display and a second display, including one above
   or left of the primary display. The green outline must match the selection.
   The panel should be positioned beside it when space permits. Capture must
   wait for **Start Capture**; the page can be positioned before starting.
3. Start **Vertical** capture. The live preview must show the first frame, then
   grow while scrolling downward in small steps. It should follow the newest
   content and remain responsive. Try **Horizontal** capture by scrolling right.
   Check pixel dimensions, seam order, and the short final scroll when clicking
   **Done**. The pointer, outline, controls, and live preview must be absent from
   the saved PNG, even when the controls overlap the selected region.
4. Repeat with a modest fixed header and footer, and a small animated widget.
   Detected fixed edges should appear once. Matching may still fail with large
   animations or changed layouts. Deliberately jump past all overlap and scroll
   backward. No unmatched section should be appended. Scroll back toward the
   last accepted view to recover, or choose **Done** to save the visible preview.
   Done must work even if the final viewport does not match.
5. Click **Auto-scroll**. Deny Accessibility and verify manual scrolling remains
   usable. Grant access, reopen if needed, and retry. The pointer should move
   inside the selected region, scrolling should advance in overlapping steps,
   and **Pause** should stop it. Move the pointer outside the area and verify it
   pauses; click Auto-scroll to resume. At the bottom, scrolling should stop
   after several unchanged views and offer Done. Check horizontal mode too.
6. Cancel selection, cancel capture, and close the panel. No PNG should be
   created. Start again. Quit or disconnect the selected display during capture;
   no overlay or sampling task should remain. At the size limit, Done must still
   save accepted content. Verify failed capture/encoding leaves usable controls.
7. Finish with inbox mode and copied-image handling off. Exactly one PNG should
   appear on the line and open in **Image Editor**. Repeat with inbox mode on to
   rule out duplicate cards. Confirm persistence, copy, drag, and discard.
8. Open an ordinary screenshot using its visible **Edit** button, double-click,
   press and hold, **Edit Latest Image…**, and **Open Image in Editor…**. Each
   route should expose Cut Out in the editor toolbar. **Open** and system
   **Markup** remain available in the right-click menu. Recordings keep playback
   and Trim and should not expose image editing.
9. In **Cut Out**, remove horizontal and vertical strips in either drag
   direction. The retained sides should merge without resizing, blank seams,
   or reordered pixels. Edge cuts are valid; zero-length and whole-image cuts
   must disable Cut. Zoom and scroll while selecting a tall image. Make multiple
   cuts, then undo the latest one with the button and ⌘Z.
10. Test **Crop**, **Arrow**, and **Rectangle**, including reverse drags. Apply,
    Undo, Copy, and Export should use image coordinates and original resolution.
    Test a transparent PNG and an oriented JPEG. **Save Copy** must preserve the
    source and add the edited PNG. Closing an unsaved edit or quitting should offer Save
    Copy, Discard, and Cancel. Cancel must retain the open editor.

Capture supports one positive axis per session, with overlapping viewports.
Repeated patterns, large animations, layout changes, and fixed edges wider than
a quarter of the viewport can prevent reliable matching. The editor has
one-step undo, raster arrows and rectangles in red, and PNG export. System
Markup remains available for additional annotation tools.

Check light and dark appearances, narrow windows, and long translated labels.
Verify that images initially fit, smaller images remain centred, the footer
tracks dimensions and zoom, and capture status remains visible separately from
its frame count and dimensions. Return should start or finish capture, and
Escape should cancel. Saving should disable capture controls until it finishes.
