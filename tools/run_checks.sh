#!/usr/bin/env bash
# Acceptance checks (bash / Git Bash, godot on PATH). Opens a window briefly; audio muted.
# Usage: tools/run_checks.sh [walls|conservation|bench|pick|all]
# Render cost breakdown: tools/bench_render.sh
set -euo pipefail
cd "$(dirname "$0")/.."
what="${1:-all}"
run() { godot --path . --audio-driver Dummy "$@"; }
if [[ $what == walls || $what == all ]]; then
	# Wet wall vs dry wall vs ditch/pool over 120 s of waves (prints WALLS lines every 2 s).
	# back_flooded = wet fraction of the back beach (z 9.5-12.5 m) behind the walls.
	run -- --test=walls --quit-after=120 | grep -E "WALLS|STATS"
fi
if [[ $what == conservation || $what == all ]]; then
	# Closed box dam break with erosion + slumping: water / sand volume drift, min depth.
	run -- --test=conservation --quit-after=60 | grep STATS
fi
if [[ $what == bench || $what == all ]]; then
	# 1080p, full simulation load (1/60 s of simulation per frame).
	run --resolution 1920x1080 -- --bench=15 --fixed --cam=overview | grep BENCH
fi
if [[ $what == pick || $what == all ]]; then
	# Mouse ray vs heightfield: max xz error of the picked point (2 camera presets).
	for c in walls wet; do run --resolution 1920x1080 -- --test=pick --cam=$c --fixed | grep PICK; done
fi
