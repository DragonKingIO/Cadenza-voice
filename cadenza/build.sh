#!/bin/bash
# 产物安装到 /Applications（用户可见、TCC"+"选择方便）。
# 显式指定部署版本，避免本机工具链默认写入高于运行系统的 Mach-O minos。
set -euo pipefail
cd "$(dirname "$0")"
# Refuse the retired source layout so an old copy cannot silently replace the installed app.
if [ "$(basename "$PWD")" != "cadenza" ] || [ ! -f ../BRAND.md ]; then
    echo "ERROR: build from the current cadenza directory in the project root"
    exit 6
fi

# Permission questions must go through src/TCC.swift (see the comment there), or test runs can wipe the installed app's grants.
./tools/check-tcc-calls.sh || exit 7

INSTALL_APP="/Applications/随言.app"
STAGE_ONLY=false
if [ "${1:-}" = "--stage-only" ]; then STAGE_ONLY=true; fi
STAGE_DIR=$(mktemp -d /tmp/cadenza-build.XXXXXX)
# Builds run from a temporary bundle; unregister it so macOS does not keep ghost app entries (Spotlight, Open With).
cleanup_stage() {
    # set -e is still active inside an EXIT trap: a failing unregister must neither change the exit status nor skip the removal.
    for staged in "$STAGE_DIR"/*.app; do
        if [ -e "$staged" ]; then /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$staged" >/dev/null 2>&1 || true; fi
    done
    rm -rf "$STAGE_DIR" || true
    return 0
}
trap cleanup_stage EXIT
APP="$STAGE_DIR/随言.app"
BIN="$APP/Contents/MacOS/Cadenza"

mkdir -p build
if [ "$STAGE_ONLY" = false ]; then mkdir -p "$HOME/Library/Application Support/Cadenza"; fi
# Build a fresh bundle; never inherit obsolete resources from an installed app.
mkdir -p "$APP/Contents/MacOS"

# 本地模型推理（可选）：存在 third_party/sherpa-onnx（tools/fetch-sherpa-onnx.sh 获取）时静态链接，
# 否则编译不含本地推理的版本，应用其余功能不受影响。
SHERPA_DIR="third_party/sherpa-onnx"
SHERPA_FLAGS=()
if [ -f "$SHERPA_DIR/include/sherpa-onnx/c-api/c-api.h" ] && [ -f "$SHERPA_DIR/lib/libonnxruntime.a" ]; then
    SHERPA_FLAGS=(-D LOCAL_SHERPA -import-objc-header bridge/SherpaBridge.h -I "$SHERPA_DIR/include" -L "$SHERPA_DIR/lib"
        -lsherpa-onnx-c-api -lsherpa-onnx-core -lonnxruntime -lkaldi-native-fbank-core -lkaldi-decoder-core -lkissfft-float
        -lsherpa-onnx-fst -lsherpa-onnx-fstfar -lsherpa-onnx-kaldifst-core -lssentencepiece_core -lc++)
    if [ -f "$SHERPA_DIR/include/onnxruntime/core/session/onnxruntime_c_api.h" ]; then SHERPA_FLAGS+=(-D LOCAL_ORT); fi
    echo "local-inference=sherpa-onnx $(cat "$SHERPA_DIR/VERSION" 2>/dev/null) onnxruntime-api=$([ -f "$SHERPA_DIR/include/onnxruntime/core/session/onnxruntime_c_api.h" ] && echo yes || echo no)"
else
    echo "local-inference=absent (run tools/fetch-sherpa-onnx.sh to enable local models)"
fi

# One binary for Apple silicon and Intel (override with CADENZA_ARCHS="arm64" for a quicker single-architecture build).
# Each architecture is compiled for the oldest supported macOS; the result is merged with lipo.
MIN_MACOS="14.0"
ARCHS="${CADENZA_ARCHS:-arm64 x86_64}"
SLICES=()
RC=0
: > build/swiftc.log
set +e
for ARCH in $ARCHS; do
    swiftc -target "$ARCH-apple-macosx$MIN_MACOS" -swift-version 5 -O src/*.swift trigger-state-machine/Sources/TriggerCore/TriggerStateMachine.swift -lz ${SHERPA_FLAGS[@]+"${SHERPA_FLAGS[@]}"} -o "$BIN.$ARCH" >> build/swiftc.log 2>&1
    SLICE_RC=$?
    [ "$SLICE_RC" -ne 0 ] && RC=$SLICE_RC
    SLICES+=("$BIN.$ARCH")
done
set -e
echo "swiftc-exit=$RC archs=$ARCHS min-macos=$MIN_MACOS"
if [ "$RC" -ne 0 ]; then
    echo "--- swiftc.log (tail) ---"
    tail -40 build/swiftc.log
    exit "$RC"
fi
if [ "${#SLICES[@]}" -eq 1 ]; then mv "${SLICES[0]}" "$BIN"; else lipo -create "${SLICES[@]}" -output "$BIN"; rm -f "${SLICES[@]}"; fi
echo "binary-architectures=$(lipo -archs "$BIN")"
if [ -s build/swiftc.log ]; then
    echo "--- swiftc.log (warnings) ---"
    cat build/swiftc.log
fi
if [ ! -x "$BIN" ]; then
    echo "ERROR: expected binary missing: $BIN"
    exit 3
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
    <key>CFBundleName</key><string>Cadenza</string>
    <key>CFBundleDisplayName</key><string>Cadenza</string>
    <key>CFBundleIdentifier</key><string>local.cadenza.app</string>
    <key>CFBundleIconFile</key><string>Cadenza</string>
    <key>CFBundleExecutable</key><string>Cadenza</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.2.0</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSUIElement</key><false/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Cadenza uses the microphone to turn your speech into text.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Cadenza uses speech recognition to turn your speech into text.</string>
</dict>
</plist>
PLIST
mkdir -p "$APP/Contents/Resources"
cp LICENSE "$APP/Contents/Resources/LICENSE"
# Third-party notices and the license texts of the code linked in from third_party (see licenses/README.md);
# distributing the binary requires shipping them.
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
mkdir -p "$APP/Contents/Resources/Licenses"
cp -R licenses/. "$APP/Contents/Resources/Licenses/"
cp resources/brand/Cadenza.icns "$APP/Contents/Resources/"
cp resources/brand/cadenza-menubar*.png "$APP/Contents/Resources/"
cp resources/brand/cadenza-icon-128.png "$APP/Contents/Resources/"
cp resources/brand/cadenza-logo.svg "$APP/Contents/Resources/"
cp resources/*.svg "$APP/Contents/Resources/"
# Character animations for the recording bar (see THIRD_PARTY_NOTICES.md); the app falls back to the waveform if the folder is missing.
# Privacy notice and terms shown inside the app (the repository copies stay the source of truth).
rm -rf "$APP/Contents/Resources/legal"; mkdir -p "$APP/Contents/Resources/legal"
cp PRIVACY.md PRIVACY.zh-CN.md TERMS.md TERMS.zh-CN.md "$APP/Contents/Resources/legal/"
cp docs/LOCAL-API.md "$APP/Contents/Resources/legal/LOCAL-API.md"
rm -rf "$APP/Contents/Resources/character"
if [ -d resources/character ]; then ditto resources/character "$APP/Contents/Resources/character"; fi
# Shared vocabulary packs (cadenza/vocab); the app ignores a pack that is not valid, and --selftest fails on one.
rm -rf "$APP/Contents/Resources/vocab"
if [ -d vocab ]; then mkdir -p "$APP/Contents/Resources/vocab"; cp vocab/*.json "$APP/Contents/Resources/vocab/"; fi
for LANGUAGE_DIR in resources/en.lproj resources/zh-Hans.lproj; do
    ditto "$LANGUAGE_DIR" "$APP/Contents/Resources/$(basename "$LANGUAGE_DIR")"
done
for LANGUAGE in en zh-Hans; do
    plutil -lint "$APP/Contents/Resources/$LANGUAGE.lproj/Localizable.strings"
    plutil -lint "$APP/Contents/Resources/$LANGUAGE.lproj/InfoPlist.strings"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ "$STAGE_ONLY" = false ]; then cp test-field.html "$HOME/Library/Application Support/Cadenza/test-field.html"; fi
# 安装目录在非同步位置，但仍然防御性清理并重试签名；签名后必须通过严格校验
# 签名身份跨重建保持。证书缺失时停止，不替换 TCC 身份。
# Contributors do not have the maintainer's certificate. A staged package (--stage-only) may be signed ad hoc, which is
# enough to build, self-test and preview. Installing over /Applications still requires the real identity, so another
# build can never replace the signature that the installed app's privacy permissions are tied to.
# CADENZA_SIGN_IDENTITY overrides the certificate; "-" means ad hoc.
SIGN_ID="${CADENZA_SIGN_IDENTITY:-0f20bc528fd015ac71e1fea73d8185707ed22c27}"
SIGNED=0
for i in 1 2 3; do
    xattr -cr "$APP" 2>/dev/null || true
    if [ "$SIGN_ID" = "-" ]; then
        CODESIGN_ARGS=(-f -s - --timestamp=none)
    elif security find-identity -v -p codesigning 2>/dev/null | grep -qi "$SIGN_ID"; then
        CODESIGN_ARGS=(-f -s "$SIGN_ID" --timestamp=none)
    elif [ "$STAGE_ONLY" = true ]; then
        [ "$i" = 1 ] && echo "NOTE: signing identity not found; the staged package is signed ad hoc (fine for building and testing)"
        CODESIGN_ARGS=(-f -s - --timestamp=none)
    else
        echo "ERROR: required signing identity unavailable; installed app preserved (use --stage-only to build without it)"
        exit 6
    fi
    if codesign "${CODESIGN_ARGS[@]}" "$APP" 2>/dev/null; then
        SIGNED=1
        break
    fi
    sleep 1
done
if [ "$SIGNED" -ne 1 ]; then
    echo "ERROR: codesign failed after retries"
    exit 4
fi
xattr -cr "$APP" 2>/dev/null || true
if ! codesign --verify --strict "$APP" 2>/dev/null; then
    echo "ERROR: codesign verify failed (detritus/xattr race?)"
    codesign --verify --strict "$APP"
    exit 5
fi
echo "codesign-verify-exit=0"
# A stage-only build creates a signed reviewable artifact, without replacing the app or user files.
if [ "$STAGE_ONLY" = true ]; then
    # Keep review builds non-launchable in the checkout, so app-name lookup cannot open one.
    STAGED_ARCHIVE="$PWD/build/stage.noindex/Cadenza.app.zip"
    mkdir -p "$(dirname "$STAGED_ARCHIVE")"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGED_ARCHIVE"
    unzip -t "$STAGED_ARCHIVE" >/dev/null
    echo "staged archive: $STAGED_ARCHIVE"
    exit 0
fi
# Verify this fresh binary before touching the installed application.
set +e
"$BIN" --selftest > build/selftest.log 2>&1
SELFTEST_RC=$?
set -e
echo "selftest-exit=$SELFTEST_RC"
if [ "$SELFTEST_RC" -ne 0 ]; then
    cat build/selftest.log
    exit "$SELFTEST_RC"
fi
# Replace the whole bundle instead of merging into it, so renamed or removed files never linger and break the seal.
INSTALL_NEW="$INSTALL_APP.installing"
rm -rf "$INSTALL_NEW"
ditto "$APP" "$INSTALL_NEW"
codesign --verify --strict "$INSTALL_NEW"
rm -rf "$INSTALL_APP"
mv "$INSTALL_NEW" "$INSTALL_APP"
codesign --verify --strict "$INSTALL_APP"
echo "installed: $INSTALL_APP"
