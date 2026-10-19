// Shallow water surface. M1: depth-tinted translucent water, speed = white water.
shader_type spatial;
render_mode cull_disabled, depth_draw_always;

uniform sampler2D water_tex : filter_linear, repeat_disable; // w, hu, hv, hs
uniform sampler2D bed_tex : filter_linear, repeat_disable;   // B centre ...
uniform float size = 20.48;
uniform float texel = 0.04;
uniform vec3 shallow : source_color = vec3(0.18, 0.66, 0.70);
uniform vec3 deep : source_color = vec3(0.02, 0.22, 0.42);

varying float depth;
varying float speed;
varying float silt;
varying vec2 world_xz;

void vertex() {
	world_xz = VERTEX.xz + vec2(size * 0.5);
	vec2 uv = world_xz / size;
	vec4 q = textureLod(water_tex, uv, 0.0);
	float b = textureLod(bed_tex, uv, 0.0).r;
	depth = q.r - b;
	float h = max(depth, 1e-4);
	speed = length(q.gb) / h;
	silt = q.a / h;
	VERTEX.y = depth > 0.003 ? q.r : b - 0.03;
}

float eta(vec2 xz) { return textureLod(water_tex, xz / size, 0.0).r; }

void fragment() {
	if (depth < 0.003) discard;
	float e = texel;
	float hx = eta(world_xz + vec2(e, 0.0)) - eta(world_xz - vec2(e, 0.0));
	float hz = eta(world_xz + vec2(0.0, e)) - eta(world_xz - vec2(0.0, e));
	vec3 n = normalize(vec3(-hx, 2.0 * e, -hz));
	NORMAL = (VIEW_MATRIX * vec4(n, 0.0)).xyz;
	float t = 1.0 - exp(-depth * 3.0);
	vec3 col = mix(shallow, deep, t);
	col = mix(col, vec3(0.80, 0.70, 0.52), clamp(silt * 40.0, 0.0, 0.6));
	float foam = smoothstep(1.4, 2.8, speed) * smoothstep(0.003, 0.03, depth);
	ALBEDO = mix(col, vec3(1.0), foam * 0.8);
	ALPHA = clamp(0.45 + t * 0.5 + foam * 0.5, 0.0, 0.95) * smoothstep(0.003, 0.012, depth);
	ROUGHNESS = mix(0.12, 0.6, foam);
	SPECULAR = 0.3;
}
