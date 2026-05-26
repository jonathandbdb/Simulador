// sprint2_blur_test.gdshader
//
// PoC del Sprint 2 - iteracion 2: blur mas pronunciado + halo con anillos
// concentricos y tinte cromatico (efecto difractivo de IOL multifocal).
//
// Que hace:
//   1. Lee SCREEN_TEXTURE y DEPTH_TEXTURE.
//   2. Convierte depth a distancia real en metros (INV_PROJECTION_MATRIX).
//   3. Calcula blur por distancia a los 3 planos focales.
//   4. Aplica box blur 9-tap con radio mayor (12 px) para diferenciacion visible.
//   5. Halo realista: 2 anillos concentricos (efecto difraccion), falloff
//      cuadratico, tinte amarillento suave.
//   6. Bifurca con VIEW_INDEX para Blend asimetrico.

shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never, blend_mix, cull_disabled;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear, repeat_disable;
uniform sampler2D depth_texture  : hint_depth_texture,  filter_nearest, repeat_disable;

// === Planos focales (metros, espacio mundo) ===
uniform float near_distance   : hint_range(0.1, 5.0)  = 0.4;
uniform float medium_distance : hint_range(0.5, 10.0) = 2.0;
uniform float far_distance    : hint_range(2.0, 50.0) = 10.0;

// === Blur por ojo (0 = nitido, 1 = blur maximo) ===
uniform float blur_near_l   : hint_range(0.0, 1.0) = 0.0;
uniform float blur_medium_l : hint_range(0.0, 1.0) = 0.0;
uniform float blur_far_l    : hint_range(0.0, 1.0) = 0.0;
uniform float blur_near_r   : hint_range(0.0, 1.0) = 0.0;
uniform float blur_medium_r : hint_range(0.0, 1.0) = 0.0;
uniform float blur_far_r    : hint_range(0.0, 1.0) = 0.0;

// === Halo ===
uniform float halo_intensity_l : hint_range(0.0, 1.0) = 0.0;
uniform float halo_intensity_r : hint_range(0.0, 1.0) = 0.0;
uniform float halo_threshold   : hint_range(0.0, 1.0) = 0.75;
uniform vec3  halo_tint = vec3(1.05, 1.0, 0.78);  // amarillo-blanco realista

// === Constantes de muestreo ===
const float BLUR_RADIUS_PX     = 12.0;   // antes 4.0 — diferenciacion mas visible
const float HALO_INNER_RING_PX = 18.0;   // primer anillo difractivo
const float HALO_OUTER_RING_PX = 32.0;   // segundo anillo difractivo (1.8x)
const float HALO_INNER_WEIGHT  = 1.0;
const float HALO_OUTER_WEIGHT  = 0.4;


float linear_depth_meters(float raw_depth, vec2 uv, mat4 inv_proj) {
	vec4 ndc = vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
	vec4 view = inv_proj * ndc;
	return length(view.xyz / view.w);
}

float blur_for_distance(float dist, float bn, float bm, float bf) {
	if (dist <= near_distance) {
		return bn * smoothstep(0.0, near_distance, dist);
	} else if (dist <= medium_distance) {
		float t = (dist - near_distance) / (medium_distance - near_distance);
		return mix(bn, bm, t);
	} else if (dist <= far_distance) {
		float t = (dist - medium_distance) / (far_distance - medium_distance);
		return mix(bm, bf, t);
	} else {
		return bf;
	}
}

vec3 box_blur_9tap(vec2 uv, vec2 texel, float radius_px) {
	vec3 sum = vec3(0.0);
	vec2 step = texel * radius_px;
	sum += texture(screen_texture, uv + vec2(-1.0, -1.0) * step).rgb;
	sum += texture(screen_texture, uv + vec2( 0.0, -1.0) * step).rgb;
	sum += texture(screen_texture, uv + vec2( 1.0, -1.0) * step).rgb;
	sum += texture(screen_texture, uv + vec2(-1.0,  0.0) * step).rgb;
	sum += texture(screen_texture, uv                              ).rgb;
	sum += texture(screen_texture, uv + vec2( 1.0,  0.0) * step).rgb;
	sum += texture(screen_texture, uv + vec2(-1.0,  1.0) * step).rgb;
	sum += texture(screen_texture, uv + vec2( 0.0,  1.0) * step).rgb;
	sum += texture(screen_texture, uv + vec2( 1.0,  1.0) * step).rgb;
	return sum / 9.0;
}

// Halo realista: dos anillos concentricos alrededor del pixel actual.
// Cada anillo muestrea 8 direcciones; solo contribuyen pixeles brillantes.
// Falloff cuadratico simula la caida fisica de la luz con r^2.
vec3 halo_rings(vec2 uv, vec2 texel, float intensity) {
	if (intensity < 0.01) {
		return vec3(0.0);
	}
	vec2 dirs[8] = vec2[8](
		vec2( 1.0,  0.0), vec2(-1.0,  0.0), vec2( 0.0,  1.0), vec2( 0.0, -1.0),
		vec2( 0.7,  0.7), vec2(-0.7,  0.7), vec2( 0.7, -0.7), vec2(-0.7, -0.7)
	);
	float radius_inner = HALO_INNER_RING_PX * intensity;
	float radius_outer = HALO_OUTER_RING_PX * intensity;
	float inv_above = 1.0 / max(1.0 - halo_threshold, 0.001);

	vec3 halo = vec3(0.0);
	for (int i = 0; i < 8; i++) {
		vec3 ci = texture(screen_texture, uv + dirs[i] * texel * radius_inner).rgb;
		vec3 co = texture(screen_texture, uv + dirs[i] * texel * radius_outer).rgb;
		float li = max(ci.r, max(ci.g, ci.b));
		float lo = max(co.r, max(co.g, co.b));
		if (li > halo_threshold) {
			float strength = (li - halo_threshold) * inv_above;
			halo += ci * (strength * strength) * HALO_INNER_WEIGHT;
		}
		if (lo > halo_threshold) {
			float strength = (lo - halo_threshold) * inv_above;
			halo += co * (strength * strength) * HALO_OUTER_WEIGHT;
		}
	}
	// Promediar y aplicar tinte cromatico del halo.
	return (halo / 8.0) * intensity * halo_tint;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 texel = 1.0 / vec2(textureSize(screen_texture, 0));

	float raw_depth = texture(depth_texture, uv).r;
	float dist_m = linear_depth_meters(raw_depth, uv, INV_PROJECTION_MATRIX);

	float blur_amount;
	float halo_amount;
	if (VIEW_INDEX == VIEW_MONO_LEFT) {
		blur_amount = blur_for_distance(dist_m, blur_near_l, blur_medium_l, blur_far_l);
		halo_amount = halo_intensity_l;
	} else {
		blur_amount = blur_for_distance(dist_m, blur_near_r, blur_medium_r, blur_far_r);
		halo_amount = halo_intensity_r;
	}

	vec3 base = texture(screen_texture, uv).rgb;
	vec3 blurred = box_blur_9tap(uv, texel, BLUR_RADIUS_PX * blur_amount);
	vec3 color = mix(base, blurred, blur_amount);
	color += halo_rings(uv, texel, halo_amount);

	ALBEDO = color;
	ALPHA = 1.0;
}
