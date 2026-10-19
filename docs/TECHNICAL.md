# BeachSandbox technical notes

This file describes how the simulation and rendering work: the grids, the order of kernels
each frame, the binding layout, the sand model, the foam particles and caustics, and how
props follow the sand. All units are metres and seconds. World x runs along the beach and z
runs from the sea (z = 0) up to the land.

## Code map

- `scripts/sim/beach_sim.gd` (`BeachSim`) owns every GPU resource. All `RenderingDevice`
  calls go through `RenderingServer.call_on_render_thread()`. Its public API:
  - `setup(sand, level, sea_max_z)`
  - `step(frame_dt)`
  - `dig / pile / stamp / pour`: queued, then applied at the start of the next step
  - `request_stats()` → `stats`
  - `pick_height(x, z)`
  - the textures `water_tex`, `bed_tex`, `sand_tex`, `fx_tex`, `foam_tex` and `caustic_tex`
    (all `Texture2DRD`)

  Every tunable is a member variable in SI units. They are packed into a uniform buffer
  each frame.
- `shaders/compute/beach.compute` holds every kernel. It is compiled once per kernel, each
  time with `#define KERNEL_<NAME>`. The file deliberately avoids the `.glsl` extension so
  Godot doesn't import it as an `RDShaderFile`.
- `scripts/sim/scenario.gd` builds the initial sand on the CPU (about 1.5 s).

**GLSL caveat:** don't index a `vec4` with a dynamic index. Godot's SPIR-V path doesn't
support `OpVectorExtractDynamic`, so use explicit branches such as `pick()`.

## Grids

| Grid | Size | Cell | Contents |
|---|---|---|---|
| water | 512² | 4 cm | `(w = B + h, hu, hv, hs)`: free surface, momentum and suspended sand |
| bed | 512² | 4 cm | `(B centre, B east face, B north face, max centre B in 3×3)` |
| sand | 1024² | 2 cm | `(height, wetness, strength, freshness)` |
| fx | 512² | 4 cm | `(foam, previous-frame w, stranded foam, aeration)` (render only) |
| foam splat | 2048² | 1 cm | foam particle sizes (R16F, render only) |
| caustic map | 512² | 1 cm (5.12 m tile) | light density at 3 focal distances (RGBA16F, render only) |

The water bed is the 4×4 box mean of the sand. Each water-cell corner is the mean of the
2×2 sand cells around it, and each face value is the mean of its two corners. This keeps
KP07 well balanced: still water stays exactly still over any bed.

The edges work like this:

- The south edge (z = 0) is the sea boundary.
- The other three edges are reflecting walls.
- The outer 4 sand cells mirror the interior, so the ghost bed under those walls matches its
  mirror image and no water leaks out.

## Per-frame kernel order

1. **Edits:** `BRUSH` (dig, pile, stamp) and `POUR`, then `BED` twice. This rebuilds the
   water bed from the edited sand and keeps the water depth unchanged.
2. **Water substeps:** `STEP` then `BOUNDARY`, N times with dt = 1.4 ms. N is rounded to an
   even number so the state ends in texture A; at 60 fps that is about 12 substeps.
3. **`FX`:** foam sources and advection. It also spawns foam particles. The result is copied
   back to fx A.
4. **`PART`:** foam particle update and splat. On frames where `update_caustics()` was
   called, **`CAUS_H` → `CAUS_SPLAT` → `CAUS_RESOLVE`** run in the same compute list.
5. **`EROSION`:** pick-up and deposition, wave impact on dry steps, infiltration.
6. **`SAND_APPLY`:** spreads the bed change onto the sand grid using a conservative
   [1 3 3 1] upsampling. Then it updates wetness, strength and freshness.
7. **`THERMAL_OUT` / `THERMAL_IN`** × 4: slumping, as two conservative gather passes.
8. **`BED`:** rebuilds the water bed from the sand and keeps the water depth.
9. Every 6 frames, **`PICK`**: the maximum sand height in each block of a 256² grid, read
   back with `buffer_get_data_async` for mouse picking.
10. **`STATS`**, only when requested: water, sand and suspended-sand volumes, minimum depth
    and maximum speed. This one is a blocking readback, used by the tests.

## Bindings (set 0)

| Binding | Type | Resource |
|---|---|---|
| 0 | UBO | parameters (`Params`) |
| 1 / 2 | image rgba32f | water source / destination (two uniform sets swap them on alternate substeps) |
| 3 | image rgba32f | bed |
| 4 / 5 | image rgba32f | sand A / B |
| 6 / 7 | image rgba32f | slumping outflow |
| 8 | image r32f | bed change from erosion |
| 9 | SSBO | stats sums |
| 10 / 11 | image rgba32f | fx source / destination |
| 12 | SSBO | pick heights (256²) |
| 13 | image r16f | foam splat (2048²) |
| 14 | SSBO | foam particles `vec4(x, z, age, life)` (262144 particles, life 0 = dead) |
| 15 | SSBO | particle ring counter (atomic) |
| 16 | image rgba16f | caustic ripple slope field |
| 17 | SSBO | caustic photon accumulator (3 × 512², fixed-point uint) |
| 18 | image rgba16f | resolved caustic map |

The push constants are an `ivec4 pi` and a `vec4 pf`, both kernel specific.

## Water

The water step uses Kurganov–Petrova 2007 central-upwind finite volumes, with the KP07
positivity-preserving reconstruction and the well-balanced source term. It is ported from
REBOOT16 "Realistic Shoreline Waves" (MIT, see `THIRD_PARTY.md`).

- **State:** `(w, hu, hv, hs)`. The fourth channel is suspended sand. It is transported
  conservatively with the mass flux.
- **Friction:** Manning, n = 0.022. Speed is capped at 4 m/s.
- **Sea boundary:** a ghost row plus a 50-cell relaxation zone on the south edge. It pulls
  the state toward four analytic wave components (`waves`: amplitude, period, phase,
  angle), using Eckart's dispersion approximation. The tide (`tide`) is added to the mean
  level.
- **Outer sea:** `water_outer.gdshader` animates the same four components, so the open sea
  matches the boundary forcing.

## Sand

There are four values per sand cell:

- **Height.**
- **Wetness w** (0–1).
- **Strength s.** 1 means wet, packed sand (a built wall). 0 means loose sand: poured,
  deposited or slumped.
- **Freshness** (render only). It is set to 1 by slides, by scour or deposition faster than
  about 6 mm/s, and by brushes. It decays over `fresh_life` (20 s).

### Angle of repose

`max_tan(w, s)` blends between loose and packed sand by s²:

| | dry | moist | saturated |
|---|---|---|---|
| loose (s = 0) | 33° | 37° | 15° (flows) |
| packed (s = 1) | 33° | 80° | 80° |

The threshold of every cell is jittered by ±15% each frame. This hides grid-aligned
artefacts.

### Erosion and deposition (on the water grid)

- Carrying capacity = `Kc · min(h, 0.15) · max(|v| − 0.25, 0)²`.
- Pick-up rate = `Ke_packed + (Ke_loose − Ke_packed) · (1 − s)³`, times 1.5 when dry. Packed
  beach sand barely erodes, while loose sand washes away easily.
- Settling uses rate `kd`. Waves wear down dry steps through `impact_k`.

### Strength

- Packed sand loses strength under fast flow on steep faces, or when waves hit it.
- Sand above the water that stays soaked (w > 0.9) slowly loses cohesion
  (`soak_weakening`, 0.006/s).
- Under calm water, strength recovers to 0.9 (wave compaction).
- Freshly deposited or slumped sand blends in by thickness. About 5 cm replaces the whole
  column's strength, because each column stores only one strength value.

### Wetness

- Sand under water wets at 0.4/s.
- Sand above the water relaxes toward a water-table target: anything within 0.35 m of sea
  level stays damp.
- Wetness wicks sideways at 12 cells²/s in loose sand and 1 cell²/s in packed sand. Dry
  loose sand soaks up water fast, so a dry pile gets saturated and collapses quickly.
- Water infiltrates dry sand at 4 mm/s, scaled by (1 − w).

## Foam

### fx texture (`KERNEL_FX`, once per frame)

- **r: foam concentration.** It is advected semi-Lagrangian with the flow, with life
  `foam_life` (2.2 s) and gain `foam_gain` (0.7). It has four sources:
  - breaking: the free surface rises faster than 0.2–0.5 times the wave speed
  - bores: Froude number 1.1–1.6 with depth over 2 cm
  - swash fronts: cells that were dry last frame and are now flooded by moving water
  - flow into steps taller than 3 cm

  The relaxation zone produces no foam.
- **g: previous-frame free surface**, used for the rise rate and to detect swash fronts.
- **b: stranded foam.** When a cell dries, its foam is left on the sand for
  `stranded_life` (2.5 s) and washes off quickly when the cell floods again. Only used at a
  distance; up close the particles are drawn instead.
- **a: aeration.** Set by breaking and bores, decays over 0.5 s. The water shader uses it
  to tint the water a lighter cyan, not white.

### Foam particles (`KERNEL_FX` spawn + `KERNEL_PART` update)

- 262144 particles live in a ring buffer.
- **Spawning:** each water cell spawns particles at its fx source strength ×
  `foam_particle_rate` (6/s) × a slowly drifting 14 cm value noise. The noise makes the
  foam clump, and the flow stretches the clumps into streaks.
- **Life:** `foam_particle_life` (2.6 s) × 0.45–1.55.
- **Motion:** midpoint advection with the bilinear simulated velocity, plus a
  1.2 cm/√s random walk.
- **Stranding:** a particle on a dry cell stops and fades over `foam_stranded_life` (3 s).
  Particles die when they leave the area or reach their life.
- **Splat:** live particles write their remaining size into the 1 cm R16F `foam_tex`.
  Size is 1 for the first half of the life, then falls to 0. A quarter of the particles
  write 2×2 texels (bigger bubbles). The texture is cleared every frame, and writes are not
  atomic.
- **Shading:** `foam_bubbles()` in `beach_common.gdshaderinc` thresholds the bilinear splat
  into round bubbles, so a dying bubble shrinks away. When a pixel covers more than about
  1.2 cm, it switches to the average coverage over the pixel footprint, which avoids
  shimmer.

## Caustics (`KERNEL_CAUS_H / CAUS_SPLAT / CAUS_RESOLVE`, render only)

The caustic map is rebuilt once per rendered frame at the shader animation time. It costs
about 0.25–0.3 ms.

1. **`CAUS_H`:** a periodic ripple field 5.12 m across, made of 48 waves. Their wave
   vectors sit on integer lattice points, so the tile is seamless.
   - Wavelengths: 0.18–0.55 m.
   - Slope per wave: `caustic_slope` × 0.5–1.5.
   - Each wave moves at its own speed, 0.35·√(gk + σk³/ρ). The pattern deforms over time
     instead of just sliding.
2. **`CAUS_SPLAT`:** one photon per cell. It lands at x − f·∇η and is splatted bilinearly
   with `atomicAdd` into 3 focal layers (f = 0.12 / 0.27 / 0.45 m).
3. **`CAUS_RESOLVE`:** a 3×3 tent blur, then normalisation to a light density. The result
   goes into `caustic_tex`.

The terrain shader samples the map as follows:

- **Hiding the tiling:** the lookup is rotated by 26.6° and warped by 12 cm of low-frequency
  noise, so the 5.12 m tile never lines up.
- **Following the waves:** the lookup is shifted by the simulated surface slope, and the
  light is focused by its curvature, 1/(1 + f·∇²η).
- **Focus:** f = `caustic_focus` · h/(h + 0.12), interpolated between the three layers.
- **Dispersion:** slightly different focus per R/G/B channel.
- **Variation:** a broad brightness mask from 0.55 to 1.15.
- **Fading:**
  - toward the average where a pixel covers 2–7 cm, to avoid shimmer in the distance
  - with depth, by `caustic_falloff` (2.5 /m)

## Rendering

### Terrain (`terrain.gdshader`, 1024² vertices)

- **Wetness colour:** dry #F4D29C → damp #E4BC80 → wet #CFA375.
- **Grain:** fresh sand is lighter and coarser; packed sand has a finer grain.
- **Highlights:** a sheen on saturated sand just above the waterline, and sparkles on dry
  loose sand up close.
- **Darkening:** 8-tap heightfield AO darkens moats and wall bases.
- **Pebbles:** scattered small dark pebbles, which fade out beyond 9 m.
- **Lighting:** a custom `light()` with a two-band toon ramp that keeps half of the Lambert
  term. Shadowed sides get a lavender fill.

### Water (`water.gdshader`, 512² vertices)

- **Dry cells:** pushed under the sand, and pixels shallower than 0.8 mm are discarded.
- **Colour:** set by **simulated depth**, not the depth buffer, in four steps: #8FF3E4 →
  #1BBFC6 → #1690C8 → #0D5FA0.
- **Transmission:** Beer–Lambert with absorption 5 / 2 / 1.3 per metre. At least 18% of
  the body colour always shows.
- **Refraction:** depth-tested.
- **Reflection:** a hand-made sky reflection capped at 0.3. **`SPECULAR = 0`** turns off
  Godot's built-in sky reflection, which washed the water out. The sun glint is drawn in
  `light()` as a small hard highlight.
- **Waterline:** a white line 2.5 px wide, measured with `fwidth(h)`.
- **Shallow edges:** as depth goes to 0, the water converges to the background pixel
  instead of alpha blending.

### Shared helpers (`beach_common.gdshaderinc`)

- **`toon_ramp()`:** the two-band lighting ramp.
- **Ripples:** Vlachos two-phase flow-map sampling for ripple normals.
- **`far_sea()`:** fades water deeper than 0.3 m to one common sea blue between 5 and 28 m
  from the camera, and then to the horizon haze. This hides the seam between the simulated
  water and the outer sea.

### Outer ring

- `terrain_outer.gdshader`: a 245 m static sand skirt. Its `profile()` must match
  `Scenario.outer_height()` and `Scenario.cove_height()`.
- `water_outer.gdshader`: a 400 m analytic sea.

### Animation clock

Every animated shader uses the global uniform `anim_time`, never `TIME`. `main.gd` advances
it by the frame dt, which is exactly 1/60 in fixed and recorded runs. When frames are saved
one at a time, real time between frames is uneven, and `TIME` would make the caustics
stutter.

### Environment

- Linear tonemap, to keep the palette's saturated colours.
- Lights kept low, so only glints go into glow.
- Ambient light from a fixed colour (#D2E2F5 × 0.42). Sky ambient would tint the sand green.
- Very light fog.
- Two shadow cascades over 30 m.

## Props stick to the sand

- `props.gd` loads the cleaned GLBs and normalises them: origin at the bottom centre,
  longest side 1.
- `prop.gdshader` snaps every prop inside the simulated area to the live sand surface in the
  **vertex shader**:
  1. sample the sand height under the origin
  2. subtract `sink`
  3. tilt to a 4-tap slope with a Rodrigues rotation

  The shadow pass does the same, so props never hover when the sand under them washes away,
  and no CPU readback is needed.
- Props outside the simulated area (rocks, hill palms) get their height from the CPU
  profile `Scenario.outer_height()`.
- Below the water and in a band above wet sand, props get a darkened wet mark.

## Sandcastle and shots

- `castle.gd` builds towers and walls from `BeachSim.stamp()` frustums: a flat top, like a
  sand bucket turned over. It digs the moat and a channel toward the waterline.
  - Keep frustum slopes at about 75° or less. Packed moist sand stands at 80°, and with the
    ±15% jitter anything steeper slumps into a cone.
- `cam_rig.gd` joins camera keyframes with cubic Hermite splines (non-uniform
  Catmull-Rom), easing in and out at the ends.
- Shots are evaluated only on the shot clock (frames / 60), so recordings don't jitter.
- `shots.gd` describes each shot: castle mode, pre-roll, simulation steps per frame, length,
  camera, optional swell keyframes and parameter overrides.
- The showcase shots (`ditch`, `versus`, `pour`) drive the same brushes as the mouse, from
  `main.gd` `_shot_edits()`.

## Validation

`tools/run_checks.sh` runs these checks:

- **walls:** 120 s of waves against a wet packed wall, a dry loose wall and a ditch to a
  pool.
- **conservation:** a closed-box dam break with erosion and slumping on, 60 s.
- **pick:** 77 mouse rays checked against the full-resolution heightfield.

Reference numbers are in the README.
