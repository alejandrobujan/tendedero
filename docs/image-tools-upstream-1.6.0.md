# Image tools reconciliation with upstream 1.6.0

Integration target: `32a3e47187fdea7b2fd43b3ab5a913f0ed33724a` (v1.6.0).
Original PR #56 head: `2d267ec39ffc7e49655e0da39ec7dae69fd92dbe`.
Merge base: `cf87e6ebc275d4f2cc42900e55f88a52d3ce9e46` (v1.5.0).
The feature head contains one commit beyond the merge base; the upstream target
contains twelve. Integration uses a merge with the original feature head as
first parent, preserving history, tests, and synthetic fixtures. It does not
merge the PR into upstream main.

## Actual conflicts and resolutions

A trial `git merge --no-commit --no-ff upstream/main` identified three conflicted
files (four conflict hunks), rather than every file changed by both branches.

| File | Conflict | Resolution |
| --- | --- | --- |
| `Sources/Tendedero/AppDelegate.swift` | `refresh()`: scrolling-capture suppression versus explicit fullscreen reveal | Keep the capture guard first, then upstream's `!openedOnPurpose` fullscreen condition. Preserve the Space-change reset, tuck-away reset, shortcut/menu intent, empty-hover restriction, and status icon updates. Existing capture guards in `toggle()`, `tick()`, and `comeDown()` remain. |
| `Sources/Tendedero/GrabArea.swift` | Header documentation only | Describe delayed single-click copy and editor/recording routes. Keep upstream's click timer cancellation on the second mouse-down and delayed copy in `mouseUp()`. Keep the feature's editor dispatch, Edit hit target, and context-menu actions. |
| `scripts/build-app.sh` | Version plus argument validation; bundle version plus development region | Use 1.6.0 / build 7 / `en`, matching the actual English resource directory. Retain argument validation, native SwiftPM backend, SDK fallback, universal/native builds, executable-slice checks, and certificate-hash/ad hoc signing. |

## Shared edits that merged cleanly

- `GrabArea.swift` executable changes are independent: upstream changes when a
  single click copies, while the feature changes the double-click/hold target
  for images. Double-click opens the editor without copying; recordings still
  use playback/Trim. Explicit Open and system Markup remain in the context menu.
- `PeggedView.swift`: upstream's `.fixedSize()` for the Copied badge coexists
  with the feature's visible Edit affordance.
- `README.md`: preserve upstream language links/badge additions and the feature
  interaction table, capture/editor instructions, and build/test documentation.
- The nine existing `Localizable.strings` files (`az`, `en`, `es`, `fr`, `ja`,
  `ko`, `pt-BR`, `tr`, `zh-Hans`): upstream adds two line-status keys and the
  feature adds 60 image-tool keys in separate sections. Retain both sets.
- Upstream's new Galician/Hindi resources, translated README files, README art,
  and art-generator changes are carried through unchanged.

## Localization boundary

There are 117 literal localization keys in the integrated sources. The original
nine languages contain all 117. Galician and Hindi each contain 57 upstream
keys and lack the 60 feature keys; these display English through the existing
lookup/fallback behavior. No guessed translations or English-filled tables are
introduced merely to silence warnings. `CFBundleDevelopmentRegion=en` matches
`en.lproj`, and the build script discovers all eleven languages automatically.
The existing Swift checker treats missing non-English translations as warnings.
Completion of Galician/Hindi feature translations and visual language review
remain outstanding.

## Validation in this integration environment

Performed on Linux without a Swift toolchain:

- `bash -n scripts/build-app.sh scripts/test-image-tools.sh`: passed.
- Static extraction of every literal `L(...)` call and every strings-table
  entry: 117 keys; no duplicate or unused keys; complete coverage in the original
  nine languages; exactly 60 missing keys each in Galician and Hindi.
- Format-placeholder comparison for every available translation: passed.
- Comparison of all translated values against upstream: every upstream value
  preserved.
- Parsed the generated Info.plist template with version/language substitutions:
  1.6.0, build 7, development region en, eleven languages, macOS 14 minimum.
- Existing Tests tree, synthetic PNG fixtures, and the geometry, image editing,
  editor, and scrolling-capture implementation files match the original feature
  head byte for byte.
- Whitespace and conflict-marker checks: passed after resolution.

Attempted but unavailable: `bash scripts/test-image-tools.sh` stops because
`swiftc` is absent; `swift scripts/check-strings.swift` cannot run because
`swift` is absent. Static localization checks are not a run of the Swift checker.
No native test, portable Swift test, macOS build, codesign verification, or
hardware/UI run is claimed for this integrated revision. The PR's earlier
32-test/universal-build results describe its earlier head only.

See the added integration section in [image-tools-testing.md](image-tools-testing.md)
for the pending Mac, fullscreen, clipboard, SDK/build, localization, Intel,
physical-display-disconnection, and large-animation checks.
