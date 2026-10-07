# Releasing

Maintainers publish releases on GitHub. A release is a signed-ad-hoc, not notarized macOS package plus its checksum.

## Before you start

1. CI is green on `main` and all self-test suites pass ([DEVELOPING.md](DEVELOPING.md)).
2. `CHANGELOG.md` describes the changes in the new version.
3. The version in `build.sh` (`CFBundleShortVersionString`) is the one you are releasing. The in-app update check compares
   it with the release tag, and local models declare the lowest app version they need (`minAppVersion`), so change versions
   deliberately.

## Steps

1. Tag the commit: `git tag -a vX.Y.Z -m "Cadenza X.Y.Z"` and push the tag.
2. From a clean checkout of that tag run `cadenza/tools/make-release.sh`. It builds the package and writes
   `cadenza/build/release/Cadenza-X.Y.Z-macos-<arch>.zip` and `SHA256SUMS.txt`. The script warns when the tree is not clean.
3. Smoke test the zip on a Mac that did not build it: unzip, open (see "First launch" below), grant the permissions,
   record a sentence with a downloaded local model, and check that the text arrives.
4. Create the GitHub Release for the tag, attach both files, and paste notes from the template below.
5. **Do not mark it as a pre-release or draft** if you want the in-app update check to offer it: the check reads GitHub's
   "latest release" and ignores drafts and pre-releases.
6. Link the release from the website: its download page reads the latest release when it is built (daily, or push a commit).

## How people find out about a release

`AppUpdate.repository` in `src/AppUpdate.swift` points at this repository. People who answered yes in the setup wizard (or ticked
the box in About) are checked once a week; everyone can press **Check for updates** in About. When a newer, non-pre-release
version exists, the app remembers it and shows a notice in the menu bar menu and on About, with a link to the release page. Nothing
is downloaded or installed automatically, and a person can skip a version.

About shows the **first section** of the release notes (up to 8 lines, plain text: headings, tables and code are dropped), so put
the user-facing changes in the first section and the install steps after it, as in the template above. Write them so they make sense
to someone who has not read the changelog.

## First launch of a downloaded build

The package is signed ad hoc and not notarized, so macOS blocks the first launch of a downloaded copy. Open
**System Settings → Privacy & Security**, scroll to the message about the app, choose **Open Anyway** and confirm.
(Since macOS 15, Control-click → Open no longer bypasses this.) A copy you built yourself is not quarantined and opens
normally. Because each ad hoc build has a new identity, macOS asks again for Microphone, Accessibility and Input Monitoring
after an update.

## Release notes template

```markdown
## What's new
- …

## Install
1. Download `Cadenza-X.Y.Z-macos-universal.zip` and unzip it.
2. Open the app. macOS blocks the first launch because the app is not notarized: open System Settings → Privacy & Security,
   scroll to the message about the app and choose **Open Anyway**.
3. Allow Microphone, Accessibility and Input Monitoring when asked.

Requires macOS 14 or later (Apple silicon or Intel).

## Verify
`shasum -a 256 -c SHA256SUMS.txt`

## Known limitations
- Not notarized; permissions must be granted again after each update.
- …
```

## Why no notarization

Notarization needs a paid Apple Developer ID. The project is a volunteer open-source effort without a budget for it, so it
ships ad hoc builds and says so plainly. Anyone can build from source. If a sponsor or the community later covers the
fee, releases can be notarized without changing the app.
