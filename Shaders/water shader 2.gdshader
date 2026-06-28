shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_lambert, specular_schlick_ggx;

uniform sampler2D DEPTH_TEXTURE  : hint_depth_texture, filter_nearest;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear;

uniform vec4  color_shallow : source_color = vec4(0.10, 0.72, 0.62, 0.15);
uniform vec4  color_deep    : source_color = vec4(0.01, 0.28, 0.50, 0.90);
uniform vec4  color_foam    : source_color = vec4(1.00, 1.00, 1.00, 1.00);
uniform vec4  color_ripple  : source_color = vec4(1.00, 1.00, 1.00, 0.35);

uniform float wave_scale        : hint_range(0.5,  32.0, 0.1)  = 3.0;
uniform float wave_speed        : hint_range(0.0,  10.0, 0.01) = 0.5;
uniform float water_world_scale : hint_range(0.1,  10.0, 0.1)  = 1.0;
uniform float noise_seed        : hint_range(0.0, 100.0, 0.1)  = 0.0;
uniform float chop_scale        : hint_range(0.01, 0.5,  0.01) = 0.08;
uniform float chop_drift        : hint_range(0.0,  0.5,  0.005)= 0.02;
uniform float chop_contrast     : hint_range(0.0,  1.0,  0.05) = 0.2;
uniform float chop_max          : hint_range(0.0,  1.0,  0.05) = 0.8;
uniform float normal_strength   : hint_range(0.0,  16.0, 0.1)  = 4.0;
uniform float wave_height       : hint_range(0.0,  10.0, 0.05) = 0.25;
uniform float wave_frequency    : hint_range(0.01, 4.0,  0.01) = 0.25;
uniform float wave_time_scale   : hint_range(0.01, 8.0,  0.01) = 0.60;

// Ripple system
uniform vec3  trail_pos[32];
uniform float trail_age[32];
uniform vec2  trail_dir[32];
uniform float trail_fade[32];
uniform int   trail_count   : hint_range(4, 32, 1)    = 20;
uniform float player_radius : hint_range(0.0, 10.0, 0.05) = 0.4;
uniform float ripple_freq   : hint_range(1.0, 200.0, 0.5) = 8.0;
uniform float ripple_speed  : hint_range(0.1, 20.0,  0.1) = 4.0;
uniform float ripple_radius : hint_range(1.0, 200.0,  1.0) = 14.0;
uniform float ripple_decay  : hint_range(0.01, 20.0, 0.01) = 3.0;
uniform float event_speed   : hint_range(0.1, 10.0,  0.1) = 1.2;
uniform float event_radius  : hint_range(1.0, 100.0, 0.5) = 6.0;
uniform float ripple_str    : hint_range(0.0,  2.0,  0.05) = 0.5;

uniform float foam_distance  : hint_range(0.0, 4.0,  0.05) = 0.5;
uniform float foam_strength  : hint_range(0.0, 1.0,  0.05) = 0.8;
uniform float depth_density  : hint_range(0.0, 2.0,  0.01) = 0.35;
uniform float depth_strength : hint_range(0.0, 1.0,  0.01) = 0.75;
uniform float beers_law      : hint_range(0.0, 20.0,  0.1) = 4.0;
uniform float water_color_ratio : hint_range(0.0, 1.0, 0.01) = 0.55;

uniform vec3  sun_dir        = vec3(0.5, 0.8, 0.3);
uniform vec4  shimmer_color  : source_color = vec4(1.0, 0.97, 0.82, 1.0);
uniform float shimmer_str    : hint_range(0.0, 20.0, 0.1)  = 8.0;
uniform float shininess      : hint_range(1.0, 512.0, 1.0) = 80.0;
uniform float opacity        : hint_range(0.0,  1.0, 0.01) = 1.0;
uniform vec4  water_tint     : source_color = vec4(0.08, 0.18, 0.28, 0.25);
uniform float alpha_min      : hint_range(0.0,  1.0, 0.01) = 0.35;
uniform float alpha_max      : hint_range(0.0,  1.0, 0.01) = 0.95;

varying vec3 v_world_pos;

// ── Noise ───────────────────────────────────────────────────────────────────

float hash(vec2 p) {
	p = fract(p * vec2(127.1 + noise_seed, 311.7 + noise_seed));
	p += dot(p, p + 17.5);
	return fract(p.x * p.y * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 q = vec2(dot(i,           vec2(127.1, 311.7)),
	              dot(i+vec2(1,0),  vec2(127.1, 311.7)));
	vec2 r = vec2(dot(i+vec2(0,1), vec2(127.1, 311.7)),
	              dot(i+vec2(1,1),  vec2(127.1, 311.7)));
	return mix(mix(fract(sin(q.x)*43758.5453), fract(sin(q.y)*43758.5453), u.x),
	           mix(fract(sin(r.x)*43758.5453), fract(sin(r.y)*43758.5453), u.x), u.y);
}

float choppiness(vec2 p, float t) {
	vec2 s = p * chop_scale + vec2(t * chop_drift, t * chop_drift * 0.75);
	return smoothstep(chop_contrast, chop_max, (noise(s) + noise(s * 1.7 + 3.4)) * 0.5);
}

vec2 surface_normal(vec2 p, float t) {
	float e    = 0.1;
	float chop = mix(0.15, 1.0, choppiness(p, t));
	float n0   = noise(p           + vec2(t*0.4,  t*0.3));
	float nx   = noise(p+vec2(e,0) + vec2(t*0.4,  t*0.3));
	float ny   = noise(p+vec2(0,e) + vec2(t*0.4,  t*0.3));
	float n1   = noise(p*2.3       + vec2(-t*0.5, t*0.2));
	float nx1  = noise(p*2.3+vec2(e,0) + vec2(-t*0.5, t*0.2));
	float ny1  = noise(p*2.3+vec2(0,e) + vec2(-t*0.5, t*0.2));
	return vec2((nx-n0)+(nx1-n1), (ny-n0)+(ny1-n1)) / e * chop;
}

// ── Ripples (advanced — semi-circles, noisy decay, analytical gradient) ─────

float ripple_from(vec2 xz, int i, float t, out vec2 grad) {
	grad = vec2(0.0);
	if (trail_pos[i].x > 9000.0) return 0.0;
	float age      = trail_age[i];
	float age_fade = exp(-age * ripple_decay);
	if (age_fade < 0.005) return 0.0;
	vec2  src       = trail_pos[i].xz;
	float raw_dist  = length(xz - src);
	float front_est = age * ripple_speed;
	if (raw_dist > front_est + 4.5) return 0.0;
	if (raw_dist < front_est - 4.0) return 0.0;
	bool  is_event   = dot(trail_dir[i], trail_dir[i]) < 0.01;
	float eff_freq   = is_event ? ripple_freq * 8.0 : ripple_freq / clamp(0.5 + age * 0.1, 0.5, 0.9);
	float eff_speed  = is_event ? event_speed  : ripple_speed;
	float eff_radius = is_event ? event_radius : ripple_radius;
	float seed       = hash(vec2(float(i) * 5.3, 2.7)) * 31.4;
	float n          = noise(xz * 0.5 + src * 0.2 + t * 0.1 + seed);
	float wobble     = (n * 2.0 - 1.0) * 0.18;
	float noisy_fade = exp(-age * ripple_decay * (n * 0.7 + 0.65));
	float death_fade = smoothstep(0.0, 0.5, noisy_fade);
	float dist       = max(raw_dist - player_radius + wobble, 0.0);
	float front      = age * eff_speed;
	float delta      = dist - front;
	float fade       = noisy_fade * death_fade * trail_fade[i]
	                 * (1.0 - smoothstep(eff_radius * 0.6, eff_radius, dist));
	vec2  to_frag    = dist > 0.001 ? normalize(xz - src) : vec2(0.0);
	float arc_edge   = mix(0.131, -0.087, hash(vec2(float(i) * 7.1, 3.9)));
	float dir_mask   = is_event ? 1.0
	                 : smoothstep(arc_edge, arc_edge + 0.7, dot(to_frag, trail_dir[i]));
	float tip_freq   = is_event ? eff_freq : eff_freq * (1.0 + (1.0 - dir_mask) * 1.2);
	float t0 = exp(-delta * delta * tip_freq);
	float t1 = exp(-(delta + 0.8) * (delta + 0.8) * tip_freq) * 0.6;
	float tdval = (-2.0*delta*tip_freq*t0 + -2.0*(delta+0.8)*tip_freq*t1) * fade;
	grad = to_frag * tdval * dir_mask;
	return (t0 + t1) * fade * dir_mask;
}

vec3 total_ripple(vec2 xz, float t) {
	float v = 0.0;
	vec2  g = vec2(0.0);
	vec2  grad;
	vec2  xz_bent  = xz;
	vec2  bend_acc = vec2(0.0);
	for (int i = 0; i < trail_count; i++) {
		v += ripple_from(xz_bent, i, t, grad);
		g += grad;
		float glen = length(grad);
		vec2  step = glen > 0.001 ? (grad / glen) * min(glen, 0.18) * 0.07 : vec2(0.0);
		bend_acc = mix(bend_acc, bend_acc + step, 0.65);
		xz_bent  = xz + bend_acc;
	}
	return vec3(v, g) * ripple_str;
}

// ── Vertex ───────────────────────────────────────────────────────────────────

void vertex() {
	float t  = TIME;
	float f  = wave_frequency * 20.0;
	float s  = wave_time_scale;
	float wy = (sin(UV.x*f*1.0 + UV.y*f*0.35 + t*s) * 0.5
	          + sin(UV.x*f*0.55 - UV.y*f*0.75 + t*s*0.67) * 0.3
	          + sin(UV.x*f*0.35 + UV.y*f*1.10 + t*s*1.27) * 0.2) * 0.5 + 0.5;
	VERTEX.y += wy * wave_height;
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// ── Fragment ─────────────────────────────────────────────────────────────────

void fragment() {
	float t   = TIME;
	vec2  xz  = v_world_pos.xz;
	vec2  sxz = xz / water_world_scale;

	// Ripples — analytical gradient, single loop pass
	vec3  rip_result = total_ripple(xz, t);
	float rip        = rip_result.x;
	vec2  rip_wn     = rip_result.yz;

	// Surface normals + ripple contribution
	vec2 p_norm = sxz / wave_scale;
	vec2 wn     = surface_normal(p_norm, t * wave_speed);
	wn += rip_wn * (18.0 + rip * 6.0);

	// Base colour from choppiness
	float chop = choppiness(p_norm, t * wave_speed);
	vec3  col  = mix(color_deep.rgb, color_shallow.rgb, chop);
	col = mix(col, color_ripple.rgb, clamp(rip * color_ripple.a, 0.0, 1.0));

	// Depth buffer
	float raw_depth   = texture(DEPTH_TEXTURE, SCREEN_UV).r;
	vec4  view_pos    = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw_depth, 1.0);
	view_pos.xyz     /= view_pos.w;
	float scene_depth = -view_pos.z;
	float surf_depth  = -VERTEX.z;
	float depth_diff  = scene_depth - surf_depth;

	// Edge foam
	float edge_foam = 1.0 - smoothstep(0.0, foam_distance, depth_diff);
	col = mix(col, color_foam.rgb, edge_foam * foam_strength);

	// Shore distortion rings
	float shore_reach   = foam_distance * 2.0;
	float shore_mask    = smoothstep(shore_reach, 0.0, depth_diff);
	float sd            = depth_diff * 4.0 - t * 1.5;
	float shore_distort = (pow(abs(sin(sd)), 6.0)
	                    + pow(abs(sin(sd - 1.2)), 6.0) * 0.65) * shore_mask * 8.0;
	wn += vec2(shore_distort, shore_distort);

	NORMAL_MAP       = normalize(vec3(wn * normal_strength, 1.0)) * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 1.0;

	// Sun shimmer
	vec3  w_norm   = normalize(vec3(wn.x, 1.0 / max(normal_strength, 0.01), wn.y));
	vec3  half_v   = normalize(normalize(sun_dir) + VIEW);
	float sun_spec = pow(max(0.0, dot(w_norm, half_v)), shininess);
	EMISSION = shimmer_color.rgb * sun_spec * shimmer_str + water_tint.rgb * water_tint.a;

	// Beer's Law depth + Fresnel
	float fresnel   = pow(1.0 - clamp(dot(VIEW, w_norm), 0.0, 1.0), 3.0);
	float vol_depth = clamp(1.0 - exp(-depth_diff * depth_density), 0.0, 1.0);
	float beer      = clamp(pow(exp(-vol_depth * beers_law), 3.0), 0.0, 1.0);
	vec3  refraction = textureLod(SCREEN_TEXTURE, SCREEN_UV, 0.0).rgb;
	vec3  water_col  = mix(col, color_deep.rgb, vol_depth * depth_strength);

	ALBEDO    = mix(water_col, refraction * beer, 1.0 - water_color_ratio);
	ROUGHNESS = 0.08;
	SPECULAR  = 0.9;
	METALLIC  = 0.0;
	ALPHA     = clamp(mix(alpha_min, alpha_max, fresnel) + vol_depth * 0.3, 0.0, 1.0) * opacity;
}
