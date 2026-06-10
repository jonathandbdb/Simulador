extends Node
## Harness temporal de QA a resolucion Quest (borrar al cierre).
##
## Monta lens_lab dentro de un SubViewport de 2064x2208 (buffer por-ojo del
## Quest 3) para reproducir en PC los fallos de muestreo del glare que solo
## aparecen a alta resolucion. Saca screenshots y mide el costo GPU del
## viewport como proxy relativo.
##
## Uso: godot --path . res://tmp_lens_hires.tscn -- --tag base [--scene ruta]

const LENS_LAB := preload("res://features/scenarios/lens_lab/lens_lab.tscn")
const RUTA_NOCHE := preload("res://features/scenarios/ruta_noche/ruta_noche.tscn")
const POST_SHADER := preload("res://features/vision_shaders/sprint2_blur_test.gdshader")
const OUT_DIR := "res://.godot/glare_shots"
const QUEST_SIZE := Vector2i(2064, 2208)
const PC_SIZE := Vector2i(605, 648)

var svp: SubViewport
var lab: Node3D
var tag: String = "base"
var scene_mode: String = "lab"
var ruta_mat: ShaderMaterial


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--tag" and i + 1 < args.size():
			tag = args[i + 1]
		if args[i] == "--scene" and i + 1 < args.size():
			scene_mode = args[i + 1]
	get_window().size = Vector2i(740, 790)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	svp = SubViewport.new()
	svp.size = QUEST_SIZE
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var cont := SubViewportContainer.new()
	cont.stretch = false
	cont.scale = Vector2(0.34, 0.34)
	cont.add_child(svp)
	add_child(cont)

	RenderingServer.viewport_set_measure_render_time(svp.get_viewport_rid(), true)
	if scene_mode == "ruta":
		_setup_ruta()
		_run_ruta()
	else:
		lab = LENS_LAB.instantiate()
		svp.add_child(lab)
		_add_road_proxy()
		_run()


## Replica el setup de main.gd para la escena nocturna real (NIGHT_PARAMS +
## camara del paciente + quad de post-proceso con panoptix), sin XR.
func _setup_ruta() -> void:
	var ruta := RUTA_NOCHE.instantiate()
	svp.add_child(ruta)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.02, 0.05)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.08, 0.09, 0.14)
	env.ambient_light_energy = 0.40
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_strength = 1.0
	env.glow_bloom = 0.1
	env.glow_hdr_threshold = 1.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 0.6
	env.tonemap_white = 8.0
	var we := WorldEnvironment.new()
	we.environment = env
	svp.add_child(we)

	var moon := DirectionalLight3D.new()
	moon.light_energy = 0.04
	moon.light_color = Color(0.7, 0.75, 1.0)
	moon.rotation_degrees = Vector3(-40.0, -20.0, 0.0)
	svp.add_child(moon)

	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 1.6, 0.0)
	cam.fov = 75.0
	cam.current = true
	svp.add_child(cam)

	var quad_mesh := QuadMesh.new()
	quad_mesh.size = Vector2(2.0, 2.0)
	var quad := MeshInstance3D.new()
	quad.mesh = quad_mesh
	quad.position = Vector3(0.0, 0.0, -0.05)
	quad.extra_cull_margin = 16384.0
	ruta_mat = ShaderMaterial.new()
	ruta_mat.shader = POST_SHADER
	ruta_mat.set_shader_parameter("halo_threshold", 0.72)
	# Panoptix en ambos ojos (efectos maximos para detectar falsos glares).
	var pan := {
		"foco_lejos": 6.0, "foco_intermedio": 0.6, "foco_cerca": 0.4,
		"profundidad_foco": 1.0, "desenfoque_max": 0.55,
		"halo_intensity": 0.6, "halo_extra_rings": 0.8,
		"contrast_loss": 0.2, "destello_intensity": 0.5, "destello_rayos": 9.0,
	}
	for key in pan.keys():
		ruta_mat.set_shader_parameter(key + "_l", pan[key])
		ruta_mat.set_shader_parameter(key + "_r", pan[key])
	quad.material_override = ruta_mat
	cam.add_child(quad)


func _run_ruta() -> void:
	await _settle(2.0)
	await _shot("ruta_panoptix_a")
	var gpu := await _gpu_avg(1.2)
	await _settle(3.0)
	await _shot("ruta_panoptix_b")
	print("GPU_MS tag=%s ruta_panoptix=%.2f" % [tag, gpu])
	get_tree().quit()


func _run() -> void:
	await _settle(1.5)
	# panoptix es el default de lens_lab (efectos pronunciados).
	await _shot("panoptix_2208")
	var gpu_pan := await _gpu_avg(1.2)

	DataManager.apply_lens("monofocal", "both")
	await _settle(0.6)
	await _shot("monofocal_2208")

	DataManager.apply_lens("vivity", "both")
	await _settle(0.6)
	await _shot("vivity_2208")

	# Astigmatismo (vara de calidad — su look no debe cambiar con el fix).
	DataManager.apply_lens("monofocal", "both")
	await _settle(0.4)
	lab._shader_mat.set_shader_parameter("astig_enabled_l", 1.0)
	lab._shader_mat.set_shader_parameter("astig_enabled_r", 1.0)
	lab._shader_mat.set_shader_parameter("astig_magnitude_l", 120.0)
	lab._shader_mat.set_shader_parameter("astig_magnitude_r", 120.0)
	lab._shader_mat.set_shader_parameter("astig_angle_l", 0.5)
	lab._shader_mat.set_shader_parameter("astig_angle_r", 0.5)
	await _settle(0.5)
	await _shot("astig_2208")
	lab._shader_mat.set_shader_parameter("astig_enabled_l", 0.0)
	lab._shader_mat.set_shader_parameter("astig_enabled_r", 0.0)

	# Costo GPU con post-proceso apagado (baseline de escena).
	DataManager.apply_lens("panoptix", "both")
	await _settle(0.5)
	lab._toggle_post_process()
	await _settle(0.5)
	var gpu_off := await _gpu_avg(1.2)
	lab._toggle_post_process()
	await _settle(0.3)

	# Comparacion a resolucion de ventana PC (donde "funcionaba").
	svp.size = PC_SIZE
	await _settle(0.8)
	await _shot("panoptix_648")

	print("GPU_MS tag=%s panoptix=%.2f post_off=%.2f delta=%.2f" % [
		tag, gpu_pan, gpu_off, gpu_pan - gpu_off,
	])
	get_tree().quit()


## Proxy de calzada/cebra: quad gris mate como la pintura vial de ruta_noche
## (unshaded ~0.45). NO debe generar glare con el umbral lod-aware nuevo.
func _add_road_proxy() -> void:
	var plate := MeshInstance3D.new()
	plate.name = "RoadProxy"
	var quad := QuadMesh.new()
	quad.size = Vector2(5.0, 1.2)
	plate.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.45, 0.45)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	plate.material_override = mat
	plate.position = Vector3(-3.6, 0.4, -8.0)
	lab.add_child(plate)


func _settle(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := svp.get_texture().get_image()
	img.save_png("%s/%s_%s.png" % [OUT_DIR, tag, shot_name])
	print("SHOT_SAVED %s_%s" % [tag, shot_name])


func _gpu_avg(seconds: float) -> float:
	var total := 0.0
	var frames := 0
	var elapsed := 0.0
	while elapsed < seconds:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		var ms := RenderingServer.viewport_get_measured_render_time_gpu(svp.get_viewport_rid())
		if ms > 0.0:
			total += ms
			frames += 1
	return total / max(frames, 1)
