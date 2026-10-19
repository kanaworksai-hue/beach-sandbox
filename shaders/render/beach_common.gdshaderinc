// Shared helpers for the BeachSandbox render shaders.

// Soft two-tone sun ramp: flat bright lit side, narrow soft terminator, a little
// of the Lambert falloff kept so slopes still read.
float toon_ramp(float ndl) {
	return smoothstep(-0.02, 0.18, ndl) * 0.5 + 0.5 * clamp(ndl, 0.0, 1.0);
}

// Two-phase flow-map sample (Vlachos 2010): xz world metres, scale metres per tile,
// disp = capped flow displacement over one cycle (m), t = cycles (per-pixel offset added).
float flow_sample(sampler2D tex, vec2 xz, float scale, vec2 disp, float t) {
	float p0 = fract(t);
	float p1 = fract(t + 0.5);
	float w = abs(2.0 * p0 - 1.0); // 1 when layer 0 restarts
	vec2 j0 = vec2(0.24, 0.21) * floor(t);
	vec2 j1 = vec2(0.24, 0.21) * floor(t + 0.5) + 0.5;
	float a = texture(tex, (xz - disp * (p0 - 0.5)) / scale + j0).r;
	float b = texture(tex, (xz - disp * (p1 - 0.5)) / scale + j1).r;
	return mix(a, b, w);
}

vec3 flow_normal(sampler2D tex, vec2 xz, float scale, vec2 disp, float t) {
	float p0 = fract(t);
	float p1 = fract(t + 0.5);
	float w = abs(2.0 * p0 - 1.0);
	vec2 j0 = vec2(0.24, 0.21) * floor(t);
	vec2 j1 = vec2(0.24, 0.21) * floor(t + 0.5) + 0.5;
	vec3 a = texture(tex, (xz - disp * (p0 - 0.5)) / scale + j0).rgb * 2.0 - 1.0;
	vec3 b = texture(tex, (xz - disp * (p1 - 0.5)) / scale + j1).rgb * 2.0 - 1.0;
	return mix(a, b, w);
}

// Deep water far from the camera converges to one saturated sea blue that brightens to a
// haze towards the horizon. Used by both the sim water and the outer analytic sea, so the
// edge of the sim square disappears in wide shots. h = water depth (m), dist = view distance (m).
vec3 far_sea(vec3 col, float h, float dist) {
	vec3 sea_blue = vec3(0.071, 0.380, 0.741);   // #1261BD (linear-ish, matches deep_blue family)
	vec3 haze = vec3(0.55, 0.80, 0.93);
	vec3 target = mix(sea_blue, haze, smoothstep(60.0, 320.0, dist));
	float k = smoothstep(5.0, 28.0, dist) * smoothstep(0.3, 0.75, h);
	return mix(col, target, k);
}

// Foam bubbles from the 1 cm particle splat texture. Near: threshold the
// bilinear splat into round bubbles (cut = splat value where a bubble starts). When a
// pixel spans several bubbles, average 4 taps over its footprint instead (box filter),
// so dense foam stays white and sparse specks fade to a faint tint without aliasing.
float foam_bubbles(sampler2D tex, vec2 xz, float size, float cut) {
	vec2 dx = dFdx(xz), dy = dFdy(xz);
	float fp = sqrt(max(length(dx) * length(dy), 1e-10)); // metres per pixel (geometric mean)
	float near = 1.0 - smoothstep(0.007, 0.016, fp);
	float c = texture(tex, xz / size).r;
	float bub = smoothstep(cut, cut + 0.2, c);
	if (near > 0.999) return bub;
	float avg = 0.0;
	avg += texture(tex, (xz + 0.3 * dx + 0.3 * dy) / size).r;
	avg += texture(tex, (xz - 0.3 * dx + 0.3 * dy) / size).r;
	avg += texture(tex, (xz + 0.3 * dx - 0.3 * dy) / size).r;
	avg += texture(tex, (xz - 0.3 * dx - 0.3 * dy) / size).r;
	float cov = clamp((avg * 0.25 + c * 0.25) * 2.2 * clamp(0.012 / fp, 0.35, 1.0) * 2.2, 0.0, 1.0);
	return mix(cov, bub, near);
}
