// Shader de prueba VIEW_INDEX para Sprint 1.
// Pinta rojo en ojo izquierdo y azul en ojo derecho.
// Si en el Quest se ve correctamente esto, toda la base del "Blend" funciona:
//  - OpenXR esta activo
//  - Multiview esta habilitado
//  - XR Shaders esta habilitado (sin esto VIEW_INDEX no existe en el shader)
//  - El Quad esta en posicion delante de la camara estereo
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled;

void fragment() {
	if (VIEW_INDEX == VIEW_MONO_LEFT) {
		ALBEDO = vec3(1.0, 0.0, 0.0); // ojo izquierdo: rojo
	} else {
		ALBEDO = vec3(0.0, 0.3, 1.0); // ojo derecho: azul
	}
}
