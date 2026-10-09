#!/bin/bash
# Builds the macOS release package and its checksum.
#
#   cadenza/tools/make-release.sh
#
# Output (cadenza/build/release/): Cadenza-<version>-macos-<label>.dmg (the disk image people open and drag to Applications),
# Cadenza-<version>-macos-<label>.zip (the same app, zipped) and SHA256SUMS.txt covering both.
# The package is signed ad hoc unless CADENZA_SIGN_IDENTITY names a certificate. It is not notarized.
# Build releases from a clean checkout of the version's tag so the package matches the published source.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's|.*<key>CFBundleShortVersionString</key><string>\(.*\)</string>.*|\1|p' build.sh | head -1)
[ -n "$VERSION" ] || { echo "ERROR: cannot read the version from build.sh"; exit 2; }

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    echo "WARNING: the working tree has uncommitted changes; the package will not match any published source."
fi

./build.sh --stage-only
STAGED="build/stage.noindex/Cadenza.app.zip"
[ -f "$STAGED" ] || { echo "ERROR: the staged package is missing"; exit 3; }

OUT="build/release"
ARCHS="${CADENZA_ARCHS:-arm64 x86_64}"
if [ "$ARCHS" = "arm64 x86_64" ]; then LABEL="universal"; else LABEL="${ARCHS// /-}"; fi
NAME="Cadenza-$VERSION-macos-$LABEL.zip"
DMG="Cadenza-$VERSION-macos-$LABEL.dmg"
mkdir -p "$OUT"
cp "$STAGED" "$OUT/$NAME"

# The disk image holds the same app as the zip, with a link to Applications so the app can be dragged across.
# The zip is unpacked into a temporary folder first, so the image is built from exactly the bytes the zip carries.
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cadenza-dmg.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
ditto -x -k "$OUT/$NAME" "$STAGE_DIR"
ln -s /Applications "$STAGE_DIR/Applications"
rm -f "$OUT/$DMG"
hdiutil create -quiet -volname "Cadenza $VERSION" -srcfolder "$STAGE_DIR" -ov -format UDZO "$OUT/$DMG"
hdiutil verify -quiet "$OUT/$DMG"

( cd "$OUT" && shasum -a 256 "$NAME" "$DMG" > SHA256SUMS.txt && shasum -a 256 -c SHA256SUMS.txt )
echo
echo "disk image:     $PWD/$OUT/$DMG"
echo "zip package:    $PWD/$OUT/$NAME"
echo "checksum file:   $PWD/$OUT/SHA256SUMS.txt"
echo "next: see cadenza/docs/RELEASING.md"
