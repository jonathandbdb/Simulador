// sprint2_blur_test.gdshader
//
// PoC del Sprint 2: validar que el post-procesado asimetrico por ojo corre
// a >=72 FPS estables en Quest 2 con frame time GPU < 11 ms.
//
// Que hace:
//   1. Lee SCREEN_TEXTURE y DEPTH_TEXTURE.
//   2. Convierte el depth a distancia real en metros usando INV_PROJECTION_MATRIX.
//   3. Calcula la cantidad de blur en funcion de los 3 planos focales (cerca/media/lejos).
//   4. Aplica box blur 9-tap proporcional a la cantidad de blur.
//   5. Suma halo en zonas brillantes con muestras lineales (sin mipmaps).
//   6. Bifurca con VIEW_INDEX: cada ojo usa su propio set de parametros.
//
// El shader corre en un Quad delante del XRCamera3D, modo transparente sin profundidad.
// hint_screen_texture captura el render del scene 3D antes del pase transparente,
// asi que aca leemos la escena ya renderizada y aplicamos el efecto encima.
//
// NOTA: filter_linear (NO mipmap). Multiview + mipmap en hint_screen_texture
// causa "Layers of our texture doesn't match view count" en Godot 4.6 con Quest Link.

shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never, blend_mix, cull_disabled;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear, repeat_disable;
uniform sampler2D depth_texture  : hint_depth_texture,  filter_nearest, repeat_disable;

// === Planos focales (en metros, espacio de mundo) ===
uniform float near_distance   : hint_range(0.1, 5.0)  = 0.4;
uniform float medium_distance : hint_range(0.5, 10.0) = 2.0;
uniform float far_distance    : hint_range(2.0, 50.0) = 10.0;

// === Intensidad de blur por ojo en cada plano focal (0 = nitido, 1 = blur maximo) ===
uniform float blur_near_l   : hint_range(0.0, 1.0) = 0.0;
uniform float blur_medium_l : hint_range(0.0, 1.0) = 0.0;
uniform float blur_far_l    : hint_range(0.0, 1.0) = 0.0;
uniform float blur_near_r   : hint_range(0.0, 1.0) = 0.0;
uniform float blur_medium_r : hint_range(0.0, 1.0) = 0.0;
uniform float blur_far_r    : hint_range(0.0, 1.0) = 0.0;

// === Halo nocturno ===
uniform float halo_intensity_l : hint_range(0.0, 1.0) = 0.0;
uniform float halo_intensity_r : hint_range(0.0, 1.0) = 0.0;
uniform float halo_threshold   : hint_range(0.0, 1.0) = 0.8;

const float BLUR_RADIUS_PX = 4.0;
const float HALO_RADIUS_PX = 24.0;


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

vec3 halo_sample(vec2 uv, vec2 texel, float intensity) {
	if (intensity < 0.01) {
		return vec3(0.0);
	}
	// 8 muestras en ring + 8 muestras en ring exterior, filter linear (sin mipmaps).
	// Solo contribuyen las que superan halo_threshold.
	vec3 halo = vec3(0.0);
	float inv_above = 1.0 / max(1.0 - halo_threshold, 0.001);
	float radius_a = HALO_RADIUS_PX * intensity;
	float radius_b = radius_a * 1.6;
	vec2 dirs[8] = vec2[8](
		vec2( 1.0,  0.0), vec2(-1.0,  0.0), vec2( 0.0,  1.0), vec2( 0.0, -1.0),
		vec2( 0.7,  0.7), vec2(-0.7,  0.7), vec2( 0.7, -0.7), vec2(-0.7, -0.7)
	);
	for (int i = 0; i < 8; i++) {
		vec3 ca = texture(screen_texture, uv + dirs[i] * texel * radius_a).rgb;
		vec3 cb = texture(screen_texture, uv + dirs[i] * texel * radius_b).rgb;
		float la = max(ca.r, max(ca.g, ca.b));
		float lb = max(cb.r, max(cb.g, cb.b));
		if (la > halo_threshold) {
			halo += ca * (la - halo_threshold) * inv_above;
		}
		if (lb > halo_threshold) {
			halo += cb * (lb - halo_threshold) * inv_above * 0.5;
		}
	}
	return (halo / 16.0) * intensity;
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
	color += halo_sample(uv, texel, halo_amount);

	ALBEDO = color;
	ALPHA = 1.0;
}
