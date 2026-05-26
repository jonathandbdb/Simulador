extends Node3D
## Escena raiz del simulador VR — Sprint 5.
##
## Responsabilidades:
##   1. Inicializa OpenXR + viewport XR + physics 90 Hz.
##   2. Conecta al DataManager (autoload) y refleja el estado del catalogo
##      en el SyncHud.
##   3. Aplica las lentes del catalogo al shader unificado (halo + DoF).
##      Sprint 5: ya no hay PRESET hardcodeado — la fuente de verdad es
##      DataManager.current_vision_state y la senial vision_state_changed.
##   4. Permite ciclar lentes en runtime desde el control derecho:
##        - boton A (ax_button)   -> proxima lente para el ojo IZQUIERDO
##        - boton B (by_button)   -> proxima lente para el ojo DERECHO
##        - trigger              -> aplica la misma lente a ambos ojos (reset Blend)
##      Esto habilita el modo Blend (lentes distintas por ojo) de forma natural.
##   5. Auto-cicla un dia/noche cada DAY_NIGHT_INTERVAL segundos con
##      fade-to-black intermedio.

const TARGET_PHYSICS_TICKS := 90
const DAY_NIGHT_INTERVAL := 15.0  # segundos entre toggles
const FADE_DURATION := 0.8        # tiempo de fade-out / fade-in
const HOLD_AT_BLACK := 0.2        # tiempo en negro mientras se cambia el ambiente

# Lente inicial aplicada a ambos ojos al cargar el catalogo. Si no existe
# en el catalogo, se usa la primera disponible.
const INITIAL_LENS_ID := "monofocal"

# Parametros visuales para el modo "dia" y el modo "noche".
const DAY_PARAMS := {
	"sun_energy": 1.2,
	"sky_top": Color(0.18, 0.32, 0.55, 1),
	"sky_horizon": Color(0.5, 0.55, 0.55, 1),
	"ground_bottom": Color(0.1, 0.1, 0.1, 1),
	"ground_horizon": Color(0.4, 0.4, 0.4, 1),
	"ambient_color": Color(0.6, 0.7, 0.85, 1),
	"ambient_energy": 0.4,
}
const NIGHT_PARAMS := {
	"sun_energy": 0.05,
	"sky_top": Color(0.0, 0.01, 0.04, 1),
	"sky_horizon": Color(0.05, 0.05, 0.1, 1),
	"ground_bottom": Color(0.0, 0.0, 0.0, 1),
	"ground_horizon": Color(0.03, 0.03, 0.06, 1),
	"ambient_color": Color(0.1, 0.12, 0.2, 1),
	"ambient_energy": 0.05,
}

@onready var post_process_quad: MeshInstance3D = $XROrigin3D/XRCamera3D/PostProcessQuad
@onready var fade_quad: MeshInstance3D = $XROrigin3D/XRCamera3D/FadeQuad
@onready var fps_label: Label3D = $XROrigin3D/XRCamera3D/FpsHud
@onready var sync_label: Label3D = $XROrigin3D/XRCamera3D/SyncHud
@onready var stream_label: Label3D = $XROrigin3D/XRCamera3D/StreamHud
@onready var dir_light: DirectionalLight3D = $DirectionalLight3D
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var right_hand: XRController3D = $XROrigin3D/RightHand
@onready var xr_camera: XRCamera3D = $XROrigin3D/XRCamera3D

var xr_interface: XRInterface
var fps_accumulator: float = 0.0
var fps_frames: int = 0
var is_night: bool = false
var _cycle_timer: Timer
# Indice de la lente activa en cada ojo dentro de DataManager.get_lens_ids().
var _lens_index_left: int = 0
var _lens_index_right: int = 0
# Sprint 6: nodo de captura de streaming (creado en _ready).
var _streaming_capture: Node = null


func _ready() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface == null or not xr_interface.is_initialized():
		push_warning("OpenXR no inicializado — corriendo en modo no-VR (probablemente PC editor).")
	else:
		get_viewport().use_xr = true
		Engine.physics_ticks_per_second = TARGET_PHYSICS_TICKS

	_apply_environment(DAY_PARAMS)

	# Wiring con DataManager (autoload).
	DataManager.catalog_loaded.connect(_on_catalog_loaded)
	DataManager.catalog_synced_with_backend.connect(_on_catalog_synced)
	DataManager.catalog_sync_failed.connect(_on_catalog_sync_failed)
	DataManager.vision_state_changed.connect(_on_vision_state_changed)

	# Input del control derecho — cicla lentes en runtime.
	right_hand.button_pressed.connect(_on_right_hand_button_pressed)

	# Si DataManager ya cargo el catalogo antes de conectar las seniales
	# (carrera comun con autoloads), reflejamos el estado actual y aplicamos
	# la lente inicial.
	if not DataManager.catalog.is_empty():
		var ver: String = DataManager.catalog.get("version", "?")
		_update_sync_label("loaded(%s) %d lentes [%s]" % [
			DataManager.catalog_source,
			DataManager.get_lens_ids().size(),
			ver,
		])
		_apply_initial_lens()

	_start_day_night_cycle()
	_setup_streaming_capture()


func _setup_streaming_capture() -> void:
	var script := load("res://features/tablet/streaming_capture.gd")
	if script == null:
		push_warning("main: streaming_capture.gd no encontrado, streaming desactivado.")
		return
	_streaming_capture = Node.new()
	_streaming_capture.name = "StreamingCapture"
	_streaming_capture.set_script(script)
	_streaming_capture.camera_to_follow = xr_camera.get_path()
	add_child(_streaming_capture)

	# Sprint 7: canal de control bidireccional con la tablet.
	StreamingServer.client_connected.connect(_on_streaming_client_connected)
	StreamingServer.command_received.connect(_on_streaming_command_received)


# ====================================================================
# Sprint 7 — Control bidireccional desde la tablet
# ====================================================================
func _on_streaming_client_connected(peer_id: int, host: String) -> void:
	print("main: cliente tablet %d conectado desde %s, enviando catalogo." % [peer_id, host])
	# Snapshot del catalogo + estado actual de vision para que la tablet
	# arme su UI sin tener que consultar el backend.
	var msg := {
		"type": "hello",
		"catalog_version": DataManager.catalog.get("version", "?"),
		"lenses": DataManager.catalog.get("catalogo", []),
		"vision_state": DataManager.current_vision_state,
	}
	StreamingServer.send_text_to(peer_id, JSON.stringify(msg))


func _on_streaming_command_received(cmd: Dictionary, peer_id: int) -> void:
	var cmd_type: String = cmd.get("cmd", "")
	match cmd_type:
		"apply_lens":
			var lens_id: String = cmd.get("lens_id", "")
			var eye: String = cmd.get("eye", "both")
			if lens_id == "":
				push_warning("main: apply_lens sin lens_id (peer %d)" % peer_id)
				return
			var ids := DataManager.get_lens_ids()
			if not ids.has(lens_id):
				push_warning("main: apply_lens lens_id desconocido '%s' (peer %d)" % [lens_id, peer_id])
				return
			# Actualizar tambien los indices internos para que los botones del
			# control derecho sigan ciclando coherentemente.
			var idx := ids.find(lens_id)
			if eye == "left" or eye == "both":
				_lens_index_left = idx
			if eye == "right" or eye == "both":
				_lens_index_right = idx
			DataManager.apply_lens(lens_id, eye)
			print("main: tablet aplico '%s' en ojo '%s'" % [lens_id, eye])
		_:
			push_warning("main: comando desconocido de peer %d: %s" % [peer_id, cmd])


# ====================================================================
# DataManager wiring
# ====================================================================
func _on_catalog_loaded(version: String, source: String, lens_count: int) -> void:
	_update_sync_label("loaded(%s) %d lentes [%s]" % [source, lens_count, version])
	_apply_initial_lens()


func _on_catalog_synced(version: String) -> void:
	_update_sync_label("backend OK [%s]" % version)


func _on_catalog_sync_failed(reason: String) -> void:
	# El catalogo local sigue activo; solo informamos del fallo en el HUD.
	var short_reason := reason.substr(0, 40)
	_update_sync_label("sync OFFLINE: %s" % short_reason)


func _update_sync_label(text: String) -> void:
	sync_label.text = "catalogo:\n%s" % text


# ====================================================================
# Sprint 5 — Lentes aplicadas al shader desde DataManager
# ====================================================================
##
## Mapeo parametros del catalogo -> uniforms del shader.
## Las claves coinciden con sprint2_blur_test.gdshader.
const SHADER_PARAM_MAP := {
	"blur_near":      ["blur_near_l",      "blur_near_r"],
	"blur_medium":    ["blur_medium_l",    "blur_medium_r"],
	"blur_far":       ["blur_far_l",       "blur_far_r"],
	"halo_intensity": ["halo_intensity_l", "halo_intensity_r"],
}


func _apply_initial_lens() -> void:
	var ids := DataManager.get_lens_ids()
	if ids.is_empty():
		push_warning("main: catalogo sin lentes — shader queda en valores default.")
		return

	var initial_id := INITIAL_LENS_ID
	if not ids.has(initial_id):
		initial_id = ids[0]

	_lens_index_left = ids.find(initial_id)
	_lens_index_right = _lens_index_left
	# apply_lens("both") emite vision_state_changed para ambos ojos,
	# y _on_vision_state_changed actualiza los uniforms del shader.
	DataManager.apply_lens(initial_id, "both")


func _on_vision_state_changed(eye: String, params: Dictionary) -> void:
	var mat := post_process_quad.get_active_material(0) as ShaderMaterial
	if mat == null:
		push_error("PostProcessQuad sin ShaderMaterial.")
		return

	var eye_idx := 0 if eye == "left" else 1
	for key in SHADER_PARAM_MAP.keys():
		if params.has(key):
			var uniform_name: String = SHADER_PARAM_MAP[key][eye_idx]
			mat.set_shader_parameter(uniform_name, float(params[key]))

	_update_lens_hud()


func _update_lens_hud() -> void:
	var ids := DataManager.get_lens_ids()
	if ids.is_empty():
		return
	var left_id: String = ids[_lens_index_left] if _lens_index_left < ids.size() else "?"
	var right_id: String = ids[_lens_index_right] if _lens_index_right < ids.size() else "?"
	var blend := " (Blend)" if left_id != right_id else ""
	sync_label.text = "L: %s\nR: %s%s" % [left_id, right_id, blend]


# ====================================================================
# Input — control derecho cicla lentes
# ====================================================================
func _on_right_hand_button_pressed(name: String) -> void:
	var ids := DataManager.get_lens_ids()
	if ids.is_empty():
		return

	match name:
		"ax_button":
			# A — proxima lente para el ojo izquierdo.
			_lens_index_left = (_lens_index_left + 1) % ids.size()
			DataManager.apply_lens(ids[_lens_index_left], "left")
		"by_button":
			# B — proxima lente para el ojo derecho.
			_lens_index_right = (_lens_index_right + 1) % ids.size()
			DataManager.apply_lens(ids[_lens_index_right], "right")
		"trigger_click":
			# Trigger — reset Blend: misma lente en ambos ojos (la del ojo izq).
			_lens_index_right = _lens_index_left
			DataManager.apply_lens(ids[_lens_index_left], "both")


# ====================================================================
# Day/Night cycle
# ====================================================================
func _start_day_night_cycle() -> void:
	_cycle_timer = Timer.new()
	_cycle_timer.wait_time = DAY_NIGHT_INTERVAL
	_cycle_timer.one_shot = false
	_cycle_timer.timeout.connect(_toggle_day_night)
	add_child(_cycle_timer)
	_cycle_timer.start()


func _toggle_day_night() -> void:
	is_night = not is_night
	var target_params: Dictionary = NIGHT_PARAMS if is_night else DAY_PARAMS

	# Secuencia: fade-out -> swap del environment -> hold -> fade-in.
	var tween := create_tween()
	tween.tween_method(_set_fade_alpha, 0.0, 1.0, FADE_DURATION).set_trans(Tween.TRANS_SINE)
	tween.tween_callback(func() -> void: _apply_environment(target_params))
	tween.tween_interval(HOLD_AT_BLACK)
	tween.tween_method(_set_fade_alpha, 1.0, 0.0, FADE_DURATION).set_trans(Tween.TRANS_SINE)


func _set_fade_alpha(alpha: float) -> void:
	var mat := fade_quad.get_active_material(0) as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("alpha", alpha)


func _apply_environment(params: Dictionary) -> void:
	dir_light.light_energy = params.sun_energy

	var env: Environment = world_env.environment
	if env == null:
		return
	env.ambient_light_color = params.ambient_color
	env.ambient_light_energy = params.ambient_energy
	var sky_mat := env.sky.sky_material as ProceduralSkyMaterial
	if sky_mat == null:
		return
	sky_mat.sky_top_color = params.sky_top
	sky_mat.sky_horizon_color = params.sky_horizon
	sky_mat.ground_bottom_color = params.ground_bottom
	sky_mat.ground_horizon_color = params.ground_horizon


# ====================================================================
# FPS HUD
# ====================================================================
func _process(delta: float) -> void:
	fps_accumulator += delta
	fps_frames += 1
	if fps_accumulator >= 0.5:
		var fps := fps_frames / fps_accumulator
		var frame_ms := (fps_accumulator / fps_frames) * 1000.0
		var mode := "noche" if is_night else "dia"
		fps_label.text = "FPS: %d\nFrame: %.2f ms\nmodo: %s" % [int(fps), frame_ms, mode]
		_update_stream_hud()
		fps_accumulator = 0.0
		fps_frames = 0


func _update_stream_hud() -> void:
	if stream_label == null:
		return
	if StreamingServer == null or not StreamingServer.is_listening():
		stream_label.text = "stream: OFF"
		return
	var clients := StreamingServer.get_open_client_count()
	var frames := 0
	var last_kb := 0.0
	if _streaming_capture != null:
		frames = _streaming_capture.get_frames_sent()
		last_kb = _streaming_capture.get_last_jpg_size() / 1024.0
	stream_label.text = "stream :%d\nclients: %d\nframes: %d\nlast: %.1f KB" % [
		StreamingServer.LISTEN_PORT, clients, frames, last_kb,
	]
