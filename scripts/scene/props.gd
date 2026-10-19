class_name Props
extends Node3D
## Meshy props (assets/props/*.glb, cleaned by tools/blender/prep_prop.py) with the toon
## prop shader. Props on the sim square follow the live sand on the GPU (prop.gdshader:
## lifted to the sand height under their origin, tilted to the slope), so they never float
## when the sand under them is washed away; props outside use the static cove profile.

const DEFS := {
	# size: longest side (m) after base_rot; base_rot: degrees applied before placement;
	# sink: fraction of the height pushed into the sand; tilt: follow the slope (0..1)
	"scallop": {"file": "shell-scallop", "size": 0.09, "base_rot": Vector3(-80, 0, 0), "sink": 0.25, "tilt": 1.0},
	"conch": {"file": "shell-conch", "size": 0.12, "base_rot": Vector3(-90, 0, 20), "sink": 0.3, "tilt": 1.0},
	"starfish": {"file": "starfish", "size": 0.15, "base_rot": Vector3.ZERO, "sink": 0.3, "tilt": 1.0},
	"pebbles": {"file": "pebbles", "size": 0.18, "base_rot": Vector3.ZERO, "sink": 0.3, "tilt": 0.8},
	"driftwood": {"file": "driftwood", "size": 1.3, "base_rot": Vector3.ZERO, "sink": 0.3, "tilt": 0.7},
	"palm": {"file": "palm", "size": 6.0, "base_rot": Vector3.ZERO, "sink": 0.02, "tilt": 0.0},
	"grass": {"file": "grass", "size": 0.7, "base_rot": Vector3.ZERO, "sink": 0.08, "tilt": 0.3},
	"bucket": {"file": "bucket", "size": 0.26, "base_rot": Vector3.ZERO, "sink": 0.0, "tilt": 0.0},
	"spade": {"file": "spade", "size": 0.42, "base_rot": Vector3.ZERO, "sink": 0.0, "tilt": 0.0},
	"rock": {"file": "rock-big", "size": 4.0, "base_rot": Vector3.ZERO, "sink": 0.15, "tilt": 0.0, "tint": Vector3(1.0, 0.86, 0.72)},
	"stack": {"file": "rock-stack", "size": 6.5, "base_rot": Vector3.ZERO, "sink": 0.05, "tilt": 0.0, "tint": Vector3(1.0, 0.86, 0.72)},
}

var sim: BeachSim
var size := 20.48
var _meshes := {}      ## name -> ArrayMesh (normalized: bottom centre at origin, longest side 1)
var _heights := {}     ## name -> height of the normalized mesh
var _mats := {}        ## name -> ShaderMaterial


func setup(p_sim: BeachSim, p_size: float) -> void:
	sim = p_sim
	size = p_size


func has_prop(name: String) -> bool:
	return _mesh(name) != null


## A prop instance. snap: follow the sim sand (only meaningful inside the sim square).
func spawn(name: String, pos: Vector3, yaw_deg: float, scale_mul := 1.0, snap := true) -> MeshInstance3D:
	var m := _mesh(name)
	if m == null:
		return null
	var d: Dictionary = DEFS[name]
	var s: float = d.size * scale_mul
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = _mats[name]
	mi.position = pos
	mi.rotation = Vector3(0.0, deg_to_rad(yaw_deg), 0.0)
	mi.scale = Vector3.ONE * s
	var inside := pos.x > 0.2 and pos.z > 0.2 and pos.x < size - 0.2 and pos.z < size - 0.2
	mi.set_instance_shader_parameter("snap", 1.0 if snap and inside else 0.0)
	mi.set_instance_shader_parameter("tilt", d.tilt)
	mi.set_instance_shader_parameter("sink", d.sink * _heights[name] * s)
	mi.set_instance_shader_parameter("foot", clampf(s * 0.4, 0.03, 0.5))
	mi.set_instance_shader_parameter("wet_band", clampf(_heights[name] * s * 0.5, 0.01, 0.08))
	if s < 0.3:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mi)
	return mi


func _mesh(name: String) -> ArrayMesh:
	if _meshes.has(name):
		return _meshes[name]
	var d: Dictionary = DEFS[name]
	var path := "res://assets/props/%s.glb" % d.file
	if not ResourceLoader.exists(path):
		push_warning("prop missing: " + path)
		_meshes[name] = null
		return null
	var scene: Node = (load(path) as PackedScene).instantiate()
	var src := _find_mesh(scene)
	var tex: Texture2D = null
	var out := ArrayMesh.new()
	var basis := Basis.from_euler(Vector3(deg_to_rad(d.base_rot.x), deg_to_rad(d.base_rot.y), deg_to_rad(d.base_rot.z)))
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	var surfaces := []
	for si in src.mesh.get_surface_count():
		var arr := src.mesh.surface_get_arrays(si)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		for i in v.size():
			v[i] = basis * v[i]
			lo = lo.min(v[i])
			hi = hi.max(v[i])
		for i in n.size():
			n[i] = basis * n[i]
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_NORMAL] = n
		arr[Mesh.ARRAY_TANGENT] = null
		surfaces.append(arr)
		var mat := src.mesh.surface_get_material(si)
		if tex == null and mat is BaseMaterial3D:
			tex = (mat as BaseMaterial3D).albedo_texture
	# Bottom centre to the origin, longest side to 1 m.
	var ext := hi - lo
	var k := 1.0 / maxf(ext.x, maxf(ext.y, ext.z))
	var off := Vector3((lo.x + hi.x) * 0.5, lo.y, (lo.z + hi.z) * 0.5)
	for arr in surfaces:
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for i in v.size():
			v[i] = (v[i] - off) * k
		arr[Mesh.ARRAY_VERTEX] = v
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	scene.free()
	var sm := ShaderMaterial.new()
	sm.shader = preload("res://shaders/render/prop.gdshader")
	sm.set_shader_parameter("albedo_tex", tex)
	sm.set_shader_parameter("sand_tex", sim.sand_tex)
	sm.set_shader_parameter("water_tex", sim.water_tex)
	sm.set_shader_parameter("bed_tex", sim.bed_tex)
	sm.set_shader_parameter("size", size)
	if d.has("tint"):
		sm.set_shader_parameter("albedo_tint", d.tint)
	_meshes[name] = out
	_heights[name] = ext.y * k
	_mats[name] = sm
	return out


static func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var r := _find_mesh(c)
		if r:
			return r
	return null


## Height of the prop mesh at scale 1 (normalized: longest side 1 m).
func prop_height(name: String) -> float:
	_mesh(name)
	return _heights.get(name, 1.0)


## Shared material of a prop type (e.g. to fade distant island palms into the haze).
func material(name: String) -> ShaderMaterial:
	_mesh(name)
	return _mats.get(name)


## The cove dressing: shells / starfish / pebbles on the beach, driftwood, dune grass,
## palms on the dunes and hills, rocks over both sides of the sim square (they hide the
## seam between the simulated surf and the analytic outer sea). keep_out: Rect2 in xz
## left free for the castle.
func dress_cove(keep_out: Rect2) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026
	# Small beach finds.
	var small := ["scallop", "scallop", "conch", "starfish", "pebbles", "pebbles", "scallop", "starfish"]
	var placed: Array[Vector2] = []
	var tries := 0
	while placed.size() < 34 and tries < 2000:
		tries += 1
		var p := Vector2(rng.randf_range(2.6, 17.9), rng.randf_range(6.6, 15.5))
		if keep_out.has_point(p):
			continue
		var ok := true
		for q in placed:
			if q.distance_to(p) < 0.55:
				ok = false
				break
		if not ok:
			continue
		placed.append(p)
		var name: String = small[placed.size() % small.size()]
		spawn(name, Vector3(p.x, 0.0, p.y), rng.randf_range(0.0, 360.0), rng.randf_range(0.8, 1.25))
	# Driftwood on the upper beach.
	spawn("driftwood", Vector3(4.2, 0.0, 15.6), 18.0, 1.0)
	spawn("driftwood", Vector3(15.8, 0.0, 16.4), -32.0, 0.8)
	# Dune grass tufts (inside the square: follow the sand; outside: static profile).
	for i in 46:
		var p := Vector2(rng.randf_range(-6.0, 26.5), rng.randf_range(17.0, 27.0))
		if i < 14:
			p = Vector2(rng.randf_range(1.0, 19.5), rng.randf_range(17.2, 20.2))
		var y := 0.0 if _inside(p) else Scenario.outer_height(p.x, p.y)
		spawn("grass", Vector3(p.x, y, p.y), rng.randf_range(0.0, 360.0), rng.randf_range(0.7, 1.4))
	# Palms: a loose row on the dunes plus a few on the headland hills, leaning seaward.
	var palms := [Vector2(2.5, 21.5), Vector2(6.8, 23.4), Vector2(12.8, 22.6), Vector2(17.3, 21.2),
		Vector2(21.8, 24.5), Vector2(-2.6, 24.0), Vector2(-7.5, 14.0), Vector2(-9.0, 7.5),
		Vector2(28.0, 13.0), Vector2(29.5, 6.0), Vector2(15.5, 27.0), Vector2(-4.0, 30.0)]
	for p in palms:
		var y := 0.0 if _inside(p) else Scenario.outer_height(p.x, p.y)
		var mi := spawn("palm", Vector3(p.x, y, p.y), rng.randf_range(0.0, 360.0), rng.randf_range(0.8, 1.15))
		if mi:
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# Rocks along both sides, from the surf up to the beach; base sunk into the sea floor.
	var rocks := [
		[Vector2(-0.6, 3.2), 20.0, 1.1, "rock"], [Vector2(0.3, 6.6), 75.0, 0.95, "rock"],
		[Vector2(-0.2, 9.8), 140.0, 0.8, "rock"], [Vector2(-2.6, 1.0), 0.0, 1.0, "stack"],
		[Vector2(20.9, 3.6), 200.0, 1.15, "rock"], [Vector2(20.2, 7.0), 250.0, 0.9, "rock"],
		[Vector2(20.7, 10.2), 320.0, 0.75, "rock"], [Vector2(23.4, 1.6), 60.0, 0.85, "stack"],
		[Vector2(-1.4, 12.8), 95.0, 0.6, "rock"], [Vector2(21.8, 13.2), 280.0, 0.6, "rock"],
	]
	for r in rocks:
		var p: Vector2 = r[0]
		var y := minf(Scenario.outer_height(p.x, p.y), Scenario.cove_height(clampf(p.x, 0.0, size), p.y))
		var mi := spawn(r[3], Vector3(p.x, y - 0.25, p.y), r[1], r[2], false)
		if mi:
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


func _inside(p: Vector2) -> bool:
	return p.x > 0.2 and p.y > 0.2 and p.x < size - 0.2 and p.y < size - 0.2
