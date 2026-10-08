# Memory optimizations

Measured on macOS 15.7.4, Apple silicon, with Swift 6.2.3 compiling in release mode. The reference is commit `d991454`. These are isolated harness measurements, not the complete app's idle memory footprint. The fixture is a synthetic 6000 × 4000 image; image and animation bursts contain 12 entries. The watcher folder contains 10,000 unrelated files and 12 image paths.

The harness samples process physical footprint every 1 ms, including synchronous decoding/encoding. Peaks are sampled rather than guaranteed high-water marks, and do not include WindowServer/GPU memory. Results vary with the system and decoder caches.

| Scenario | Original peak MiB | Updated peak MiB |
| --- | ---: | ---: |
| Retain 12 thumbnails | 16.56 | 13.66 |
| Copy JPEG without requesting PNG | 190.02 | 5.17 |
| Request full-resolution clipboard PNG | 189.94 | 189.64 |
| Save full-resolution image from Markup | 192.27 | 189.97 |
| Burst of falling cards | 23.53 | 14.72 |
| Burst of arriving captures | 593.19 | 45.42 |
| Start watcher on large folder | 14.30 | 5.23 |

The retained thumbnail raster buffers fall from 7.03 MiB to 2.25 MiB (68%). Arrival raster allocations in the burst fall from 274.66 MiB to 11.44 MiB. The watcher adds 0.17 MiB above its warmed baseline instead of 9.11 MiB.

## Changes and tradeoffs

- Card thumbnails fit the 136 × 104 point photo area at the largest connected display scale. Display configuration changes reload live thumbnails. Image sources disable full-source caching and decode the thumbnail immediately.
- Arrival images are capped at 1500 pixels on their longest side, with at most two large arrivals active. Further captures land directly. Full-resolution source files, clipboard PNGs, and edits retain their original resolution; only the transient arrival image has lower resolution.
- Each display has one animation overlay and one timer. Its window covers the union of the cards' complete motion bounds, clipped to the display. Layers, timers, and windows are released when idle. Landing fades remain per-card, allowing overlapping animations.
- Copy creates one disk snapshot, advertises the original file URL, and promises PNG data only when requested. The snapshot preserves copy-time contents after editing, deletion, or a moved original. Symlinks are resolved when taking the snapshot. Snapshots are removed when fulfilled or superseded. Normal quit and handled termination signals fulfill the current promise before exiting. Clipboard managers or applications that immediately request PNG still incur the full-resolution conversion cost.
- PNG originals remain compressed. Other images transcode directly through ImageIO, with orientation normalization when needed. Avoiding TIFF reduces intermediate/retained allocations but does not eliminate ImageIO's full-resolution decoding/encoding workspaces: the full-resolution paste and image-save peaks remain approximately unchanged for this fixture.
- Markup writes encoded images straight to a staging file and copies returned files atomically on disk. Providers prefer file representations, copied within their callback lifetime, with a data-representation fallback. Original targets remain intact if staging fails.
- The watcher enumerates only the immediate directory, retains image paths, and sorts only newly discovered candidates. Unrelated entries are released during enumeration.

## Reproduce

Compile the isolated harness with all application sources except the normal entry point:

```sh
swiftc -O $(rg --files Sources/Tendedero -g '*.swift' | rg -v '/main.swift$') \
  scripts/measure-memory.swift -o /tmp/tendedero-memory
/tmp/tendedero-memory fixture /tmp/tendedero-fixture.png
/tmp/tendedero-memory fixture /tmp/tendedero-fixture.jpg
/tmp/tendedero-memory thumbnails /tmp/tendedero-fixture.png
/tmp/tendedero-memory falls /tmp/tendedero-fixture.png
/tmp/tendedero-memory flights /tmp/tendedero-fixture.png
/tmp/tendedero-memory copy /tmp/tendedero-fixture.jpg
/tmp/tendedero-memory paste /tmp/tendedero-fixture.jpg
/tmp/tendedero-memory markup /tmp/tendedero-fixture.jpg
/tmp/tendedero-memory watcher /path/to/test-folder
```

The animation modes briefly display synthetic cards. The harness uses unique test pasteboards and temporary files; it does not start AppDelegate, change system screenshot settings, or access the user's clipboard.

For the reference, export `d991454` into a temporary directory, compile those application sources excluding `main.swift` with the current harness and `-D BASELINE`, and run the same fixtures. Its baseline copy/save code reproduces the original private TIFF conversion methods.

Clipboard persistence can be checked across process exit:

```sh
BOARD=$(/tmp/tendedero-memory clipboard-exit /tmp/tendedero-fixture.png)
swift scripts/check-clipboard.swift "$BOARD" /tmp/tendedero-fixture.png
```

The `clipboard-signal` mode prints its unique pasteboard name, installs a SIGTERM handler, and waits. Terminate that test process, wait for it to exit, then run the same clipboard reader. Both normal exit and SIGTERM were verified with a separate reader process: it recovered exactly 428,877 PNG bytes at 6000 × 4000 pixels after the writer had terminated.

## Validation

- `swift test -c release`: 20 tests, zero failures.
- Apple silicon release executable built as part of the release tests.
- `swift build -c release --triple x86_64-apple-macosx14.0`: successful Intel release build.
- Tests cover PNG transparency, full resolution, colored JPEG orientation, thumbnail budgets, overlay expansion/shrink without coordinate jumps, completion reentrancy, arrival limits, idle window release, watcher ordering, atomic replacement failures, relative symlinks, copy-time snapshots, clipboard ownership, snapshot cleanup, and quit materialization.
- Independent source review completed; the identified symlink regression was reproduced and fixed.
- The system Markup extension's UI itself was not automated; its save helpers and callback handling were tested/reviewed.
