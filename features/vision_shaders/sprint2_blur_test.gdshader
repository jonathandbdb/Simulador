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
// Numero de anillos extra (0=solo dos anillos base, 1=tercer anillo exterior).
// Escena nocturna: subir a 1.0+ para halos mas grandes con pupila dilatada.
uniform float halo_extra_rings_l : hint_range(0.0, 1.0) = 0.0;
uniform float halo_extra_rings_r : hint_range(0.0, 1.0) = 0.0;

// === Destello / Starburst ===
// Rayos radiales desde fuentes brillantes (aberracion difractiva de sutura).
// destello_intensity: cuanto suman los rayos al color base. 0 = apagado.
// destello_rayos: cantidad de rayos (4, 6, 8...). 0 = apagado.
uniform float destello_intensity_l : hint_range(0.0, 1.0) = 0.0;
uniform float destello_intensity_r : hint_range(0.0, 1.0) = 0.0;
uniform float destello_rayos_l     : hint_range(0.0, 12.0) = 0.0;
uniform float destello_rayos_r     : hint_range(0.0, 12.0) = 0.0;

// === Astigmatismo ===
// Blur 1D direccional: estira los puntos brillantes a lo largo del eje.
// astig_enabled: toggle por ojo (1.0 = activo, 0.0 = inactivo).
// bool uniforms no son soportados en Vulkan mobile (Quest) — se usa float.
// astig_magnitude: largo del streak en px (0 = apagado).
// astig_angle: angulo del eje en radianes (0 = horizontal).
uniform float astig_enabled_l   : hint_range(0.0, 1.0) = 0.0;
uniform float astig_enabled_r   : hint_range(0.0, 1.0) = 0.0;
uniform float astig_magnitude_l : hint_range(0.0, 50.0) = 0.0;
uniform float astig_magnitude_r : hint_range(0.0, 50.0) = 0.0;
uniform float astig_angle_l     : hint_range(0.0, 3.14159) = 0.0;
uniform float astig_angle_r     : hint_range(0.0, 3.14159) = 0.0;

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
// El desenfoque optico es proporcional al error de enfoque en DIOPTRIAS (1/dist),
// no en metros. De cerca las dioptrias cambian muy rapido (0.35 m=2.86 D,
// 0.70 m=1.43 D) y de lejos se aplanan; por eso al estirar el brazo el libro
// mejora de forma visible y a partir de ~2 m ya se ve nitido. profundidad_foco_m
// se convierte a una tolerancia dioptrica con DOF_M_TO_D, y MAX_DEFOCUS_D fija
// cuanto error de enfoque (en D) corresponde al desenfoque maximo.
const float MAX_DEFOCUS_D      = 3.0;    // error de enfoque (D) que satura el blur
const float DOF_M_TO_D         = 0.5;    // mapea profundidad_foco_m a tolerancia (D)
const float HALO_INNER_RING_PX = 18.0;   // primer anillo difractivo
const float HALO_OUTER_RING_PX = 32.0;   // segundo anillo difractivo (1.8x)
const float HALO_INNER_WEIGHT  = 1.0;
const float HALO_OUTER_WEIGHT  = 0.4;


float linear_depth_meters(float raw_depth, vec2 uv, mat4 inv_proj) {
	vec4 ndc = vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
	vec4 view = inv_proj * ndc;
	return length(view.xyz / view.w);
}

// Dioptrias de una distancia (1/m). Clamp a 5 cm para evitar division por ~0.
float diopters(float d) {
	return 1.0 / max(d, 0.05);
}

// Error de enfoque (en dioptrias) respecto al foco mas cercano que este activo.
// Trabajar en dioptrias hace que la mejoria al alejar un objeto cercano sea
// notoria (la curva 1/d es empinada cerca) y que de lejos todo quede nitido.
float defocus_diopters(float d, float f_far, float f_int, float f_near) {
	float dd = diopters(d);
	float best = 1.0e9;
	if (f_far  > 0.001) best = min(best, abs(dd - diopters(f_far)));
	if (f_int  > 0.001) best = min(best, abs(dd - diopters(f_int)));
	if (f_near > 0.001) best = min(best, abs(dd - diopters(f_near)));
	return best;
}

// Curva de desenfoque: nitido dentro de la profundidad de foco (tolerancia
// dioptrica), y sube de forma proporcional al error de enfoque hasta 'max_blur'
// cuando el objeto queda a MAX_DEFOCUS_D dioptrias de todo foco.
float blur_from_focus(float d, float f_far, float f_int, float f_near,
		float depth_of_focus_m, float max_blur) {
	float err_d = defocus_diopters(d, f_far, f_int, f_near);
	float tol_d = depth_of_focus_m * DOF_M_TO_D;   // zona nitida en dioptrias
	float over  = max(err_d - tol_d, 0.0);
	return max_blur * clamp(over / MAX_DEFOCUS_D, 0.0, 1.0);
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

// Halo realista: dos anillos concentricos + un tercer anillo opcional (nocturno).
// Cada anillo muestrea 8 direcciones; solo contribuyen pixeles brillantes.
// Falloff cuadratico simula la caida fisica de la luz con r^2.
// extra_rings: 0.0 = solo dos anillos base; 1.0 = tercer anillo exterior visible.
vec3 halo_rings(vec2 uv, vec2 texel, float intensity, float extra_rings) {
	if (intensity < 0.01) {
		return vec3(0.0);
	}
	vec2 dirs[8] = vec2[8](
		vec2( 1.0,  0.0), vec2(-1.0,  0.0), vec2( 0.0,  1.0), vec2( 0.0, -1.0),
		vec2( 0.7,  0.7), vec2(-0.7,  0.7), vec2( 0.7, -0.7), vec2(-0.7, -0.7)
	);
	float radius_inner = HALO_INNER_RING_PX * intensity;
	float radius_outer = HALO_OUTER_RING_PX * intensity;
	// Tercer anillo: 55 px escalado por intensidad y modulado por extra_rings.
	float radius_third = 55.0 * intensity;
	float inv_above = 1.0 / max(1.0 - halo_threshold, 0.001);

	vec3 halo = vec3(0.0);
	for (int i = 0; i < 8; i++) {
		vec3 ci = texture(screen_texture, uv + dirs[i] * texel * radius_inner).rgb;
		vec3 co = texture(screen_texture, uv + dirs[i] * texel * radius_outer).rgb;
		float li = dot(ci, vec3(0.2126, 0.7152, 0.0722));
		float lo = dot(co, vec3(0.2126, 0.7152, 0.0722));
		if (li > halo_threshold) {
			float strength = clamp((li - halo_threshold) * inv_above, 0.0, 1.0);
			halo += clamp(ci, 0.0, 1.0) * (strength * strength) * HALO_INNER_WEIGHT;
		}
		if (lo > halo_threshold) {
			float strength = clamp((lo - halo_threshold) * inv_above, 0.0, 1.0);
			halo += clamp(co, 0.0, 1.0) * (strength * strength) * HALO_OUTER_WEIGHT;
		}
		// Tercer anillo (nocturno, pupila dilatada).
		if (extra_rings > 0.01) {
			vec3 ct = texture(screen_texture, uv + dirs[i] * texel * radius_third).rgb;
			float lt = dot(ct, vec3(0.2126, 0.7152, 0.0722));
			if (lt > halo_threshold) {
				float strength = clamp((lt - halo_threshold) * inv_above, 0.0, 1.0);
				// Peso mas debil (0.4) y ligeramente azulado (efecto purkinje nocturno).
				halo += clamp(ct, 0.0, 1.0) * (strength * strength) * 0.4 * extra_rings
					* vec3(0.85, 0.95, 1.1);
			}
		}
	}
	// Promediar y aplicar tinte cromatico del halo.
	return (halo / 8.0) * intensity * halo_tint;
}

// Starburst: rayos radiales desde fuentes brillantes (sutura de IOL difractiva).
// Muestrea N_STEPS radios a lo largo de 'num_rays' direcciones igualmente
// espaciadas. Solo contribuyen pixeles sobre el umbral.
// Costo acotado: early-out si la luminancia del pixel base es baja.
vec3 starburst(vec2 uv, vec2 texel, float intensity, float num_rays) {
	if (intensity < 0.01 || num_rays < 1.0) {
		return vec3(0.0);
	}
	// Early-out rapido: si el propio pixel no es brillante, no hay rayo.
	vec3 base_col = texture(screen_texture, uv).rgb;
	float base_lum = dot(base_col, vec3(0.2126, 0.7152, 0.0722));
	if (base_lum < halo_threshold) {
		return vec3(0.0);
	}

	const int N_STEPS = 6;
	const float MAX_RAY_PX = 40.0;
	float inv_above = 1.0 / max(1.0 - halo_threshold, 0.001);
	float pi2 = 6.28318530718;
	int iray = int(clamp(num_rays, 1.0, 12.0));

	vec3 accum = vec3(0.0);
	float total_w = 0.0;
	for (int r = 0; r < iray; r++) {
		float angle = (float(r) / float(iray)) * pi2;
		vec2 dir = vec2(cos(angle), sin(angle));
		for (int s = 1; s <= N_STEPS; s++) {
			float t = float(s) / float(N_STEPS);
			float dist_px = t * MAX_RAY_PX;
			vec3 c = texture(screen_texture, uv + dir * texel * dist_px).rgb;
			float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
			if (lum > halo_threshold) {
				float strength = clamp((lum - halo_threshold) * inv_above, 0.0, 1.0);
				// Falloff lineal con la distancia para efecto de rayo que se desvanece.
				float w = strength * (1.0 - t);
				accum += clamp(c, 0.0, 1.0) * w;
				total_w += w;
			}
		}
	}
	if (total_w < 0.001) return vec3(0.0);
	return (accum / total_w) * intensity;
}

// Astigmatismo: streak 1D direccional de puntos brillantes.
// Blur lineal a lo largo del eje 'angle' (radianes), solo sobre umbral.
vec3 astigmatism_streak(vec2 uv, vec2 texel, float magnitude_px, float angle) {
	if (magnitude_px < 0.5) {
		return vec3(0.0);
	}
	// Early-out: si el pixel no es brillante, no aporta streak.
	vec3 base_col = texture(screen_texture, uv).rgb;
	float base_lum = dot(base_col, vec3(0.2126, 0.7152, 0.0722));
	if (base_lum < halo_threshold) {
		return vec3(0.0);
	}

	vec2 axis = vec2(cos(angle), sin(angle));
	const int N = 8;
	float inv_above = 1.0 / max(1.0 - halo_threshold, 0.001);

	vec3 streak = vec3(0.0);
	float total_w = 0.0;
	for (int i = -N; i <= N; i++) {
		if (i == 0) continue;
		float t = float(i) / float(N);
		float dist_px = t * magnitude_px;
		vec3 c = texture(screen_texture, uv + axis * texel * dist_px).rgb;
		float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
		if (lum > halo_threshold) {
			float strength = clamp((lum - halo_threshold) * inv_above, 0.0, 1.0);
			float w = strength * (1.0 - abs(t));
			streak += clamp(c, 0.0, 1.0) * w;
			total_w += w;
		}
	}
	if (total_w < 0.001) return vec3(0.0);
	// Intensidad fija 0.8: el streak no satura la imagen pero es claramente visible.
	return (streak / total_w) * 0.8;
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
	float halo_extra;
	float contrast_amount;
	float destello_int;
	float destello_n;
	float astig_on;
	float astig_mag;
	float astig_ang;
	if (VIEW_INDEX == VIEW_MONO_LEFT) {
		blur_amount    = blur_from_focus(eff_dist, foco_lejos_l, foco_intermedio_l,
			foco_cerca_l, profundidad_foco_l, desenfoque_max_l);
		halo_amount    = halo_intensity_l;
		halo_extra     = halo_extra_rings_l;
		contrast_amount = contrast_loss_l;
		destello_int   = destello_intensity_l;
		destello_n     = destello_rayos_l;
		astig_on       = astig_enabled_l;
		astig_mag      = astig_magnitude_l;
		astig_ang      = astig_angle_l;
	} else {
		blur_amount    = blur_from_focus(eff_dist, foco_lejos_r, foco_intermedio_r,
			foco_cerca_r, profundidad_foco_r, desenfoque_max_r);
		halo_amount    = halo_intensity_r;
		halo_extra     = halo_extra_rings_r;
		contrast_amount = contrast_loss_r;
		destello_int   = destello_intensity_r;
		destello_n     = destello_rayos_r;
		astig_on       = astig_enabled_r;
		astig_mag      = astig_magnitude_r;
		astig_ang      = astig_angle_r;
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
	color += halo_rings(uv, texel, halo_amount, halo_extra);

	// Destello/starburst: rayos radiales desde fuentes muy brillantes.
	// Solo activo cuando destello_intensity > 0 (escena nocturna con IOL difractiva).
	color += starburst(uv, texel, destello_int, destello_n);

	// Astigmatismo: streak 1D en el eje configurado por ojo.
	if (astig_on > 0.5) {
		color += astigmatism_streak(uv, texel, astig_mag, astig_ang);
	}

	ALBEDO = color;
	ALPHA = 1.0;
}
