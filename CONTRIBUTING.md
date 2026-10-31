# Contributing to Tendedero

Thanks for wanting to help. Tendedero is small on purpose: one line at the
top of the screen, one gesture for each thing you do with a photo, and
nothing else in the way. This guide says what tends to fit, how to build it,
and how to send a change so it can be merged quickly.

## Before you start

For anything bigger than a fix, open an issue first and describe what you
want to do and why. Many ideas have already been weighed in earlier issues,
and a short conversation saves you from building something that will not be
merged. Small fixes, translations and typo corrections can go straight to a
pull request.

## What fits

Tendedero tries to stay one physical metaphor: photos hanging on a line.
Changes that make that metaphor work better are the most welcome.

Usually a good fit:

- Fixes, especially with clear steps to reproduce them.
- A gesture that means the same thing everywhere it applies, like Space
  for a quick look or ⌘Z to put something back.
- Making an existing behaviour clearer, smoother or easier to discover.
- New languages, and better translations of existing ones.

Usually not a fit:

- A settings window. Options live in submenus of the menu bar item, and
  each new option has to earn its place.
- Network access. The only thing that reaches the internet is Check for
  Updates, which opens the website.
- Deleting files for good. Anything that leaves the line goes to the Trash
  or stays where it is, and ⌘Z can bring it back.
- Taking screenshots, editing images or managing a clipboard history.
  Tendedero shows what macOS captures and hands editing to Markup.
- New permissions, such as Accessibility or Screen Recording, or private
  APIs, unless there is no other way and the gain is large.
- Several unrelated changes in one pull request.

When several people ask for something, the answer is usually a more
general change that covers all of them, so please be patient if an idea
waits for that.

## Building

```sh
git clone git@github.com:alejandrobujan/tendedero.git
cd tendedero
scripts/build-app.sh
open build/Tendedero.app
```

Requires the Swift toolchain; Xcode is optional. With the Command Line
Tools for macOS 27, the script falls back to the macOS 26 SDK, because the
new SDK needs a SwiftUI macro plugin only Xcode includes. Tendedero
supports macOS 14 Sonoma and later.

Quit any other copy of Tendedero before opening a build: they share the
same bundle id and the same screenshot settings. Quitting restores the
macOS screenshot settings Tendedero changed.

## Sending a change

- One change per pull request. Small ones get reviewed and merged sooner.
- Test it on a real Mac and say what you did and on which macOS version.
  For anything visual, a short recording helps a lot.
- Keep "Allow edits by maintainers" on. I sometimes push a commit on top of
  your branch to adjust details, so the change still lands as yours.
- Pull requests are merged with a squash. You stay the author, and anyone
  whose idea or code went into it is added as a co-author.
- `XCTest` is not part of the Command Line Tools, so please do not add test
  targets that need it.

## Text and languages

Every piece of text in the app goes through `L("English text")` and lives in
`Sources/Tendedero/Resources/<language>.lproj/Localizable.strings`. The app
speaks eleven languages: English, Spanish, Galician, French, Brazilian
Portuguese, Japanese, Korean, Simplified Chinese, Turkish, Azerbaijani and
Hindi.

- When you add text, add it to every language. A rough translation is
  better than none; say which ones need a native speaker's review.
- Run `swift scripts/check-strings.swift`, which checks that every language
  has every string and nothing is left unused.
- New gestures go in the gesture table of every README, in `README.md` and
  in `docs/i18n`.
- A new language is very welcome: copy `en.lproj`, translate it, and add a
  README in `docs/i18n` if you can.

## Code

- Match the code around your change: its names, its structure, and its
  comments, which are short prose in plain English that say why, not what.
- No new dependencies.
- Keep the app quiet: no logging of personal data, no background work that
  is not needed.

## Ports and forks

The code is MIT licensed, but the Tendedero name and icon are not: see the
note at the end of `LICENSE`. Ports to other platforms and forks are
welcome as separate projects with their own name and icon, and I am happy
to link to them from the README. They will not be merged into this
repository.

## AI tools

Using them is fine. Please read and test what you send as carefully as if
you had written every line, keep the change as small as the problem needs,
and describe how you tested it in your own words.

## Reporting a bug

Use the bug report template and include your macOS version, the Tendedero
version, whether "Handle screenshots" is on, and the steps that lead to the
problem. If the line does not come down where you expect, say how your
displays and menu bar are set up.
