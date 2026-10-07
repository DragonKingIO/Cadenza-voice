#!/bin/bash
# Runs every self-test suite against a built app and fails unless each one ran to the end and reported no failures.
#
#   cadenza/tools/run-selftests.sh /path/to/Cadenza.app
#
# Used by CI on every runner; also handy locally on an unpacked package.
set -uo pipefail
APP="${1:?usage: run-selftests.sh /path/to/Cadenza.app}"
BIN="$APP/Contents/MacOS/Cadenza"
LOGDIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
test -x "$BIN" || { echo "::error::executable not found: $BIN"; exit 1; }
echo "machine: $(uname -m), macOS $(sw_vers -productVersion), binary architectures: $(lipo -archs "$BIN")"
FAILED=0
for suite in selftest selftest-settings-ui selftest-settings-polish selftest-status-menu selftest-asr-settings selftest-asr-entry selftest-local-model selftest-trigger-stage2 selftest-screenshot; do
    echo "== $suite"
    LOG="$LOGDIR/$suite.log"
    STATUS=0; "$BIN" --$suite > "$LOG" 2>&1 || STATUS=$?
    grep -a -E "FAIL|failures=" "$LOG" || true
    if [ "$STATUS" -ne 0 ]; then tail -n 20 "$LOG"; echo "::error::$suite exited with status $STATUS"; FAILED=1; continue; fi
    # A suite passes only when it ran to the end and reported no failures.
    if grep -a -q "FAIL" "$LOG" || ! grep -a -q "failures=0" "$LOG"; then echo "::error::$suite failed"; FAILED=1; fi
done
"$BIN" --check-brand-resources || { echo "::error::brand resources check failed"; FAILED=1; }
exit "$FAILED"
