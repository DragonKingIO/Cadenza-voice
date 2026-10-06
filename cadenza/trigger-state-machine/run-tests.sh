#!/bin/bash
set -euo pipefail
TASK_PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
TASK_DEVELOPER_DIR="$(xcode-select -p)"
TASK_TEST_ARGS=()
# Command Line Tools ship Testing outside Swift's default framework search path.
for TASK_FRAMEWORK_DIR in "$TASK_DEVELOPER_DIR/Library/Developer/Frameworks" "$TASK_DEVELOPER_DIR/Library/Frameworks"; do
    if [ -d "$TASK_FRAMEWORK_DIR/Testing.framework" ]; then
        TASK_TEST_ARGS+=(-Xswiftc -F -Xswiftc "$TASK_FRAMEWORK_DIR" -Xlinker -rpath -Xlinker "$TASK_FRAMEWORK_DIR")
        break
    fi
done
TASK_TEST_LIBRARY_DIR="$TASK_DEVELOPER_DIR/Library/Developer/usr/lib"
if [ -f "$TASK_TEST_LIBRARY_DIR/lib_TestingInterop.dylib" ]; then
    TASK_TEST_ARGS+=(-Xlinker -rpath -Xlinker "$TASK_TEST_LIBRARY_DIR")
fi
exec swift test --package-path "$TASK_PACKAGE_DIR" "${TASK_TEST_ARGS[@]}" "$@"
