#!/bin/bash
# Fails when source code asks macOS about a privacy permission directly. Every such question must go through
# src/TCC.swift, which keeps test, preview and benchmark runs from touching the permission records of the installed app
# (see the comment on `enum TCC`).
set -euo pipefail
cd "$(dirname "$0")/.."
PATTERN='AXIsProcessTrusted|CGPreflightListenEventAccess|CGPreflightScreenCaptureAccess|CGRequestScreenCaptureAccess|AVCaptureDevice\.authorizationStatus|AVCaptureDevice\.requestAccess|SFSpeechRecognizer\.authorizationStatus|SFSpeechRecognizer\.requestAuthorization'
HITS=$(grep -n -E "$PATTERN" src/*.swift | grep -v '^src/TCC.swift:' | grep -v -E '^[^:]+:[0-9]+:\s*///' | grep -v -E '`[^`]*('"$PATTERN"')[^`]*`' || true)
if [ -n "$HITS" ]; then
    echo "ERROR: ask for permissions through TCC (src/TCC.swift), not directly:"
    echo "$HITS"
    exit 1
fi
echo "tcc-calls ok"
