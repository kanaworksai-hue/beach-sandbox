// Sand skirt around the simulated 20.48 m square (static, analytic beach profile
// matching Scenario.beach_height), so the edges of the sim domain are not visible.
// Same palette / lighting as terrain.gdshader; discards inside the sim domain.
shader_type spatial;
render_mode cull_back;

#include "res://shaders/render/beach_common.gdshaderinc"

// Animation clock: rendered frames / 60 in fixed and recorded runs (main.gd),
// so moving patterns do not jitter when frames take uneven wall time.
global uniform float anim_time;
uniform sampler2D grain_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D cell_tex : filter_linear_mipmap, repeat_enable;
uniform float size = 20.48;
uniform float tide = 0.0;
uniform vec3 dry_color : source_color = vec3(0.957, 0.824, 0.612);   // #F4D29C
uniform vec3 damp_color : source_color = vec3(0.851, 0.659, 0.424);  // #D9A86C
uniform vec3 wet_color : source_color = vec3(0.753, 0.580, 0.416);   // #C0946A
uniform vec3 shadow_fill = vec3(0.30, 0.22, 0.32);
uniform bool cove = false;  // cove profile (Scenario.cove_height) + headland hills outside
uniform vec3 grass_color : source_color = vec3(0.553, 0.769, 0.329);  // #8DC454
uniform vec3 grass_dark : source_color = vec3(0.333, 0.620, 0.322);   // #559E52

varying vec2 world_xz;
varying float v_caustic;

float base_profile(float z) {
	float b;
	if (z < 2.2) b = -0.9 + min(z, 0.0) * 0.04;
	else if (z < 8.0) { float t = (z - 2.2) / 5.8; b = -0.9 * (1.0 - t) * (1.0 - 0.35 * t); }
	else b = 0.05 * (min(z, 26.0) - 8.0) + 0.02 * max(z - 26.0, 0.0);
	return b;
}

// 0..1: grassy headland hills beyond the sim square's sides (cove only).
float hill(vec2 xz) {
	float ax = abs(xz.x - 10.24) / 10.24;
	return smoothstep(1.0, 1.6, ax) * smoothstep(-4.0, 6.0, xz.y);
}

float profile(vec2 xz) {
	float z = xz.y;
	float b;
	if (cove) {
		float ax = abs(xz.x - 10.24) / 10.24;
		float zz = z + 1.6 * pow(min(ax, 1.0), 2.5) * (1.0 - smoothstep(13.0, 19.0, z));
		b = base_profile(zz) + 0.12 * smoothstep(9.4, 11.6, zz) + 0.45 * smoothstep(15.0, 24.0, z);
		// Rounded hills: rise from the beach, gentle noise so they are not a ramp.
		float hl = hill(xz);
		b += hl * (2.2 + 0.6 * sin(xz.y * 0.11 + xz.x * 0.05) + 0.4 * sin(xz.x * 0.23 - xz.y * 0.07));
		return max(b, -3.0);
	}
	if (z < 2.2) b = -0.9 + min(z, 0.0) * 0.04;
	else if (z < 8.0) { float t = (z - 2.2) / 5.8; b = -0.9 * (1.0 - t) * (1.0 - 0.35 * t); }
	else b = 0.05 * (min(z, 26.0) - 8.0) + 0.02 * max(z - 26.0, 0.0);
	b += 0.12 * smoothstep(9.4, 11.6, z);
	b = max(b, -3.0);
	return b;
}

void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	VERTEX.y = profile(world_xz);
	// Vertices inside the sim square sink below it, so the strip drawn just inside the
	// edge (see fragment) closes any crack between the two surfaces.
	vec2 inside = step(vec2(0.01), world_xz) * step(world_xz, vec2(size - 0.01));
	VERTEX.y -= 0.05 * inside.x * inside.y;
}

void fragment() {
	vec2 inside = step(vec2(0.08), world_xz) * step(world_xz, vec2(size - 0.08));
	if (inside.x * inside.y > 0.5) discard;
	// The seam strip just inside the edge is only needed above the water line.
	vec2 in0 = step(vec2(0.0), world_xz) * step(world_xz, vec2(size));
	if (in0.x * in0.y > 0.5 && profile(world_xz) < tide - 0.03) discard;
	float e = 0.1;
	float hx = profile(world_xz + vec2(e, 0.0)) - profile(world_xz - vec2(e, 0.0));
	float hz = profile(world_xz + vec2(0.0, e)) - profile(world_xz - vec2(0.0, e));
	vec3 n = normalize(vec3(-hx, 2.0 * e, -hz));
	float h0 = profile(world_xz);
	float above = h0 - tide;
	float wet = above > 0.0 ? clamp(1.0 - above / 0.35, 0.0, 1.0) * 0.9 : 1.0;
	float grain = mix(texture(grain_tex, world_xz * 3.1).r, texture(grain_tex, world_xz * 11.3 + 0.37).r, 0.5) - 0.5;
	vec3 col = mix(dry_color, damp_color, smoothstep(0.08, 0.5, wet));
	col = mix(col, wet_color, smoothstep(0.5, 0.95, wet));
	col *= 1.0 + grain * 0.2;
	if (cove) {
		// Grass on the hills (above the sand line), darker in the folds.
		float g = smoothstep(0.75, 1.1, h0) * smoothstep(0.2, 0.6, hill(world_xz));
		float gn = texture(grain_tex, world_xz * 0.07).r;
		vec3 gc = mix(grass_dark, grass_color, smoothstep(0.3, 0.75, gn + n.y * 0.3));
		col = mix(col, gc * (1.0 + grain * 0.15), g);
	}
	float wd = max(tide - h0, 0.0);
	float c1 = texture(cell_tex, world_xz / 0.55 + vec2(0.11, 0.07) * anim_time).r;
	float c2 = texture(cell_tex, world_xz / 0.55 * 1.27 + vec2(-0.08, 0.10) * anim_time + 0.5).r;
	v_caustic = pow(1.0 - min(c1, c2), 6.0) * 0.9 * smoothstep(0.004, 0.04, wd) * exp(-wd * 2.2)
		* (1.0 - smoothstep(25.0, 45.0, length(VERTEX)));
	ALBEDO = col;
	NORMAL = (VIEW_MATRIX * vec4(n, 0.0)).xyz;
	ROUGHNESS = 0.9;
	SPECULAR = 0.15;
}

void light() {
	float d = toon_ramp(dot(NORMAL, LIGHT)) * ATTENUATION;
	if (LIGHT_IS_DIRECTIONAL) {
		DIFFUSE_LIGHT += LIGHT_COLOR / PI * (d * (1.0 + v_caustic) + (1.0 - d) * shadow_fill);
	} else {
		DIFFUSE_LIGHT += LIGHT_COLOR / PI * ATTENUATION * toon_ramp(dot(NORMAL, LIGHT));
	}
}
