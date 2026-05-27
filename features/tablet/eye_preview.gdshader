// eye_preview.gdshader (Sprint 7 polish)
//
// Shader canvas_item que corre en el TextureRect de cada panel del split
// de la tablet. Simula visualmente como se veria el frame del stream a
// traves de la lente del ojo correspondiente.
//
// Limitaciones (vs el shader spatial del visor):
//   - No tenemos depth_texture en la tablet (el stream es un JPG 2D).
//   - Por eso usamos un blur "efectivo" precalculado en GDScript que
//     combina blur_near/medium/far ponderado para representar lo que
//     domina visualmente.
//   - Los halos detectan pixels brillantes en el JPG (umbral de luminancia)
//     y suman anillos concentricos, replicando el efecto del shader real.
//
// Uniforms (todos seteados desde GDScript a partir del catalogo de lentes):
//   blur_amount    -> intensidad del box blur (0 = nitido, 1 = maximo).
//   halo_intensity -> intensidad de los anillos de halo (0 = sin halos).
//   contrast_loss  -> mezcla hacia gris medio (0 = contraste pleno).

shader_type canvas_item;

uniform float blur_amount    : hint_range(0.0, 1.0) = 0.0;
uniform float halo_intensity : hint_range(0.0, 1.0) = 0.0;
uniform float contrast_loss  : hint_range(0.0, 1.0) = 0.0;
uniform float halo_threshold : hint_range(0.0, 1.0) = 0.65;
uniform vec3  halo_tint      = vec3(1.05, 1.0, 0.78);

// Radio maximo del box blur en pixeles del TextureRect.
const float BLUR_RADIUS_PX     = 8.0;
const float HALO_INNER_RING_PX = 14.0;
const float HALO_OUTER_RING_PX = 26.0;

vec3 box_blur_9tap(sampler2D tex, vec2 uv, vec2 texel, float radius_px) {
	vec3 sum = vec3(0.0);
	vec2 step = texel * radius_px;
	sum += texture(tex, uv + vec2(-1.0, -1.0) * step).rgb;
	sum += texture(tex, uv + vec2( 0.0, -1.0) * step).rgb;
	sum += texture(tex, uv + vec2( 1.0, -1.0) * step).rgb;
	sum += texture(tex, uv + vec2(-1.0,  0.0) * step).rgb;
	sum += texture(tex, uv                            ).rgb;
	sum += texture(tex, uv + vec2( 1.0,  0.0) * step).rgb;
	sum += texture(tex, uv + vec2(-1.0,  1.0) * step).rgb;
	sum += texture(tex, uv + vec2( 0.0,  1.0) * step).rgb;
	sum += texture(tex, uv + vec2( 1.0,  1.0) * step).rgb;
	return sum / 9.0;
}

vec3 halo_rings(sampler2D tex, vec2 uv, vec2 texel, float intensity) {
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
		vec3 ci = texture(tex, uv + dirs[i] * texel * radius_inner).rgb;
		vec3 co = texture(tex, uv + dirs[i] * texel * radius_outer).rgb;
		float li = max(ci.r, max(ci.g, ci.b));
		float lo = max(co.r, max(co.g, co.b));
		if (li > halo_threshold) {
			float s = (li - halo_threshold) * inv_above;
			halo += ci * (s * s) * 1.0;
		}
		if (lo > halo_threshold) {
			float s = (lo - halo_threshold) * inv_above;
			halo += co * (s * s) * 0.4;
		}
	}
	return (halo / 8.0) * intensity * halo_tint;
}

void fragment() {
	vec2 uv = UV;
	vec2 texel = TEXTURE_PIXEL_SIZE;

	// 1) Color base (nitido) o blureado segun blur_amount.
	vec3 sharp = texture(TEXTURE, uv).rgb;
	vec3 blurred = box_blur_9tap(TEXTURE, uv, texel, BLUR_RADIUS_PX);
	vec3 col = mix(sharp, blurred, clamp(blur_amount, 0.0, 1.0));

	// 2) Halos sumados.
	col += halo_rings(TEXTURE, uv, texel, clamp(halo_intensity, 0.0, 1.0));

	// 3) Perdida de contraste: mix con gris 0.5.
	col = mix(col, vec3(0.5), clamp(contrast_loss, 0.0, 1.0));

	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.5)), 1.0);
}
