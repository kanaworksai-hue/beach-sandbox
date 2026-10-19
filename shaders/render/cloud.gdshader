// Cartoon cumulus puffs: clusters of spheres far away, flat two-tone shading
// (bright sunlit side, soft lilac-blue underside), faded into the horizon at the bottom.
shader_type spatial;
render_mode unshaded, cull_back, shadows_disabled;

uniform vec3 lit_color : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 shade_color : source_color = vec3(0.78, 0.84, 0.97);
uniform vec3 haze_color : source_color = vec3(0.925, 0.976, 1.0);
uniform vec3 sun_dir = vec3(0.0, 0.7, -0.7); // towards the sun, world space

varying vec3 wn;
varying vec3 wp;

void vertex() {
	wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float ndl = dot(wn, normalize(sun_dir)) * 0.6 + wn.y * 0.6;
	float lit = smoothstep(-0.15, 0.1, ndl);
	vec3 col = mix(shade_color, lit_color, lit);
	// Rim towards the viewer edge reads as a soft cotton outline.
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	col = mix(col, vec3(1.0), rim * 0.35);
	// Bottom of the cloud melts into the horizon haze.
	col = mix(col, haze_color, smoothstep(0.0, 1.0, 1.0 - clamp((wp.y - 15.0) / 40.0, 0.0, 1.0)) * 0.5);
	ALBEDO = col;
}
