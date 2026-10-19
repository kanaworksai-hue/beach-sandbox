class_name Backdrop
extends Node3D
## Far scenery for the cove: two cartoon islands with palms out at sea and puffy
## cumulus clouds (sphere clusters) low over the horizon all round, for parallax in moves.


func build(props: Props, grain: Texture2D, sun_dir: Vector3) -> void:
	var islands := [
		[Vector3(-70.0, 0.0, -200.0), Vector3(46.0, 13.0, 30.0), 0.3, 3],
		[Vector3(95.0, 0.0, -260.0), Vector3(30.0, 8.0, 22.0), 1.7, 2],
		[Vector3(25.0, 0.0, -275.0), Vector3(14.0, 4.5, 10.0), 4.1, 1],
	]
	for d in islands:
		var m := SphereMesh.new()
		m.is_hemisphere = true
		m.radius = 1.0
		m.height = 1.0
		m.radial_segments = 48
		m.rings = 12
		var mat := ShaderMaterial.new()
		mat.shader = preload("res://shaders/render/island.gdshader")
		mat.set_shader_parameter("grain_tex", grain)
		mat.set_shader_parameter("seed", d[2])
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.material_override = mat
		mi.position = d[0]
		mi.scale = d[1]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		# A few big palms on the island (silhouettes).
		for k in d[3]:
			var off := Vector3((k - (d[3] - 1) * 0.5) * d[1].x * 0.35, 0.0, d[1].z * 0.1 * k)
			var p: Vector3 = d[0] + off
			var top: float = d[1].y * 0.9
			var pm := props.spawn("palm", Vector3(p.x, top - 1.5, p.z), 40.0 * k + d[2] * 30.0, 2.6, false)
			if pm:
				pm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pmat := props.material("palm")
	if pmat:
		pmat.set_shader_parameter("distance_tint", 0.55)

	var cmat := ShaderMaterial.new()
	cmat.shader = preload("res://shaders/render/cloud.gdshader")
	cmat.set_shader_parameter("sun_dir", sun_dir)
	var sphere := SphereMesh.new()
	sphere.radial_segments = 24
	sphere.rings = 12
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	# Clouds over the sea (seen from the beach) and over the land (seen from the sea).
	var spots := [
		Vector3(-160, 48, -260), Vector3(-40, 62, -330), Vector3(70, 40, -300), Vector3(190, 55, -250),
		Vector3(130, 75, -380), Vector3(-230, 44, -150), Vector3(260, 42, -120),
		Vector3(-120, 50, 220), Vector3(40, 58, 260), Vector3(180, 46, 200), Vector3(-260, 52, 60),
	]
	for c in spots:
		var cloud := Node3D.new()
		cloud.position = c
		cloud.rotation.y = rng.randf_range(0.0, TAU)
		var w := rng.randf_range(26.0, 44.0)
		var puffs := rng.randi_range(6, 9)
		for i in puffs:
			var s := MeshInstance3D.new()
			s.mesh = sphere
			s.material_override = cmat
			s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var x := (float(i) / (puffs - 1) - 0.5) * w
			var r := w * 0.22 * (1.0 - 0.55 * absf(x) / (w * 0.5)) * rng.randf_range(0.85, 1.2)
			s.position = Vector3(x, r * 0.35 + rng.randf_range(-1.0, 1.0), rng.randf_range(-4.0, 4.0))
			s.scale = Vector3(r * 2.0, r * 1.7, r * 1.7)
			cloud.add_child(s)
		# Flat-ish base: a wide squashed puff under the cluster.
		var base := MeshInstance3D.new()
		base.mesh = sphere
		base.material_override = cmat
		base.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		base.scale = Vector3(w * 1.05, w * 0.18, w * 0.4)
		cloud.add_child(base)
		add_child(cloud)
