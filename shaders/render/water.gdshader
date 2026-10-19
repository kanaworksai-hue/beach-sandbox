// Shallow-water surface, cartoon look.
// Colour by sim depth (clear cyan at the edge -> turquoise -> deep blue) composited
// over the refracted screen (the sand with its caustics), salt-like foam bubbles from the
// foam particles, a crisp line along every waterline, flow-advected ripple
// normals, a capped stylized sky reflection and a hard toon sun glint.
// Built-in specular / sky radiance is off (SPECULAR = 0) so the water never washes
// out to white; the surface converges to the background pixel as depth -> 0.
shader_type spatial;
render_mode depth_draw_always, cull_back;

#include "res://shaders/render/beach_common.gdshaderinc"

// Animation clock: rendered frames / 60 in fixed and recorded runs (main.gd),
// so moving patterns do not jitter when frames take uneven wall time.
global uniform float anim_time;
uniform sampler2D water_tex : filter_linear, repeat_disable; // w, hu, hv, hs
uniform sampler2D bed_tex : filter_linear, repeat_disable;   // B centre ...
uniform sampler2D fx_tex : filter_linear, repeat_disable;    // foam, prev w, stranded, aeration
uniform sampler2D foam_tex : filter_linear, repeat_disable;  // foam bubble splats, 1 cm (size 0..1)
uniform sampler2D lace_tex : filter_linear_mipmap, repeat_enable;   // cellular F2-F1
uniform sampler2D ripple_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D grain_tex : filter_linear_mipmap, repeat_enable;  // phase noise
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform float size = 20.48;
uniform float texel = 0.04;

uniform vec3 edge_color : source_color = vec3(0.561, 0.953, 0.894);   // #8FF3E4
uniform vec3 turquoise : source_color = vec3(0.106, 0.749, 0.776);    // #1BBFC6
uniform vec3 mid_blue : source_color = vec3(0.086, 0.565, 0.784);     // #1690C8
uniform vec3 deep_blue : source_color = vec3(0.051, 0.373, 0.627);    // #0D5FA0
uniform vec3 sky_zenith : source_color = vec3(0.498, 0.827, 1.0);     // #7FD3FF
uniform vec3 sky_horizon : source_color = vec3(0.839, 0.953, 1.0);    // #D6F3FF
uniform vec3 foam_color : source_color = vec3(1.0);
uniform vec3 absorption = vec3(5.0, 2.0, 1.3);  // per metre: reds die first
uniform float refraction = 0.05;
uniform float max_reflection = 0.3;
uniform float shallow_body = 0.18;
uniform vec3 water_tint = vec3(0.65, 0.95, 1.3); // transmitted light: a cyan push (stylized)
uniform float ripple_strength = 0.35;
uniform float silt_tint = 1.5;
uniform float aer_gain = 0.35;
uniform float bubble_cut = 0.3;   // splat value where a bubble starts (higher = smaller bubbles)
uniform float line_px = 2.5;      // waterline width in pixels

varying vec2 world_xz;
varying float v_depth;
varying float v_foam;

float eta(vec2 xz) { return textureLod(water_tex, xz / size, 0.0).r; }

float linear_depth(float raw, vec2 suv, mat4 inv_proj) {
	vec4 v = inv_proj * vec4(suv * 2.0 - 1.0, raw, 1.0);
	return -v.z / max(v.w, 1e-6);
}

void vertex() {
	world_xz = VERTEX.xz + vec2(size * 0.5);
	vec2 uv = world_xz / size;
	float w = textureLod(water_tex, uv, 0.0).r;
	float b = textureLod(bed_tex, uv, 0.0).r;
	float h = max(w - b, 0.0);
	// Dry cells tuck under the sand; wet cells ride the free surface.
	VERTEX.y = mix(b - 0.03, w, smoothstep(0.0, 0.004, h));
}

void fragment() {
	vec2 uv = world_xz / size;
	vec4 q = texture(water_tex, uv);
	float h = max(q.r - texture(bed_tex, uv).r, 0.0);
	if (h < 0.0008) discard;
	// Ghost cells of the mirror walls are boundary data, not water to draw (the south
	// wavemaker ghosts match the open sea outside and stay).
	if (world_xz.x < 2.0 * texel || world_xz.x > size - 2.0 * texel || world_xz.y > size - 2.0 * texel) discard;
	v_depth = h;
	float shore = smoothstep(0.0008, 0.006, h);
	vec4 fx = texture(fx_tex, uv);

	// Sim normal (4 cm finite differences) + flow-advected ripples.
	float e = texel;
	float hx = eta(world_xz + vec2(e, 0.0)) - eta(world_xz - vec2(e, 0.0));
	float hz = eta(world_xz + vec2(0.0, e)) - eta(world_xz - vec2(0.0, e));
	vec3 n = normalize(vec3(-hx, 2.0 * e, -hz));
	vec2 vel = q.gb / max(h, 0.01) * smoothstep(0.002, 0.01, h);
	float sp = length(vel);
	vec2 disp = vel * 0.8;
	disp *= min(length(disp), 0.3) / max(length(disp), 1e-5);
	float phase = texture(grain_tex, world_xz / 7.3).r;
	float t = anim_time * 0.6 + phase;
	vec3 rn = flow_normal(ripple_tex, world_xz, 0.9, disp, t);
	vec3 rn2 = flow_normal(ripple_tex, world_xz * 1.0 + 3.1, 2.3, disp * 0.5, t * 0.7 + 0.3);
	float ramt = ripple_strength * (0.35 + 0.65 * clamp(sp, 0.0, 1.0)) * shore;
	n = normalize(n + vec3(rn.x + rn2.x * 0.6, 0.0, rn.y + rn2.y * 0.6) * ramt);
	NORMAL = (VIEW_MATRIX * vec4(n, 0.0)).xyz;

	// Refraction with a depth test against geometry in front of the water.
	float frag_ld = -VERTEX.z;
	vec2 ruv = SCREEN_UV + NORMAL.xz * refraction * clamp(h / 0.1, 0.0, 1.0) * shore;
	ruv = clamp(ruv, vec2(0.001), vec2(0.999));
	float refr_ld = linear_depth(texture(depth_tex, ruv).r, ruv, INV_PROJECTION_MATRIX);
	if (refr_ld < frag_ld) ruv = SCREEN_UV;
	float aer = fx.a * aer_gain;
	vec3 under = textureLod(screen_tex, ruv, aer * 2.5 * shore).rgb;

	// Absorption along the (vertical) sim depth, scattered colour by depth bands.
	float nv = clamp(dot(VIEW, NORMAL), 0.0, 1.0);
	float path = h / max(nv, 0.35);
	vec3 trans = exp(-absorption * path);
	vec3 scat = mix(edge_color, turquoise, smoothstep(0.0, 0.18, h));
	scat = mix(scat, mid_blue, smoothstep(0.25, 0.6, h));
	scat = mix(scat, deep_blue, smoothstep(0.6, 1.0, h));
	// Suspended sand clouds the water a little; aeration makes it pale, never white.
	float silt = clamp(q.a / max(h, 0.01) * silt_tint, 0.0, 0.12);
	scat = mix(scat, vec3(0.85, 0.80, 0.62), silt);
	trans *= 1.0 - silt * 0.6;
	scat = mix(scat, vec3(0.60, 0.95, 0.92), aer * 0.35);
	trans *= 1.0 - aer * 0.3;
	// Even very thin water gets a little cyan body colour so puddles read as water.
	vec3 opac = max(1.0 - trans, vec3(shallow_body * smoothstep(0.001, 0.015, h)));
	vec3 col = under * (1.0 - opac) * mix(vec3(1.0), water_tint, shore) + scat * opac;

	// Stylized sky reflection, capped.
	vec3 r = reflect(-VIEW, NORMAL);
	vec3 rw = (INV_VIEW_MATRIX * vec4(r, 0.0)).xyz;
	vec3 sky = mix(sky_horizon, sky_zenith, smoothstep(0.0, 0.6, rw.y));
	float fres = (0.02 + 0.98 * pow(1.0 - nv, 5.0)) * max_reflection / 0.3;
	col = mix(col, sky, min(fres, max_reflection) * shore);
	col = mix(under, col, shore);
	col = far_sea(col, h, length(VERTEX));

	// Foam: salt-like bubbles from the foam particles (1 cm splats that ride the
	// flow, shrink and pop), so dense breaking foam reads as a white band that frays into
	// specks and streaks (foam_bubbles: box-filtered when a pixel is bigger than a bubble).
	float foam = foam_bubbles(foam_tex, world_xz, size, bubble_cut);
	float fpx = length(fwidth(world_xz));
	// Waterline: a crisp line a few pixels wide where the sheet thins out to nothing.
	float line = 1.0 - smoothstep(0.0, line_px * fwidth(h), h - 0.0009);
	line *= 1.0 - smoothstep(0.02, 0.06, fpx); // far away it would cover everything
	foam = clamp(max(foam, line * 0.95), 0.0, 1.0);
	v_foam = foam;

	EMISSION = col * (1.0 - foam);
	ALBEDO = foam_color * foam;
	ROUGHNESS = 0.8;
	SPECULAR = 0.0;
}

void light() {
	// Foam: soft diffuse (ALBEDO is zero elsewhere).
	float d = toon_ramp(dot(NORMAL, LIGHT)) * ATTENUATION;
	DIFFUSE_LIGHT += LIGHT_COLOR / PI * (mix(0.65, 1.0, d) * (LIGHT_IS_DIRECTIONAL ? 1.0 : ATTENUATION));
	// Hard-edged toon glint on open water.
	vec3 hv = normalize(LIGHT + VIEW);
	float g = pow(max(dot(NORMAL, hv), 0.0), 2500.0);
	float glint = smoothstep(0.5, 0.6, g) * (1.0 - v_foam) * smoothstep(0.004, 0.02, v_depth);
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * glint * 0.8;
}
