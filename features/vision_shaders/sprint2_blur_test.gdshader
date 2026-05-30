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

// === Modelo de focos por ojo (metros). Foco = 0 => no usado ===
// La nitidez se calcula como distancia al foco mas cercano: si el objeto cae
// dentro de la profundidad de foco de alguno, se ve nitido; si no, se desenfoca
// hasta 'desenfoque_max'. Esta UNICA curva gobierna tanto la escena como el
// libro en la mano, asi no hay dos sistemas de blur compitiendo.
uniform float foco_lejos_l      : hint_range(0.0, 50.0) = 6.0;
uniform float foco_intermedio_l : hint_range(0.0, 50.0) = 0.0;
uniform float foco_cerca_l      : hint_range(0.0, 50.0) = 0.0;
uniform float foco_lejos_r      : hint_range(0.0, 50.0) = 6.0;
uniform float foco_intermedio_r : hint_range(0.0, 50.0) = 0.0;
uniform float foco_cerca_r      : hint_range(0.0, 50.0) = 0.0;

// Profundidad de foco (m): ancho de la zona nitida alrededor de cada foco.
// EDOF => alto (plateau ancho); trifocal => bajo (picos estrechos).
uniform float profundidad_foco_l : hint_range(0.05, 5.0) = 0.6;
uniform float profundidad_foco_r : hint_range(0.05, 5.0) = 0.6;

// Desenfoque maximo (0..1) cuando el objeto queda fuera de toda zona de foco.
uniform float desenfoque_max_l : hint_range(0.0, 1.0) = 0.9;
uniform float desenfoque_max_r : hint_range(0.0, 1.0) = 0.9;

// === Halo ===
uniform float halo_intensity_l : hint_range(0.0, 1.0) = 0.0;
uniform float halo_intensity_r : hint_range(0.0, 1.0) = 0.0;
uniform float halo_threshold   : hint_range(0.0, 1.0) = 0.75;
uniform vec3  halo_tint = vec3(1.05, 1.0, 0.78);  // amarillo-blanco realista

// === Perdida de contraste (sensibilidad al contraste reducida) ===
// Caracteristica de IOLs multifocales/trifocales: la luz se reparte entre
// varios focos, bajando la sensibilidad al contraste (imagen mas "lavada").
// 0 = sin perdida (monofocal), ~0.3 = trifocal en condiciones exigentes.
uniform float contrast_loss_l : hint_range(0.0, 0.6) = 0.0;
uniform float contrast_loss_r : hint_range(0.0, 0.6) = 0.0;

// === Libro en la mano (Sprint 10) ===
// El libro sostenido no escribe profundidad estable en el depth texture, asi que
// book_holder.gd calcula en CPU su distancia real a la camara y la pasa aca,
// junto con una mascara en pantalla. Dentro de la mascara usamos esta distancia
// con la MISMA curva de focos, en vez del depth. book_distance_m = 0 => sin libro.
uniform float book_distance_m = 0.0;
uniform vec2  book_screen_uv = vec2(0.5, 0.5);
uniform float book_screen_radius : hint_range(0.0, 0.5) = 0.0;

// === Constantes de muestreo ===
const float BLUR_RADIUS_PX     = 7.0;    // suavizado del kernel — menos artefactos blocky
const float CLEAR_RADIUS_M     = 0.15;   // tolerancia minima nitida alrededor del foco
const float HALO_INNER_RING_PX = 18.0;   // primer anillo difractivo
const float HALO_OUTER_RING_PX = 32.0;   // segundo anillo difractivo (1.8x)
const float HALO_INNER_WEIGHT  = 1.0;
const float HALO_OUTER_WEIGHT  = 0.4;


float linear_depth_meters(float raw_depth, vec2 uv, mat4 inv_proj) {
	vec4 ndc = vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
	vec4 view = inv_proj * ndc;
	return length(view.xyz / view.w);
}

// Distancia (m) al foco mas cercano que este activo (>0).
float dist_to_nearest_focus(float d, float f_far, float f_int, float f_near) {
	float best = 1.0e9;
	if (f_far  > 0.001) best = min(best, abs(d - f_far));
	if (f_int  > 0.001) best = min(best, abs(d - f_int));
	if (f_near > 0.001) best = min(best, abs(d - f_near));
	return best;
}

// Curva de desenfoque: nitido dentro de la profundidad de foco, sube hasta
// 'max_blur' a medida que el objeto se aleja de todo foco.
float blur_from_focus(float d, float f_far, float f_int, float f_near,
		float depth_of_focus, float max_blur) {
	float err = dist_to_nearest_focus(d, f_far, f_int, f_near);
	float outer = max(depth_of_focus, CLEAR_RADIUS_M + 0.001);
	return max_blur * smoothstep(CLEAR_RADIUS_M, outer, err);
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
		float li = dot(ci, vec3(0.2126, 0.7152, 0.0722));
		float lo = dot(co, vec3(0.2126, 0.7152, 0.0722));
		if (li > halo_threshold) {
			// Clamp del strength: evita que un pixel HDR (>1.0 en Forward+ lineal)
			// genere un halo desbordado. Saturamos a 1.0 antes del falloff^2.
			float strength = clamp((li - halo_threshold) * inv_above, 0.0, 1.0);
			halo += clamp(ci, 0.0, 1.0) * (strength * strength) * HALO_INNER_WEIGHT;
		}
		if (lo > halo_threshold) {
			float strength = clamp((lo - halo_threshold) * inv_above, 0.0, 1.0);
			halo += clamp(co, 0.0, 1.0) * (strength * strength) * HALO_OUTER_WEIGHT;
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

	// En la mascara del libro, su profundidad no es confiable: usamos la
	// distancia real calculada en CPU (book_distance_m) con la misma curva.
	float book_mask = 0.0;
	if (book_screen_radius > 0.0001 && book_distance_m > 0.0001) {
		float book_dist_uv = distance(uv, book_screen_uv);
		book_mask = 1.0 - smoothstep(book_screen_radius * 0.65, book_screen_radius, book_dist_uv);
	}
	float eff_dist = mix(dist_m, book_distance_m, book_mask);

	float blur_amount;
	float halo_amount;
	float contrast_amount;
	if (VIEW_INDEX == VIEW_MONO_LEFT) {
		blur_amount = blur_from_focus(eff_dist, foco_lejos_l, foco_intermedio_l,
			foco_cerca_l, profundidad_foco_l, desenfoque_max_l);
		halo_amount = halo_intensity_l;
		contrast_amount = contrast_loss_l;
	} else {
		blur_amount = blur_from_focus(eff_dist, foco_lejos_r, foco_intermedio_r,
			foco_cerca_r, profundidad_foco_r, desenfoque_max_r);
		halo_amount = halo_intensity_r;
		contrast_amount = contrast_loss_r;
	}
	blur_amount = clamp(blur_amount, 0.0, 1.0);

	vec3 base = texture(screen_texture, uv).rgb;
	vec3 blurred = box_blur_9tap(uv, texel, BLUR_RADIUS_PX * blur_amount);
	vec3 color = mix(base, blurred, blur_amount);

	// Perdida de contraste: comprime el rango alrededor del gris medio. Se aplica
	// a la imagen retiniana (base + blur) ANTES del halo, porque el halo es luz
	// dispersada adicional que se suma encima.
	color = (color - 0.5) * (1.0 - contrast_amount) + 0.5;

	// El halo simula la dispersion de luz de las IOL multifocales alrededor de
	// fuentes de luz REALES (lamparas, faros). Con tonemapping AGX la pagina del
	// libro iluminada NO se clipea a blanco: su luminancia queda por debajo del
	// umbral (halo_threshold ~0.9), por lo que NO genera halo a ninguna distancia.
	// Solo las fuentes muy brillantes (lampara de escritorio) superan el umbral y
	// producen el halo. Asi se evita el "blanco quemado" al alejar el libro y el
	// efecto sigue siendo clinicamente correcto: el halo depende del brillo de la
	// fuente, no de la distancia.
	color += halo_rings(uv, texel, halo_amount);

	ALBEDO = color;
	ALPHA = 1.0;
}
