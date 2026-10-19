// Meshy props (shells, starfish, pebbles, driftwood, palms, rocks, bucket ...).
// Same toon light as the sand. Props on the sim square follow the live sand surface on
// the GPU: the whole mesh is lifted to the sand height under its origin (minus `sink`,
// so it sits a little buried) and optionally tilted to the local slope, every frame and
// also in the shadow pass, so nothing floats when the sand under it is washed away.
// Wet look: darker and glossier below the water surface and in a band above wet sand.
shader_type spatial;
render_mode world_vertex_coords, cull_back;

#include "res://shaders/render/beach_common.gdshaderinc"

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D sand_tex : filter_linear, repeat_disable;   // height, wetness, strength, freshness
uniform sampler2D water_tex : filter_linear, repeat_disable;  // w, hu, hv, hs
uniform sampler2D bed_tex : filter_linear, repeat_disable;
uniform float size = 20.48;
uniform vec3 shadow_fill = vec3(0.30, 0.22, 0.32);
uniform vec3 rim_color : source_color = vec3(0.84, 0.95, 1.0);
uniform vec3 albedo_tint = vec3(1.0);
uniform float saturation = 1.08;
uniform float posterize = 0.0;     // > 0: quantize albedo value into this many steps
uniform float wet_darken = 0.62;
uniform float distance_tint = 0.0; // far props (islands) blend toward the horizon haze
uniform vec3 haze_color : source_color = vec3(0.78, 0.92, 0.98);

instance uniform float snap = 0.0;  // 1: follow the sim sand height under the origin
instance uniform float tilt = 0.0;  // 0..1: align to the sand normal (small props)
instance uniform float sink = 0.0;  // m below the sand surface
instance uniform float foot = 0.1;  // m, radius used for the slope
instance uniform float wet_band = 0.04; // m above wet sand that gets darkened

varying vec3 world_pos;
varying float v_sand_wet;

float sand_h(vec2 xz) { return textureLod(sand_tex, xz / size, 0.0).r; }

bool inside(vec2 xz) { return all(greaterThan(xz, vec2(0.1))) && all(lessThan(xz, vec2(size - 0.1))); }

void vertex() {
	vec3 pivot = NODE_POSITION_WORLD;
	v_sand_wet = 0.0;
	if (snap > 0.5 && inside(pivot.xz)) {
		float h = sand_h(pivot.xz);
		v_sand_wet = textureLod(sand_tex, pivot.xz / size, 0.0).g;
		float e = max(foot, 0.03);
		vec3 n = normalize(vec3(sand_h(pivot.xz - vec2(e, 0.0)) - sand_h(pivot.xz + vec2(e, 0.0)), 2.0 * e,
			sand_h(pivot.xz - vec2(0.0, e)) - sand_h(pivot.xz + vec2(0.0, e))));
		n = normalize(mix(vec3(0.0, 1.0, 0.0), n, tilt));
		// Rotation taking +Y to n (Rodrigues about axis Y x n).
		vec3 ax = vec3(n.z, 0.0, -n.x);
		float s = length(ax);
		float c = n.y;
		mat3 R = mat3(1.0);
		if (s > 1e-4) {
			ax /= s;
			mat3 K = mat3(vec3(0.0, ax.z, -ax.y), vec3(-ax.z, 0.0, ax.x), vec3(ax.y, -ax.x, 0.0));
			R = mat3(1.0) + s * K + (1.0 - c) * K * K;
		}
		VERTEX = pivot + R * (VERTEX - pivot);
		VERTEX.y += h - sink - pivot.y;
		NORMAL = R * NORMAL;
		TANGENT = R * TANGENT;
		BINORMAL = R * BINORMAL;
	}
	world_pos = VERTEX;
}

void fragment() {
	vec3 col = texture(albedo_tex, UV).rgb * albedo_tint;
	float l = dot(col, vec3(0.299, 0.587, 0.114));
	col = max(mix(vec3(l), col, saturation), 0.0);
	if (posterize > 0.0) {
		float lq = (floor(l * posterize) + 0.5) / posterize;
		col *= mix(1.0, lq / max(l, 1e-3), 0.6);
	}
	// Wetness: below the sim water surface, or a band just above wet sand.
	float wet = 0.0;
	if (inside(world_pos.xz)) {
		vec2 uv = world_pos.xz / size;
		float w = texture(water_tex, uv).r;
		float b = texture(bed_tex, uv).r;
		float sh = sand_h(world_pos.xz);
		float covered = (w - b > 0.003) ? 1.0 - smoothstep(w - 0.005, w + 0.01, world_pos.y) : 0.0;
		float sw = max(texture(sand_tex, uv).g, v_sand_wet);
		float band = smoothstep(0.35, 0.9, sw) * (1.0 - smoothstep(sh + wet_band * 0.5, sh + wet_band, world_pos.y));
		wet = max(covered, band);
	}
	col *= mix(1.0, wet_darken, wet);
	float dist = length(world_pos - CAMERA_POSITION_WORLD);
	col = mix(col, haze_color, distance_tint * (1.0 - exp(-dist * 0.004)));
	ALBEDO = col;
	ROUGHNESS = mix(0.85, 0.35, wet);
	SPECULAR = mix(0.1, 0.35, wet);
	// Cool rim so props separate from the sand (stylized, no outline).
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	EMISSION = rim_color * rim * 0.12 * (1.0 - distance_tint);
}

void light() {
	float d = toon_ramp(dot(NORMAL, LIGHT)) * ATTENUATION;
	if (LIGHT_IS_DIRECTIONAL) {
		DIFFUSE_LIGHT += LIGHT_COLOR / PI * (d + (1.0 - d) * shadow_fill);
	} else {
		DIFFUSE_LIGHT += LIGHT_COLOR / PI * ATTENUATION * toon_ramp(dot(NORMAL, LIGHT));
	}
}
