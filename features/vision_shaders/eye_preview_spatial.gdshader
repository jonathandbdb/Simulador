// eye_preview_spatial.gdshader (Sprint 7 polish — server-side por ojo)
//
// Variante simplificada del shader del Sprint 2 para correr DENTRO de los
// SubViewports de captura del StreamingCapture. A diferencia del shader
// principal del visor (sprint2_blur_test.gdshader), este NO usa VIEW_INDEX
// ni DEPTH_TEXTURE: una instancia por ojo, uniforms planos. Esto baja el
// costo y permite capturar dos vistas a frecuencia reducida (5 Hz cada
// una) sin pegarle a los 90 FPS del render principal.
//
// Va sobre un QuadMesh hijo de la Camera3D del SubViewport (offset -0.1 z),
// con render_mode unshaded + depth_test_disabled como el del visor.

shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never, blend_mix, cull_disabled;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear, repeat_disable;

uniform float blur_amount    : hint_range(0.0, 1.0) = 0.0;
uniform float halo_intensity : hint_range(0.0, 1.0) = 0.0;
uniform float contrast_loss  : hint_range(0.0, 1.0) = 0.0;
uniform float halo_threshold : hint_range(0.0, 1.0) = 0.7;
uniform vec3  halo_tint = vec3(1.05, 1.0, 0.78);

const float BLUR_RADIUS_PX     = 10.0;
const float HALO_INNER_RING_PX = 16.0;
const float HALO_OUTER_RING_PX = 28.0;

vec3 box_blur_9tap(vec2 uv, vec2 texel, float radius_px) {
	vec3 sum = vec3(0.0);
	vec2 step = texel * radius_px;
	sum += texture(screen_texture, uv + vec2(-1.0, -1.0) * step).rgb;
	sum += texture(screen_texture, uv + vec2( 0.0, -1.0) * step).rgb;
	sum += texture(screen_texture, uv + vec2( 1.0, -1.0) * step).rgb;
	sum += texture(screen_texture, uv + vec2(-1.0,  0.0) * step).rgb;
	sum += texture(screen_texture, uv                            ).rgb;
	sum += texture(screen_texture, uv + vec2( 1.0,  0.0) * step).rgb;
	sum += texture(screen_texture, uv + vec2(-1.0,  1.0) * step).rgb;
	sum += texture(screen_texture, uv + vec2( 0.0,  1.0) * step).rgb;
	sum += texture(screen_texture, uv + vec2( 1.0,  1.0) * step).rgb;
	return sum / 9.0;
}

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
	vec2 uv = SCREEN_UV;
	vec2 texel = 1.0 / vec2(textureSize(screen_texture, 0));

	vec3 sharp = texture(screen_texture, uv).rgb;
	vec3 blurred = box_blur_9tap(uv, texel, BLUR_RADIUS_PX);
	vec3 col = mix(sharp, blurred, clamp(blur_amount, 0.0, 1.0));

	col += halo_rings(uv, texel, clamp(halo_intensity, 0.0, 1.0));
	col = mix(col, vec3(0.5), clamp(contrast_loss, 0.0, 1.0));

	ALBEDO = clamp(col, vec3(0.0), vec3(1.5));
}
