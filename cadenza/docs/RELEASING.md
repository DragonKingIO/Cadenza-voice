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
6. After the first public release, set `AppUpdate.repository` (in `src/AppUpdate.swift`) to `DragonKingIO/Cadenza-voice`
   so that Settings → About can check for updates, and link the release from the website.

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
1. Download `Cadenza-X.Y.Z-macos-arm64.zip` and unzip it.
2. Open the app. macOS blocks the first launch because the app is not notarized: open System Settings → Privacy & Security,
   scroll to the message about the app and choose **Open Anyway**.
3. Allow Microphone, Accessibility and Input Monitoring when asked.

Requires macOS 26 or later on Apple silicon.

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
