extends Node3D
## Escena raiz del simulador VR — Sprint 4.
##
## Responsabilidades:
##   1. Inicializa OpenXR + viewport XR + physics 90 Hz.
##   2. Conecta al DataManager (autoload) para mostrar el estado de sync
##      con el backend en el SyncHud.
##   3. Aplica un preset asimetrico al shader del Sprint 2 (sera reemplazado
##      por seleccion desde el catalogo en Sprint 5).
##   4. Auto-cicla un dia/noche cada DAY_NIGHT_INTERVAL segundos con
##      fade-to-black intermedio.

const TARGET_PHYSICS_TICKS := 90
const DAY_NIGHT_INTERVAL := 15.0  # segundos entre toggles
const FADE_DURATION := 0.8        # tiempo de fade-out / fade-in
const HOLD_AT_BLACK := 0.2        # tiempo en negro mientras se cambia el ambiente

# Preset asimetrico aplicado al shader.
# Ojo izquierdo: PanOptix simulado (multifocal, halos fuertes, DoF parejo).
# Ojo derecho:  Vivity simulado (EDOF, foco lejos, halo bajo, blur cerca alto).
# TODO Sprint 5: armar este preset dinamicamente desde DataManager.get_lens(...).
const PRESET := {
	"left": {
		"blur_near": 0.05,
		"blur_medium": 0.05,
		"blur_far": 0.05,
		"halo_intensity": 0.8,
	},
	"right": {
		"blur_near": 0.7,
		"blur_medium": 0.05,
		"blur_far": 0.0,
		"halo_intensity": 0.2,
	},
}

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
@onready var dir_light: DirectionalLight3D = $DirectionalLight3D
@onready var world_env: WorldEnvironment = $WorldEnvironment

var xr_interface: XRInterface
var fps_accumulator: float = 0.0
var fps_frames: int = 0
var is_night: bool = false
var _cycle_timer: Timer


func _ready() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface == null or not xr_interface.is_initialized():
		push_warning("OpenXR no inicializado — corriendo en modo no-VR (probablemente PC editor).")
	else:
		get_viewport().use_xr = true
		Engine.physics_ticks_per_second = TARGET_PHYSICS_TICKS

	_apply_shader_preset()
	_apply_environment(DAY_PARAMS)

	# DataManager (autoload) ya intento cargar catalogo en su _ready y
	# dispara el sync con el backend en background. Nos suscribimos para
	# reflejar el estado en el HUD.
	DataManager.catalog_loaded.connect(_on_catalog_loaded)
	DataManager.catalog_synced_with_backend.connect(_on_catalog_synced)
	DataManager.catalog_sync_failed.connect(_on_catalog_sync_failed)
	# Si DataManager ya cargo antes de conectar (carrera comun con autoloads),
	# reflejamos el estado actual:
	if not DataManager.catalog.is_empty():
		var ver: String = DataManager.catalog.get("version", "?")
		_update_sync_label("loaded(%s) %d lentes [%s]" % [
			DataManager.catalog_source,
			DataManager.get_lens_ids().size(),
			ver,
		])

	_start_day_night_cycle()


# ====================================================================
# DataManager wiring
# ====================================================================
func _on_catalog_loaded(version: String, source: String, lens_count: int) -> void:
	_update_sync_label("loaded(%s) %d lentes [%s]" % [source, lens_count, version])


func _on_catalog_synced(version: String) -> void:
	_update_sync_label("backend OK [%s]" % version)


func _on_catalog_sync_failed(reason: String) -> void:
	# El catalogo local sigue activo; solo informamos del fallo en el HUD.
	var short_reason := reason.substr(0, 40)
	_update_sync_label("sync OFFLINE: %s" % short_reason)


func _update_sync_label(text: String) -> void:
	sync_label.text = "catalogo:\n%s" % text


# ====================================================================
# Shader preset (heredado de Sprint 2 — Sprint 5 lo conectara al catalogo)
# ====================================================================
func _apply_shader_preset() -> void:
	var mat := post_process_quad.get_active_material(0) as ShaderMaterial
	if mat == null:
		push_error("PostProcessQuad sin ShaderMaterial.")
		return
	mat.set_shader_parameter("blur_near_l",   PRESET.left.blur_near)
	mat.set_shader_parameter("blur_medium_l", PRESET.left.blur_medium)
	mat.set_shader_parameter("blur_far_l",    PRESET.left.blur_far)
	mat.set_shader_parameter("halo_intensity_l", PRESET.left.halo_intensity)
	mat.set_shader_parameter("blur_near_r",   PRESET.right.blur_near)
	mat.set_shader_parameter("blur_medium_r", PRESET.right.blur_medium)
	mat.set_shader_parameter("blur_far_r",    PRESET.right.blur_far)
	mat.set_shader_parameter("halo_intensity_r", PRESET.right.halo_intensity)


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
		fps_accumulator = 0.0
		fps_frames = 0
