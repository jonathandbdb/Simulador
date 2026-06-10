extends Node3D
## LensLab — escena STANDALONE de QA para validar los efectos de cada lente
## intraocular contra distancias reales.
##
## NO esta en SCENARIOS de main.gd (es solo para dev). Para correrla:
##   - F6 en el editor con esta escena activa, o
##   - Drag&drop sobre el viewport y Play Current Scene.
##
## Que hace:
##   1. Construye targets a varias distancias:
##        - Luces emisivas (puntos brillantes) a 1, 3, 6, 12, 25, 50 m al frente.
##        - Etiquetas de texto Label3D a 0.35, 0.6, 1.0, 2.0, 6.0 m
##          (lectura cerca/intermedio/lejos).
##   2. Monta una camara fija + WorldEnvironment de noche con glow + PostProcessQuad
##      con el shader principal sprint2_blur_test.gdshader.
##   3. Conecta al DataManager (autoload) y aplica una lente. Permite ciclar:
##        - tecla 1 -> monofocal      (lente)
##        - tecla 2 -> panoptix       (lente)
##        - tecla 3 -> vivity         (lente)
##        - tecla N -> alterna noche/dia (cambia ambient + halo_threshold)
##        - tecla P -> alterna dilatacion pupilar (halo_extra_rings 0 <-> 1)
##        - tecla H -> on/off post-process (comparar "con lentes" vs "sin lentes")
##   4. Un HUD muestra lente activa, distancia de cada target y modo dia/noche.

const POST_PROCESS_SHADER := preload("res://features/vision_shaders/sprint2_blur_test.gdshader")

## Distancias de las luces puntuales emisivas (m).
const LIGHT_DISTANCES_M: Array[float] = [1.0, 3.0, 6.0, 12.0, 25.0, 50.0]
## Distancias de los carteles con texto (m).
const TEXT_DISTANCES_M: Array[float] = [0.35, 0.6, 1.0, 2.0, 6.0]
## Texto de prueba (Snellen-ish). Tamano se ajusta por distancia.
const TEXT_SAMPLE := "ABC 6 9\nLECTURA\n123 456"

## Mapeo parametro_catalogo -> [uniform_l, uniform_r]. Mismo que main.gd.
const SHADER_PARAM_MAP := {
	"foco_lejos_m":       ["foco_lejos_l",       "foco_lejos_r"],
	"foco_intermedio_m":  ["foco_intermedio_l",  "foco_intermedio_r"],
	"foco_cerca_m":       ["foco_cerca_l",       "foco_cerca_r"],
	"profundidad_foco_m": ["profundidad_foco_l", "profundidad_foco_r"],
	"desenfoque_max":     ["desenfoque_max_l",   "desenfoque_max_r"],
	"halo_intensity":     ["halo_intensity_l",   "halo_intensity_r"],
	"halo_extra_rings":   ["halo_extra_rings_l", "halo_extra_rings_r"],
	"contrast_loss":      ["contrast_loss_l",    "contrast_loss_r"],
	"destello_intensity": ["destello_intensity_l", "destello_intensity_r"],
	"destello_rayos":     ["destello_rayos_l",   "destello_rayos_r"],
}

var _camera: Camera3D
var _post_process_quad: MeshInstance3D
var _shader_mat: ShaderMaterial
var _world_env: WorldEnvironment
var _hud_label: Label
var _night_mode: bool = true
var _post_process_on: bool = true
var _pupil_dilated_override: float = -1.0  # -1 = usar valor de la lente; 0/1 = forzado


func _ready() -> void:
	_setup_environment()
	_setup_camera_and_post_process()
	_spawn_light_targets()
	_spawn_text_targets()
	_setup_hud()

	# Conectar a DataManager y aplicar la primera lente.
	DataManager.vision_state_changed.connect(_on_vision_state_changed)
	_apply_lens_by_index(1)  # panoptix por default (efectos pronunciados)


# ====================================================================
# Setup
# ====================================================================
func _setup_environment() -> void:
	_world_env = WorldEnvironment.new()
	_world_env.name = "WorldEnvironment"
	_world_env.environment = _make_environment(_night_mode)
	add_child(_world_env)

	# Luz direccional muy tenue para que se vean los carteles fuera de la luz puntual.
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_energy = 0.05 if _night_mode else 1.0
	sun.rotation_degrees = Vector3(-35.0, -30.0, 0.0)
	add_child(sun)


func _make_environment(night: bool) -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.015, 0.015, 0.03) if night else Color(0.55, 0.65, 0.75)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.08, 0.09, 0.14) if night else Color(0.6, 0.7, 0.85)
	env.ambient_light_energy = 0.35 if night else 0.5
	# Alineado con NIGHT_PARAMS/DAY_PARAMS de main.gd: el banco de QA debe
	# reproducir EXACTAMENTE las condiciones del visor (antes validaba una
	# escena mas facil: AGX, glow 1.2, threshold 0.55 — y el Quest fallaba).
	env.glow_enabled = night
	env.glow_intensity = 0.6
	env.glow_strength = 1.0
	env.glow_bloom = 0.1
	env.glow_hdr_threshold = 1.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC if night else Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 0.6 if night else 1.0
	env.tonemap_white = 8.0 if night else 6.0
	return env


func _setup_camera_and_post_process() -> void:
	_camera = Camera3D.new()
	_camera.name = "LensLabCamera"
	_camera.position = Vector3(0.0, 1.6, 0.0)
	_camera.current = true
	# FOV alto para que las luces cercanas se vean grandes y se distinga el halo.
	_camera.fov = 75.0
	add_child(_camera)

	# Post-process quad colgado de la camara: muy cerca, full screen.
	_post_process_quad = MeshInstance3D.new()
	_post_process_quad.name = "PostProcessQuad"
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	_post_process_quad.mesh = quad
	_post_process_quad.position = Vector3(0.0, 0.0, -0.05)  # justo delante de la camara
	_post_process_quad.extra_cull_margin = 16384.0
	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = POST_PROCESS_SHADER
	# 0.72 de noche = mismo umbral que ruta_noche en main.gd SCENARIOS.
	_shader_mat.set_shader_parameter("halo_threshold", 0.72 if _night_mode else 0.9)
	_post_process_quad.material_override = _shader_mat
	_camera.add_child(_post_process_quad)


func _spawn_light_targets() -> void:
	# Las luces se colocan en linea recta al frente, en X = 0, levemente arriba y abajo
	# alternadas para que no se superpongan en pantalla.
	for i in range(LIGHT_DISTANCES_M.size()):
		var d: float = LIGHT_DISTANCES_M[i]
		# Pequeno offset lateral y vertical para que se distingan en pantalla.
		var offset_x: float = (-0.6 if (i % 2 == 0) else 0.6) * (1.0 + d * 0.04)
		var offset_y: float = (0.3 if (i % 2 == 0) else -0.3) * (1.0 + d * 0.02)
		var pos := Vector3(offset_x, 1.6 + offset_y, -d)
		_spawn_emissive_sphere(pos, d, i)


func _spawn_emissive_sphere(pos: Vector3, distance_m: float, idx: int) -> void:
	var node := Node3D.new()
	node.name = "Light_%dm" % int(distance_m)
	node.position = pos
	add_child(node)

	# Esfera emisiva (fuente puntual para el shader).
	var sphere := MeshInstance3D.new()
	var sm := SphereMesh.new()
	# Radio FISICO pequeno (~5 cm) — asi en pantalla la fuente subtiende un
	# angulo aproximadamente realista (mas chica de lejos, mas grande de cerca).
	sm.radius = 0.05
	sm.height = 0.10
	sphere.mesh = sm
	var mat := StandardMaterial3D.new()
	# Colores variados para que el doctor distinga cada distancia.
	var palette := [
		Color(1.0, 0.95, 0.85),   # blanco calido
		Color(1.0, 0.20, 0.20),   # rojo
		Color(0.20, 1.0, 0.30),   # verde
		Color(1.0, 0.78, 0.10),   # ambar
		Color(0.55, 0.78, 1.0),   # azul
		Color(1.0, 1.0, 1.0),     # blanco frio
	]
	var col: Color = palette[idx % palette.size()]
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	# 24 = car_light_emission de ruta_traffic.gd (mismas fuentes que el visor).
	mat.emission_energy_multiplier = 24.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sphere.material_override = mat
	node.add_child(sphere)

	# Glare procedural anclado a la fuente (mismo sistema que ruta_noche;
	# el halo/starburst ya no se generan en el post-proceso screen-space).
	GlareSource.attach(node, Vector3.ZERO, col, 1.0)

	# Etiqueta con la distancia para identificar cada luz en el HUD.
	var lbl := Label3D.new()
	lbl.text = "%.0f m" % distance_m
	lbl.font_size = 96
	lbl.outline_size = 8
	lbl.modulate = Color(1.0, 1.0, 1.0, 0.7)
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.position = Vector3(0.0, -0.18, 0.0)
	node.add_child(lbl)


func _spawn_text_targets() -> void:
	# Carteles de texto a varias distancias para validar la curva de blur dioptrico.
	# Los tamanos del texto crecen con la distancia para que el ANGULO subtendido
	# sea aproximadamente constante (test optometrico clasico).
	for i in range(TEXT_DISTANCES_M.size()):
		var d: float = TEXT_DISTANCES_M[i]
		var offset_x: float = -2.0 - i * 0.5  # carteles a la izquierda, escalonados
		var pos := Vector3(offset_x, 1.5, -d)
		_spawn_text_card(pos, d)


func _spawn_text_card(pos: Vector3, distance_m: float) -> void:
	var node := Node3D.new()
	node.name = "Text_%.2fm" % distance_m
	node.position = pos
	add_child(node)

	# Fondo blanco del cartel para que el texto contraste y se vea de noche.
	var bg := MeshInstance3D.new()
	var quad := QuadMesh.new()
	# Tamano fisico proporcional a la distancia (mantener angulo similar).
	var size: float = 0.08 * distance_m + 0.10
	quad.size = Vector2(size * 1.6, size)
	bg.mesh = quad
	var bg_mat := StandardMaterial3D.new()
	bg_mat.albedo_color = Color(0.92, 0.92, 0.88)
	bg_mat.emission_enabled = true
	bg_mat.emission = Color(0.55, 0.55, 0.52)
	bg_mat.emission_energy_multiplier = 0.6  # tenue, NO dispara halo
	node.add_child(bg)

	# Texto principal.
	var lbl := Label3D.new()
	lbl.text = "%s\n[%.2f m]" % [TEXT_SAMPLE, distance_m]
	# Tamano de fuente proporcional a la distancia (test optometrico).
	lbl.font_size = int(28.0 + distance_m * 18.0)
	lbl.outline_size = 6
	lbl.modulate = Color.BLACK
	lbl.position = Vector3(0.0, 0.0, 0.01)
	lbl.pixel_size = 0.001 * (1.0 + distance_m * 0.5)
	node.add_child(lbl)


func _setup_hud() -> void:
	# HUD 2D en CanvasLayer (independiente del 3D).
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)
	var panel := Panel.new()
	panel.position = Vector2(12, 12)
	panel.size = Vector2(440, 220)
	panel.self_modulate = Color(0.0, 0.0, 0.0, 0.6)
	layer.add_child(panel)
	_hud_label = Label.new()
	_hud_label.position = Vector2(12, 8)
	_hud_label.size = Vector2(420, 200)
	_hud_label.add_theme_font_size_override("font_size", 14)
	_hud_label.add_theme_color_override("font_color", Color(0.9, 0.92, 0.95))
	panel.add_child(_hud_label)
	_refresh_hud()


# ====================================================================
# Input
# ====================================================================
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var k := event as InputEventKey
	match k.keycode:
		KEY_1: _apply_lens_by_index(0)
		KEY_2: _apply_lens_by_index(1)
		KEY_3: _apply_lens_by_index(2)
		KEY_N: _toggle_night()
		KEY_P: _toggle_pupil()
		KEY_H: _toggle_post_process()


func _apply_lens_by_index(idx: int) -> void:
	var ids := DataManager.get_lens_ids()
	if ids.is_empty():
		push_warning("LensLab: catalogo vacio")
		return
	var safe_idx: int = clamp(idx, 0, ids.size() - 1)
	DataManager.apply_lens(ids[safe_idx], "both")


func _toggle_night() -> void:
	_night_mode = not _night_mode
	_world_env.environment = _make_environment(_night_mode)
	_shader_mat.set_shader_parameter("halo_threshold", 0.72 if _night_mode else 0.9)
	_refresh_hud()


func _toggle_pupil() -> void:
	# Cicla: lente -> forzado 1.0 -> forzado 0.0 -> lente.
	if _pupil_dilated_override < -0.5:
		_pupil_dilated_override = 1.0
	elif _pupil_dilated_override > 0.5:
		_pupil_dilated_override = 0.0
	else:
		_pupil_dilated_override = -1.0
	# Reaplicar el override sobre ambos ojos (no toca el catalogo).
	var state_l: Dictionary = DataManager.current_vision_state.get("left", {})
	if not state_l.is_empty() and _pupil_dilated_override >= 0.0:
		DataManager.override_params({"halo_extra_rings": _pupil_dilated_override}, "both")
	elif _pupil_dilated_override < 0.0 and not state_l.is_empty():
		# Restaurar el valor del catalogo de la lente activa.
		var lens_id: String = state_l.get("lens_id", "")
		if lens_id != "":
			var lens: Dictionary = DataManager.get_lens(lens_id)
			var params_def = lens.get("params", {})
			var extra_def: float = float(params_def.get("halo_extra_rings", {}).get("default", 0.0))
			DataManager.override_params({"halo_extra_rings": extra_def}, "both")
	_refresh_hud()


func _toggle_post_process() -> void:
	_post_process_on = not _post_process_on
	_post_process_quad.visible = _post_process_on
	# Los billboards de glare son parte de "la lente": se ocultan juntos.
	get_tree().call_group("glare_billboards", "set_visible", _post_process_on)
	_refresh_hud()


# ====================================================================
# Wiring shader
# ====================================================================
func _on_vision_state_changed(eye: String, params: Dictionary) -> void:
	if _shader_mat == null:
		return
	var eye_idx := 0 if eye == "left" else 1
	for key in SHADER_PARAM_MAP.keys():
		if params.has(key):
			var uniform_name: String = SHADER_PARAM_MAP[key][eye_idx]
			var value := float(params[key])
			# El glare (halo/starburst) ya NO corre en el post-proceso: en el
			# Quest los mips del backbuffer no se generan y el gather fallaba.
			# Lo dibujan los billboards GlareSource via shader globals.
			if key in ["halo_intensity", "halo_extra_rings", "destello_intensity", "destello_rayos"]:
				value = 0.0
			_shader_mat.set_shader_parameter(uniform_name, value)
	GlareSource.set_eye_globals(eye, params, true)
	_refresh_hud()


func _refresh_hud() -> void:
	if _hud_label == null:
		return
	var l_state: Dictionary = DataManager.current_vision_state.get("left", {})
	var lens_id: String = l_state.get("lens_id", "?")
	var lens: Dictionary = DataManager.get_lens(lens_id)
	var lens_name: String = lens.get("nombre", lens_id)
	var pupil_state := "(catalogo)"
	if _pupil_dilated_override > 0.5:
		pupil_state = "DILATADA (1.0)"
	elif _pupil_dilated_override >= 0.0 and _pupil_dilated_override <= 0.5:
		pupil_state = "CONTRAIDA (0.0)"
	_hud_label.text = (
		"LENS LAB\n"
		+ "Lente: %s\n" % lens_name
		+ "Modo:  %s | PostProc: %s | Pupila: %s\n" % [
			"NOCHE" if _night_mode else "DIA",
			"ON" if _post_process_on else "OFF",
			pupil_state,
		]
		+ "------------------------------------------------\n"
		+ "1/2/3 = monofocal / panoptix / vivity\n"
		+ "N = noche/dia    P = dilatacion pupilar    H = post-proc on/off\n"
		+ "Luces a %s m\n" % ", ".join(LIGHT_DISTANCES_M.map(func(v: float) -> String: return "%.0f" % v))
		+ "Texto a %s m" % ", ".join(TEXT_DISTANCES_M.map(func(v: float) -> String: return "%.2f" % v))
	)
