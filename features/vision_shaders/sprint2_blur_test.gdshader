// sprint2_blur_test.gdshader
//
// Shader unificado de simulacion de visualizacion por IOL (intra-ocular lens).
//
// Que hace:
//   1. Lee SCREEN_TEXTURE y DEPTH_TEXTURE.
//   2. Convierte depth a distancia real en metros (INV_PROJECTION_MATRIX).
//   3. Blur dioptrico: error de enfoque (D) respecto al foco mas cercano,
//      proporcional al error, satura a MAX_DEFOCUS_D. Tolerancia (DoF) viene
//      de profundidad_foco_m * DOF_M_TO_D.
//   4. Perdida de contraste: compresion alrededor de gris medio.
//   5. Halo difractivo con escala ANGULAR REAL: el halo en pantalla escala con
//      1/distancia_a_la_fuente, lee depth del pixel brillante. halo_extra_rings
//      modula la dilatacion pupilar (escotopico).
//   6. Starburst angular: rayos radiales desde la fuente, largo escalado por
//      1/D_src. Cantidad de rayos parametrizable (0..16).
//   7. Astigmatismo: streak 1D direccional.
//   8. Bifurca con VIEW_INDEX para soporte Blend asimetrico por ojo.

shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never, blend_mix, cull_disabled;

// filter_linear_mipmap: Godot genera mipmaps del backbuffer una vez por frame.
// Muestrear un nivel de mip borroso (textureLod) en los halos/glare da suavidad
// "gratis" con MUCHAS menos muestras — clave para que corra en Quest 3 standalone.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap, repeat_disable;
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
// Dilatacion pupilar (0..1). 0 = pupila normal (dia); 1 = escotopica (noche).
// En la realidad, una pupila dilatada deja pasar mas luz por la zona difractiva
// de la IOL, agrandando el halo angular y agregando tinte azulado (Purkinje).
// El nombre del uniform se mantiene como "halo_extra_rings" para compatibilidad
// con el catalogo, pero su semantica ahora es la dilatacion pupilar.
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
uniform float astig_magnitude_l : hint_range(0.0, 160.0) = 0.0;
uniform float astig_magnitude_r : hint_range(0.0, 160.0) = 0.0;
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
// Recalibrado: error de enfoque (D) al que el blur llega al maximo. A 1.5 D, un
// objeto a distancia de lectura (~0.4-0.5 m => 2-2.5 D) visto con una lente
// enfocada a lejos (~0.17 D) queda claramente borroso (clinicamente, un monofocal
// sin gafas no puede leer de cerca). Lejos/intermedio siguen nitidos porque su
// error es <0.6 D. Antes era 3.0 y dejaba el cercano demasiado legible.
const float MAX_DEFOCUS_D      = 1.5;    // error de enfoque (D) que satura el blur
const float DOF_M_TO_D         = 0.5;    // mapea profundidad_foco_m a tolerancia (D)

// === Halo (rediseño Quest 3: mipmaps + sin depth) ===
// El radio del halo se basa en la INTENSIDAD de la lente (control clinico) y se
// modula por el BRILLO de la fuente: una luz mas brillante deslumbra mas y da
// halo mayor. Como una fuente lejana llega mas tenue (atenuacion), el brillo es
// un buen proxy de distancia SIN leer depth (que era la mitad del costo).
// El muestreo lee niveles de MIPMAP borrosos (textureLod), asi pocas muestras
// dan un halo suave y continuo. ~12 fetches (antes 168).
// Tamaño RELATIVO a la resolución (fracción del alto de pantalla), NO en píxeles
// fijos. En el Quest la resolución por ojo (~2000px) triplica la del preview de
// escritorio (~650px); con un radio en px fijo el halo quedaba diminuto (~3°)
// y casi invisible en el visor. Como fracción del alto, el halo conserva el
// MISMO tamaño angular en ambos. (Auditoría: "halos no se ven en el visor".)
const float HALO_MAX_R_FRAC      = 0.11;  // radio del halo a intensity=1 (frac. del alto)
const int   HALO_SAMPLES         = 18;    // con glare_excess (mips compensados) alcanza
// Un UNICO anillo difractivo suave (gaussiano), no oscilacion -> sin bandas negras.
const float HALO_RING_POS        = 0.70;
const float HALO_RING_WIDTH      = 0.18;
// Multiplicador del radio cuando la pupila esta dilatada (halo_extra_rings=1.0).
const float HALO_PUPIL_DILATION_GAIN = 1.7;

// === Starburst (rediseño Quest 3: mipmaps + variacion + sin depth) ===
// Largo del rayo en px a intensity=1, modulado por brillo de fuente. Rayos con
// longitud/intensidad/angulo variados por hash (sin simetria mecanica).
const float STARBURST_MAX_LEN_FRAC = 0.17;  // largo del rayo (fracción del alto)
// Pasos por rayo. El footprint del mip se ata al ESPACIADO entre pasos
// (cone-tracing), asi el rayo no tiene huecos a ninguna resolucion: con 6
// pasos en Quest el espaciado es ~31px y el mip cubre ~16px+bilinear.
const int   STARBURST_STEPS      = 6;


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

// Brillo de una fuente para decidir si genera halo/destello/streak. Usa el canal
// maximo (valor HSV), NO luminancia: asi una luz ROJA pura (luminancia ~0.21,
// pero perceptualmente una fuente brillante) dispara los efectos igual que la
// verde o la amarilla. Con luminancia, el semaforo en rojo nunca hacia halo.
float src_brightness(vec3 c) {
	return max(c.r, max(c.g, c.b));
}

// === Energia de glare consciente del nivel de mip ===
// Problema que resuelve: un faro lejano subtiende ~10-20 px; muestreado a un
// mip alto su brillo se DILUYE por el promedio del area (un blob de 20px a
// lod 5 queda en ~0.37) y el umbral duro 0.72 lo descartaba por completo.
// Por eso en el Quest (buffer ~2200px => lods altos en el gather) los halos
// solo aparecian con la fuente pegada a la camara y el starburst no se veia.
// Modelo: el umbral efectivo DECAE con el lod (a mips altos el ambiente
// nocturno es casi negro: cualquier energia es de una fuente) y el exceso se
// COMPENSA por la dilucion (~4^lod de area, restauramos 2^(comp*lod) con
// tope). Invariante clave: a lod 0 esto es EXACTAMENTE la formula anterior
// (thr = halo_threshold, comp = 1) -> el look validado de cerca no cambia.
// La pintura vial promediada a mip alto (~0.10-0.18) queda bajo GLARE_FLOOR
// y ademas surface_factor() la suprime como segunda guarda.
const float GLARE_THR_DECAY   = 0.35; // thr_eff = halo_threshold * 2^(-decay*lod)
// Piso del umbral: DEBE quedar por encima del valor en pantalla de las
// superficies mate de la escena (pintura vial 0.45 unshaded ~0.27 con
// Filmic 0.6) para que NUNCA generen glare a ningun lod. Con 0.32, las
// fuentes chicas dejan de contribuir alrededor de lod ~4.5 (footprint
// ~24-48px) — suficiente para faros reales a 10-80 m; solo una fuente
// puntual minuscula y lejisima pierde su halo (clinicamente irrelevante).
const float GLARE_FLOOR       = 0.32;
const float GLARE_ENERGY_COMP = 0.7;  // restaura 2^(comp*lod) de la dilucion
const float GLARE_COMP_MAX    = 14.0; // tope de compensacion
const float GLARE_EXCESS_CAP  = 1.2;  // tope por muestra: limita tambien la
                                      // varianza del dither (sin "arenilla")

float glare_excess(float lum, float lod) {
	float thr = max(halo_threshold * exp2(-GLARE_THR_DECAY * lod), GLARE_FLOOR);
	float excess = max(lum - thr, 0.0) / max(1.0 - thr, 0.001);
	float comp = min(exp2(GLARE_ENERGY_COMP * lod), GLARE_COMP_MAX);
	return min(excess * comp, GLARE_EXCESS_CAP);
}

// True si el uv cae dentro de la mascara del objeto de lectura (libro/celular).
// Esos objetos son TARGETS DE LECTURA, no fuentes de luz: aunque su pantalla
// supere el umbral de brillo, NO deben generar halo ni starburst (igual que la
// pagina del libro del consultorio). Se excluyen como fuente en halo/starburst.
bool is_reading_target(vec2 uv) {
	if (book_screen_radius <= 0.0001 || book_distance_m <= 0.0001) {
		return false;
	}
	return distance(uv, book_screen_uv) < book_screen_radius;
}

// Hash 2D -> [0,1). Usado para rotar el patron de muestreo del halo por pixel
// (dithering): sin esto, el halo de una fuente queda como N_DIRS*N_RINGS puntos
// discretos (aspecto "blocky"); con una rotacion aleatoria por pixel esos puntos
// se reparten en angulos distintos y el halo se ve continuo.
float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Halo difractivo SUAVE (reescrito para realismo + costo).
// En vez de anillos*direcciones con coseno oscilante (creaba bandas negras) y
// jitter por pixel (ruido), muestrea HALO_SAMPLES puntos en una espiral de
// Fibonacci que cubre el disco del halo de forma uniforme. El perfil radial es
// continuo: un glow gaussiano central + UN anillo difractivo suave (gaussiano),
// sin oscilacion -> sin pixeles negros intermedios. ~24 fetches (vs 168 antes).
//   - el radio del halo escala 1/distancia (angulo fijo)
//   - pupil_dilation agranda el halo y vira a azulado (Purkinje)
//   - el halo hereda el color de la fuente (faro rojo -> halo rojo)
vec3 halo_rings(vec2 uv, vec2 texel, float intensity, float pupil_dilation,
		mat4 inv_proj) {
	if (intensity < 0.01) {
		return vec3(0.0);
	}
	float pupil = clamp(pupil_dilation, 0.0, 1.0);
	float scale = mix(1.0, HALO_PUPIL_DILATION_GAIN, pupil);
	float h_px = 1.0 / texel.y;                         // alto de pantalla en px
	float r_max = HALO_MAX_R_FRAC * h_px * intensity * scale;   // radio relativo a la resolución
	if (r_max < 1.5) {
		return vec3(0.0);
	}
	vec3 night_tint = mix(halo_tint, vec3(0.85, 0.95, 1.1), pupil * 0.6);
	float ring_amt = clamp(intensity, 0.0, 1.0);

	// Espiral de Fibonacci con offset rotacional por bloque (continuo, sin ruido
	// granular). Cada muestra lee un nivel de MIPMAP proporcional al radio: el
	// borde del halo usa mips mas borrosos -> suave y barato.
	float ga = 2.39996323;
	// Dither por bloque de 2px (mas fino que 4px: menos "arenilla" en el borde)
	// + jitter RADIAL con el mismo hash: las muestras de pixeles vecinos caen
	// en radios distintos y el rim del halo se integra suave.
	float dith = hash12(floor(uv / (texel * 2.0)));
	float rot = dith * 6.28318530718;
	float texel_px = 1.0 / texel.x;   // ancho en px para estimar el nivel de mip

	vec3 halo = vec3(0.0);
	float wsum = 0.0;
	for (int s = 0; s < HALO_SAMPLES; s++) {
		float fs = (float(s) + dith) / float(HALO_SAMPLES);
		float rn = sqrt(fs);                 // posicion radial 0..1 (densa al centro)
		float ang = float(s) * ga + rot;
		vec2 dir = vec2(cos(ang), sin(ang));
		float step_px = rn * r_max;
		vec2 suv = uv + dir * step_px * texel;
		if (is_reading_target(suv)) {
			continue;
		}
		// Nivel de mip: crece con el radio (muestras lejanas mas borrosas).
		float lod = clamp(log2(max(step_px, 1.0)) - 1.0, 0.0, 5.0);
		vec3 c = textureLod(screen_texture, suv, lod).rgb;
		float lum = src_brightness(c);
		// Umbral/energia consciente del lod: una fuente CHICA y lejana diluida
		// por el mip sigue contribuyendo (antes el umbral duro la descartaba y
		// el halo solo aparecia con la fuente pegada a la camara).
		float excess = glare_excess(lum, lod);
		// Perfil radial CONTINUO: glow gaussiano + un unico anillo suave (gaussiano).
		float glow = exp(-rn * rn * 3.0);
		float d_ring = (rn - HALO_RING_POS) / HALO_RING_WIDTH;
		float ring = exp(-d_ring * d_ring);
		float profile = mix(glow, max(glow * 0.55, ring), ring_amt);
		halo += clamp(c, 0.0, 1.0) * (excess * profile);
		wsum += profile;
	}
	if (wsum < 0.001) {
		return vec3(0.0);
	}
	vec3 halo_col = halo / wsum;         // promedio ponderado -> suave (sin granos)
	float mx = max(halo_col.r, max(halo_col.g, halo_col.b));
	float mn = min(halo_col.r, min(halo_col.g, halo_col.b));
	float sat = (mx - mn) / max(mx, 0.001);
	vec3 tint = mix(night_tint, vec3(1.0), clamp(sat, 0.0, 1.0));
	return halo_col * intensity * tint * 1.2;   // ganancia: visible tras promediar
	// (1.6 -> 1.2: glare_excess compensa la dilucion, la ganancia vieja saturaba)
}

// Starburst angular (reescrito). Los rayos se EXTIENDEN desde la fuente hacia el
// fondo oscuro. La version anterior solo corria sobre pixeles ya brillantes y
// acumulaba muestras tambien brillantes, por lo que nunca dibujaba rayos hacia
// la oscuridad (efecto invisible). Ahora, igual que halo_rings, cada pixel mira
// a lo largo de N direcciones radiales buscando una fuente; si la encuentra
// dentro del largo angular del rayo (escala 1/D_src), este pixel cae sobre un
// rayo de esa fuente y se ilumina, con atenuacion hacia la punta. El resultado
// es aditivo (sin normalizar) para conservar el degrade del rayo.
vec3 starburst(vec2 uv, vec2 texel, float intensity, float num_rays, mat4 inv_proj) {
	if (intensity < 0.01 || num_rays < 1.0) {
		return vec3(0.0);
	}
	float pi2 = 6.28318530718;
	float h_px = 1.0 / texel.y;                         // alto de pantalla en px
	float max_len = STARBURST_MAX_LEN_FRAC * h_px;      // largo relativo a la resolución
	int iray = int(clamp(num_rays, 1.0, 16.0));

	// Gather a lo largo de iray direcciones radiales. Cada rayo: longitud, brillo y
	// jitter angular variados por hash -> sin simetria mecanica. El largo del rayo
	// se basa en intensity (sin depth) y se modula por el brillo de la fuente. Los
	// pasos lejanos leen mipmaps borrosos (textureLod) para un trazo suave y barato.
	vec3 accum = vec3(0.0);
	for (int r = 0; r < iray; r++) {
		float h = hash12(vec2(float(r) * 12.9898, 7.233));
		float h2 = hash12(vec2(float(r) * 3.17, 19.1));
		float angle = (float(r) + (h - 0.5) * 0.7) / float(iray) * pi2;
		vec2 dir = vec2(cos(angle), sin(angle));
		float ray_len_px = max_len * intensity * mix(0.5, 1.0, h);
		float ray_gain = mix(0.45, 1.0, h2);
		if (ray_len_px < 1.0) {
			continue;
		}
		// CONE-TRACING: el footprint del mip se ata al espaciado entre pasos.
		// Antes el lod era casi 0 (footprint ~3px) con pasos cada 12-23px en el
		// buffer del Quest -> casi todos los pasos PERDIAN la fuente de ~5-10px
		// y el destello era invisible en el visor (y con "cuentas" en PC).
		// Con footprint = espaciado/2 el rayo es continuo a cualquier resolucion.
		float spacing_px = ray_len_px / float(STARBURST_STEPS);
		float lod_base = clamp(log2(max(spacing_px, 1.0)) - 0.5, 0.0, 4.0);
		// Jitter de FASE por pixel: corre las posiciones de los pasos a lo
		// largo del rayo en cada pixel. Sin esto, cada paso deja un "blob"
		// discreto y el rayo se ve como cuentas (beading); con la fase
		// jitterada los pixeles vecinos muestrean posiciones distintas y el
		// trazo se integra continuo.
		float phase = hash12(uv * vec2(521.7, 233.9) + vec2(float(r)));
		for (int s = 1; s <= STARBURST_STEPS; s++) {
			float t = (float(s) - phase) / float(STARBURST_STEPS);
			float step_px = t * ray_len_px;
			vec2 suv = uv + dir * texel * step_px;
			if (is_reading_target(suv)) {
				continue;
			}
			// Taper: cerca de la fuente (t chico) el footprint baja -> rayo FINO
			// en la base; hacia la punta sube -> cobertura sin huecos. Los rayos
			// reales tambien se ensanchan levemente al alejarse de la fuente.
			float lod = max(lod_base - (1.0 - t) * 0.7, 0.0);
			vec3 c = textureLod(screen_texture, suv, lod).rgb;
			float lum = src_brightness(c);
			// Energia consciente del lod (sin gate duro): la fuente diluida por
			// el mip sigue alimentando el rayo.
			float strength = clamp(glare_excess(lum, lod), 0.0, 1.0);
			if (strength > 0.0) {
				float core = strength * strength;           // solo el nucleo -> rayo fino
				float falloff = pow(1.0 - t, 1.5);           // degrade suave hacia la punta
				accum += clamp(c, 0.0, 1.0) * (core * falloff * ray_gain);
			}
		}
	}
	return clamp(accum, vec3(0.0), vec3(2.0)) * intensity;
}

// Astigmatismo: blur direccional 1D CONTINUO (convolucion gaussiana a lo largo
// del eje). La version anterior SUMABA el color de la fuente en posiciones
// discretas, por lo que se veian copias de la fuente (circulitos). Aca hacemos
// un promedio ponderado gaussiano del "exceso de luz" sobre el eje: la fuente se
// ESPARCE en un trazo suave que se desvanece en los extremos, sin repeticiones.
vec3 astigmatism_streak(vec2 uv, vec2 texel, float magnitude_px, float angle) {
	if (magnitude_px < 0.5) {
		return vec3(0.0);
	}
	vec2 axis = vec2(cos(angle), sin(angle));
	// 18 muestras con mip LEVE: el mip alto emborrona la fuente y le quita brillo
	// (el streak se apaga); un mip bajo solo tapa los huecos del muestreo sin matar
	// la fuente. Gaussiana -> trazo continuo sin escalones ni circulitos.
	const int N = 13;
	const float SIGMA = 0.45;
	float inv_above = 1.0 / max(1.0 - halo_threshold, 0.001);
	float inv2s2 = 1.0 / (2.0 * SIGMA * SIGMA);
	float lod = clamp(log2(max(magnitude_px / float(N), 1.0)) - 1.0, 0.0, 1.5);

	vec3 streak = vec3(0.0);
	float wsum = 0.0;
	for (int i = -N; i <= N; i++) {
		float t = float(i) / float(N);
		float gw = exp(-t * t * inv2s2);
		vec2 suv = uv + axis * t * magnitude_px * texel;
		vec3 c = textureLod(screen_texture, suv, lod).rgb;
		float lum = src_brightness(c);
		float excess = max(lum - halo_threshold, 0.0) * inv_above;
		streak += clamp(c, 0.0, 1.0) * (excess * gw);
		wsum += gw;
	}
	return clamp(streak / max(wsum, 0.001), vec3(0.0), vec3(2.0)) * 2.2;
}

// Factor (0..1) para suprimir el glare sobre SUPERFICIES brillantes extensas
// (calzada/cebra iluminada por las farolas): solo las FUENTES de luz puntuales
// (faros, semaforo, farolas) deben deslumbrar, no una superficie reflectante.
// Truco con mipmaps (barato, 1 fetch por pixel): una fuente puntual es brillante
// en el detalle pero su entorno AMPLIO (mip alto) es oscuro; una superficie
// iluminada es brillante tambien en el area amplia. Si el area amplia alrededor
// del pixel es brillante y uniforme, esta sobre una superficie -> suprimir.
float surface_factor(vec2 uv, vec2 texel) {
	// Muestreo del "area amplia" SIN mipmaps: en multiview (Quest) los mipmaps del
	// backbuffer pueden no generarse, y entonces textureLod() devolvia el nivel 0
	// (el pixel brillante) como "area" -> el glare se suprimia por completo y los
	// halos DESAPARECIAN en el visor. Con taps explicitos a nivel 0 el resultado
	// es identico en escritorio y Quest. (Auditoría: "halos no se ven en el visor".)
	float h_px = 1.0 / texel.y;
	float r = 0.035 * h_px;   // radio del muestreo (fraccion del alto, ~consistente)
	float area = 0.0;
	for (int i = 0; i < 6; i++) {
		float a = float(i) * 1.04719755;   // 60°
		vec2 d = vec2(cos(a), sin(a));
		area += src_brightness(texture(screen_texture, uv + d * r * texel).rgb);
	}
	area /= 6.0;
	float surf = 1.0 - smoothstep(0.28, 0.50, area);
	// Excepcion para FUENTES PUNTUALES (faros de autos, farolas): si el pixel
	// central destaca mucho sobre el area amplia, es un pico de luz, no una
	// superficie -> NO suprimir, aunque el area sea brillante. Una calzada/cebra
	// iluminada es uniforme (centro ~ area) -> el pico es ~0 -> se suprime igual.
	float center = src_brightness(texture(screen_texture, uv).rgb);
	float peak = smoothstep(0.12, 0.30, center - area);
	return max(surf, peak);
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
	// El 9-tap solo corre cuando hay desenfoque real: en pixeles en foco
	// (blur_amount ~ 0) se evitan 9 fetches sin cambiar el resultado (mix con
	// peso ~0 ya devolvia 'base'). La rama es coherente en regiones amplias
	// (todo el fondo en foco), asi que el ahorro es efectivo en GPU.
	vec3 color = base;
	if (blur_amount > 0.001) {
		vec3 blurred = box_blur_9tap(uv, texel, BLUR_RADIUS_PX * blur_amount);
		color = mix(base, blurred, blur_amount);
	}

	// Perdida de contraste: comprime el rango de luminancia. Se aplica a la imagen
	// retiniana (base + blur) ANTES del halo, porque el halo es luz dispersada
	// adicional que se suma encima. El pivote es BAJO (0.22), no el gris medio:
	// asi reducir el contraste NO levanta los negros hasta gris (de noche el cielo
	// negro debe seguir oscuro). Clinicamente la perdida de sensibilidad al
	// contraste lava sobre todo las zonas de bajo contraste, no agrega un velo gris
	// plano sobre el negro puro.
	const float CONTRAST_PIVOT = 0.22;
	color = (color - CONTRAST_PIVOT) * (1.0 - contrast_amount) + CONTRAST_PIVOT;

	// El halo simula la dispersion de luz de las IOL multifocales alrededor de
	// fuentes de luz REALES (lamparas, faros). Con tonemapping AGX la pagina del
	// libro iluminada NO se clipea a blanco: su luminancia queda por debajo del
	// umbral (halo_threshold ~0.9), por lo que NO genera halo a ninguna distancia.
	// Solo las fuentes muy brillantes (lampara de escritorio) superan el umbral y
	// producen el halo. Asi se evita el "blanco quemado" al alejar el libro y el
	// efecto sigue siendo clinicamente correcto: el halo depende del brillo de la
	// fuente, no de la distancia.
	// Supresion de superficies extensas: el glare solo nace de fuentes puntuales,
	// no de la calzada/cebra iluminada (que de noche satura a casi blanco).
	// Glare (halo + starburst + astigmatismo). Estos parametros son uniforms
	// (constantes por ojo), asi que la rama es TOTALMENTE coherente — sin
	// divergencia. Cuando la lente del ojo no activa ningun glare (p.ej. el
	// consultorio de dia con halos OFF) se evitan por completo surface_factor
	// (3 fetches, 2 de ellos a mips) y las funciones de glare, sin cambiar el
	// resultado (antes surf se computaba y se multiplicaba por ceros).
	bool has_halo  = halo_amount > 0.01;
	bool has_star  = destello_int > 0.01 && destello_n >= 1.0;
	bool has_astig = astig_on > 0.5 && astig_mag >= 0.5;
	if (has_halo || has_star || has_astig) {
		// Supresion de superficies extensas: el glare solo nace de fuentes
		// puntuales, no de la calzada/cebra iluminada (que de noche satura).
		float surf = surface_factor(uv, texel);
		if (has_halo) {
			color += halo_rings(uv, texel, halo_amount, halo_extra, INV_PROJECTION_MATRIX) * surf;
		}
		if (has_star) {
			color += starburst(uv, texel, destello_int, destello_n, INV_PROJECTION_MATRIX) * surf;
		}
		if (has_astig) {
			color += astigmatism_streak(uv, texel, astig_mag, astig_ang) * surf;
		}
	}

	ALBEDO = color;
	ALPHA = 1.0;
}
