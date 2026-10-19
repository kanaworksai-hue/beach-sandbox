#!/usr/bin/env bash
# Render cost breakdown at 1080p: full cartoon frame, then with one
# part removed at a time (difference = cost of that part), plus the flat debug look.
# Each run: 1/60 s of simulation per frame, 15 s measured after 5 s warm-up.
set -euo pipefail
cd "$(dirname "$0")/.."
run() { echo "== $1"; shift; godot --path . --audio-driver Dummy --resolution 1920x1080 -- --bench=15 --fixed --nolabels --cam=overview "$@" 2>&1 | grep BENCH; }
run "full frame"
run "without water surface" --hide=water
run "without sand terrain" --hide=terrain
run "without outer sand/sea" --hide=outer
run "without sun shadows" --hide=shadow
run "without glow" --hide=glow
run "debug look" --look=m1
