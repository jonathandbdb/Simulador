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
##        - grip (squeeze)        -> apaga/enciende el shader post-proceso
##                                   (modo "sin lentes" para comparar)
##      Esto habilita el modo Blend (lentes distintas por ojo) de forma natural.
##   5. Mantiene el consultorio en modo dia fijo por ahora.

const TARGET_PHYSICS_TICKS := 90

# Supersampling per-eye: renderiza el eye-buffer a mayor resolucion que la
# nativa del panel para ganar nitidez en texto/detalle a distancia (imita lo
# que hace PCVR/Air Link). >1.0 = mas nitido pero mas costo GPU. Se compensa
# con foveated rendering (xr/openxr/foveation_*). 1.15 es un punto conservador
# para Quest 2; Quest 3 admite mas holgura.
# Bajado a 1.0: el post-proceso nocturno (halo/starburst/astig) es fill-rate
# bound; supersamplear lo multiplicaba (a 1.15 => +32% de píxeles a sombrear ×2
# ojos). 1.0 es el mayor ahorro de GPU en Quest sin tocar el efecto.
const XR_RENDER_SCALE := 1.0

# Lente inicial aplicada a ambos ojos al cargar el catalogo. Si no existe
# en el catalogo, se usa la primera disponible.
const INITIAL_LENS_ID := "panoptix"

# Activacion de halos en esta escena. En el consultorio (lectura de cerca) los
# halos no aportan y molestan, por eso quedan APAGADOS por defecto. Se pueden
# reactivar en el inspector o en runtime con set_halos_enabled(true) — por
# ejemplo en una escena nocturna con fuentes de luz puntuales. Cuando esta en
# false, halo_intensity se fuerza a 0 en el shader sin tocar el catalogo.
@export var halos_enabled: bool = false

# ====================================================================
# Escenarios disponibles
# ====================================================================
## Mapa de escenas disponibles. Clave = id usado en el comando load_scenario.
## halos: activa destello/halo cuando es true.
## env: "day" | "night" — que PARAMS aplicar al entorno de main.
## show_book: muestra el libro en la mano derecha.
const SCENARIOS := {
	"consultorio": {
		"scene":     "res://features/scenarios/consultorio/consultorio.tscn",
		"halos":     false,
		"env":       "day",
		"show_book": true,
		# Umbral alto: de dia solo la lampara de escritorio (muy brillante) genera
		# halo; la pagina iluminada no debe disparar el efecto.
		"halo_threshold": 0.9,
	},
	"auto_noche": {
		"scene":     "res://features/scenarios/auto_noche/auto_noche.tscn",
		"halos":     true,
		"env":       "night",
		"show_book": false,
		# Umbral medio-alto: con Filmic las fuentes emisivas (faros, farolas,
		# semaforo) quedan altas (~0.9) y lo superan; la calzada/cebra iluminada
		# queda por debajo. Junto con surface_factor() evita que la pintura del
		# piso genere halos/destellos falsos. Si se baja, la calzada deslumbra.
		"halo_threshold": 0.72,
	},
	"ruta_noche": {
		"scene":     "res://features/scenarios/ruta_noche/ruta_noche.tscn",
		"halos":     true,
		"env":       "night",
		"show_book": false,
		"halo_threshold": 0.72,
	},
}

# Parametros visuales para el consultorio en modo dia fijo.
const DAY_PARAMS := {
	"sun_energy": 1.2,
	"sky_top": Color(0.18, 0.32, 0.55, 1),
	"sky_horizon": Color(0.5, 0.55, 0.55, 1),
	"ground_bottom": Color(0.1, 0.1, 0.1, 1),
	"ground_horizon": Color(0.4, 0.4, 0.4, 1),
	"ambient_color": Color(0.6, 0.7, 0.85, 1),
	"ambient_energy": 0.4,
	# Glow apagado de dia: no hay fuentes puntuales que justifiquen bloom.
	"glow_enabled": false,
	# De dia el sol sí proyecta sombras (da volumen al consultorio).
	"sun_shadow": true,
	# AGX comprime altas luces sin quemar (mismo criterio que el consultorio).
	"tonemap_mode": 4,       # AGX
	"tonemap_exposure": 1.0,
	"tonemap_white": 6.0,
}

# Parametros visuales para la escena nocturna.
const NIGHT_PARAMS := {
	"sun_energy":    0.04,
	"sun_color":     Color(0.7, 0.75, 1.0, 1),
	"sky_top":       Color(0.02, 0.02, 0.05, 1),
	"sky_horizon":   Color(0.05, 0.05, 0.09, 1),
	"ground_bottom": Color(0.02, 0.02, 0.03, 1),
	"ground_horizon":Color(0.04, 0.04, 0.06, 1),
	"ambient_color": Color(0.08, 0.09, 0.14, 1),
	"ambient_energy":0.40,
	# Sin sombra direccional de noche (el sol está casi apagado): ahorra un pase
	# de sombras completo sobre el modelo de la calle.
	"sun_shadow":    false,
	# Glow encendido de noche: da el "bloom" alrededor de faros/semaforo/celular
	# que, sumado al post-proceso de halos, vende la disfotopsia nocturna.
	"glow_enabled":   true,
	"glow_intensity": 0.6,
	"glow_strength":  1.0,
	"glow_bloom":     0.1,
	# Umbral SUBIDO (1.2 -> 1.6): la pintura vial y la cebra iluminadas por las
	# farolas quedaban por encima de 1.2 y bloomeaban, dominando la escena. Con
	# 1.6 solo las fuentes emisivas (faros, semaforo, farolas) hacen bloom y la
	# calzada queda limpia. (Auditoria escena nocturna.)
	"glow_hdr_threshold": 1.6,
	# Filmic en vez de AGX: AGX desatura fuerte las altas luces, asi una luz de
	# freno roja o el semaforo verde/rojo se veian BLANCOS (perdian su color, que
	# es info clinica). Filmic comprime las altas luces igual de bien pero
	# conserva el tono de las fuentes de color. Exposicion baja mantiene el fondo
	# oscuro. (Auditoria escena nocturna.)
	"tonemap_mode":     2,     # Filmic
	"tonemap_exposure": 0.6,
	"tonemap_white":    8.0,
}

@onready var post_process_quad: MeshInstance3D = $XROrigin3D/XRCamera3D/PostProcessQuad
@onready var fade_quad: MeshInstance3D = $XROrigin3D/XRCamera3D/FadeQuad
@onready var fps_label: Label3D = $XROrigin3D/XRCamera3D/FpsHud
@onready var sync_label: Label3D = $XROrigin3D/XRCamera3D/SyncHud
@onready var stream_label: Label3D = $XROrigin3D/XRCamera3D/StreamHud
@onready var dir_light: DirectionalLight3D = $DirectionalLight3D
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var right_hand: XRController3D = $XROrigin3D/RightHand
@onready var left_hand: XRController3D = $XROrigin3D/LeftHand
@onready var xr_camera: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var scenario_container: Node3D = $ScenarioContainer
@onready var book_holder: Node3D = $XROrigin3D/RightHand/BookHolder

var xr_interface: XRInterface
var fps_accumulator: float = 0.0
var fps_frames: int = 0
# Sprint 6: nodo de captura de streaming (creado en _ready).
var _streaming_capture: Node = null
# Toggle del shader post-proceso. Cuando esta en false, el quad se oculta
# y se ve el render "crudo" del consultorio (sin DoF/halos).
var _post_process_enabled: bool = true
# Escenario activo y su nodo raiz en ScenarioContainer.
var _current_scenario_id: String = "consultorio"
var _scenario_node: Node3D = null


func _ready() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface == null or not xr_interface.is_initialized():
		push_warning("OpenXR no inicializado — corriendo en modo no-VR (probablemente PC editor).")
	else:
		get_viewport().use_xr = true
		Engine.physics_ticks_per_second = TARGET_PHYSICS_TICKS
		# Supersampling per-eye para nitidez (ver XR_RENDER_SCALE).
		xr_interface.set_render_target_size_multiplier(XR_RENDER_SCALE)

	_apply_environment(DAY_PARAMS)

	# Wiring con DataManager (autoload).
	DataManager.catalog_loaded.connect(_on_catalog_loaded)
	DataManager.catalog_synced_with_backend.connect(_on_catalog_synced)
	DataManager.catalog_sync_failed.connect(_on_catalog_sync_failed)
	DataManager.vision_state_changed.connect(_on_vision_state_changed)

	# Input del control derecho — cicla lentes en runtime.
	right_hand.button_pressed.connect(_on_right_hand_button_pressed)
	# Input del control izquierdo — cicla escenas (Y) y toggle halos (X).
	left_hand.button_pressed.connect(_on_left_hand_button_pressed)

	# Referencia inicial al nodo de escena (el Consultorio instanciado en .tscn).
	if scenario_container.get_child_count() > 0:
		_scenario_node = scenario_container.get_child(0) as Node3D

	# Si DataManager ya cargo el catalogo antes de conectar las seniales
	# (carrera comun con autoloads), reflejamos el estado actual y aplicamos
	# la lente inicial.
	if not DataManager.catalog.is_empty():
		var ver: String = String(DataManager.catalog.get("version", "?"))
		_update_sync_label("loaded(%s) %d lentes [%s]" % [
			DataManager.catalog_source,
			DataManager.get_lens_ids().size(),
			ver,
		])
		_apply_initial_lens()

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
		"scenario": _current_scenario_id,
		"scenarios": SCENARIOS.keys(),
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
			if not DataManager.get_lens_ids().has(lens_id):
				push_warning("main: apply_lens lens_id desconocido '%s' (peer %d)" % [lens_id, peer_id])
				return
			DataManager.apply_lens(lens_id, eye)
			print("main: tablet aplico '%s' en ojo '%s'" % [lens_id, eye])
		"override_params":
			# Ajuste en vivo de parametros de la lente desde la tablet.
			# NO toca catalogo ni cache: solo el estado de vision en memoria.
			var params: Dictionary = cmd.get("params", {})
			var eye2: String = cmd.get("eye", "both")
			if params.is_empty():
				push_warning("main: override_params sin params (peer %d)" % peer_id)
				return
			DataManager.override_params(params, eye2)
			print("main: tablet ajusto %d param(s) en ojo '%s'" % [params.size(), eye2])
		"set_astigmatism":
			# Astigmatismo: canal independiente del catalogo de lentes.
			# Campos: eye ("left"|"right"|"both"), enabled (bool),
			#         magnitude (float px), angle (float rad).
			var eye_a: String  = cmd.get("eye", "both")
			var enabled: bool  = cmd.get("enabled", false)
			var magnitude: float = float(cmd.get("magnitude", 0.0))
			var angle: float     = float(cmd.get("angle", 0.0))
			set_astigmatism(eye_a, enabled, magnitude, angle)
			print("main: tablet astig eye='%s' enabled=%s mag=%.1f ang=%.2f" % [
				eye_a, str(enabled), magnitude, angle])
		"load_scenario":
			# Cambio de escena desde la tablet.
			# Campos: scenario (string id, ver SCENARIOS).
			var scenario_id: String = cmd.get("scenario", "")
			if scenario_id == "":
				push_warning("main: load_scenario sin scenario (peer %d)" % peer_id)
				return
			load_scenario(scenario_id)
			print("main: tablet cargo escenario '%s'" % scenario_id)
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

# Estado de astigmatismo (independiente del catalogo de lentes).
# Se controla desde la tablet con el comando "set_astigmatism".
var _astig_state: Dictionary = {
	"left":  {"enabled": false, "magnitude": 0.0, "angle": 0.0},
	"right": {"enabled": false, "magnitude": 0.0, "angle": 0.0},
}


func _apply_initial_lens() -> void:
	var ids := DataManager.get_lens_ids()
	if ids.is_empty():
		push_warning("main: catalogo sin lentes — shader queda en valores default.")
		return

	var initial_id := INITIAL_LENS_ID
	if not ids.has(initial_id):
		initial_id = ids[0]

	# apply_lens("both") emite vision_state_changed para ambos ojos,
	# y _on_vision_state_changed actualiza los uniforms del shader.
	DataManager.apply_lens(initial_id, "both")


## Devuelve el indice (en DataManager.get_lens_ids()) de la lente actualmente
## aplicada al ojo dado. Si no hay lente o no se encuentra, devuelve 0.
## Se calcula on-demand desde DataManager.current_vision_state para evitar el
## desfase que tendria un indice cacheado al cambiarse la lente desde otra
## fuente (tablet, sync de backend, override_params, etc).
func _current_lens_index(eye: String) -> int:
	var lens_id: String = DataManager.current_vision_state.get(eye, {}).get("lens_id", "")
	if lens_id == "":
		return 0
	var ids := DataManager.get_lens_ids()
	var idx := ids.find(lens_id)
	return idx if idx >= 0 else 0


func _on_vision_state_changed(eye: String, params: Dictionary) -> void:
	var mat := post_process_quad.get_active_material(0) as ShaderMaterial
	if mat == null:
		push_error("PostProcessQuad sin ShaderMaterial.")
		return

	var eye_idx := 0 if eye == "left" else 1
	for key in SHADER_PARAM_MAP.keys():
		if params.has(key):
			var uniform_name: String = SHADER_PARAM_MAP[key][eye_idx]
			var value := float(params[key])
			# Si los halos estan desactivados en esta escena, forzamos su
			# intensidad a 0 sin alterar el catalogo (se restaura al reactivar).
			if key in ["halo_intensity", "halo_extra_rings", "destello_intensity", "destello_rayos"] \
					and not halos_enabled:
				value = 0.0
			mat.set_shader_parameter(uniform_name, value)

	_update_lens_hud()


## Activa o desactiva los halos en runtime. Al cambiar, reaplica el estado de
## vision actual de ambos ojos para que los uniforms reflejen la decision.
func set_halos_enabled(enabled: bool) -> void:
	if halos_enabled == enabled:
		return
	halos_enabled = enabled
	print("main: halos ", "ON" if enabled else "OFF")
	for eye in ["left", "right"]:
		var state: Dictionary = DataManager.current_vision_state.get(eye, {})
		if not state.is_empty():
			_on_vision_state_changed(eye, state)


## Invierte el estado actual de los halos (util para enlazar a un boton).
func toggle_halos() -> void:
	set_halos_enabled(not halos_enabled)


## Configura el astigmatismo por ojo. Independiente del catalogo de lentes.
## eye: "left" | "right" | "both".
## magnitude: longitud del streak en px (0 = apagado).
## angle: orientacion del eje en radianes (0 = horizontal).
func set_astigmatism(eye: String, enabled: bool, magnitude: float, angle: float) -> void:
	var mat := post_process_quad.get_active_material(0) as ShaderMaterial
	if mat == null:
		return
	var eyes: Array[String] = []
	if eye == "both":
		eyes = ["left", "right"]
	else:
		eyes = [eye]
	for e in eyes:
		_astig_state[e]["enabled"]   = enabled
		_astig_state[e]["magnitude"] = magnitude
		_astig_state[e]["angle"]     = angle
		var suffix: String = "_l" if e == "left" else "_r"
		mat.set_shader_parameter("astig_enabled"   + suffix, 1.0 if enabled else 0.0)
		mat.set_shader_parameter("astig_magnitude" + suffix, magnitude)
		mat.set_shader_parameter("astig_angle"     + suffix, angle)


func _update_lens_hud() -> void:
	# Fuente unica de verdad: DataManager.current_vision_state. No cachear el
	# id de la lente — la tablet, el sync con backend o un override_params
	# pueden cambiarlo entre apply_lens y el siguiente refresh del HUD.
	var left_id: String = DataManager.current_vision_state.get("left", {}).get("lens_id", "?")
	var right_id: String = DataManager.current_vision_state.get("right", {}).get("lens_id", "?")
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
			var next_idx := (_current_lens_index("left") + 1) % ids.size()
			DataManager.apply_lens(ids[next_idx], "left")
		"by_button":
			# B — proxima lente para el ojo derecho.
			var next_idx := (_current_lens_index("right") + 1) % ids.size()
			DataManager.apply_lens(ids[next_idx], "right")
		"trigger_click":
			# Trigger — reset Blend: misma lente en ambos ojos (la del ojo izq).
			var left_idx := _current_lens_index("left")
			DataManager.apply_lens(ids[left_idx], "both")
		"grip_click":
			# Grip — toggle del shader post-proceso (modo "sin lentes").
			_toggle_post_process()


func _on_left_hand_button_pressed(name: String) -> void:
	match name:
		"by_button":
			# Y — cicla a la siguiente escena disponible.
			var ids := SCENARIOS.keys()
			var idx := ids.find(_current_scenario_id)
			var next_id: String = ids[(idx + 1) % ids.size()]
			load_scenario(next_id)
		"ax_button":
			# X — toggle halos (util para comparar con/sin en la escena nocturna).
			toggle_halos()


# ====================================================================
# Sprint 11 — Cambio de escena en runtime
# ====================================================================
## Carga una escena por su id (ver SCENARIOS). Hace fade negro durante el swap.
## Puede llamarse desde la tablet (cmd "load_scenario") o desde el controller (Y).
func load_scenario(id: String) -> void:
	if id == _current_scenario_id:
		return
	var cfg: Dictionary = SCENARIOS.get(id, {})
	if cfg.is_empty():
		push_warning("main: escenario '%s' desconocido." % id)
		return

	print("main: cargando escenario '%s'..." % id)

	# Fade a negro.
	var fade_mat := fade_quad.get_active_material(0) as ShaderMaterial
	var tween := create_tween()
	tween.tween_method(func(v: float) -> void:
		fade_mat.set_shader_parameter("alpha", v), 0.0, 1.0, 0.35)
	await tween.finished

	# Liberar escena actual.
	if _scenario_node != null:
		_scenario_node.queue_free()
		_scenario_node = null

	# Instanciar la nueva.
	var packed: PackedScene = load(cfg["scene"])
	if packed == null:
		push_error("main: no se pudo cargar '%s'" % cfg["scene"])
		return
	_scenario_node = packed.instantiate() as Node3D
	scenario_container.add_child(_scenario_node)
	_current_scenario_id = id

	_apply_scenario_config(cfg)

	# Fade de vuelta.
	tween = create_tween()
	tween.tween_method(func(v: float) -> void:
		fade_mat.set_shader_parameter("alpha", v), 1.0, 0.0, 0.35)

	print("main: escenario '%s' activo." % id)


func _apply_scenario_config(cfg: Dictionary) -> void:
	# Halos / destello.
	set_halos_enabled(cfg.get("halos", false))

	# Umbral de brillo a partir del cual una fuente genera halo/destello/streak.
	# Es por escena: de noche se baja para que todas las luces lo superen.
	var mat := post_process_quad.get_active_material(0) as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("halo_threshold", cfg.get("halo_threshold", 0.9))

	# Entorno visual (cielo, luz solar).
	var env_id: String = cfg.get("env", "day")
	_apply_environment(NIGHT_PARAMS if env_id == "night" else DAY_PARAMS)

	# Libro: visible solo en escenas de dia/consultorio. Ademas se detiene su
	# _process cuando no se usa, para que no pelee por el uniform book_distance_m
	# con el celular de la escena nocturna (ambos escriben el mismo uniform).
	var show_book: bool = cfg.get("show_book", true)
	book_holder.visible = show_book
	book_holder.set_process(show_book)

	# PhoneHolder en auto_noche: conectar con PostProcessQuad y camara.
	if _scenario_node != null:
		var phone := _scenario_node.get_node_or_null("PhoneAnchor")
		if phone != null:
			phone._post_quad = post_process_quad
			phone._camera   = xr_camera
			# Re-init shader mat (el _ready() corrio antes de que se asignaran).
			if phone._post_quad != null:
				phone._shader_mat = phone._post_quad.get_active_material(0) as ShaderMaterial


func _toggle_post_process() -> void:
	_post_process_enabled = not _post_process_enabled
	post_process_quad.visible = _post_process_enabled
	var tag := "ON" if _post_process_enabled else "OFF (sin lentes)"
	print("main: post-process ", tag)
	_update_lens_hud_with_toggle()


func _update_lens_hud_with_toggle() -> void:
	if not _post_process_enabled:
		sync_label.text = "SIN LENTES\n(grip para volver)"
	else:
		_update_lens_hud()


func _apply_environment(params: Dictionary) -> void:
	dir_light.light_energy = params.get("sun_energy", 1.0)
	dir_light.light_color  = params.get("sun_color", Color.WHITE)
	# De noche el sol está casi apagado: su mapa de sombras no aporta nada visual
	# pero igual renderiza un pase de sombras sobre TODO el modelo (miles de meshes).
	# Apagarlo es la optimización de mayor impacto de la escena nocturna.
	dir_light.shadow_enabled = params.get("sun_shadow", true)

	var env: Environment = world_env.environment
	if env == null:
		return
	env.ambient_light_color  = params.get("ambient_color",  Color(0.6, 0.7, 0.85, 1))
	env.ambient_light_energy = params.get("ambient_energy", 0.4)

	# Glow/bloom por escena (clave para los halos nocturnos; ver fase_6).
	env.glow_enabled = params.get("glow_enabled", false)
	if env.glow_enabled:
		env.glow_intensity     = params.get("glow_intensity", 1.0)
		env.glow_strength      = params.get("glow_strength", 1.0)
		env.glow_bloom         = params.get("glow_bloom", 0.0)
		env.glow_hdr_threshold = params.get("glow_hdr_threshold", 1.0)

	# Tonemap/exposicion por escena: AGX de noche evita que la suma de luces
	# de la calle queme la imagen a blanco, manteniendo el fondo oscuro.
	env.tonemap_mode     = params.get("tonemap_mode", 0)
	env.tonemap_exposure = params.get("tonemap_exposure", 1.0)
	env.tonemap_white    = params.get("tonemap_white", 1.0)

	var sky_mat := env.sky.sky_material as ProceduralSkyMaterial
	if sky_mat == null:
		return
	sky_mat.sky_top_color      = params.get("sky_top",       Color(0.18, 0.32, 0.55, 1))
	sky_mat.sky_horizon_color  = params.get("sky_horizon",   Color(0.5, 0.55, 0.55, 1))
	sky_mat.ground_bottom_color  = params.get("ground_bottom",  Color(0.1, 0.1, 0.1, 1))
	sky_mat.ground_horizon_color = params.get("ground_horizon", Color(0.4, 0.4, 0.4, 1))


# ====================================================================
# FPS HUD
# ====================================================================
func _process(delta: float) -> void:
	fps_accumulator += delta
	fps_frames += 1
	if fps_accumulator >= 0.5:
		var fps := fps_frames / fps_accumulator
		var frame_ms := (fps_accumulator / fps_frames) * 1000.0
		fps_label.text = "FPS: %d\nFrame: %.2f ms\nescena: %s" % [int(fps), frame_ms, _current_scenario_id]
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
