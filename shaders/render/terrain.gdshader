// Sand heightfield, cartoon look.
// Dry sand is bright cream with fine grain and sun sparkles; wetness darkens and
// saturates it (and dries back with the sim's wetness); a thin glossy film right at
// the waterline; fresh (just slid / scoured / dug) sand is lighter and grainier;
// packed walls are smoother. Under water: caustics from the real surface curvature
// plus a small procedural pattern. Soft two-tone sun ramp, warm lavender shadows,
// cheap heightfield AO for moats and wall feet.
shader_type spatial;
render_mode cull_back;

#include "res://shaders/render/beach_common.gdshaderinc"

// Animation clock: rendered frames / 60 in fixed and recorded runs (main.gd),
// so moving patterns do not jitter when frames take uneven wall time.
global uniform float anim_time;
uniform sampler2D sand_tex : filter_linear, repeat_disable;  // height, wetness, strength, freshness
uniform sampler2D water_tex : filter_linear, repeat_disable; // w, hu, hv, hs
uniform sampler2D bed_tex : filter_linear, repeat_disable;
uniform sampler2D fx_tex : filter_linear, repeat_disable;    // foam, prev w, stranded foam, aeration
uniform sampler2D foam_tex : filter_linear, repeat_disable;  // foam bubble splats, 1 cm
uniform sampler2D grain_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D cell_tex : filter_linear_mipmap, repeat_enable; // cellular F1 (caustics)
uniform sampler2D lace_tex : filter_linear_mipmap, repeat_enable; // cellular F2-F1 (foam lace)
uniform float size = 20.48;
uniform float texel = 0.02;

uniform vec3 dry_color : source_color = vec3(0.957, 0.824, 0.612);   // #F4D29C
uniform vec3 fresh_color : source_color = vec3(1.0, 0.949, 0.824);   // #FFF2D2
uniform vec3 damp_color : source_color = vec3(0.894, 0.737, 0.502);  // #E4BC80
uniform vec3 wet_color : source_color = vec3(0.812, 0.639, 0.459);   // #CFA375
uniform vec3 shadow_fill = vec3(0.30, 0.22, 0.32);
uniform float caustic_strength = 0.75;
uniform float caustic_focus = 0.6;    // focal factor (m) at depth; caustic lines sharpen as it grows
uniform float caustic_warp = 0.12;    // m of low-frequency warp of the caustic map lookup
uniform sampler2D caustic_tex : filter_linear, repeat_enable; // BeachSim caustic map (3 focal slices)

// Light density at focal factor f (m): blend of the map's slices at f = 0.12 / 0.27 / 0.45
// (beach.compute KERNEL_CAUS_SPLAT); below the first slice it fades to undisturbed light.
float caustic_light(vec2 uv, float f) {
	vec3 m = texture(caustic_tex, uv).rgb;
	if (f < 0.12) return mix(1.0, m.r, f / 0.12);
	if (f < 0.27) return mix(m.r, m.g, (f - 0.12) / 0.15);
	return mix(m.g, m.b, clamp((f - 0.27) / 0.18, 0.0, 1.0));
}
uniform float caustic_falloff = 2.5;  // per metre of water
uniform float ao_strength = 2.2;
uniform float underwater_light = 0.0;

varying vec2 world_xz;
varying vec3 v_caustic;
varying float v_sparkle;
varying float v_sheen;

float hgt(vec2 xz) { return textureLod(sand_tex, xz / size, 0.0).r; }
float eta(vec2 xz) { return textureLod(water_tex, xz / size, 0.0).r; }

void vertex() {
	world_xz = VERTEX.xz + vec2(size * 0.5);
	VERTEX.y = hgt(world_xz);
}

void fragment() {
	vec2 uv = world_xz / size;
	float e = texel;
	float h0 = hgt(world_xz);
	float hx = hgt(world_xz + vec2(e, 0.0)) - hgt(world_xz - vec2(e, 0.0));
	float hz = hgt(world_xz + vec2(0.0, e)) - hgt(world_xz - vec2(0.0, e));
	vec3 n = normalize(vec3(-hx, 2.0 * e, -hz));
	vec4 sd = texture(sand_tex, uv);
	float wet = sd.g;
	float strength = sd.b;
	float fresh = sd.a;

	// Water above this point (sim depth, not the view ray).
	float wd = max(texture(water_tex, uv).r - texture(bed_tex, uv).r, 0.0);
	float under = smoothstep(0.002, 0.012, wd);

	// Heightfield AO: how much the surrounding sand rises above this point.
	float occ = 0.0;
	for (int i = 0; i < 8; i++) {
		float a = float(i) * 0.785398 + 0.39;
		float r = i % 2 == 0 ? 0.07 : 0.22;
		occ += max(hgt(world_xz + vec2(cos(a), sin(a)) * r) - h0, 0.0) / r;
	}
	float ao = clamp(1.0 - ao_strength * occ / 8.0, 0.45, 1.0);

	// Colour: dry -> damp -> wet, fresh sand lighter, grain.
	float dist = length(VERTEX);
	float g1 = texture(grain_tex, world_xz * 3.1).r;
	float g2 = texture(grain_tex, world_xz * 11.3 + 0.37).r;
	float grain = mix(g1, g2, 0.5) - 0.5;
	vec3 col = mix(dry_color, fresh_color, fresh * 0.7);
	col = mix(col, damp_color, smoothstep(0.08, 0.5, wet));
	col = mix(col, wet_color, smoothstep(0.5, 0.95, wet));
	float grain_amt = mix(0.10, 0.05, strength) + 0.06 * fresh;
	col *= 1.0 + grain * grain_amt * 2.0;
	// Scattered dark grains / tiny pebbles (0.8-1.6 cm, ~10 per m^2 in 35% of 18 cm cells),
	// faded out with distance.
	vec2 pc = world_xz / 0.18;
	vec2 pci = floor(pc);
	vec3 pr = fract(sin(vec3(dot(pci, vec2(12.9898, 78.233)), dot(pci, vec2(39.35, 11.13)),
		dot(pci, vec2(73.1, 19.7)))) * 43758.55);
	float pd = length(pc - pci - (0.15 + 0.7 * pr.xy)) * 0.18;
	float peb = (1.0 - smoothstep(0.004, 0.0065, pd / mix(0.5, 1.0, pr.z)))
		* step(0.65, fract(pr.z * 7.13)) * (1.0 - smoothstep(4.0, 9.0, dist));
	col = mix(col, col * vec3(0.42, 0.36, 0.33), peb * 0.85);

	// Foam stranded on the sand after the water ran back: the foam particles
	// stop on dry cells and pop one by one; far away the smooth stranded field stands in.
	vec4 fx = texture(fx_tex, uv);
	float strand = foam_bubbles(foam_tex, world_xz, size, 0.3) * (1.0 - under);
	col = mix(col, vec3(0.97, 0.99, 1.0), strand * 0.9);

	// Under water the sand reads lighter (cartoon clarity) than the dark wet beach.
	col = mix(col, damp_color * 1.08, under * underwater_light);
	// Caustics: the per-frame caustic map (BeachSim, 48-wave periodic ripple
	// field refracted onto the bed by photon splatting, 3 focal slices) looked up with a
	// rotated, noise-warped coordinate so its 5.12 m tile never lines up, bent and focused by
	// the sim surface (slope shift + curvature lens), with a large-scale brightness mask.
	vec3 caus = vec3(0.0);
	if (wd > 0.002) {
		float c = 0.04;
		float e0 = eta(world_xz);
		float ex = eta(world_xz + vec2(c, 0.0)), ew = eta(world_xz - vec2(c, 0.0));
		float ez = eta(world_xz + vec2(0.0, c)), es = eta(world_xz - vec2(0.0, c));
		vec2 slope = vec2(ex - ew, ez - es) / (2.0 * c);
		float lap = (ex + ew + ez + es - 4.0 * e0) / (c * c);
		float f = caustic_focus * wd / (wd + 0.12);
		float t = anim_time;
		vec2 warp = vec2(texture(grain_tex, world_xz / 40.0 + vec2(0.003, 0.002) * t).r,
			texture(grain_tex, world_xz / 40.0 + vec2(0.37, 0.61) - vec2(0.002, 0.003) * t).r) - 0.5;
		vec2 q = world_xz - slope * wd * 0.25 + warp * caustic_warp;
		vec2 uv = mat2(vec2(0.894, 0.447), vec2(-0.447, 0.894)) * q / 5.12; // rotated 26.6 deg
		vec2 du = vec2(0.0012, 0.0008) / 5.12 * (0.5 + wd * 4.0);
		caus = vec3(caustic_light(uv + du, f * 0.96), caustic_light(uv, f), caustic_light(uv - du, f * 1.04));
		// Sim curvature: wave crests focus the whole pattern, troughs spread it.
		caus *= clamp(1.0 / max(0.4, 1.0 + f * lap), 0.6, 1.8);
		// Far away the 1 cm lines cannot be resolved: fade towards the mean (1) to avoid crawl.
		vec2 dxz = dFdx(world_xz), dyz = dFdy(world_xz);
		float fp = sqrt(max(length(dxz) * length(dyz), 1e-10));
		caus = mix(caus, vec3(1.0), smoothstep(0.02, 0.07, fp) * 0.8);
		float mask = mix(0.55, 1.15, texture(grain_tex, world_xz / 75.0 + 0.53).r);
		float amt = smoothstep(0.003, 0.03, wd) * exp(-wd * caustic_falloff);
		caus = (caus - 1.0) * amt * caustic_strength * mask;
	}
	v_caustic = caus * (1.0 - smoothstep(25.0, 45.0, dist));

	// Glossy film at the waterline (just uncovered, saturated).
	v_sheen = smoothstep(0.88, 0.98, wet) * (1.0 - under);
	// Sparkles: dry loose sand only, faded with distance (avoid shimmer).
	vec2 sp = world_xz * 140.0;
	float s1 = texture(grain_tex, sp / 64.0 + VIEW.xz * 0.02).r;
	float s2 = texture(grain_tex, sp / 61.0 - VIEW.xz * 0.017 + 0.3).r;
	v_sparkle = smoothstep(0.84, 0.92, s1 * s2 * 1.45) * (1.0 - smoothstep(0.1, 0.35, wet))
		* (1.0 - smoothstep(3.0, 8.0, dist)) * (1.0 - strand);

	ALBEDO = col;
	AO = ao;
	AO_LIGHT_AFFECT = 0.6;
	NORMAL = (VIEW_MATRIX * vec4(n, 0.0)).xyz;
	ROUGHNESS = mix(mix(0.95, 0.75, smoothstep(0.3, 0.9, wet)), 0.4, v_sheen);
	SPECULAR = mix(0.15, 0.3, v_sheen);
}

void light() {
	float d = toon_ramp(dot(NORMAL, LIGHT)) * ATTENUATION;
	// Shadowed side gets a little warm lavender fill instead of only the blue sky ambient.
	if (LIGHT_IS_DIRECTIONAL) {
		DIFFUSE_LIGHT += LIGHT_COLOR / PI * (d * (1.0 + max(v_caustic, vec3(-0.4))) + (1.0 - d) * shadow_fill);
	} else {
		DIFFUSE_LIGHT += LIGHT_COLOR / PI * ATTENUATION * toon_ramp(dot(NORMAL, LIGHT));
	}
	vec3 hv = normalize(LIGHT + VIEW);
	float ndh = max(dot(NORMAL, hv), 0.0);
	// Point lights get a broad reflection, unlike the hard toon sun glint.
	float sheen = LIGHT_IS_DIRECTIONAL ? smoothstep(0.55, 0.62, pow(ndh, 60.0)) * v_sheen * 0.6
		: pow(ndh, 28.0) * v_sheen * 0.18;
	SPECULAR_LIGHT += LIGHT_COLOR / PI * ATTENUATION * (sheen + v_sparkle * 2.5);
}
