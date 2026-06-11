class_name GlareSource
extends MeshInstance3D
## Billboard de glare procedural anclado a una fuente de luz real (farola,
## faro, piloto trasero, esfera del lens_lab).
##
## Reemplaza al gather screen-space de halo/starburst, que dependia de los
## mipmaps del backbuffer (no se generan en el Quest/multiview). Ver
## glare_billboard.gdshader para el detalle.
##
## Uso: GlareSource.attach(parent, pos_local, color, energia_relativa, beam_dir)
##   - beam_dir (espacio local del parent): direccion hacia donde APUNTA el haz.
##     Vector3.ZERO = omnidireccional (farolas). Con direccion, el glare solo se
##     ve cuando la luz mira a la camara (faros de frente / pilotos de atras).
##   - Material COMPARTIDO entre todas las fuentes (instance uniforms para
##     color/energia/seed) -> un solo shader compilado, draw calls baratos.
##   - El grupo "glare_billboards" permite ocultarlos todos al apagar el
##     post-proceso (comparacion "sin lentes").

const GLARE_SHADER := preload("res://features/vision_shaders/glare_billboard.gdshader")

static var _shared_mat: ShaderMaterial = null
static var _seed_counter: int = 0


static func attach(parent: Node3D, local_pos: Vector3, color: Color,
		energy: float, beam_dir: Vector3 = Vector3.ZERO) -> GlareSource:
	if _shared_mat == null:
		_shared_mat = ShaderMaterial.new()
		_shared_mat.shader = GLARE_SHADER
		# Dibujar DESPUES del quad de post-proceso (que cuelga a 5cm de la
		# camara y replica screen_texture, tapando todo el pase transparente
		# anterior). El glare se compone encima de la imagen ya procesada,
		# igual que hacia el shader screen-space (color += glare tras el blur).
		_shared_mat.render_priority = 10
	var g := GlareSource.new()
	g.name = "Glare"
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	g.mesh = quad
	g.material_override = _shared_mat
	g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# El vertex shader escala el quad en mundo (tamano angular constante):
	# el AABB local queda chico, este margen evita que el culling lo corte.
	g.extra_cull_margin = 64.0
	g.position = local_pos
	g.add_to_group("glare_billboards")
	parent.add_child(g)
	g.set_instance_shader_parameter("src_color", Vector3(color.r, color.g, color.b))
	g.set_instance_shader_parameter("src_energy", energy)
	g.set_instance_shader_parameter("src_dir", beam_dir)
	_seed_counter += 1
	g.set_instance_shader_parameter("seed", float(_seed_counter % 97))
	return g


## Mapea los parametros de lente de un ojo a los shader globals del glare.
## La llaman main.gd y lens_lab.gd desde vision_state_changed. `enabled`
## refleja halos_enabled del escenario (consultorio de dia = off).
const GLOBAL_MAP := {
	"halo_intensity":     ["glare_halo_l",  "glare_halo_r"],
	"halo_extra_rings":   ["glare_pupil_l", "glare_pupil_r"],
	"destello_intensity": ["glare_star_l",  "glare_star_r"],
	"destello_rayos":     ["glare_rays_l",  "glare_rays_r"],
}

static func set_eye_globals(eye: String, params: Dictionary, enabled: bool) -> void:
	var eye_idx := 0 if eye == "left" else 1
	for key in GLOBAL_MAP.keys():
		if params.has(key):
			var value := float(params[key]) if enabled else 0.0
			RenderingServer.global_shader_parameter_set(GLOBAL_MAP[key][eye_idx], value)
