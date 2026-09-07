#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $# == 3 ]] || { echo 'Usage: inspect-h264-picture-order.sh <local-file> <start-seconds> <video-packet-limit>' >&2; exit 2; }
TASK_FFMPEG_ROOT=${AETHER_DIAGNOSTIC_FFMPEG_ROOT:-/opt/homebrew/opt/ffmpeg}
[[ -f "$TASK_FFMPEG_ROOT/include/libavformat/avformat.h" && -f "$TASK_FFMPEG_ROOT/lib/libavformat.dylib" ]] \
  || { echo 'FFmpeg development headers/libraries missing; set AETHER_DIAGNOSTIC_FFMPEG_ROOT' >&2; exit 2; }
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/aether-poc-probe.XXXXXX")
trap 'rm -f "$TASK_TMP/probe"; rmdir "$TASK_TMP"' EXIT
# No pkg-config dependency; this is a numeric CLI diagnostic, never an Apple app build.
clang "$TASK_ROOT/Scripts/tests/inspect-h264-picture-order.c" \
  -I "$TASK_FFMPEG_ROOT/include" -L "$TASK_FFMPEG_ROOT/lib" \
  -lavformat -lavcodec -lavutil -o "$TASK_TMP/probe"
"$TASK_TMP/probe" "$1" "$2" "$3"
