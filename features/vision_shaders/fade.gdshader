// fade.gdshader — Quad negro semitransparente para fade-to-black en VR.
//
// Usado en transiciones de escena (ej. dia/noche) para evitar el
// flash visual cuando se cambia DirectionalLight + Sky de golpe.
//
// Controlado via uniform `alpha` desde GDScript con un Tween.

shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_test_disabled, depth_draw_never;

uniform float alpha : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = alpha;
}
