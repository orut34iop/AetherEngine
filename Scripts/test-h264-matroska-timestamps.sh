#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/aether-matroska-time.XXXXXX")
trap 'rm -f "$TASK_TMP/check"; rmdir "$TASK_TMP"' EXIT
# Focused Foundation CLI test, no Apple app target or package resolution.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -swift-version 6 \
  "$TASK_ROOT/Sources/AetherEngine/Video/H264MatroskaTimestampRepair.swift" \
  "$TASK_ROOT/Scripts/tests/H264MatroskaTimestampStandalone.swift" -o "$TASK_TMP/check"
"$TASK_TMP/check" "$TASK_ROOT/Scripts/tests/Data/MatroskaCodingOrderTimestamps.json" "$@"
