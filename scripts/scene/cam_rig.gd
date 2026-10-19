class_name CamRig
extends RefCounted
## Smooth camera paths for the recorded shots. Keys (time, position, look-at, fov) are
## joined with cubic Hermite segments whose tangents come from the neighbouring keys
## divided by their time gap (non-uniform Catmull-Rom), so velocity is continuous across
## keys; the first and last keys have zero velocity (ease in / ease out). Evaluated from the
## shot clock (frames / 60), never from wall time, so recordings are jitter-free.

var keys: Array = []  ## [t, pos: Vector3, look: Vector3, fov]


func key(t: float, pos: Vector3, look: Vector3, fov := 45.0) -> CamRig:
	keys.append([t, pos, look, fov])
	return self


## Orbit keys round `center` (yaw in degrees, 0 = camera on the sea side looking +z).
func orbit(t0: float, t1: float, center: Vector3, yaw0: float, yaw1: float, dist0: float, dist1: float,
		height0: float, height1: float, fov := 45.0, n := 6) -> CamRig:
	for i in n + 1:
		var k := float(i) / n
		var yaw := deg_to_rad(lerpf(yaw0, yaw1, k))
		var d := lerpf(dist0, dist1, k)
		var p := center + Vector3(sin(yaw) * d, lerpf(height0, height1, k), -cos(yaw) * d)
		keys.append([lerpf(t0, t1, k), p, center, fov])
	return self


func duration() -> float:
	return keys[keys.size() - 1][0] if not keys.is_empty() else 0.0


## Returns [position, look_at, fov] at time t.
func eval(t: float) -> Array:
	var n := keys.size()
	if n == 1 or t <= keys[0][0]:
		return [keys[0][1], keys[0][2], keys[0][3]]
	if t >= keys[n - 1][0]:
		return [keys[n - 1][1], keys[n - 1][2], keys[n - 1][3]]
	var i := 0
	while i < n - 2 and t > keys[i + 1][0]:
		i += 1
	var t0: float = keys[i][0]
	var t1: float = keys[i + 1][0]
	var dt := t1 - t0
	var s := (t - t0) / dt
	var out := []
	for c in [1, 2, 3]:
		var p0 = keys[i][c]
		var p1 = keys[i + 1][c]
		var m0 = _tangent(i, c)
		var m1 = _tangent(i + 1, c)
		var s2 := s * s
		var s3 := s2 * s
		out.append((2.0 * s3 - 3.0 * s2 + 1.0) * p0 + (s3 - 2.0 * s2 + s) * dt * m0
			+ (-2.0 * s3 + 3.0 * s2) * p1 + (s3 - s2) * dt * m1)
	return out


func _tangent(i: int, c: int):
	var n := keys.size()
	if i == 0 or i == n - 1:
		return keys[i][c] * 0.0
	return (keys[i + 1][c] - keys[i - 1][c]) / (keys[i + 1][0] - keys[i - 1][0])
