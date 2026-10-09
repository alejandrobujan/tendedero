# Clipboard image support

The menu bar's **Hang copied images** option is off by default. Enable it to
hang screenshots made with Control–Shift–Command–4 while keeping the image
available for immediate paste in another app. The option watches all newly
copied PNG/TIFF images; it cannot distinguish screenshots from other copied
images. Turning it on or restarting monitoring does not import the previous
clipboard contents. There is no new launch-time prompt.

The watcher polls the change count every 0.5 seconds. It reads image bytes only
after checking every clipboard item's types. Concealed, transient and
auto-generated items are skipped before reading image data. It never writes
to the clipboard, reads text, opens file/remote URLs, or uses the network.
Finder file copies are ignored, including their image icon representations.
PNG is kept byte-for-byte; TIFF's first frame is decoded locally to PNG.
Inputs are limited to 32 MiB and 40 million pixels, with PNG output also
limited to 32 MiB. Invalid images are ignored. Saved files use unique names
and owner-only permissions in the existing inbox. Storage failures do not
change the clipboard or hang a broken entry.

Click-to-copy records the resulting pasteboard change count, so monitoring
does not hang the application's own copies again. An image saved by this
watcher can also be observed by the existing folder watcher; `Line.hang`
already rejects a second entry for the same URL.

## Review and attribution

Based on [Tendedero](https://github.com/alejandrobujan/tendedero), upstream
commit `ed0618a67cc59e0a8621b97bb5e32ab9af3b0b69` (2026-10-08).
The [MIT license and original copyright](../LICENSE) remain unchanged.

The opt-in preference, polling, enable-time baseline, private-type names and
copy change-count suppression are adapted from
[PR #1, “Hang images copied to the clipboard”](https://github.com/alejandrobujan/tendedero/pull/1),
authored by **Anubhav-Rai**, head commit
`0f4b3df1d05ed88303b0c3bb3311aa4c08d57745`. It was open and unmerged when
reviewed on 2026-10-09. Its source is covered by the repository's MIT license.

The PR's direct Finder-file import and first-launch offer are omitted to keep
the feature small and its access explicit. This adaptation adds injectable,
read-only clipboard access, all-item privacy checks, change-count race
checks, image validation/resource limits, private uniquely named files, and
Chinese translations required by current main. It introduces no dependencies.
The hardening and tests can also be reused in PR #1 if that is the preferred
implementation; this adaptation does not replace its author's contribution.

The license requires modified or redistributed builds to use a different name
and icon. See [LICENSE](../LICENSE) before distributing a development build.

## Synthetic verification

`Tests/TendederoTests/ClipboardWatcherTests.swift` uses only in-memory fake
clipboard objects and tiny images generated with Apple's ImageIO. It never
accesses `NSPasteboard.general`, constructs `Line`/`AppDelegate`, launches the
app, or changes user preferences. It checks enable/disable baselines,
PNG preservation, TIFF conversion, duplicate suppression, private markers,
unsupported types and Finder icons, races, resource bounds and storage errors.

On a normal macOS development machine:

```sh
swift test
swift scripts/check-strings.swift
```

If XCTest is unavailable (Command Line Tools only), the same 17 cases run
through a small local assertion adapter, without SwiftPM:

```sh
bash scripts/test-clipboard.sh
```

With macOS 27 Command Line Tools, use the macOS 26 SDK if SwiftUI's required
macro plugin is unavailable. See the upstream README's build instructions.
The committed automated tests use synthetic clipboard sources only. They do
not require an installed app or access to the user's clipboard.
