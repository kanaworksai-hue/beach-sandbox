class_name Shots
extends RefCounted
## Recorded shot scripts. Each shot: the castle mode, a pre-roll
## (simulated seconds fast-forwarded before the shot starts, not recorded), simulation
## steps per frame during the shot (2 = 2x time-lapse), its length in video seconds and a
## CamRig in shot time. Portrait (9:16) variants pull the camera back a little and widen the
## vertical field of view so the castle stays in the middle third.
##
##   cove      establishing crane: from the palms over the dunes down to the castle, sea and islands beyond
##   build     the bucket stamps the towers, walls rise, the spade digs the moat and channel (slow orbit)
##   wave      low side dolly at the waterline: the swash runs up the channel and fills the moat
##   collapse  2x time-lapse push-in on the seaward wall as the rising tide breaks it, then crane up
##   surge     2x time-lapse: a scripted swell (sea +5 cm, waves x2.3, faster strength
##             loss) floods the moat and knocks the walls and towers down; low sea-side push-in,
##             then crane up over the ruin
##
## Optional keys: "surge" = [[sim_t, tide_add m, wave_gain], ...] (main.gd _apply_surge; cove
## shots only, the tests never see it), "sim" = {BeachSim member: value} set at start, "tools" = false hides the bucket and spade (props
## don't float, so they would sit under the flood).
## "speed" = [[shot_t, steps], ...] (overrides "steps" from
## that shot time on). Brush edits of the tech shots (ditch / versus / pour) are scripted in
## main.gd _shot_edits() and show the brush ring like the interactive cursor.
##
##   ditch     the brush digs a pool and a channel to the sea; the swash runs up and fills it (2x)
##   versus    a packed wet wall and a loose dry pile side by side; the waves hit both (3x)
##   pour      a packed mound, then water poured uphill: it cuts a gully and the sand settles below

const NAMES := ["cove", "build", "wave", "collapse", "surge", "ditch", "versus", "pour"]

const DITCH_X := 10.24
const DITCH_Z := Vector2(11.0, 8.5)  ## pool centre z, sea end of the channel
const VERSUS_Z := 9.0
const POUR_MOUND := Vector2(14.5, 12.6)


static func make(name: String, c: Vector2, ground: float, portrait: bool) -> Dictionary:
	var C := Vector3(c.x, ground, c.y)
	var rig := CamRig.new()
	var s := {"castle": "instant", "preroll": 0.0, "steps": 1, "length": 12.0, "rig": rig}
	match name:
		"ditch":
			s.castle = "none"
			s.preroll = 6.0
			s.steps = 2
			s.length = 13.0
			s.tools = false
			var d := Vector3(DITCH_X, 0.1, 9.8)
			rig.key(0.0, d + Vector3(1.7, 1.8, 3.0), d + Vector3(0.0, 0.0, -0.2), 44.0)
			rig.key(13.0, d + Vector3(1.3, 1.45, 2.6), d + Vector3(0.0, 0.0, -0.4), 44.0)
		"versus":
			s.castle = "none"
			s.preroll = 8.0
			s.length = 16.0
			s.tools = false
			s.speed = [[0.0, 1], [4.5, 3]]
			var v := Vector3(10.24, 0.05, VERSUS_Z)
			rig.key(0.0, v + Vector3(0.0, 2.3, 3.7), v + Vector3(0.0, 0.0, -0.5), 44.0)
			rig.key(16.0, v + Vector3(0.0, 2.0, 3.3), v + Vector3(0.0, 0.0, -0.5), 44.0)
		"pour":
			s.castle = "none"
			s.preroll = 2.0
			s.length = 15.0
			s.tools = false
			var m := Vector3(POUR_MOUND.x, Scenario.cove_height(POUR_MOUND.x, POUR_MOUND.y), POUR_MOUND.y)
			rig.key(0.0, m + Vector3(1.9, 2.3, -3.2), m + Vector3(0.0, 0.05, 0.25), 42.0)
			rig.key(15.0, m + Vector3(1.4, 1.9, -2.7), m + Vector3(0.0, 0.0, 0.15), 42.0)
		"cove":
			s.preroll = 14.0
			s.length = 12.0
			rig.key(0.0, Vector3(9.4, 7.6, 29.0), Vector3(10.6, 0.0, -18.0), 50.0)
			rig.key(5.0, Vector3(9.0, 4.4, 21.0), Vector3(10.5, 0.0, -6.0), 48.0)
			rig.key(12.0, C + Vector3(-1.6, 1.25, 3.6), C + Vector3(0.2, 0.1, -1.6), 44.0)
		"build":
			s.castle = "build"
			s.length = 19.5
			rig.orbit(0.0, 19.5, C + Vector3(0.0, 0.18, 0.0), -38.0, 22.0, 3.4, 2.7, 1.7, 1.15, 42.0, 7)
		"wave":
			s.preroll = 9.0
			s.length = 14.0
			rig.key(0.0, C + Vector3(-2.8, 0.55, -1.5), C + Vector3(0.4, 0.02, -0.6), 40.0)
			rig.key(14.0, C + Vector3(-1.5, 0.45, -1.75), C + Vector3(0.2, 0.06, -0.2), 40.0)
		"collapse":
			s.preroll = 40.0
			s.steps = 2
			s.length = 22.0
			rig.key(0.0, C + Vector3(0.9, 0.5, -2.6), C + Vector3(0.0, 0.14, 0.0), 40.0)
			rig.key(15.0, C + Vector3(0.35, 0.36, -1.55), C + Vector3(0.0, 0.12, 0.0), 40.0)
			rig.key(22.0, C + Vector3(0.05, 3.2, -0.6), C + Vector3(0.0, 0.0, 0.0), 46.0)
		"surge":
			s.preroll = 20.0
			s.steps = 2
			s.length = 14.0
			s.tools = false
			s.surge = [[14.0, 0.0, 1.0], [24.0, 0.05, 2.3]]
			# Storm-battered sand gives way faster (walls test untouched: shot-only).
			s.sim = {"strength_loss": 0.12, "impact_k": 1.5, "soak_weakening": 0.03}
			rig.key(0.0, C + Vector3(1.3, 0.7, -3.0), C + Vector3(0.0, 0.16, 0.0), 40.0)
			rig.key(9.5, C + Vector3(0.55, 0.62, -2.1), C + Vector3(0.0, 0.12, 0.0), 40.0)
			rig.key(14.0, C + Vector3(0.1, 2.9, -1.3), C + Vector3(0.0, 0.0, 0.1), 46.0)
		_:
			push_error("unknown shot " + name)
	if portrait:
		for k in rig.keys:
			k[1] = k[2] + (k[1] - k[2]) * 1.45
			k[3] = k[3] * 1.3
	return s
