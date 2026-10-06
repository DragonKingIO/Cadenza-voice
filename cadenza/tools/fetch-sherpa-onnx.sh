#!/bin/bash
# 获取本地模型推理库 sherpa-onnx（静态库 + C 头文件），放到 third_party/sherpa-onnx。
# 这是推理库，不是语音模型；语音模型由应用内“本地模型”页面下载。
# 不运行此脚本也能构建：build.sh 找不到库时会编译不含本地推理的版本。
#
#   tools/fetch-sherpa-onnx.sh
#   SHERPA_ARCHIVE=/path/to/sherpa-onnx-v1.13.8-osx-universal2-static-no-tts-lib.tar.bz2 \
#   SHERPA_HEADER=/path/to/c-api.h tools/fetch-sherpa-onnx.sh     # 使用已下载的文件
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="v1.13.8"
ARCHIVE_NAME="sherpa-onnx-${VERSION}-osx-universal2-static-no-tts-lib.tar.bz2"
ARCHIVE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${VERSION}/${ARCHIVE_NAME}"
ARCHIVE_SHA256="7bbaa4bf1c73a68cc9ea126967278873c86eeeb99774b544f3644e0a6200e993"
HEADER_URL="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/${VERSION}/sherpa-onnx/c-api/c-api.h"
HEADER_SHA256="2a1b95084be8fd1deb3228fcad2fd3f7f0258b64582f7402281ec174c7b7f4ce"
DEST="third_party/sherpa-onnx"
LIBS="libsherpa-onnx-c-api libsherpa-onnx-core libonnxruntime libkaldi-native-fbank-core libkaldi-decoder-core libkissfft-float libsherpa-onnx-fst libsherpa-onnx-fstfar libsherpa-onnx-kaldifst-core libssentencepiece_core"

WORK=$(mktemp -d /tmp/sherpa-fetch.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

fetch() { # name url sha256 override
    local out="$WORK/$1"
    if [ -n "${4:-}" ]; then cp "$4" "$out"; else curl -fL --retry 3 -o "$out" "$2"; fi
    local got; got=$(shasum -a 256 "$out" | awk '{print $1}')
    if [ "$got" != "$3" ]; then echo "ERROR: SHA256 mismatch for $1 (expected $3, got $got)"; exit 1; fi
}

fetch archive "$ARCHIVE_URL" "$ARCHIVE_SHA256" "${SHERPA_ARCHIVE:-}"
fetch c-api.h "$HEADER_URL" "$HEADER_SHA256" "${SHERPA_HEADER:-}"

rm -rf "$DEST"; mkdir -p "$DEST/lib" "$DEST/include/sherpa-onnx/c-api"
tar -xjf "$WORK/archive" -C "$WORK"
for l in $LIBS; do cp "$WORK/${ARCHIVE_NAME%.tar.bz2}/lib/$l.a" "$DEST/lib/"; done
cp "$WORK/c-api.h" "$DEST/include/sherpa-onnx/c-api/c-api.h"
echo "$VERSION" > "$DEST/VERSION"
echo "sherpa-onnx $VERSION installed to $DEST"
