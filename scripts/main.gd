extends Node3D
## Test bench: sand + water simulation with the cartoon look (--look=m1: debug look).
##
## User args (after `--`):
##   --scenario=cove|walls|flat    initial beach (default cove, walls with --test)
##   --test=walls|conservation     log metrics to stdout (and quit after --quit-after)
##   --bench=SECONDS               measure fps / GPU pass times after 5 s warm-up, then quit
##   --quit-after=SECONDS          simulated seconds
##   --shots=DIR --shot-every=N    save a PNG every N frames
##   --cam=beach|overview|walls|ditch  camera preset (default beach)
##   --fixed                       advance exactly 1/60 s of simulation per frame
##   --steps-per-frame=N           N such steps per rendered frame (time-lapse for --write-movie)
##   --nohud / --nolabels          hide the overlay / the 3D labels
##   --caption=TEXT                show only TEXT and the simulated time (for recordings)
##   --snap=T --snap-out=PNG       save one screenshot at simulated time T, then quit
##   --demo=pour                   scripted mound + pouring water (use with --cam=demo)
##   --look=m2|m1                  cartoon look (default) or the flat debug shaders
##                                 cove: props, rocks, islands, clouds
##   --castle                      build the sandcastle at once (interactive cove)
##   --shot=cove|build|wave|collapse|surge|ditch|versus|pour  recorded shot script (Shots);
##                                 --portrait for 9:16. ditch / versus / pour are scripted brush
##                                 edits (ring shown) for the sand/water showcase
##   --rec=DIR                     save the shot's frames as DIR/f_00000.jpg (pre-roll skipped)
##
## Mouse: LMB dig, RMB pile wet sand, MMB / Space pour water; drag with Alt to orbit,
## wheel to zoom. Keys: 1/2/3/4 cameras, T toggles tide animation, R restarts and releases the old GPU simulation.

const SIZE_W := 512
const DXW := 0.04
const DEMO_MOUND := Vector2(14.5, 12.6)

var sim: BeachSim
var args := {}
var size := SIZE_W * DXW
var terrain_mat: ShaderMaterial
var water_mat: ShaderMaterial
var outer_sea_mat: ShaderMaterial
var outer_skirt_mat: ShaderMaterial
var cam: Camera3D
var hud: Label
var cursor: MeshInstance3D
var _outer_nodes: Array[Node3D] = []
var cam_target := Vector3(10.0, 0.0, 10.5)
var cam_yaw := 0.0
var cam_pitch := deg_to_rad(38.0)
var cam_dist := 9.0
var tide_on := true
var tide_amp := 0.05
var tide_period := 120.0

var _gpu_ms := {"water": 0.0, "erosion": 0.0, "sand": 0.0, "total_sim": 0.0}
var _bench_samples: Array = []
var _frame_times: Array = []
var _stat_timer := 0.0
var _metric_timer := 0.0
var _shot_frame := 0
var _log_rows: Array = []
var _start_water := -1.0
var _start_sand := -1.0
var _snap_wait := 0
var _pick_done := false
var cove := false
var props: Props
var castle: Castle
var shot := {}
var shot_name := ""
var portrait := false
var bucket: MeshInstance3D
var spade: MeshInstance3D
var _frame_i := 0
var _shot_t := -1.0
var _anim_time := 0.0  ## shader animation clock (global anim_time)
var _base_waves: Array[Vector4] = []
var _surge: Array = []  ## [[sim_t, tide_add, wave_gain], ...] from the shot or --surge
var _edit_flags := {}
var _quitting := false
const CASTLE_C := Vector2(10.24, 10.0)


func _ready() -> void:
	if RenderingServer.get_rendering_device() == null:
		print("BeachSandbox needs the Forward+ renderer (compute shaders); nothing to do in headless mode.")
		set_process(false)
		set_process_unhandled_input(false)
		get_tree().quit()
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if not args.has("scenario"):
		args["scenario"] = "walls" if args.has("test") else "cove"
	cove = args.scenario == "cove"
	portrait = args.has("portrait")
	shot_name = args.get("shot", "")
	_build_sim()
	_build_scene()
	# MSAA keeps thin palm fronds, grass and prop edges from crawling in camera moves.
	if cove and args.get("aa", "1") != "0":
		get_viewport().msaa_3d = Viewport.MSAA_4X
	if args.has("rec"):
		# Exact 1920x1080 frames (a bordered window on a 1080p screen is only 1061 tall).
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
		DisplayServer.window_set_size(Vector2i(1920, 1080))
		DisplayServer.window_set_position(Vector2i.ZERO)
	_apply_cam_preset(args.get("cam", "beach"))
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)


func _build_sim() -> void:
	sim = BeachSim.new()
	sim.nw = SIZE_W
	sim.dxw = DXW
	var test: String = args.get("test", "")
	if test == "conservation":
		# Closed box: no sea, no infiltration. Erosion and slumping stay on.
		sim.flags = BeachSim.FLAG_EROSION | BeachSim.FLAG_THERMAL
		tide_on = false
	if args.has("flags"):
		sim.flags = int(args["flags"])
	if args.has("foam-sources"):
		sim.foam_sources = int(args["foam-sources"])
	if args.has("berm"):
		Scenario.berm_h = float(args["berm"])
	var t0 := Time.get_ticks_msec()
	var sand := Scenario.build(SIZE_W * 2, DXW * 0.5, args.get("scenario", "walls"))
	print("scenario built in %d ms" % (Time.get_ticks_msec() - t0))
	sim.setup(sand, 0.0, Scenario.SHORE_Z + 0.5)
	if cove:
		castle = Castle.new(CASTLE_C)
		if shot_name != "":
			shot = Shots.make(shot_name, CASTLE_C, castle.ground, portrait)
		if args.has("castle") or shot.get("castle", "") == "instant":
			castle.build_instant(sim)
		_surge = shot.get("surge", [])
		if args.has("surge"):  # --surge=t:tide:gain,... (tuning)
			_surge = []
			for k in String(args["surge"]).split(","):
				var v := k.split(":")
				_surge.append([float(v[0]), float(v[1]), float(v[2])])
		_base_waves = sim.waves.duplicate()
		# Shot-scoped sim parameters ("sim" in the shot, or --simp=name:value,... for tuning).
		var simp: Dictionary = shot.get("sim", {}).duplicate()
		if args.has("simp"):
			for kv in String(args["simp"]).split(","):
				var v := kv.split(":")
				simp[v[0]] = float(v[1])
		for k in simp:
			sim.set(k, simp[k])
	if test == "conservation":
		# A tall column of water released next to the walls: dam break over the beach.
		for i in 40:
			sim.pour(Vector2(10.0, 9.0), 1.6, 0.02, 1.0)


func _build_scene() -> void:
	var m1: bool = args.get("look", "m2") == "m1"
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var psky := ProceduralSkyMaterial.new()
	if m1:
		psky.sky_top_color = Color(0.25, 0.55, 0.95)
		psky.sky_horizon_color = Color(0.75, 0.88, 0.98)
		psky.ground_horizon_color = Color(0.75, 0.88, 0.98)
		psky.ground_bottom_color = Color(0.55, 0.70, 0.85)
	else:
		psky.sky_top_color = Color("4fb6ff")
		psky.sky_horizon_color = Color("d6f3ff")
		psky.ground_horizon_color = Color("d6f3ff")
		psky.ground_bottom_color = Color("9fd8f0")
		psky.sun_angle_max = 20.0
	sky.sky_material = psky
	if cove and not m1:
		var ssky := ShaderMaterial.new()
		ssky.shader = load("res://shaders/render/sky.gdshader")
		var cn := FastNoiseLite.new()
		cn.frequency = 0.012
		cn.fractal_octaves = 4
		ssky.set_shader_parameter("cloud_noise", _noise_tex(cn, 512, false))
		sky.sky_material = ssky
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.7
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	if not m1:
		# Bright, saturated tropical grade (AgX keeps hues; saturation pushed back up).
		e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		e.ambient_light_color = Color("d2e2f5")  # mild sky blue, so sand stays warm
		e.ambient_light_energy = 0.42
		e.fog_enabled = true
		e.fog_light_color = Color("cfeefc")
		e.fog_density = 0.002
		e.fog_sky_affect = 0.0
		e.fog_aerial_perspective = 0.0
		e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
		# Linear keeps the palette's hex colours; lights are kept low so only glints
		# and sparkles go above 1 (into glow).
		e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		if args.get("tonemap", "") == "agx":
			e.tonemap_mode = Environment.TONE_MAPPER_AGX
			e.tonemap_agx_contrast = 1.35
		e.adjustment_enabled = true
		e.adjustment_saturation = 1.1
		e.glow_enabled = true
		e.glow_intensity = 0.5
		e.glow_hdr_threshold = 1.2
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(-30.0), 0.0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 40.0
	if not m1:
		sun.rotation = Vector3(deg_to_rad(-42.0), deg_to_rad(235.0), 0.0)  # from the front left
		sun.light_color = Color("fff3d6")
		sun.light_energy = 0.95
		sun.light_angular_distance = float(args.get("sun-soft", "0"))  # soft penumbra (PCSS)
		sun.shadow_blur = 2.0
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		sun.directional_shadow_max_distance = 30.0
	add_child(sun)
	var tex := _make_noise_textures()

	var tm := PlaneMesh.new()
	tm.size = Vector2(size, size)
	tm.subdivide_width = SIZE_W * 2 - 1
	tm.subdivide_depth = SIZE_W * 2 - 1
	terrain_mat = ShaderMaterial.new()
	terrain_mat.shader = load("res://shaders/render/terrain_m1.gdshader" if m1 else "res://shaders/render/terrain.gdshader")
	terrain_mat.set_shader_parameter("sand_tex", sim.sand_tex)
	terrain_mat.set_shader_parameter("water_tex", sim.water_tex)
	terrain_mat.set_shader_parameter("bed_tex", sim.bed_tex)
	terrain_mat.set_shader_parameter("fx_tex", sim.fx_tex)
	terrain_mat.set_shader_parameter("foam_tex", sim.foam_tex)
	terrain_mat.set_shader_parameter("caustic_tex", sim.caustic_tex)
	for k in tex:
		terrain_mat.set_shader_parameter(k, tex[k])
	terrain_mat.set_shader_parameter("size", size)
	terrain_mat.set_shader_parameter("texel", DXW * 0.5)
	var terrain := MeshInstance3D.new()
	terrain.mesh = tm
	terrain.material_override = terrain_mat
	terrain.position = Vector3(size * 0.5, 0.0, size * 0.5)
	terrain.custom_aabb = AABB(Vector3(-size, -5.0, -size), Vector3(size * 2.0, 10.0, size * 2.0))
	add_child(terrain)

	var wm := PlaneMesh.new()
	wm.size = Vector2(size, size)
	wm.subdivide_width = SIZE_W - 1
	wm.subdivide_depth = SIZE_W - 1
	water_mat = ShaderMaterial.new()
	water_mat.shader = load("res://shaders/render/water_m1.gdshader" if m1 else "res://shaders/render/water.gdshader")
	water_mat.set_shader_parameter("water_tex", sim.water_tex)
	water_mat.set_shader_parameter("bed_tex", sim.bed_tex)
	water_mat.set_shader_parameter("fx_tex", sim.fx_tex)
	water_mat.set_shader_parameter("foam_tex", sim.foam_tex)
	for k in tex:
		water_mat.set_shader_parameter(k, tex[k])
	water_mat.set_shader_parameter("size", size)
	water_mat.set_shader_parameter("texel", DXW)
	var water := MeshInstance3D.new()
	water.mesh = wm
	water.material_override = water_mat
	water.position = Vector3(size * 0.5, 0.0, size * 0.5)
	water.custom_aabb = terrain.custom_aabb
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(water)

	if not m1:
		_build_outer(tex)
		outer_skirt_mat.set_shader_parameter("cove", cove)
	if cove and not m1:
		props = Props.new()
		props.setup(sim, size)
		add_child(props)
		props.dress_cove(Rect2(CASTLE_C.x - 2.4, CASTLE_C.y - 2.3, 4.8, 4.0))
		var bd := Backdrop.new()
		add_child(bd)
		bd.build(props, tex["grain_tex"], sun.global_transform.basis.z)
		bucket = props.spawn("bucket", Vector3(CASTLE_C.x + 1.9, castle.ground, CASTLE_C.y + 0.9), 30.0, 1.0, false)
		spade = props.spawn("spade", Vector3(CASTLE_C.x - 1.7, castle.ground + 0.02, CASTLE_C.y + 1.0), 0.0, 1.0, false)
		if bucket:
			castle.bucket_scale0 = bucket.scale.x
			castle.bucket_height = props.prop_height("bucket") * bucket.scale.x
			castle.pose_tools(1e9 if shot.get("castle", "") != "build" else 0.0, bucket, spade)
			if not shot.get("tools", true):  # props don't float: keep them out of the flooded shots
				bucket.visible = false
				spade.visible = false
	# Tuning: --wp=name:value,...  (water material)  --tp=name:value,...  (terrain material)
	for pair in [["wp", water_mat], ["tp", terrain_mat]]:
		if args.has(pair[0]):
			for kv in String(args[pair[0]]).split(","):
				var p := kv.split(":")
				var v := p[1].split(";")
				pair[1].set_shader_parameter(p[0], float(v[0]) if v.size() == 1 else Vector3(float(v[0]), float(v[1]), float(v[2])))
	if args.has("nofog"):
		e.fog_enabled = false
	# Profiling ablations: --hide=water,terrain,outer,shadow,glow
	var hide := String(args.get("hide", "")).split(",")
	water.visible = not hide.has("water")
	terrain.visible = not hide.has("terrain")
	for n in _outer_nodes:
		n.visible = not hide.has("outer")
	if hide.has("shadow"):
		sun.shadow_enabled = false
	if hide.has("glow"):
		e.glow_enabled = false

	if args.get("scenario", "walls") == "walls" and not cove:
		_add_label("湿った壁 wet wall", Vector3((Scenario.WET_WALL_X.x + Scenario.WET_WALL_X.y) * 0.5, 0.75, Scenario.WALL_Z + 0.4))
		_add_label("乾いた壁 dry wall", Vector3((Scenario.DRY_WALL_X.x + Scenario.DRY_WALL_X.y) * 0.5, 0.75, Scenario.WALL_Z + 0.4))
		_add_label("溝 → 水たまり ditch → pool", Vector3(Scenario.POOL.x, 0.75, Scenario.POOL.y + 0.9))

	cam = Camera3D.new()
	cam.fov = 50.0
	cam.far = 700.0 if cove else 400.0
	if portrait:
		# 9:16 rendered in the landscape window: the camera is rolled 90 degrees and the
		# frames are turned upright afterwards (ffmpeg transpose); fov is the final vertical one.
		cam.keep_aspect = Camera3D.KEEP_WIDTH
	add_child(cam)

	# Brush cursor: a flat ring on the sand under the mouse.
	var ring := TorusMesh.new()
	ring.inner_radius = 0.23
	ring.outer_radius = 0.26
	ring.rings = 48
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.albedo_color = Color(1, 1, 1, 0.75)
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rm.no_depth_test = true
	cursor = MeshInstance3D.new()
	cursor.mesh = ring
	cursor.material_override = rm
	cursor.scale = Vector3(1.0, 0.2, 1.0)
	cursor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cursor.visible = false
	add_child(cursor)

	hud = Label.new()
	hud.position = Vector2(12, 8)
	hud.add_theme_color_override("font_shadow_color", Color.BLACK)
	hud.add_theme_constant_override("shadow_offset_x", 1)
	hud.add_theme_constant_override("shadow_offset_y", 1)
	var layer := CanvasLayer.new()
	layer.add_child(hud)
	add_child(layer)
	if args.has("shots") or args.has("nohud") or args.has("shot"):
		hud.visible = false
	if args.has("caption"):
		hud.visible = true
		hud.add_theme_font_size_override("font_size", 30)


## Static sand skirt and open sea around the sim square (hide the domain edges).
func _build_outer(tex: Dictionary) -> void:
	var skirt := PlaneMesh.new()
	skirt.size = Vector2(245.76, 245.76)  # 480 cells of 0.512 m: vertices line up with the domain edges
	skirt.subdivide_width = 479
	skirt.subdivide_depth = 479
	var smat := ShaderMaterial.new()
	smat.shader = load("res://shaders/render/terrain_outer.gdshader")
	smat.set_shader_parameter("size", size)
	for k in tex:
		smat.set_shader_parameter(k, tex[k])
	var sk := MeshInstance3D.new()
	sk.mesh = skirt
	sk.material_override = smat
	sk.position = Vector3(size * 0.5, 0.0, size * 0.5)
	sk.custom_aabb = AABB(Vector3(-130, -5, -130), Vector3(260, 10, 260))
	add_child(sk)
	_outer_nodes.append(sk)
	var sea := PlaneMesh.new()
	sea.size = Vector2(400.0, 400.0)
	sea.subdivide_width = 299
	sea.subdivide_depth = 299
	outer_sea_mat = ShaderMaterial.new()
	outer_sea_mat.shader = load("res://shaders/render/water_outer.gdshader")
	outer_sea_mat.set_shader_parameter("size", size)
	outer_sea_mat.set_shader_parameter("offshore_depth", sim.offshore_depth)
	var wv := PackedVector4Array()
	for w in sim.waves:
		wv.append(w)
	outer_sea_mat.set_shader_parameter("waves", wv)
	for k in tex:
		outer_sea_mat.set_shader_parameter(k, tex[k])
	var se := MeshInstance3D.new()
	se.mesh = sea
	se.material_override = outer_sea_mat
	se.position = Vector3(size * 0.5, 0.0, size * 0.5 - 100.0)
	se.custom_aabb = AABB(Vector3(-210, -5, -210), Vector3(420, 10, 420))
	se.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(se)
	_outer_nodes.append(se)
	outer_skirt_mat = smat


## Tileable procedural textures shared by the sand and water shaders.
func _make_noise_textures() -> Dictionary:
	var out := {}
	# Grain / phase noise: fine fractal value noise.
	var gn := FastNoiseLite.new()
	gn.noise_type = FastNoiseLite.TYPE_VALUE
	gn.frequency = 0.12
	gn.fractal_octaves = 2
	out["grain_tex"] = _noise_tex(gn, 256, false)
	# Cellular F1: caustic network.
	var cn := FastNoiseLite.new()
	cn.noise_type = FastNoiseLite.TYPE_CELLULAR
	cn.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	cn.cellular_jitter = 0.9
	cn.frequency = 8.0 / 256.0
	cn.fractal_type = FastNoiseLite.FRACTAL_NONE
	out["cell_tex"] = _noise_tex(cn, 256, false)
	# Cellular F2-F1: foam lace (filaments along cell borders).
	var ln := FastNoiseLite.new()
	ln.noise_type = FastNoiseLite.TYPE_CELLULAR
	ln.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
	ln.cellular_jitter = 1.0
	ln.frequency = 10.0 / 512.0
	ln.fractal_type = FastNoiseLite.FRACTAL_FBM
	ln.fractal_octaves = 2
	ln.fractal_gain = 0.35
	out["lace_tex"] = _noise_tex(ln, 512, false, true)
	# Ripple normals.
	var rn := FastNoiseLite.new()
	rn.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	rn.frequency = 6.0 / 256.0
	rn.fractal_octaves = 3
	out["ripple_tex"] = _noise_tex(rn, 256, true)
	return out


func _noise_tex(noise: FastNoiseLite, n: int, normal_map: bool, invert := false) -> NoiseTexture2D:
	var t := NoiseTexture2D.new()
	t.width = n
	t.height = n
	t.seamless = true
	t.generate_mipmaps = true
	t.as_normal_map = normal_map
	t.bump_strength = 6.0
	t.invert = invert
	t.noise = noise
	return t


func _add_label(text: String, pos: Vector3) -> void:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.font_size = 48
	l.pixel_size = 0.004
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.outline_size = 12
	l.modulate = Color(1, 1, 1, 0.9)
	l.no_depth_test = true
	l.visible = not args.has("nolabels")
	add_child(l)


func _apply_cam_preset(name: String) -> void:
	match name:
		"beach":
			# The framing of the GAME-127 showcase recording (Shots "ditch"): low, from the beach
			# out to sea, the swash zone filling the frame.
			cam_target = Vector3(10.24, 0.1, 9.6)
			cam_yaw = deg_to_rad(152.0)
			cam_pitch = deg_to_rad(26.4)
			cam_dist = 4.05
		"walls":
			cam_target = Vector3(10.0, 0.1, 9.2)
			cam_yaw = 0.0
			cam_pitch = deg_to_rad(40.0)
			cam_dist = 11.0
		"ditch":
			cam_target = Vector3(10.0, 0.1, 11.0)
			cam_yaw = deg_to_rad(-30.0)
			cam_pitch = deg_to_rad(42.0)
			cam_dist = 5.0
		"demo":
			cam_target = Vector3(DEMO_MOUND.x, 0.25, DEMO_MOUND.y - 0.2)
			cam_yaw = deg_to_rad(25.0)
			cam_pitch = deg_to_rad(36.0)
			cam_dist = 4.2
		"wide":
			# From the dunes out over the cove to the islands (the heaviest view: everything visible).
			cam_target = Vector3(10.4, 0.0, 6.0)
			cam_yaw = PI
			cam_pitch = deg_to_rad(14.0)
			cam_dist = 15.5
		"castle":
			cam_target = Vector3(CASTLE_C.x, 0.15, CASTLE_C.y - 0.3)
			cam_yaw = deg_to_rad(-25.0)
			cam_pitch = deg_to_rad(32.0)
			cam_dist = 4.5
		"shore":
			# Low view along the waterline: swash tongues, foam line, backwash lace.
			cam_target = Vector3(6.5, 0.0, 7.6)
			cam_yaw = deg_to_rad(-120.0)
			cam_pitch = deg_to_rad(24.0)
			cam_dist = 5.0
		"shallow":
			# Looking down into the shallows: caustics on the sand.
			cam_target = Vector3(14.0, -0.05, 7.3)
			cam_yaw = deg_to_rad(160.0)
			cam_pitch = deg_to_rad(55.0)
			cam_dist = 3.2
		"top":
			# High top-down view over the shallows: caustic pattern repetition check.
			cam_target = Vector3(12.0, -0.1, 6.8)
			cam_yaw = deg_to_rad(180.0)
			cam_pitch = deg_to_rad(78.0)
			cam_dist = 6.0
		"wet":
			cam_target = Vector3(5.5, 0.15, 9.1)
			cam_yaw = deg_to_rad(-35.0)
			cam_pitch = deg_to_rad(30.0)
			cam_dist = 3.6
		"dry":
			cam_target = Vector3(14.5, 0.15, 9.1)
			cam_yaw = deg_to_rad(35.0)
			cam_pitch = deg_to_rad(30.0)
			cam_dist = 3.6
		_:
			cam_target = Vector3(10.0, 0.0, 9.0)
			cam_yaw = 0.0
			cam_pitch = deg_to_rad(52.0)
			cam_dist = 17.0
	_update_cam()


func _update_cam() -> void:
	var dir := Vector3(sin(cam_yaw) * cos(cam_pitch), sin(cam_pitch), -cos(cam_yaw) * cos(cam_pitch))
	# Camera sits on the sea side (low z) looking up the beach.
	cam.position = cam_target + dir * cam_dist
	cam.look_at(cam_target, Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_key_pressed(KEY_ALT) and event.button_mask != 0:
		cam_yaw += event.relative.x * 0.005
		cam_pitch = clampf(cam_pitch + event.relative.y * 0.005, 0.1, 1.5)
		_update_cam()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_dist = maxf(1.0, cam_dist * 0.9)
			_update_cam()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_dist = minf(40.0, cam_dist * 1.1)
			_update_cam()
	elif event is InputEventKey and event.pressed:
		if event.echo: return
		match event.keycode:
			KEY_1: _apply_cam_preset("beach")
			KEY_2: _apply_cam_preset("walls")
			KEY_3: _apply_cam_preset("ditch")
			KEY_4: _apply_cam_preset("overview")
			KEY_T: tide_on = not tide_on
			KEY_R: _restart()


## Mouse ray against the sand heightfield (coarse async height map from the GPU,
## ray-marched then refined by bisection). Falls back to the y = 0.15 plane until the
## first height map arrives. Returns Vector3(x, height, z), or x < 0 when missing.
func _mouse_ground(mp: Vector2) -> Vector3:
	var o := cam.project_ray_origin(mp)
	var d := cam.project_ray_normal(mp)
	if is_nan(sim.pick_height(0.0, 0.0)):
		if absf(d.y) < 1e-4:
			return Vector3(-1, 0, -1)
		var p := o + d * ((0.15 - o.y) / d.y)
		return Vector3(p.x, 0.15, p.z)
	var step := 0.04
	var t := 0.0
	var prev_t := 0.0
	var hit := false
	while t < 120.0:
		var p := o + d * t
		if p.y < -3.0:
			break
		var inside := p.x >= 0.0 and p.z >= 0.0 and p.x <= size and p.z <= size
		if inside and p.y <= sim.pick_height(p.x, p.z):
			hit = true
			break
		prev_t = t
		t += step * maxf(1.0, t * 0.05)  # coarser steps far from the camera
	if not hit:
		return Vector3(-1, 0, -1)
	var a := prev_t
	var b := t
	for i in 12:
		var m := (a + b) * 0.5
		var pm := o + d * m
		if pm.y <= sim.pick_height(pm.x, pm.z):
			b = m
		else:
			a = m
	var q := o + d * b
	return Vector3(q.x, sim.pick_height(q.x, q.z), q.z)


func _process(delta: float) -> void:
	var fixed := args.has("fixed") or args.has("shots") or args.has("test") or not shot.is_empty()
	var fdt := 1.0 / 60.0 if fixed else minf(delta, 1.0 / 30.0)
	_frame_times.append(delta)
	if _frame_times.size() > 120:
		_frame_times.pop_front()

	if cursor:
		cursor.visible = false
	if not Input.is_key_pressed(KEY_ALT) and _interactive():
		var p3 := _mouse_ground(get_viewport().get_mouse_position())
		var p := Vector2(p3.x, p3.z)
		if p.x >= 0.0:
			if cursor:
				cursor.visible = true
				cursor.position = p3 + Vector3(0.0, 0.01, 0.0)
			if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
				sim.dig(p, 0.25, 0.25, fdt)
			if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
				sim.pile(p, 0.25, 0.25, fdt, 0.5)
			if Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE) or Input.is_key_pressed(KEY_SPACE):
				sim.pour(p, 0.3, 0.3, fdt)

	_anim_time += fdt
	RenderingServer.global_shader_parameter_set("anim_time", _anim_time)
	if not args.has("nocaus"): sim.update_caustics(_anim_time)
	var steps := int(args.get("steps-per-frame", "1"))
	if not shot.is_empty():
		steps = _shot_tick()
		_shot_edits(fdt * steps)
	if args.get("demo", "") == "pour":
		_demo_pour(fdt * steps)  # edits apply once per rendered frame
	if tide_on:
		sim.tide = tide_amp * sin(TAU * sim.sim_time / tide_period - PI * 0.5) + tide_amp * 0.6
	if not _surge.is_empty() and tide_on:
		_apply_surge()
	if outer_sea_mat:
		outer_sea_mat.set_shader_parameter("tide", sim.tide)
		outer_sea_mat.set_shader_parameter("sim_time", sim.sim_time)
		outer_sea_mat.set_shader_parameter("ramp", clampf(sim.sim_time / sim.wave_ramp, 0.0, 1.0))
		outer_skirt_mat.set_shader_parameter("tide", sim.tide)
	_stat_timer += fdt * steps
	if _stat_timer >= 1.0:
		_stat_timer = 0.0
		sim.request_stats()
	for i in steps:
		sim.step(fdt)
	_collect_gpu_time()
	_log_stats()
	if args.get("test", "") == "pick" and sim.sim_time > 3.0 and not _pick_done:
		_pick_done = true
		RenderingServer.call_on_render_thread(_pick_test_rt)
	if args.get("test", "") == "walls":
		_metric_timer += fdt * steps
		if _metric_timer >= float(args.get("metric-every", "2")):
			_metric_timer = 0.0
			RenderingServer.call_on_render_thread(_measure_walls_rt.bind(sim.sim_time))

	var fps := 1.0 / maxf(_avg(_frame_times), 1e-6)
	var gpu_frame := RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
	hud.text = "BeachSandbox  %.0f fps  (frame GPU %.2f ms)\nsim GPU: water %.2f  erosion %.2f  sand %.2f ms\nt=%.1f s  tide %+.3f m  substeps/frame ~%d\n%s\nLMB dig  RMB pile  MMB/Space pour  Alt+drag orbit  1-4 cams  T tide  R reset
左クリック 掘る  右クリック 盛る  中クリック/Space 水  Alt+ドラッグ 回転  1-4 カメラ  T 潮  R リセット" % [
		fps, gpu_frame, _gpu_ms.water, _gpu_ms.erosion, _gpu_ms.sand, sim.sim_time, sim.tide,
		int(round(fdt / sim.dt)), _stats_line()]

	if args.has("caption"):
		hud.text = "%s   t = %.0f s" % [args["caption"], sim.sim_time]
	if args.has("bench"):
		if sim.sim_time > 5.0:
			_bench_samples.append([delta, _gpu_ms.water, _gpu_ms.erosion, _gpu_ms.sand, gpu_frame])
		if sim.sim_time > 5.0 + float(args["bench"]):
			_finish_bench()
	if args.has("shots"):
		var every := int(args.get("shot-every", "2"))
		if Engine.get_frames_drawn() % every == 0 and sim.sim_time > 0.05:
			var dir: String = args["shots"]
			DirAccess.make_dir_recursive_absolute(dir)
			get_viewport().get_texture().get_image().save_png("%s/f_%05d.png" % [dir, _shot_frame])
			_shot_frame += 1
	if args.has("snap") and sim.sim_time >= float(args["snap"]):
		_snap_wait += 1
		if _snap_wait == 3:  # let the last sim state reach the screen
			var path: String = args.get("snap-out", "captures/snap.png")
			DirAccess.make_dir_recursive_absolute(path.get_base_dir())
			get_viewport().get_texture().get_image().save_png(path)
			_quit()
	if args.has("quit-after") and sim.sim_time >= float(args["quit-after"]):
		_quit()
	if not shot.is_empty():
		_flush_rec()


## Scripted swell for a shot (cove only, never the tests): raise the sea level and scale the
## wave amplitudes along the [sim_t, tide_add, gain] keys (smoothstep between keys), in the
## sim's boundary forcing and the outer analytic sea alike.
func _apply_surge() -> void:
	var t := sim.sim_time
	var tide_add: float = _surge[0][1]
	var gain: float = _surge[0][2]
	for i in range(1, _surge.size()):
		var a: Array = _surge[i - 1]
		var b: Array = _surge[i]
		if t >= a[0]:
			var k := smoothstep(float(a[0]), float(b[0]), t)
			tide_add = lerpf(a[1], b[1], k)
			gain = lerpf(a[2], b[2], k)
	sim.tide += tide_add
	var wv := PackedVector4Array()
	for i in _base_waves.size():
		var w := _base_waves[i]
		sim.waves[i] = Vector4(w.x * gain, w.y, w.z, w.w)
		wv.append(sim.waves[i])
	if outer_sea_mat:
		outer_sea_mat.set_shader_parameter("waves", wv)


## Shot clock: fast-forward the pre-roll (8 sim steps per frame, not recorded), then run the
## shot at its own steps per frame; camera from the CamRig at shot time = frames / 60.
## Returns the number of sim steps for this frame.
func _shot_tick() -> int:
	var steps := 8
	if _shot_t < 0.0 and sim.sim_time >= float(shot.preroll) - 1e-4:
		_shot_t = 0.0
		print("SHOT %s start sim_t=%.2f" % [shot_name, sim.sim_time])
	elif _shot_t >= 0.0:
		_shot_t += 1.0 / 60.0
	if _shot_t >= 0.0:
		steps = int(shot.steps)
		for k in shot.get("speed", []):
			if _shot_t >= k[0] - 1e-4: steps = int(k[1])
	var t := maxf(_shot_t, 0.0)
	if shot.castle == "build":
		castle.update(sim, t, bucket, spade)
	var c: Array = shot.rig.eval(t)
	cam.fov = c[2]
	cam.position = c[0]
	cam.look_at(c[1], Vector3.UP)
	if portrait:
		cam.rotate_object_local(Vector3(0, 0, 1), PI * 0.5)
	if _shot_t >= 0.0 and args.has("rec") and not _quit_after_rec:
		var dir: String = args["rec"]
		if _frame_i == 0:
			DirAccess.make_dir_recursive_absolute(dir)
		_rec_pending.append(["%s/f_%05d.jpg" % [dir, _frame_i], 2])
		_frame_i += 1
	if _shot_t >= float(shot.length):
		_quit_after_rec = true
	return steps


var _rec_pending: Array = []
var _quit_after_rec := false


## Save frames two frames late (after the frame for that shot time reached the screen).
func _flush_rec() -> void:
	var keep: Array = []
	for r in _rec_pending:
		r[1] -= 1
		if r[1] <= 0:
			get_viewport().get_texture().get_image().save_jpg(r[0], 0.95)
		else:
			keep.append(r)
	_rec_pending = keep
	if _quit_after_rec and _rec_pending.is_empty():
		_quit()


## Showcase shots: the same dig / pile / stamp / pour brushes as the mouse, scripted on
## the shot clock, with the brush ring drawn where the "hand" is. `edit_dt` is the simulated
## time of this frame (rates are per simulated second, like the mouse brushes).
func _shot_edits(edit_dt: float) -> void:
	var t := _shot_t
	if t < 0.0:
		return
	var r := -1.0  # brush ring radius (< 0: hidden)
	var at := Vector2.ZERO
	var tint := Color(1, 1, 1, 0.8)
	match shot_name:
		"ditch":
			var pool := Vector2(Shots.DITCH_X, Shots.DITCH_Z.x)
			if t > 0.3 and t < 2.0:
				var a := (t - 0.3) * 7.0
				at = pool + Vector2(cos(a), sin(a)) * 0.13
				sim.dig(at, 0.26, 0.12, edit_dt)
				r = 0.26
			elif t > 2.0 and t < 5.2:
				var u := (t - 2.0) / 3.2
				at = Vector2(Shots.DITCH_X + 0.03 * sin(t * 9.0), lerpf(Shots.DITCH_Z.x - 0.25, Shots.DITCH_Z.y, u))
				var depth := maxf(Scenario.cove_height(at.x, at.y) - lerpf(0.04, -0.03, u), 0.03)
				sim.dig(at, 0.17, depth / 0.42, edit_dt)
				r = 0.17
		"versus":
			if t > 0.3 and t < 2.1:
				var n := 14
				var i := mini(int((t - 0.3) / 1.8 * n), n - 1)
				at = Vector2(lerpf(7.6, 9.2, float(i) / (n - 1)), Shots.VERSUS_Z)
				var key := "wall%d" % i
				if not _edit_flags.has(key):
					_edit_flags[key] = true
					sim.stamp(at, 0.2, Scenario.cove_height(at.x, at.y) + 0.26, 0.45, 0.6, 1.0)
				r = 0.2
			elif t > 2.4 and t < 4.4:
				var u := (t - 2.4) / 2.0
				at = Vector2(lerpf(11.3, 12.9, 1.0 - absf(1.0 - 2.0 * u)), Shots.VERSUS_Z)
				sim.pile(at, 0.34, 0.5, edit_dt, 0.0, 0.0)
				r = 0.34
				tint = Color(1.0, 0.93, 0.75, 0.8)
		"pour":
			if t > 0.3 and t < 2.8:
				at = Shots.POUR_MOUND
				sim.pile(at, 0.4, 0.12, edit_dt, 0.5, 0.9)
				r = 0.4
			elif t > 3.5 and t < 13.0:
				at = Shots.POUR_MOUND + Vector2(0.15, 0.9)
				sim.pour(at, 0.3, 0.12, edit_dt)
				r = 0.3
				tint = Color(0.65, 0.95, 1.0, 0.85)
	if cursor:
		cursor.visible = r > 0.0
		if cursor.visible:
			var h := sim.pick_height(at.x, at.y)
			if is_nan(h): h = Scenario.cove_height(at.x, at.y)
			cursor.position = Vector3(at.x, h + 0.01, at.y)
			cursor.scale = Vector3(r / 0.245, 0.2, r / 0.245)
			(cursor.material_override as StandardMaterial3D).albedo_color = tint


## Mouse editing and the brush cursor only in plain interactive runs (not tests / recordings).
func _interactive() -> bool:
	for k in ["test", "shots", "snap", "caption", "bench", "shot"]:
		if args.has(k):
			return false
	return true


## --demo=pour: build a small packed mound on the dry upper beach, then pour water
## uphill of it (recording showcase: flow over dry sand, wet trail, erosion, foam).
func _demo_pour(fdt: float) -> void:
	var t := sim.sim_time
	if t > 0.5 and t < 3.0:
		sim.pile(DEMO_MOUND, 0.4, 0.12, fdt, 0.5, 0.9)
	if t > 4.0 and t < 16.0:
		sim.pour(DEMO_MOUND + Vector2(0.15, 0.9), 0.3, 0.12, fdt)


func _stats_line() -> String:
	var s := sim.stats
	if s.is_empty():
		return ""
	return "water %.4f m3  sand+susp %.4f m3  min depth %s  max speed %.2f m/s" % [
		s.water, s.sand + s.suspended, _sci(s.min_depth), s.max_speed]


static func _sci(v: float) -> String:
	if v == 0.0:
		return "0"
	var e := floori(log(absf(v)) / log(10.0))
	return "%.3fe%d" % [v / pow(10.0, e), e]


var _last_stats_time := -1.0


func _log_stats() -> void:
	var s := sim.stats
	if s.is_empty() or s.time == _last_stats_time or not args.has("test"):
		return
	_last_stats_time = s.time
	if _start_water < 0.0:
		_start_water = s.water
		_start_sand = s.sand + s.suspended
	print("STATS t=%.2f water=%.6f (%s rel) sand=%.6f (%s m3) susp=%.6f min_depth=%s max_speed=%.3f" % [
		s.time, s.water, _sci((s.water - _start_water) / _start_water), s.sand + s.suspended,
		_sci(s.sand + s.suspended - _start_sand), s.suspended, _sci(s.min_depth), s.max_speed])


func _collect_gpu_time() -> void:
	var rd := sim.rd
	if rd == null:
		return
	var t := {}
	for i in rd.get_captured_timestamps_count():
		t[rd.get_captured_timestamp_name(i)] = rd.get_captured_timestamp_gpu_time(i)
	if args.has("dump-timestamps") and Engine.get_frames_drawn() == 200:
		for i in rd.get_captured_timestamps_count():
			print("TS %s %.3f" % [rd.get_captured_timestamp_name(i), rd.get_captured_timestamp_gpu_time(i) / 1e6])
	if t.has("beach_begin") and t.has("beach_sand"):
		_gpu_ms.water = (t.beach_water - t.beach_begin) / 1e6
		_gpu_ms.erosion = (t.beach_erosion - t.beach_water) / 1e6
		_gpu_ms.sand = (t.beach_sand - t.beach_erosion) / 1e6
		_gpu_ms.total_sim = (t.beach_sand - t.beach_begin) / 1e6


## Render thread: sample wall heights and pool depth from a full readback (debug only).
func _measure_walls_rt(t: float) -> void:
	var sand := sim.read_sand_rt()
	var water := sim.read_water_rt()
	var bedd := sim.read_bed_rt()
	var ns := SIZE_W * 2
	var dxs := DXW * 0.5
	var res := {}
	for name in ["wet", "dry"]:
		var xr: Vector2 = Scenario.WET_WALL_X if name == "wet" else Scenario.DRY_WALL_X
		var heights := PackedFloat32Array()
		var x := xr.x + 0.3
		while x < xr.y - 0.3:
			var i := int(x / dxs)
			var best := -1e9
			for j in range(int((Scenario.WALL_Z - 0.8) / dxs), int((Scenario.WALL_Z + 0.8) / dxs)):
				var z := (j + 0.5) * dxs
				var hh := sand[(j * ns + i) * 4] - Scenario.beach_height(x, z)
				best = maxf(best, hh)
			heights.append(best)
			x += 0.1
		var mean := 0.0
		var mn := 1e9
		for v in heights:
			mean += v
			mn = minf(mn, v)
		res[name] = [mean / heights.size(), mn]
	# Pool: water depth at the pool centre and in the upper ditch.
	var pc := Vector2i(int(Scenario.POOL.x / DXW), int(Scenario.POOL.y / DXW))
	var k := (pc.y * SIZE_W + pc.x) * 4
	var pool_depth := water[k] - bedd[k]
	var dc := Vector2i(int(Scenario.DITCH_X / DXW), int(12.0 / DXW))
	k = (dc.y * SIZE_W + dc.x) * 4
	var ditch_depth := water[k] - bedd[k]
	# Flooding behind the walls: wet fraction of the back beach z 9.5-12.5 m (outside the ditch).
	var wet_cells := 0
	var cells := 0
	for jj in range(int(9.5 / DXW), int(12.5 / DXW)):
		for ii in range(2, SIZE_W - 2):
			if absf((ii + 0.5) * DXW - Scenario.DITCH_X) < 0.6:
				continue
			var kk := (jj * SIZE_W + ii) * 4
			cells += 1
			if water[kk] - bedd[kk] > 0.003:
				wet_cells += 1
	var flood := float(wet_cells) / cells
	if not args.has("verbose"):
		print("WALLS t=%.1f wet_mean=%.3f wet_min=%.3f dry_mean=%.3f dry_min=%.3f pool_depth=%.3f ditch_depth=%.3f back_flooded=%.2f tide=%+.3f" % [
			t, res.wet[0], res.wet[1], res.dry[0], res.dry[1], pool_depth, ditch_depth, flood, sim.tide])
		return
	var rows := ""
	for zr in [0.04, 0.5, 1.5, 3.0, 5.0, 7.0, 8.0, 9.0]:
		var jj := int(zr / DXW)
		var acc := 0.0
		var cnt := 0
		for ii in range(2, SIZE_W - 2):
			var kk := (jj * SIZE_W + ii) * 4
			if water[kk] - bedd[kk] > 0.002:
				acc += water[kk]
				cnt += 1
		rows += " eta@%.1f=%+.3f" % [zr, acc / maxi(cnt, 1)]
	print(rows)
	for xs in [5.0, 15.0]:
		var prof := "PROFILE x=%.0f" % xs
		var zz := Scenario.WALL_Z - 0.6
		while zz <= Scenario.WALL_Z + 0.61:
			var kk := (int(zz / dxs) * ns + int(xs / dxs)) * 4
			var wc := (int(zz / DXW) * SIZE_W + int(xs / DXW)) * 4
			prof += " %.2f/%.1f/%.1f/%.2f" % [sand[kk] - Scenario.beach_height(xs, zz), sand[kk + 1], sand[kk + 2], maxf(water[wc] - bedd[wc], 0.0)]
			zz += 0.06
		print(prof)
	print("WALLS t=%.1f wet_mean=%.3f wet_min=%.3f dry_mean=%.3f dry_min=%.3f pool_depth=%.3f ditch_depth=%.3f tide=%+.3f" % [
		t, res.wet[0], res.wet[1], res.dry[0], res.dry[1], pool_depth, ditch_depth, sim.tide])


## --test=pick: mouse rays through a grid of screen points; compare the heightfield hit
## with the true sand surface (full-resolution readback) and with the old y = 0.15 plane.
func _pick_test_rt() -> void:
	var sand := sim.read_sand_rt()
	var ns := SIZE_W * 2
	var dxs := DXW * 0.5
	var vp := get_viewport().get_visible_rect().size
	var worst := 0.0
	var worst_plane := 0.0
	var n := 0
	for gy in range(3, 10):
		for gx in range(1, 12):
			var mp := Vector2(vp.x * gx / 12.0, vp.y * gy / 10.0)
			var hit := _mouse_ground(mp)
			if hit.x < 0.0:
				continue
			# Ground truth: march the full-resolution heights in 5 mm steps.
			var o := cam.project_ray_origin(mp)
			var d := cam.project_ray_normal(mp)
			var t := 0.0
			var truth := Vector3(-1, 0, -1)
			while t < 120.0:
				var p := o + d * t
				var i := int(p.x / dxs)
				var j := int(p.z / dxs)
				if i >= 0 and j >= 0 and i < ns and j < ns and p.y <= sand[(j * ns + i) * 4]:
					truth = p
					break
				t += 0.005
			if truth.x < 0.0:
				continue
			var plane := o + d * ((0.15 - o.y) / d.y)
			worst = maxf(worst, Vector2(hit.x - truth.x, hit.z - truth.z).length())
			worst_plane = maxf(worst_plane, Vector2(plane.x - truth.x, plane.z - truth.z).length())
			n += 1
	print("PICK rays=%d max_xz_error=%.3f m (old plane method %.3f m)" % [n, worst, worst_plane])
	call_deferred("_quit")


func _avg(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


func _finish_bench() -> void:
	var n := _bench_samples.size()
	var acc := [0.0, 0.0, 0.0, 0.0, 0.0]
	for smp in _bench_samples:
		for i in 5:
			acc[i] += smp[i]
	print("BENCH frames=%d avg_fps=%.1f water=%.3f ms erosion=%.3f ms sand=%.3f ms sim_total=%.3f ms frame_gpu=%.3f ms res=%s" % [
		n, n / acc[0], acc[1] / n, acc[2] / n, acc[3] / n, (acc[1] + acc[2] + acc[3]) / n, acc[4] / n,
		str(get_viewport().get_visible_rect().size)])
	_quit()


func _quit() -> void:
	if _quitting: return
	_quitting = true
	set_process(false)
	RenderingServer.call_on_render_thread(sim.free_rt)
	get_tree().quit()


func _restart() -> void:
	if _quitting: return
	_quitting = true
	set_process(false)
	set_process_unhandled_input(false)
	RenderingServer.call_on_render_thread(sim.free_rt)
	get_tree().reload_current_scene()


func _exit_tree() -> void:
	# Also release RD resources when the window is closed or the scene is replaced externally.
	if not _quitting and sim != null and sim.rd != null:
		RenderingServer.call_on_render_thread(sim.free_rt)
