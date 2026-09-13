#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "${1:-}" in
    "") TASK_TEST_SOURCE=SubtitlePacketDiagnosticsStandalone.swift ;;
    --dual-pgs) TASK_TEST_SOURCE=DualPGSDecodeStandalone.swift ;;
    *) echo "Usage: $0 [--dual-pgs]" >&2; exit 2 ;;
esac
TASK_FFMPEG_ROOT="${AETHER_FFMPEG_CHECKOUT:-$TASK_ROOT/.build/checkouts/FFmpegBuild}"
TASK_EXPECTED_REVISION=$(/usr/bin/ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("pins").find { |p| p.fetch("identity") == "ffmpegbuild" }.fetch("state").fetch("revision")' "$TASK_ROOT/Package.resolved")
TASK_ACTUAL_REVISION=$(git -C "$TASK_FFMPEG_ROOT" rev-parse HEAD)
[[ "$TASK_ACTUAL_REVISION" == "$TASK_EXPECTED_REVISION" ]] || { echo "Frozen FFmpegBuild mismatch" >&2; exit 1; }
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/aether-subtitle-diagnostics.XXXXXX")
trap 'rm -f "$TASK_TMP/check"; rmdir "$TASK_TMP"' EXIT
TASK_FRAMEWORK_ARGS=()
for TASK_LIBRARY in AetherLibavcodec AetherLibavutil AetherLibswresample AetherLibdav1d AetherLibzvbi; do
    TASK_FRAMEWORK_DIR="$TASK_FFMPEG_ROOT/Sources/$TASK_LIBRARY.xcframework/macos-arm64_x86_64"
    [[ -f "$TASK_FRAMEWORK_DIR/$TASK_LIBRARY.framework/$TASK_LIBRARY" ]] || exit 1
    TASK_FRAMEWORK_ARGS+=(-F "$TASK_FRAMEWORK_DIR" -Xlinker -rpath -Xlinker "$TASK_FRAMEWORK_DIR")
done
# Focused host-side data-structure test, no app target or dependency resolution.
xcrun swiftc -swift-version 6 "${TASK_FRAMEWORK_ARGS[@]}" \
    -framework AetherLibavcodec -framework AetherLibavutil \
    "$TASK_ROOT/Sources/AetherEngine/Subtitles/SubtitlePacketStore.swift" \
    "$TASK_ROOT/Sources/AetherEngine/Subtitles/SubtitleHarvestCoverage.swift" \
    "$TASK_ROOT/Sources/AetherEngine/Subtitles/WebVTTCueSettings.swift" \
    "$TASK_ROOT/Scripts/tests/$TASK_TEST_SOURCE" -o "$TASK_TMP/check"
"$TASK_TMP/check"
