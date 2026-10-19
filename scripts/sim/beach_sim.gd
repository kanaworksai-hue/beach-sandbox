class_name BeachSim
extends RefCounted
## GPU sand + water simulation (shaders/compute/beach.compute).
##
## Runs on the main RenderingDevice; every GPU call goes through
## RenderingServer.call_on_render_thread(). Materials read the results through
## Texture2DRD (water_tex, bed_tex, sand_tex, fx_tex) without any CPU readback
## (except the small async height map used for mouse picking, `pick_heights`).
## Call order per frame (main thread): queue edits (dig / pile / pour), then step(frame_dt).

const SHADER_PATH := "res://shaders/compute/beach.compute"
const KERNELS := ["STEP", "BOUNDARY", "EROSION", "SAND_APPLY", "THERMAL_OUT", "THERMAL_IN",
	"BED", "BRUSH", "POUR", "STATS", "FX", "PART", "PICK",
	"CAUS_H", "CAUS_SPLAT", "CAUS_RESOLVE"]
const SAND_KERNELS := ["SAND_APPLY", "THERMAL_OUT", "THERMAL_IN", "BRUSH"]
const FLAG_SEA := 1
const FLAG_INFILTRATION := 2
const FLAG_EROSION := 4
const FLAG_THERMAL := 8

var rd: RenderingDevice
var nw := 512                  ## water cells per side
var ns := 1024                 ## sand cells per side (2 * nw)
var dxw := 0.04                ## water cell size (m)
var dt := 0.0014               ## water substep (KP07 CFL ~ dx / (4 (|u| + sqrt(g h))))
var max_substeps := 16
var g := 9.81
var flags := FLAG_SEA | FLAG_INFILTRATION | FLAG_EROSION | FLAG_THERMAL
var thermal_iterations := 4

# Sea
var tide := 0.0                ## mean sea level (m); animate for tides
var relax_cells := 50
var manning := 0.022
var offshore_depth := 0.9
var max_speed := 4.0
var theta := 1.3
var kappa := 0.01
var wave_ramp := 4.0
## Up to 4 components: Vector4(amplitude m, period s, phase rad, angle rad about +Z)
var waves: Array[Vector4] = [Vector4(0.07, 5.0, 0.0, 0.0), Vector4(0.03, 3.1, 2.1, 0.25),
	Vector4(0.02, 7.6, 4.4, -0.2), Vector4(0.0, 4.0, 1.3, 0.1)]

# Erosion / deposition (water grid)
var k_capacity := 0.6          ## capacity = Kc * min(h, h_cap) * max(|v| - v_crit, 0)^2
var ke_loose := 1.5            ## pick-up rate (1/s) for loose / packed sand (cubic in looseness, x1.5 when dry)
var ke_packed := 0.01
var strength_loss := 0.03     ## packed -> loose per second per (m/s)^2 of flow
var kd := 0.4                  ## settling rate (1/s)
var v_crit := 0.25
var h_cap := 0.15
var impact_k := 0.6            ## wave impact on dry steps
var max_erosion := 0.004       ## per frame and cell (m)

# Wetness (sand grid)
var wet_in := 0.4              ## 1/s while covered by water
var dry_rate := 0.004          ## 1/s drying in the sun
var wet_diffusion := 12.0      ## lateral wicking of loose sand (cells^2/s, explicit, clamped)
var wet_diffusion_packed := 1.0
var infiltration := 0.004      ## m/s into dry sand (scaled by 1 - wetness)
var table_range := 0.35        ## sand this far above the sea level is still damp
var capillary_rise := 0.005    ## 1/s

# Slumping (sand grid): tan of the angle of repose and flow rate (1/s)
var tan_dry := tan(deg_to_rad(33.0))
var tan_moist := tan(deg_to_rad(80.0))  ## moist and fully packed
var tan_saturated := tan(deg_to_rad(15.0))  ## saturated and loose: flows
var angle_noise := 0.15
var slump_dry := 30.0
var slump_moist := 1.0
var slump_saturated := 30.0
var soak_weakening := 0.006    ## 1/s strength loss of soaked sand above the water

# Render-only fields (fx texture, sand freshness)
var foam_gain := 0.7           ## foam injected per second at full breaking
var foam_life := 2.2           ## s
var foam_sources := 15         ## debug bit mask: 1 breaking, 2 bore, 4 swash, 8 running into steps
var stranded_life := 2.5       ## s, foam left on the sand after the water recedes
var fresh_life := 20.0         ## s, fresh-sand colour after slides / scour / edits
# Foam particles: bubbles spawned by the same sources, advected by the flow and
# splatted into foam_tex (1 cm) every frame. Render only.
const NPART := 262144
var foam_particle_rate := 6.0  ## bubbles per water cell per second at unit injection
var foam_particle_life := 2.6  ## s (mean; each bubble 0.45..1.55 x)
var foam_stranded_life := 3.0  ## s, bubbles left on dry sand
var foam_jitter := 0.012       ## m/sqrt(s) random walk

# Mouse picking: coarse sand height map (PICK_N^2, max of each block), read back async.
const PICK_N := 256
var pick_every := 6            ## frames between readbacks
var pick_heights := PackedFloat32Array()

var sim_time := 0.0
var frame := 0
var _accum := 0.0
var _parity := 0               ## 0: current water state in A, 1: in B

var _water := [RID(), RID()]
var _bed := RID()
var _sand := [RID(), RID()]
var _out := [RID(), RID()]
var _dbed := RID()
var _sums := RID()
var _fx := [RID(), RID()]
var _picks := RID()
var _foam_dots := RID()
var _parts := RID()
var _part_next := RID()
var _pick_pending := false
var _ubo := RID()
var _shaders := {}
var _pipelines := {}
var _sets := [{}, {}]          ## per parity
var _edits: Array = []         ## queued [kernel, pi, pf]
var _stats_request := false
var stats: Dictionary = {}     ## filled by request_stats()

var water_tex := Texture2DRD.new()
var bed_tex := Texture2DRD.new()
var sand_tex := Texture2DRD.new()
var fx_tex := Texture2DRD.new()
var foam_tex := Texture2DRD.new()  ## R16F, 4 nw per side: foam bubble splats (size 0..1)
## RGBA16F 512^2 tiling 5.12 m: caustic light density at focal factors 0.12 / 0.27 / 0.45 m
var caustic_tex := Texture2DRD.new()
const CAUS_N := 512
var caustic_slope := 0.026     ## slope amplitude of each of the 48 ripple waves (rms ~0.13)
var caustic_wl_min := 0.18     ## ripple wavelength band (m): ~10-20 cm caustic cells
var caustic_wl_max := 0.55
var _caus_grad := RID()
var _caus_acc := RID()
var _caus_map := RID()
var _caus_t := 0.0
var _caus_due := false


## sand: PackedFloat32Array of ns*ns*4 (height, wetness, 0, 0); water starts still at `level`.
func setup(sand: PackedFloat32Array, level: float, sea_max_z := 1e9) -> void:
	RenderingServer.call_on_render_thread(_setup_rt.bind(sand, level, sea_max_z))


func _setup_rt(sand: PackedFloat32Array, level: float, sea_max_z: float) -> void:
	rd = RenderingServer.get_rendering_device()
	ns = nw * 2
	var dxs := dxw * 0.5
	var zero_w := PackedFloat32Array()
	zero_w.resize(nw * nw * 4)
	for i in 2:
		_water[i] = _make_tex(nw, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, zero_w.to_byte_array())
		_sand[i] = _make_tex(ns, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, sand.to_byte_array())
	_bed = _make_tex(nw, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, zero_w.to_byte_array())
	for i in 2:
		_fx[i] = _make_tex(nw, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, zero_w.to_byte_array())
	var zf := PackedByteArray()
	zf.resize(nw * 4 * nw * 4 * 2)
	_foam_dots = _make_tex(nw * 4, RenderingDevice.DATA_FORMAT_R16_SFLOAT, zf)
	var zpart := PackedByteArray()
	zpart.resize(NPART * 16)
	_parts = rd.storage_buffer_create(zpart.size(), zpart)
	var zc := PackedByteArray()
	zc.resize(16)
	_part_next = rd.storage_buffer_create(16, zc)
	var zc16 := PackedByteArray()
	zc16.resize(CAUS_N * CAUS_N * 8)
	_caus_grad = _make_tex(CAUS_N, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, zc16)
	_caus_map = _make_tex(CAUS_N, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, zc16)
	var zacc := PackedByteArray()
	zacc.resize(CAUS_N * CAUS_N * 3 * 4)
	_caus_acc = rd.storage_buffer_create(zacc.size(), zacc)
	caustic_tex.texture_rd_rid = _caus_map
	var zp := PackedFloat32Array()
	zp.resize(PICK_N * PICK_N)
	_picks = rd.storage_buffer_create(zp.size() * 4, zp.to_byte_array())
	var zero_s := PackedFloat32Array()
	zero_s.resize(ns * ns * 4)
	for i in 2:
		_out[i] = _make_tex(ns, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, zero_s.to_byte_array())
	var zero_1 := PackedFloat32Array()
	zero_1.resize(nw * nw)
	_dbed = _make_tex(nw, RenderingDevice.DATA_FORMAT_R32_SFLOAT, zero_1.to_byte_array())
	var sums := PackedFloat32Array()
	sums.resize(4 * nw + ns)
	_sums = rd.storage_buffer_create(sums.size() * 4, sums.to_byte_array())
	var ub := _params_bytes(dxs)
	_ubo = rd.uniform_buffer_create(ub.size(), ub)
	_compile()
	# Bed from sand, then still water at `level`.
	var cl := rd.compute_list_begin()
	_dispatch(cl, "BED", nw, [1], [level, sea_max_z])
	rd.compute_list_end()
	_parity ^= 1
	water_tex.texture_rd_rid = _water[0]
	bed_tex.texture_rd_rid = _bed
	sand_tex.texture_rd_rid = _sand[0]
	fx_tex.texture_rd_rid = _fx[0]
	foam_tex.texture_rd_rid = _foam_dots
	# The init pass wrote water B; copy back so the frame always starts and ends in A.
	rd.texture_copy(_water[1], _water[0], Vector3.ZERO, Vector3.ZERO, Vector3(nw, nw, 1), 0, 0, 0, 0)
	_parity = 0


func _make_tex(n: int, fmt_id: int, data: PackedByteArray) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.format = fmt_id
	fmt.width = n
	fmt.height = n
	fmt.usage_bits = (RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT)
	return rd.texture_create(fmt, RDTextureView.new(), [data])


func _compile() -> void:
	var body := FileAccess.get_file_as_string(SHADER_PATH)
	assert(body != "", "shader source missing: " + SHADER_PATH)
	for k in KERNELS:
		var src := RDShaderSource.new()
		src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
		src.source_compute = "#version 450\n#define KERNEL_%s\n" % k + body
		var spirv := rd.shader_compile_spirv_from_source(src)
		if spirv.compile_error_compute != "":
			push_error("beach kernel %s failed to compile:\n%s" % [k, spirv.compile_error_compute])
			continue
		var shader := rd.shader_create_from_spirv(spirv, "beach_" + k.to_lower())
		_shaders[k] = shader
		_pipelines[k] = rd.compute_pipeline_create(shader)
		for p in 2:
			_sets[p][k] = rd.uniform_set_create(_uniforms(p), shader, 0)


func _uniforms(parity: int) -> Array[RDUniform]:
	var list: Array[RDUniform] = []
	var ubo := RDUniform.new()
	ubo.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	ubo.binding = 0
	ubo.add_id(_ubo)
	list.append(ubo)
	var images := [_water[parity], _water[1 - parity], _bed, _sand[0], _sand[1], _out[0], _out[1], _dbed]
	for i in images.size():
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u.binding = i + 1
		u.add_id(images[i])
		list.append(u)
	var sb := RDUniform.new()
	sb.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	sb.binding = 9
	sb.add_id(_sums)
	list.append(sb)
	for i in 2:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u.binding = 10 + i
		u.add_id(_fx[i])
		list.append(u)
	var pb := RDUniform.new()
	pb.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	pb.binding = 12
	pb.add_id(_picks)
	list.append(pb)
	var fd := RDUniform.new()
	fd.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	fd.binding = 13
	fd.add_id(_foam_dots)
	list.append(fd)
	for k in 2:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = 14 + k
		u.add_id([_parts, _part_next][k])
		list.append(u)
	for k in 3:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER if k == 1 else RenderingDevice.UNIFORM_TYPE_IMAGE
		u.binding = 16 + k
		u.add_id([_caus_grad, _caus_acc, _caus_map][k])
		list.append(u)
	return list


func _params_bytes(dxs: float) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	for v in [nw, ns, frame, flags]:
		b.put_32(v)
	var f := [dt, dxw, dxs, g,
		sim_time, tide, float(relax_cells), manning]
	for i in 4:
		var w: Vector4 = waves[i] if i < waves.size() else Vector4(0, 1, 0, 0)
		f.append_array([w.x, w.y, w.z, w.w])
	f.append_array([offshore_depth, max_speed, theta, kappa,
		k_capacity, ke_loose, ke_packed, kd,
		v_crit, h_cap, impact_k, strength_loss,
		wet_in, dry_rate, wet_diffusion, infiltration,
		table_range, capillary_rise, _frame_dt, max_erosion,
		tan_dry, tan_moist, tan_saturated, wave_ramp,
		angle_noise, slump_dry, slump_moist, slump_saturated,
		soak_weakening, wet_diffusion_packed, float(foam_sources), 0.0,
		foam_gain, foam_life, stranded_life, fresh_life,
		foam_particle_rate, foam_particle_life, foam_stranded_life, foam_jitter])
	for v in f:
		b.put_float(v)
	return b.data_array


var _frame_dt := 1.0 / 60.0


## Main thread. dig/pile: centre in world metres (x, z), radius m, depth m per second.
func dig(center: Vector2, radius: float, rate: float, delta: float) -> void:
	_edits.append(["BRUSH", [0, 0], [center.x, center.y, radius, rate * delta]])


func pile(center: Vector2, radius: float, rate: float, delta: float, wetness := 0.5, strength := 0.9) -> void:
	_edits.append(["BRUSH", [1, int(wetness * 1000.0), int(strength * 1000.0)], [center.x, center.y, radius, rate * delta]])


## Raise the sand to a frustum (bucket tower / wall segment): absolute top height `top_y`,
## flat over `top_frac` of the radius. Packed, moist sand by default.
func stamp(center: Vector2, radius: float, top_y: float, top_frac := 0.7, wetness := 0.55, strength := 1.0) -> void:
	_edits.append(["BRUSH", [2, int(wetness * 1000.0), int(strength * 1000.0), int(top_frac * 1000.0)], [center.x, center.y, radius, top_y]])


func pour(center: Vector2, radius: float, rate: float, delta: float) -> void:
	_edits.append(["POUR", [0, 0], [center.x, center.y, radius, rate * delta]])


## Ask for conservation / sanity numbers; `stats` is filled after the next step.
func request_stats() -> void:
	_stats_request = true


func step(frame_dt: float) -> void:
	var edits := _edits.duplicate()
	_edits.clear()
	var want_stats := _stats_request
	_stats_request = false
	RenderingServer.call_on_render_thread(_step_rt.bind(frame_dt, edits, want_stats))


func _step_rt(frame_dt: float, edits: Array, want_stats: bool) -> void:
	_frame_dt = frame_dt
	_accum += frame_dt
	var n := clampi(int(_accum / dt), 0, max_substeps)
	n -= n % 2  # even, so the water state ends in texture A
	_accum = minf(_accum - n * dt, dt * 2.0)
	var dxs := dxw * 0.5
	var pb := _params_bytes(dxs)
	rd.buffer_update(_ubo, 0, pb.size(), pb)

	rd.capture_timestamp("beach_begin")
	var cl := rd.compute_list_begin()
	for e in edits:
		if e[0] == "BRUSH":
			_dispatch(cl, "BRUSH", ns, e[1], e[2])
		else:
			_dispatch(cl, "POUR", nw, e[1], e[2])
	if not edits.is_empty():
		_dispatch(cl, "BED", nw)  # keep the water depth over the edited sand
		_parity ^= 1
		_dispatch(cl, "BED", nw)  # second pass: back to A (no-op on unchanged sand)
		_parity ^= 1
	for s in n:
		_dispatch(cl, "STEP", nw)
		_dispatch(cl, "BOUNDARY", nw, [], [sim_time + (s + 1) * dt])
		_parity ^= 1
	_dispatch(cl, "FX", nw)
	rd.compute_list_end()
	rd.texture_copy(_fx[1], _fx[0], Vector3.ZERO, Vector3.ZERO, Vector3(nw, nw, 1), 0, 0, 0, 0)
	rd.texture_clear(_foam_dots, Color(0, 0, 0, 0), 0, 1, 0, 1)
	var caus := _caus_due
	_caus_due = false
	if caus:
		rd.buffer_clear(_caus_acc, 0, CAUS_N * CAUS_N * 3 * 4)
	cl = rd.compute_list_begin()
	_dispatch(cl, "PART", 512)  # NPART = 512^2 threads
	if caus:
		_caustics_dispatch(cl)
	rd.compute_list_end()
	sim_time += n * dt
	rd.capture_timestamp("beach_water")

	cl = rd.compute_list_begin()
	_dispatch(cl, "EROSION", nw)
	_parity ^= 1
	_dispatch(cl, "SAND_APPLY", ns)
	rd.compute_list_end()
	rd.capture_timestamp("beach_erosion")

	cl = rd.compute_list_begin()
	for i in thermal_iterations:
		_dispatch(cl, "THERMAL_OUT", ns, [0, 0, i % 2])
		_dispatch(cl, "THERMAL_IN", ns, [0, 0, i % 2])
	if thermal_iterations % 2 == 0:  # result is in sand B
		rd.compute_list_end()
		rd.texture_copy(_sand[1], _sand[0], Vector3.ZERO, Vector3.ZERO, Vector3(ns, ns, 1), 0, 0, 0, 0)
		cl = rd.compute_list_begin()
	_dispatch(cl, "BED", nw)
	_parity ^= 1
	rd.compute_list_end()
	if frame % pick_every == 0 and not _pick_pending:
		cl = rd.compute_list_begin()
		_dispatch(cl, "PICK", PICK_N, [PICK_N])
		rd.compute_list_end()
		_pick_pending = true
		rd.buffer_get_data_async(_picks, _on_picks)
	rd.capture_timestamp("beach_sand")
	if want_stats:
		cl = rd.compute_list_begin()
		var groups := ceili(float(ns) / 256.0)
		_dispatch_raw(cl, "STATS", Vector2i(groups, 1), [groups])
		rd.compute_list_end()
		_read_stats()
	frame += 1


func _on_picks(data: PackedByteArray) -> void:
	pick_heights = data.to_float32_array()
	_pick_pending = false


## Main thread, once per rendered frame: rebuild the caustic map for animation time `t` (s).
## The passes run inside the next step() (with the foam particles), at most once per call.
func update_caustics(t: float) -> void:
	_caus_t = t
	_caus_due = true


func _caustics_dispatch(cl: int) -> void:
	_dispatch(cl, "CAUS_H", CAUS_N, [], [_caus_t, caustic_slope, 5.12 / caustic_wl_max, 5.12 / caustic_wl_min])
	_dispatch(cl, "CAUS_SPLAT", CAUS_N)
	_dispatch(cl, "CAUS_RESOLVE", CAUS_N)


## Sand height (m) at world (x, z) from the coarse pick map (bilinear); NAN before the first readback.
func pick_height(x: float, z: float) -> float:
	if pick_heights.size() != PICK_N * PICK_N:
		return NAN
	var c := float(PICK_N) / (nw * dxw)
	var fx := clampf(x * c - 0.5, 0.0, PICK_N - 1.001)
	var fz := clampf(z * c - 0.5, 0.0, PICK_N - 1.001)
	var i := int(fx)
	var j := int(fz)
	var tx := fx - i
	var tz := fz - j
	var a := lerpf(pick_heights[j * PICK_N + i], pick_heights[j * PICK_N + i + 1], tx)
	var b := lerpf(pick_heights[(j + 1) * PICK_N + i], pick_heights[(j + 1) * PICK_N + i + 1], tx)
	return lerpf(a, b, tz)


func _dispatch(cl: int, kernel: String, n: int, pi: Array = [], pf: Array = []) -> void:
	var groups := Vector2i(ceili(n / 16.0), ceili(n / 16.0))
	_dispatch_raw(cl, kernel, groups, pi, pf)


func _dispatch_raw(cl: int, kernel: String, groups: Vector2i, pi: Array = [], pf: Array = []) -> void:
	if not _pipelines.has(kernel):
		return
	rd.compute_list_bind_compute_pipeline(cl, _pipelines[kernel])
	rd.compute_list_bind_uniform_set(cl, _sets[_parity][kernel], 0)
	var b := StreamPeerBuffer.new()
	for i in 4:
		b.put_32(int(pi[i]) if i < pi.size() else 0)
	for i in 4:
		b.put_float(float(pf[i]) if i < pf.size() else 0.0)
	rd.compute_list_set_push_constant(cl, b.data_array, 32)
	rd.compute_list_dispatch(cl, groups.x, groups.y, 1)
	rd.compute_list_add_barrier(cl)


func _read_stats() -> void:
	var data := rd.buffer_get_data(_sums).to_float32_array()
	var vol := 0.0
	var sed := 0.0
	var mn := 1e9
	var mx := 0.0
	for j in nw:
		vol += data[j]
		sed += data[nw + j]
		if j >= 2 and j < nw - 2:
			mn = minf(mn, data[2 * nw + j])
			mx = maxf(mx, data[3 * nw + j])
	var sand := 0.0
	for j in ns:
		sand += data[4 * nw + j]
	stats = {"water": vol, "suspended": sed, "sand": sand, "min_depth": mn, "max_speed": mx,
		"time": sim_time}


## Debug readback of the full sand grid (height, wetness, ...). Render thread only; stalls.
func read_sand_rt() -> PackedFloat32Array:
	return rd.texture_get_data(_sand[0], 0).to_float32_array()


func read_water_rt() -> PackedFloat32Array:
	return rd.texture_get_data(_water[0], 0).to_float32_array()


func read_bed_rt() -> PackedFloat32Array:
	return rd.texture_get_data(_bed, 0).to_float32_array()


func free_rt() -> void:
	water_tex.texture_rd_rid = RID()
	bed_tex.texture_rd_rid = RID()
	sand_tex.texture_rd_rid = RID()
	fx_tex.texture_rd_rid = RID()
	foam_tex.texture_rd_rid = RID()
	caustic_tex.texture_rd_rid = RID()
	for p in 2:
		for k in _sets[p]:
			if _sets[p][k].is_valid() and rd.uniform_set_is_valid(_sets[p][k]):
				rd.free_rid(_sets[p][k])
	for k in _pipelines:
		rd.free_rid(_pipelines[k])
	for k in _shaders:
		rd.free_rid(_shaders[k])
	for r in [_water[0], _water[1], _bed, _sand[0], _sand[1], _out[0], _out[1], _dbed, _sums, _ubo, _fx[0], _fx[1], _picks, _foam_dots, _parts, _part_next, _caus_grad, _caus_acc, _caus_map]:
		if r.is_valid():
			rd.free_rid(r)
