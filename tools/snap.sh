#!/usr/bin/env bash
# One screenshot at a simulated time: tools/snap.sh OUT.png TIME [extra user args...]
# e.g. tools/snap.sh captures/snap/walls40.png 40 --cam=walls
set -euo pipefail
cd "$(dirname "$0")/.."
out=$1; t=$2; shift 2
godot --path . --audio-driver Dummy --resolution 1920x1080 -- --snap="$t" --snap-out="$out" --steps-per-frame=4 --fixed --nolabels --nohud "$@" 2>&1 | grep -E "SCRIPT ERROR|SHADER ERROR|error" || true
