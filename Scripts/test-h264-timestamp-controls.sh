#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/aether-timestamp-controls.XXXXXX")
trap 'rm -f "$TASK_TMP/healthy.mp4" "$TASK_TMP/healthy.mkv" "$TASK_TMP/missing.mp4"; rmdir "$TASK_TMP"' EXIT
# Generated solid-colour/AAC silence fixtures only; no private media is copied or committed.
ffmpeg -v error -f lavfi -i 'color=c=blue:s=96x64:r=30000/1001' \
  -f lavfi -i 'anullsrc=r=48000:cl=stereo' -t 8 \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -bf 3 -b_strategy 0 -g 60 \
  -sc_threshold 0 -c:a aac -movflags +faststart "$TASK_TMP/healthy.mp4"
ffmpeg -v error -i "$TASK_TMP/healthy.mp4" -c copy "$TASK_TMP/healthy.mkv"
ffmpeg -v error -i "$TASK_TMP/healthy.mp4" -c copy -bsf:v 'setts=pts=DTS' -movflags +faststart "$TASK_TMP/missing.mp4"
AETHER_EXPECT_TIMESTAMP_REPAIR=0 bash "$TASK_ROOT/Scripts/test-h264-timestamp-runtime.sh" "$TASK_TMP/healthy.mp4" 0 3
AETHER_EXPECT_TIMESTAMP_REPAIR=0 bash "$TASK_ROOT/Scripts/test-h264-timestamp-runtime.sh" "$TASK_TMP/healthy.mkv" 0 3
AETHER_EXPECT_TIMESTAMP_REPAIR=1 bash "$TASK_ROOT/Scripts/test-h264-timestamp-runtime.sh" "$TASK_TMP/missing.mp4" 0 3
