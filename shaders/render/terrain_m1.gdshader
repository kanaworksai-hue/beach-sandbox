// Sand heightfield. M1: readable debug look (dry -> wet colour, slope shading).
shader_type spatial;
render_mode cull_back;

uniform sampler2D sand_tex : filter_linear, repeat_disable;
uniform float size = 20.48;
uniform float texel = 0.02;
uniform vec3 dry_color : source_color = vec3(0.84, 0.74, 0.55);
uniform vec3 wet_color : source_color = vec3(0.52, 0.40, 0.26);

varying vec2 world_xz;

float hgt(vec2 xz) { return textureLod(sand_tex, xz / size, 0.0).r; }

void vertex() {
	world_xz = VERTEX.xz + vec2(size * 0.5);
	VERTEX.y = hgt(world_xz);
}

void fragment() {
	float e = texel;
	float hx = hgt(world_xz + vec2(e, 0.0)) - hgt(world_xz - vec2(e, 0.0));
	float hz = hgt(world_xz + vec2(0.0, e)) - hgt(world_xz - vec2(0.0, e));
	vec3 n = normalize(vec3(-hx, 2.0 * e, -hz));
	NORMAL = (VIEW_MATRIX * vec4(n, 0.0)).xyz;
	float w = textureLod(sand_tex, world_xz / size, 0.0).g;
	ALBEDO = mix(dry_color, wet_color, smoothstep(0.05, 0.9, w));
	ROUGHNESS = mix(0.95, 0.55, w);
}
