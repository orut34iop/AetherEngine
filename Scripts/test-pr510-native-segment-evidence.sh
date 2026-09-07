#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/aether-pr510-init.XXXXXX")
trap 'rm -f "$TASK_TMP/check"; rmdir "$TASK_TMP"' EXIT
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -swift-version 6 \
  "$TASK_ROOT/Sources/AetherEngine/Video/PR510NativeSegmentEvidence.swift" \
  "$TASK_ROOT/Scripts/tests/PR510NativeSegmentEvidenceStandalone.swift" -o "$TASK_TMP/check"
"$TASK_TMP/check"
