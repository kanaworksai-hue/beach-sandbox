// Distant cartoon islands: a squashed hemisphere with lumpy noise, sand rim at the
// waterline, two greens above, faded into the horizon haze with distance.
shader_type spatial;
render_mode cull_back;

#include "res://shaders/render/beach_common.gdshaderinc"

uniform sampler2D grain_tex : filter_linear_mipmap, repeat_enable;
uniform vec3 sand_color : source_color = vec3(0.957, 0.824, 0.612);
uniform vec3 green_a : source_color = vec3(0.420, 0.722, 0.310);
uniform vec3 green_b : source_color = vec3(0.243, 0.553, 0.353);
uniform vec3 haze_color : source_color = vec3(0.80, 0.93, 0.99);
uniform float haze = 0.55;
uniform float seed = 0.0;
uniform vec3 shadow_fill = vec3(0.30, 0.22, 0.32);

varying vec3 wp;

void vertex() {
	vec3 p = VERTEX;
	float n = textureLod(grain_tex, p.xz * 0.35 + seed, 0.0).r - 0.5;
	float n2 = textureLod(grain_tex, p.xz * 1.3 + seed * 1.7, 0.0).r - 0.5;
	// Lumps grow with height so the rim stays round.
	VERTEX = p * (1.0 + (n * 0.35 + n2 * 0.12) * smoothstep(0.0, 0.4, p.y));
	VERTEX.y = max(VERTEX.y, 0.0) * (1.0 + n * 0.6) - 0.02;
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float g = smoothstep(0.9, 1.6, wp.y);
	float n = texture(grain_tex, wp.xz * 0.05).r;
	vec3 col = mix(sand_color, mix(green_b, green_a, smoothstep(0.35, 0.7, n + wp.y * 0.03)), g);
	float dist = length(wp - CAMERA_POSITION_WORLD);
	col = mix(col, haze_color, haze * (1.0 - exp(-dist * 0.004)));
	ALBEDO = col;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	float d = toon_ramp(dot(NORMAL, LIGHT)) * ATTENUATION;
	if (LIGHT_IS_DIRECTIONAL) {
		DIFFUSE_LIGHT += LIGHT_COLOR / PI * (d + (1.0 - d) * mix(shadow_fill, vec3(0.7, 0.8, 0.9), haze * 0.6));
	} else {
		DIFFUSE_LIGHT += LIGHT_COLOR / PI * ATTENUATION * toon_ramp(dot(NORMAL, LIGHT));
	}
}
