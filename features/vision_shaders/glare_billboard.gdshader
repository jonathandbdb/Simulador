// glare_billboard.gdshader
//
// Halo difractivo + starburst PROCEDURALES anclados a una fuente de luz real.
//
// Por que existe: el gather screen-space (sprint2_blur_test) depende de los
// mipmaps del backbuffer, que en el Quest (multiview) NO se generan — los
// halos desaparecian en el visor (solo quedaba un granulado). Este billboard
// no lee NINGUNA textura: dibuja el glare con matematica pura sobre un quad
// que sigue a la camara, asi se ve identico en PC y en el visor, a cualquier
// distancia, y con costo casi nulo (solo los pixeles del quad).
//
// Como funciona:
//   - El quad se orienta a la camara y se escala con la DISTANCIA para que el
//     glare tenga tamano ANGULAR constante (el halo vive en el ojo, no en el
//     mundo: una farola lejana produce el mismo angulo de halo, mas tenue).
//   - El brillo cae ~1/d (fuente mas lejana deslumbra menos).
//   - Per-eye via VIEW_INDEX + shader globals glare_* (modo Blend asimetrico:
//     cada ojo dibuja SU halo/starburst segun su lente).
//   - Parametros de la lente (catalogo) llegan como GLOBALS seteados por
//     main.gd/lens_lab.gd en vision_state_changed. Color/energia de la fuente
//     llegan como instance uniforms (un material compartido para todas).

shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled,
		shadows_disabled, specular_disabled, fog_disabled;

// Lente por ojo (cero = sin efecto; los setea la app, no el inspector).
global uniform float glare_halo_l;
global uniform float glare_halo_r;
global uniform float glare_pupil_l;
global uniform float glare_pupil_r;
global uniform float glare_star_l;
global uniform float glare_star_r;
global uniform float glare_rays_l;
global uniform float glare_rays_r;

// Fuente concreta (por instancia, material compartido). OJO: "source_color"
// es palabra reservada de hint en gdshader — usar src_*.
instance uniform vec3 src_color = vec3(1.0, 1.0, 1.0);
instance uniform float src_energy = 1.0;     // brillo relativo (faro=1.0)
instance uniform float seed = 0.0;           // varia los rayos entre fuentes
// Direccion LOCAL (espacio del parent) hacia donde APUNTA el haz de la fuente.
// vec3(0) = fuente omnidireccional (farolas). Si esta seteada, el glare solo se
// ve cuando la fuente mira hacia la camara (faros de frente, pilotos de atras):
// un auto que viene de frente NO debe mostrar los halos rojos de sus pilotos.
instance uniform vec3 src_dir = vec3(0.0);

// === Calibracion angular (radianes) ===
// Equivalente a las fracciones de pantalla del shader screen-space:
// 0.11 del alto con FOV ~75-90 grados ~ 0.13 rad de radio a intensity=1.
const float HALO_ANG_RADIUS = 0.10;   // radio del halo a halo=1 (sin pupila)
const float PUPIL_GAIN      = 1.7;    // dilatacion pupilar agranda el halo
const float STAR_ANG_RADIUS = 0.22;   // largo del rayo a star=1
const float RING_POS        = 0.62;   // posicion del anillo difractivo (0..1)
const float RING_WIDTH      = 0.11;
const float DIST_REF_M      = 8.0;    // distancia con brillo nominal
const float TOWARD_CAM_FRAC = 0.10;   // corrimiento hacia la camara (evita
                                      // que el propio cabezal ocluya el quad)

varying float v_halo;     // intensidad de halo del ojo activo
varying float v_star;     // intensidad de starburst
varying float v_rays;     // cantidad de rayos
varying float v_pupil;    // dilatacion pupilar
varying float v_fade;     // atenuacion por distancia/energia
varying float v_halo_frac; // radio del halo relativo al quad (0..1)
varying float v_star_frac; // largo del rayo relativo al quad (0..1)

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	return fract(p * (p + p));
}

void vertex() {
	bool left = VIEW_INDEX == VIEW_MONO_LEFT;
	v_halo  = clamp(left ? glare_halo_l  : glare_halo_r, 0.0, 1.0);
	v_star  = clamp(left ? glare_star_l  : glare_star_r, 0.0, 1.0);
	v_rays  = left ? glare_rays_l : glare_rays_r;
	v_pupil = clamp(left ? glare_pupil_l : glare_pupil_r, 0.0, 1.0);

	vec3 origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 cam_pos = INV_VIEW_MATRIX[3].xyz;
	float dist = max(distance(origin, cam_pos), 0.2);
	vec3 toward = (cam_pos - origin) / dist;

	// Direccionalidad: atenuar por el angulo entre el haz y la camara. Una luz
	// que NO mira a la camara no deslumbra (pilotos de un auto que viene de
	// frente). De costado (dot~0) ya se apaga; el fundido evita un corte seco.
	float facing = 1.0;
	if (dot(src_dir, src_dir) > 0.25) {
		vec3 beam = normalize((MODEL_MATRIX * vec4(src_dir, 0.0)).xyz);
		facing = smoothstep(0.05, 0.35, dot(beam, toward));
	}

	float pupil_scale = mix(1.0, PUPIL_GAIN, v_pupil);
	float halo_r = HALO_ANG_RADIUS * v_halo * pupil_scale;
	float star_r = STAR_ANG_RADIUS * v_star;
	float ang_max = max(halo_r, star_r);

	if (ang_max < 0.004 || facing < 0.01) {
		// Sin efecto en este ojo: colapsar el quad (cero fragmentos).
		POSITION = vec4(0.0, 0.0, 2.0, 1.0);
		v_halo_frac = 0.0;
		v_star_frac = 0.0;
		v_fade = 0.0;
	} else {
		v_halo_frac = halo_r / ang_max;
		v_star_frac = star_r / ang_max;
		// Brillo: cae ~1/d respecto de la referencia (de cerca deslumbra mas),
		// y se apaga si el haz no mira a la camara (facing).
		v_fade = clamp(src_energy * DIST_REF_M / dist, 0.0, 1.0) * facing;

		// Billboard con tamano angular constante: radio mundial = dist * angulo.
		float radius_w = dist * ang_max;
		vec3 right = normalize(INV_VIEW_MATRIX[0].xyz);
		vec3 up = normalize(INV_VIEW_MATRIX[1].xyz);
		vec3 wpos = origin
				+ (right * VERTEX.x + up * VERTEX.y) * radius_w
				+ toward * (dist * TOWARD_CAM_FRAC);
		POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(wpos, 1.0));
	}
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float total = 0.0;

	// --- Halo: glow gaussiano + UN anillo difractivo (perfil continuo) ---
	if (v_halo_frac > 0.001) {
		float rh = r / v_halo_frac;
		float glow = exp(-rh * rh * 3.2);
		float dr = (rh - RING_POS) / RING_WIDTH;
		float ring = exp(-dr * dr);
		// El anillo pesa mas cuanto mas intensa la lente (trifocal marcado).
		total += (glow * 0.85 + ring * 0.75 * v_halo) * v_halo;
	}

	// --- Starburst: rayos radiales finos con variacion por rayo ---
	if (v_star_frac > 0.001 && v_rays >= 1.0) {
		float n = clamp(v_rays, 1.0, 16.0);
		float ang = atan(p.y, p.x);
		float sector_f = fract(ang / 6.28318530718 + 1.0) * n;  // 0..n
		float k = floor(sector_f + 0.5);
		float kk = mod(k, n);                  // id del rayo (con wrap)
		float h1 = hash11(kk * 12.9898 + seed * 7.31);
		float h2 = hash11(kk * 3.17 + seed * 19.1);
		// Jitter angular del centro del rayo (sin simetria mecanica).
		float d_sec = sector_f - k - (h1 - 0.5) * 0.35;
		float width = 0.055 + 0.05 * h2;       // ancho angular (frac. de sector)
		float spoke = exp(-(d_sec * d_sec) / (width * width));
		float ray_len = v_star_frac * mix(0.55, 1.0, h1);
		float rs = r / max(ray_len, 0.001);
		float falloff = pow(max(1.0 - rs, 0.0), 1.3);
		total += spoke * falloff * mix(0.5, 1.0, h2) * v_star * 1.3;
	}

	// Ventana de borde: el glow gaussiano NO llega a 0 en el borde del quad
	// (exp(-3.2) ~ 4% de brillo residual) y con blend_add sobre el cielo oscuro
	// ese corte abrupto se veia como un RECUADRO alrededor de cada halo. La
	// ventana fuerza un fundido continuo a 0 antes del borde; dentro de r<0.8
	// no cambia nada (smoothstep = 0 alli).
	float edge_fade = 1.0 - smoothstep(0.80, 0.98, r);
	// Color de la fuente; con pupila dilatada vira levemente a azul (Purkinje).
	vec3 col = mix(src_color, src_color * vec3(0.85, 0.95, 1.15), v_pupil * 0.45);
	ALBEDO = col * (total * v_fade * edge_fade);
}
