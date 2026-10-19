// Stylized tropical sky: 3-stop gradient (bright horizon band -> turquoise -> deep
// blue), soft sun disc and halo, and thin high cartoon cloud streaks from thresholded
// noise. The big puffy clouds are separate meshes (main.gd, cloud.gdshader) for parallax.
shader_type sky;
global uniform float anim_time;

uniform vec3 horizon_color : source_color = vec3(0.925, 0.976, 1.0);  // #ECF9FF
uniform vec3 low_color : source_color = vec3(0.592, 0.882, 1.0);      // #97E1FF
uniform vec3 zenith_color : source_color = vec3(0.180, 0.580, 0.957); // #2E94F4
uniform vec3 below_color : source_color = vec3(0.62, 0.86, 0.95);
uniform vec3 sun_tint : source_color = vec3(1.0, 0.97, 0.86);
uniform sampler2D cloud_noise : filter_linear_mipmap, repeat_enable;
uniform float streaks = 0.55;

void sky() {
	vec3 d = EYEDIR;
	float y = d.y;
	vec3 col;
	if (y >= 0.0) {
		col = mix(horizon_color, low_color, smoothstep(0.0, 0.12, y));
		col = mix(col, zenith_color, smoothstep(0.08, 0.75, y));
		// High streaks: noise on a flat dome, thresholded with a soft edge, fading at the horizon.
		vec2 p = d.xz / (y + 0.12) * 0.35 + vec2(anim_time * 0.002, 0.0);
		float n = texture(cloud_noise, p).r * 0.65 + texture(cloud_noise, p * 2.7 + 0.31).r * 0.35;
		float c = smoothstep(0.62, 0.70, n) * smoothstep(0.03, 0.2, y) * (1.0 - smoothstep(0.5, 0.9, y));
		col = mix(col, vec3(1.0), c * streaks);
	} else {
		col = mix(horizon_color, below_color, smoothstep(0.0, -0.2, y));
	}
	// Sun: hard-ish disc + wide warm halo (kept below the glow threshold except the disc).
	if (LIGHT0_ENABLED) {
		float cs = dot(d, LIGHT0_DIRECTION);
		float disc = smoothstep(0.9993, 0.9996, cs);
		float halo = pow(max(cs, 0.0), 24.0) * 0.35 + pow(max(cs, 0.0), 4.0) * 0.08;
		col += sun_tint * (halo + disc * 1.6);
	}
	COLOR = col;
}
