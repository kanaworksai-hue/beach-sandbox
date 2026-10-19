// Open sea around the simulated square: the same analytic incident waves as the
// sim's wavemaker (BeachSim.waves, Eckart dispersion at the offshore depth), coloured
// like water.gdshader using the depth-buffer thickness. Discards inside the domain.
shader_type spatial;
render_mode depth_draw_always, cull_back;

#include "res://shaders/render/beach_common.gdshaderinc"

// Animation clock: rendered frames / 60 in fixed and recorded runs (main.gd),
// so moving patterns do not jitter when frames take uneven wall time.
global uniform float anim_time;
uniform sampler2D ripple_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D lace_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform float size = 20.48;
uniform float tide = 0.0;
uniform float sim_time = 0.0;
uniform float ramp = 1.0;
uniform float offshore_depth = 0.9;
uniform vec4 waves[4]; // amplitude, period, phase, angle about +Z
uniform vec3 edge_color : source_color = vec3(0.561, 0.953, 0.894);
uniform vec3 turquoise : source_color = vec3(0.106, 0.749, 0.776);
uniform vec3 mid_blue : source_color = vec3(0.086, 0.565, 0.784);
uniform vec3 deep_blue : source_color = vec3(0.051, 0.373, 0.627);
uniform vec3 sky_zenith : source_color = vec3(0.498, 0.827, 1.0);
uniform vec3 sky_horizon : source_color = vec3(0.839, 0.953, 1.0);
uniform vec3 absorption = vec3(5.0, 2.0, 1.3);  // same as water.gdshader
uniform float max_reflection = 0.3;
uniform float shallow_body = 0.18;
uniform vec3 water_tint = vec3(0.65, 0.95, 1.3); // transmitted light: a cyan push (stylized)

varying vec2 world_xz;
varying float v_thick;

float linear_depth(float raw, vec2 suv, mat4 inv_proj) {
	vec4 v = inv_proj * vec4(suv * 2.0 - 1.0, raw, 1.0);
	return -v.z / max(v.w, 1e-6);
}

// Surface elevation and its xz gradient.
vec3 sea(vec2 p) {
	vec3 r = vec3(0.0);
	for (int i = 0; i < 4; i++) {
		vec4 wv = waves[i];
		if (wv.x == 0.0) continue;
		float om = 6.28318530718 / wv.y;
		float k = om * om / (9.81 * sqrt(tanh(om * om * offshore_depth / 9.81)));
		vec2 dir = vec2(sin(wv.w), cos(wv.w));
		float ph = om * sim_time - k * dot(dir, p) + wv.z;
		r.x += wv.x * sin(ph);
		r.yz += -wv.x * k * cos(ph) * dir;
	}
	return r * ramp;
}

void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	VERTEX.y = tide + sea(world_xz).x;
}

void fragment() {
	// Inside the sim square (minus the mirror-wall ghost strips, which this sea covers).
	vec2 inside = step(vec2(0.08, 0.0), world_xz) * step(world_xz, vec2(size - 0.08));
	if (inside.x * inside.y > 0.5) discard;
	vec3 s = sea(world_xz);
	vec3 n = normalize(vec3(-s.y, 1.0, -s.z));
	vec3 rn = flow_normal(ripple_tex, world_xz, 0.9, vec2(0.0), 0.0);
	vec3 rn2 = flow_normal(ripple_tex, world_xz + vec2(0.05, 0.03) * anim_time, 2.3, vec2(0.0), 0.0);
	n = normalize(n + vec3(rn.x + rn2.x * 0.6, 0.0, rn.y + rn2.y * 0.6) * 0.12);
	NORMAL = (VIEW_MATRIX * vec4(n, 0.0)).xyz;
	float frag_ld = -VERTEX.z;
	// Vertical water depth: world height of this fragment minus the scene below it.
	vec4 sv = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, texture(depth_tex, SCREEN_UV).r, 1.0);
	vec3 scene_w = (INV_VIEW_MATRIX * vec4(sv.xyz / sv.w, 1.0)).xyz;
	vec3 frag_w = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h = max(frag_w.y - scene_w.y, 0.0);
	v_thick = h;
	if (h < 0.0008) discard;
	float shore = smoothstep(0.0008, 0.006, h);
	vec2 ruv = clamp(SCREEN_UV + NORMAL.xz * 0.05 * clamp(h / 0.1, 0.0, 1.0) * shore, vec2(0.001), vec2(0.999));
	if (linear_depth(texture(depth_tex, ruv).r, ruv, INV_PROJECTION_MATRIX) < frag_ld) ruv = SCREEN_UV;
	vec3 under = texture(screen_tex, ruv).rgb;
	float nv = clamp(dot(VIEW, NORMAL), 0.0, 1.0);
	vec3 trans = exp(-absorption * h / max(nv, 0.35));
	vec3 scat = mix(edge_color, turquoise, smoothstep(0.0, 0.18, h));
	scat = mix(scat, mid_blue, smoothstep(0.25, 0.6, h));
	scat = mix(scat, deep_blue, smoothstep(0.6, 1.0, h));
	// Even very thin water gets a little cyan body colour so puddles read as water.
	vec3 opac = max(1.0 - trans, vec3(shallow_body * smoothstep(0.001, 0.015, h)));
	vec3 col = under * (1.0 - opac) * mix(vec3(1.0), water_tint, shore) + scat * opac;
	vec3 rw = (INV_VIEW_MATRIX * vec4(reflect(-VIEW, NORMAL), 0.0)).xyz;
	vec3 sky = mix(sky_horizon, sky_zenith, smoothstep(0.0, 0.6, rw.y));
	col = mix(col, sky, min(0.02 + 0.98 * pow(1.0 - nv, 5.0), max_reflection) * shore);
	col = mix(under, col, shore);
	col = far_sea(col, h, length(VERTEX));
	float lace = texture(lace_tex, world_xz / 1.1 + vec2(0.03, 0.02) * anim_time).r;
	float foam = (1.0 - smoothstep(0.003, 0.012, h)) * smoothstep(0.3, 0.5, lace) * shore * 0.9;
	EMISSION = col * (1.0 - foam);
	ALBEDO = vec3(foam);
	ROUGHNESS = 0.8;
	SPECULAR = 0.0;
}

void light() {
	float d = toon_ramp(dot(NORMAL, LIGHT)) * ATTENUATION;
	DIFFUSE_LIGHT += LIGHT_COLOR / PI * (mix(0.65, 1.0, d) * (LIGHT_IS_DIRECTIONAL ? 1.0 : ATTENUATION));
	vec3 hv = normalize(LIGHT + VIEW);
	float g = pow(max(dot(NORMAL, hv), 0.0), 2500.0);
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * smoothstep(0.5, 0.6, g) * smoothstep(0.004, 0.02, v_thick) * 0.8;
}
