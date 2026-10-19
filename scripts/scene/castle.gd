class_name Castle
extends RefCounted
## A sandcastle made with the sim's brushes: bucket-mould towers (BeachSim.stamp), packed
## walls between them (a row of small stamps), a moat dug round it and a channel to the
## sea, so the waves fill the moat and then break the walls. Either built at once
## (build_instant) or as a timed sequence driven by update() with the bucket and spade props
## animated over the sand (the "build" shot).

var center := Vector2(10.24, 10.0)
var ground := 0.0
## Each op: {t, kind: "stamp"|"dig", pos: Vector2, r, top (stamp, absolute) / depth (dig), frac, tool}
var ops: Array = []
var _next := 0
var duration := 0.0
var bucket_height := 0.3   ## height of the bucket prop at bucket_scale0 (set by the shot)
var bucket_scale0 := 1.0


func _init(c: Vector2) -> void:
	center = c
	ground = Scenario.cove_height(c.x, c.y)
	_plan()


func _plan() -> void:
	var t := 1.0
	# Bucket towers: four corners, then the keep and a small turret on top of it.
	var corners := [Vector2(-0.6, -0.42), Vector2(0.6, -0.42), Vector2(0.6, 0.42), Vector2(-0.6, 0.42)]
	for c in corners:
		_op(t, "stamp", center + c, 0.19, ground + 0.30, 0.55, "bucket")
		t += 1.25
	_op(t, "stamp", center, 0.28, ground + 0.38, 0.6, "bucket")
	t += 1.25
	_op(t, "stamp", center, 0.15, ground + 0.56, 0.5, "bucket", ground + 0.38)
	t += 1.4
	# Walls tower to tower, piled and patted along the line (spade).
	for i in 4:
		var a: Vector2 = center + corners[i]
		var b: Vector2 = center + corners[(i + 1) % 4]
		var n := int(a.distance_to(b) / 0.04)
		for k in range(1, n):
			var p := a.lerp(b, float(k) / n)
			_op(t + 0.7 * k / n, "stamp", p, 0.12, ground + 0.19, 0.45, "spade")
		t += 0.85
	t += 0.4
	# Moat: an ellipse round the castle, then the channel down to the sea.
	var m := 72
	for k in m + 1:
		var a := TAU * k / m - PI * 0.5
		var p := center + Vector2(cos(a) * 1.18, sin(a) * 0.98)
		_op(t + 3.2 * k / m, "dig", p, 0.17, 0.028, 0.0, "spade")
	t += 3.4
	var start := center + Vector2(0.0, -0.98)
	var end := Vector2(center.x + 0.15, 8.1)  # stops above the still water: only swash fills it
	var nc := int(start.distance_to(end) / 0.05)
	for k in nc + 1:
		var p := start.lerp(end, float(k) / nc)
		_op(t + 1.8 * k / nc, "dig", p, 0.15, 0.03 * smoothstep(0.0, 0.25, 1.0 - float(k) / nc) + 0.012, 0.0, "spade")
	t += 2.0
	duration = t


func _op(t: float, kind: String, pos: Vector2, r: float, v: float, frac: float, tool: String, base := ground) -> void:
	ops.append({"t": t, "kind": kind, "pos": pos, "r": r, "v": v, "frac": frac, "tool": tool, "base": base})


func _apply(sim: BeachSim, o: Dictionary) -> void:
	if o.kind == "stamp":
		sim.stamp(o.pos, o.r, o.v, o.frac)
	else:
		sim.dig(o.pos, o.r, o.v, 1.0)


func build_instant(sim: BeachSim) -> void:
	for o in ops:
		_apply(sim, o)
	_next = ops.size()


## Pose the bucket and spade for time t without applying any brush op.
func pose_tools(t: float, bucket: Node3D, spade: Node3D) -> void:
	if bucket:
		_pose_bucket(bucket, t)
	if spade:
		_pose_spade(spade, t)


## Timed build: apply every op up to time t, and pose the tools (may be null).
func update(sim: BeachSim, t: float, bucket: Node3D, spade: Node3D) -> void:
	while _next < ops.size() and ops[_next].t <= t:
		_apply(sim, ops[_next])
		_next += 1
	if bucket:
		_pose_bucket(bucket, t)
	if spade:
		_pose_spade(spade, t)


## Bucket: flies to each tower upside down, presses down over the spot (the stamp lands at
## the bottom of the press), lifts off; parks beside the castle afterwards. The bucket is
## scaled to the height of each tower (the mesh origin is its bottom centre).
func _pose_bucket(b: Node3D, t: float) -> void:
	var stamps := ops.filter(func(o): return o.tool == "bucket")
	# Parked on the sand at its own spot: the beach there is ~11 cm above the castle ground.
	var rest := Vector3(center.x + 1.9, 0.0, center.y + 0.9)
	rest.y = Scenario.cove_height(rest.x, rest.z)
	var pos := rest
	var flip := 0.0
	var hgt := 0.30
	var prev_top := rest
	for i in stamps.size():
		var o: Dictionary = stamps[i]
		var base: float = o.base
		var h: float = o.v - base
		var down := Vector3(o.pos.x, base + h, o.pos.y)  # upside down: origin (old bottom) on top
		var above := down + Vector3(0.0, 0.35, 0.0)
		var t0: float = o.t - 0.9
		if t < t0:
			break
		hgt = h
		if t < o.t - 0.35:
			var k := smoothstep(t0, o.t - 0.35, t)
			pos = prev_top.lerp(above, k) + Vector3(0.0, 0.2 * sin(PI * k), 0.0)
			flip = k if i == 0 else 1.0
		elif t < o.t:
			pos = above.lerp(down, smoothstep(o.t - 0.35, o.t, t))
			flip = 1.0
		else:
			pos = down.lerp(above, smoothstep(o.t, o.t + 0.3, t))
			flip = 1.0
		prev_top = above
	var last: Dictionary = stamps[stamps.size() - 1]
	if t > last.t + 0.3:
		var k := smoothstep(last.t + 0.3, last.t + 1.3, t)
		pos = prev_top.lerp(rest, k) + Vector3(0.0, 0.3 * sin(PI * k), 0.0)
		flip = 1.0 - k
		hgt = lerpf(hgt, 0.30, k)
	b.position = pos
	b.rotation = Vector3(PI * flip, 0.0, 0.0)
	b.scale = Vector3.ONE * (hgt / bucket_height) * bucket_scale0


## Spade: pats along each wall as it rises, then digs the moat and the channel, lying on
## the sand next to the castle before and after. The mesh lies along x with the blade at -x
## and its origin at the middle; tilting about z puts the blade tip on the work point.
func _pose_spade(s: Node3D, t: float) -> void:
	var dig := ops.filter(func(o): return o.tool == "spade")
	var rest := Vector3(center.x - 1.6, 0.0, center.y + 1.1)
	rest.y = Scenario.cove_height(rest.x, rest.z) + 0.02  # origin mid-thickness
	var rest_yaw := 0.5
	var t_start: float = dig[0].t
	var t_end: float = dig[dig.size() - 1].t
	var half := 0.5 * s.scale.x  # half length (normalized mesh: longest side 1)
	if t < t_start - 0.8 or t > t_end + 1.2:
		s.position = rest
		s.rotation = Vector3(0.0, rest_yaw, 0.0)
		return
	var idx := 0
	for i in dig.size():
		if dig[i].t <= t:
			idx = i
	var o: Dictionary = dig[idx]
	var o2: Dictionary = dig[mini(idx + 1, dig.size() - 1)]
	var k := clampf((t - o.t) / maxf(o2.t - o.t, 1e-3), 0.0, 1.0) if o2.kind == o.kind else 0.0
	var p: Vector2 = o.pos.lerp(o2.pos, k)
	var y: float = (o.v + 0.01) if o.kind == "stamp" else ground - 0.02
	var bob := 0.03 * absf(sin(t * 9.0)) if o.kind == "stamp" else 0.015 * absf(sin(t * 13.0))
	var tilt := 0.9 if o.kind == "stamp" else 1.05
	var yaw := 2.4  # handle pointing back towards the land-side camera
	var b := Basis(Vector3.UP, yaw) * Basis(Vector3(0, 0, 1), tilt)
	var work := Vector3(p.x, y + bob, p.y) - b * Vector3(-half, 0.0, 0.0)
	var lead := clampf((t - (t_start - 0.8)) / 0.8, 0.0, 1.0) * (1.0 - clampf((t - t_end) / 1.2, 0.0, 1.0))
	var e := smoothstep(0.0, 1.0, lead)
	s.position = rest.lerp(work, e) + Vector3(0.0, 0.25 * sin(PI * e) * (1.0 - e), 0.0)
	s.basis = Basis(Vector3.UP, rest_yaw).slerp(b, e).scaled(Vector3.ONE * s.scale.x)
