class_name Scenario
extends RefCounted
## Procedural initial sand (height, wetness) for the test beach.
## World: x across the beach, z from the sea (z = 0) to the land (z = size).

const SHORE_Z := 8.0           ## still-water shoreline (sea level 0)
const OFFSHORE := -0.9
const FLAT_Z := 2.2            ## flat sea floor under the wave relaxation zone

# Test structures (all heights relative to the beach surface).
const WALL_Z := 9.0
const WALL_H := 0.28
const WALL_TOP := 0.06         ## half width of the flat top
const WET_WALL_X := Vector2(1.5, 9.5)
const DRY_WALL_X := Vector2(10.5, 18.5)
const WET_WALL_DEG := 75.0
const DRY_WALL_DEG := 32.0
const DITCH_X := 10.0
const DITCH_Z := Vector2(7.4, 12.7)
const POOL := Vector3(10.0, 13.35, 0.7)  ## centre x, z, radius
static var berm_h := 0.12  ## set before build(); 0 = the original test beach (flooded behind the walls)
const BERM_Z := Vector2(9.4, 11.6)


static var cove := false  ## set before build(): the cove (bay shoreline, dunes) instead of the test beach
const COVE_CX := 10.24         ## bay centre line (x)
const BAY_DEPTH := 1.6         ## shoreline at the domain sides sits this far seaward (headlands)


## Cove: the test beach profile with a bay-shaped shoreline (both sides reach further
## out to sea, hidden under rocks) and dunes at the back. Same formula as profile() in
## terrain_outer.gdshader (which adds the headland hills outside the sim square).
static func cove_height(x: float, z: float) -> float:
	var ax := absf(x - COVE_CX) / COVE_CX
	var zz := z + BAY_DEPTH * pow(minf(ax, 1.0), 2.5) * (1.0 - smoothstep(13.0, 19.0, z))
	var b: float
	if zz < FLAT_Z:
		b = OFFSHORE
	elif zz < SHORE_Z:
		var t := (zz - FLAT_Z) / (SHORE_Z - FLAT_Z)
		b = OFFSHORE * (1.0 - t) * (1.0 - 0.35 * t)
	else:
		b = 0.05 * (zz - SHORE_Z)
	b += berm_h * smoothstep(BERM_Z.x, BERM_Z.y, zz)
	b += 0.45 * smoothstep(15.0, 24.0, z)
	b += 0.006 * sin(x * 1.7 + z * 0.4) * sin(z * 2.3 - x * 0.3)
	return b


## Static ground outside the sim square (cove): same as profile() in terrain_outer.gdshader.
static func outer_height(x: float, z: float) -> float:
	var ax := absf(x - COVE_CX) / COVE_CX
	var zz := z + BAY_DEPTH * pow(minf(ax, 1.0), 2.5) * (1.0 - smoothstep(13.0, 19.0, z))
	var b: float
	if zz < FLAT_Z:
		b = OFFSHORE + minf(zz, 0.0) * 0.04
	elif zz < SHORE_Z:
		var t := (zz - FLAT_Z) / (SHORE_Z - FLAT_Z)
		b = OFFSHORE * (1.0 - t) * (1.0 - 0.35 * t)
	else:
		b = 0.05 * (minf(zz, 26.0) - SHORE_Z) + 0.02 * maxf(zz - 26.0, 0.0)
	b += 0.12 * smoothstep(BERM_Z.x, BERM_Z.y, zz) + 0.45 * smoothstep(15.0, 24.0, z)
	var hl := smoothstep(1.0, 1.6, ax) * smoothstep(-4.0, 6.0, z)
	b += hl * (2.2 + 0.6 * sin(z * 0.11 + x * 0.05) + 0.4 * sin(x * 0.23 - z * 0.07))
	return maxf(b, -3.0)


static func beach_height(x: float, z: float) -> float:
	if cove:
		return cove_height(x, z)
	var b: float
	if z < FLAT_Z:
		b = OFFSHORE
	elif z < SHORE_Z:
		var t := (z - FLAT_Z) / (SHORE_Z - FLAT_Z)
		b = OFFSHORE * (1.0 - t) * (1.0 - 0.35 * t)  # slightly concave profile
	else:
		b = 0.05 * (z - SHORE_Z)
	# Berm behind the test walls: the upper beach rises so water that overtops or runs
	# round the walls drains back to the sea instead of filling the whole back beach.
	b += berm_h * smoothstep(BERM_Z.x, BERM_Z.y, z)
	# Gentle long-crested ripples so the surface is not perfectly flat.
	b += 0.006 * sin(x * 1.7 + z * 0.4) * sin(z * 2.3 - x * 0.3)
	return b


## Wall cross-section: flat top, sides at `deg`, rounded ends over the x range.
static func wall(x: float, z: float, xr: Vector2, deg: float) -> float:
	var t := tan(deg_to_rad(deg))
	var dz := absf(z - WALL_Z)
	var dx := maxf(xr.x - x, x - xr.y)  # > 0 beyond the ends
	var d := maxf(dz, 0.0)
	if dx > 0.0:
		d = Vector2(dx, dz).length()
	return clampf((WALL_TOP + WALL_H / t - d) * t, 0.0, WALL_H)


static func build(ns: int, dxs: float, kind: String) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(ns * ns * 4)
	cove = kind == "cove"
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for j in ns:
		var z := (j + 0.5) * dxs
		for i in ns:
			var x := (i + 0.5) * dxs
			var h := beach_height(x, z)
			var above := h
			var w := clampf(1.0 - above / 0.45, 0.0, 1.0) * 0.9 if h > 0.0 else 1.0
			var st := 0.9 if h < 0.1 else 0.6  # wave-compacted lower beach, softer upper beach
			if kind == "walls" or kind == "conservation":
				var ww := wall(x, z, WET_WALL_X, WET_WALL_DEG)
				var dw := wall(x, z, DRY_WALL_X, DRY_WALL_DEG)
				if ww > 0.0:
					h += ww
					w = 0.5
					st = 1.0
				elif dw > 0.0:
					h += dw
					w = 0.0
					st = 0.0
				# Ditch from below the shoreline up the beach, ending in a pool.
				if z > DITCH_Z.x - 0.3 and z < DITCH_Z.y + 0.2:
					var tz := clampf((z - DITCH_Z.x) / (DITCH_Z.y - DITCH_Z.x), 0.0, 1.0)
					var bottom := lerpf(-0.07, 0.0, tz)
					var d := bottom + maxf(absf(x - DITCH_X) - 0.12, 0.0) * tan(deg_to_rad(60.0))
					if d < h:
						h = d
						w = maxf(w, 0.45)
						st = 0.8
				var r := Vector2(x - POOL.x, z - POOL.y).length()
				var pd := -0.1 + maxf(r - POOL.z * 0.65, 0.0) * tan(deg_to_rad(50.0))
				if pd < h:
					h = pd
					w = maxf(w, 0.45)
					st = 0.8
			var k := (j * ns + i) * 4
			out[k] = h
			out[k + 1] = w
			out[k + 2] = st
	return out
