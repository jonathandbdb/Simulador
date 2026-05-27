extends Node
## StreamingCapture — Sprint 7 polish (viewport-chain server-side por ojo)
##
## Arquitectura:
##   - UN SubViewport 3D "raw" que renderiza la escena con una Camera3D
##     pose-matched a la XRCamera. Igual que el codigo del Sprint 6 que
##     ya funcionaba (sin shaders, escena cruda).
##   - DOS SubViewports 2D "post" (uno por ojo) que contienen un
##     TextureRect mostrando la textura del raw + ShaderMaterial canvas_item
##     `eye_preview.gdshader` con uniforms del ojo correspondiente
##     (blur, halo, contrast_loss segun la lente del ojo).
##
## La escena 3D se rinde UNA sola vez por tick (en el raw). Los post solo
## aplican un shader 2D barato sobre la textura ya renderizada, asi el
## costo no se duplica.
##
## Protocolo en el wire:
##   Cada paquete binario empieza con 1 byte de header:
##     0x42 ('B')  -> frame compartido (ambos ojos misma lente)
##     0x4C ('L')  -> frame del ojo izquierdo (modo blend)
##     0x52 ('R')  -> frame del ojo derecho   (modo blend)
##   El resto del paquete es el JPG.
##
## Estrategia de tick:
##   - Sin blend  -> capturo solo VP_post_L con header 'B' @ 10 Hz.
##   - Con blend  -> alterno L/R en ticks consecutivos. Cada ojo @ 5 Hz,
##     10 Hz totales en broadcast.

const CAPTURE_SIZE := Vector2i(256, 256)
const CAPTURE_HZ := 10.0
const JPG_QUALITY := 0.55

const HEADER_BOTH := 0x42  # 'B'
const HEADER_LEFT := 0x4C  # 'L'
const HEADER_RIGHT := 0x52 # 'R'

@export var camera_to_follow: NodePath
@export var enabled: bool = true

# Render 3D crudo (escena con XR pose).
var _vp_raw: SubViewport
var _cam_raw: Camera3D
# Post-procesado 2D por ojo.
var _vp_post_left: SubViewport
var _vp_post_right: SubViewport
var _rect_left: TextureRect
var _rect_right: TextureRect
var _mat_left: ShaderMaterial
var _mat_right: ShaderMaterial

var _timer: Timer
var _capturing: bool = false
var _last_jpg_size: int = 0
var _frames_sent: int = 0
var _pending_image: Image = null
var _pending_header: int = HEADER_BOTH
var _next_eye_in_blend: String = "left"


func _ready() -> void:
	if not enabled:
		print("StreamingCapture: deshabilitado.")
		return

	# --- 1) SubViewport raw (escena 3D cruda) — mismo enfoque que Sprint 6. ---
	_vp_raw = SubViewport.new()
	_vp_raw.name = "RawViewport"
	_vp_raw.size = CAPTURE_SIZE
	_vp_raw.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_vp_raw.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_vp_raw.transparent_bg = false
	add_child(_vp_raw)

	_cam_raw = Camera3D.new()
	_cam_raw.fov = 75.0
	_cam_raw.near = 0.05
	_cam_raw.far = 100.0
	_cam_raw.current = true
	_vp_raw.add_child(_cam_raw)

	# --- 2) Dos SubViewports 2D para post-procesado por ojo. ---
	var shader: Shader = load("res://features/tablet/eye_preview.gdshader")
	_vp_post_left  = _build_post_viewport("PostViewport_left",  shader)
	_vp_post_right = _build_post_viewport("PostViewport_right", shader)
	_rect_left  = _vp_post_left.get_node("TextureRect")  as TextureRect
	_rect_right = _vp_post_right.get_node("TextureRect") as TextureRect
	_mat_left   = _rect_left.material  as ShaderMaterial
	_mat_right  = _rect_right.material as ShaderMaterial

	# Cada TextureRect muestra la textura del raw — apuntar despues de crear.
	_rect_left.texture  = _vp_raw.get_texture()
	_rect_right.texture = _vp_raw.get_texture()

	_sync_uniforms_for_eye("left")
	_sync_uniforms_for_eye("right")
	if DataManager.has_signal("vision_state_changed"):
		DataManager.vision_state_changed.connect(_on_vision_state_changed)

	_timer = Timer.new()
	_timer.wait_time = 1.0 / CAPTURE_HZ
	_timer.one_shot = false
	_timer.autostart = true
	_timer.timeout.connect(_on_capture_tick)
	add_child(_timer)

	print("StreamingCapture: chain 1 raw + 2 post %dx%d @ %d Hz (thread-pool JPG)." % [
		CAPTURE_SIZE.x, CAPTURE_SIZE.y, int(CAPTURE_HZ),
	])


func _build_post_viewport(node_name: String, shader: Shader) -> SubViewport:
	var vp := SubViewport.new()
	vp.name = node_name
	vp.size = CAPTURE_SIZE
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	vp.transparent_bg = false
	# Es un viewport 2D — explicito para evitar que cree world_3d propio.
	vp.disable_3d = true
	vp.own_world_3d = false
	add_child(vp)

	var rect := TextureRect.new()
	rect.name = "TextureRect"
	rect.anchor_right = 1.0
	rect.anchor_bottom = 1.0
	rect.offset_right = 0.0
	rect.offset_bottom = 0.0
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("blur_amount", 0.0)
	mat.set_shader_parameter("halo_intensity", 0.0)
	mat.set_shader_parameter("contrast_loss", 0.0)
	mat.set_shader_parameter("halo_threshold", 0.65)
	mat.set_shader_parameter("halo_tint", Vector3(1.05, 1.0, 0.78))
	rect.material = mat
	vp.add_child(rect)

	return vp


func _on_vision_state_changed(eye: String, _params: Dictionary) -> void:
	_sync_uniforms_for_eye(eye)


func _sync_uniforms_for_eye(eye: String) -> void:
	if not DataManager:
		return
	var state: Dictionary = DataManager.current_vision_state
	if state == null or not state.has(eye):
		return
	var params: Dictionary = state[eye]
	# El stream es 2D (sin depth): pondera blur_medium como rango dominante
	# visualmente, mas un toque de near/far. Coincide con lo que ya hacia
	# la tablet en el approach anterior.
	var bn := float(params.get("blur_near", 0.0))
	var bm := float(params.get("blur_medium", 0.0))
	var bf := float(params.get("blur_far", 0.0))
	var effective_blur: float = clampf(bm * 0.6 + bn * 0.2 + bf * 0.2, 0.0, 1.0)
	var halo := clampf(float(params.get("halo_intensity", 0.0)), 0.0, 1.0)
	var contrast := clampf(float(params.get("contrast_loss", 0.0)), 0.0, 1.0)

	var mat := _mat_left if eye == "left" else _mat_right
	if mat == null:
		return
	mat.set_shader_parameter("blur_amount", effective_blur)
	mat.set_shader_parameter("halo_intensity", halo)
	mat.set_shader_parameter("contrast_loss", contrast)


func _is_blend_mode() -> bool:
	if not DataManager:
		return false
	var state: Dictionary = DataManager.current_vision_state
	if state == null or not state.has("left") or not state.has("right"):
		return false
	return state["left"].get("lens_id", "") != state["right"].get("lens_id", "")


func _on_capture_tick() -> void:
	if _capturing:
		return
	if StreamingServer.get_open_client_count() == 0:
		return
	_capturing = true

	# 1) Sincronizar pose de la camara raw con la XRCamera.
	var follow := get_node_or_null(camera_to_follow)
	if follow is Node3D:
		_cam_raw.global_transform = (follow as Node3D).global_transform

	# 2) Decidir que ojo capturar este tick.
	var eye_to_capture: String
	var header: int
	if _is_blend_mode():
		eye_to_capture = _next_eye_in_blend
		header = HEADER_LEFT if eye_to_capture == "left" else HEADER_RIGHT
		_next_eye_in_blend = "right" if eye_to_capture == "left" else "left"
	else:
		eye_to_capture = "left"
		header = HEADER_BOTH

	# 3) Renderizar la escena raw UNA VEZ.
	_vp_raw.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw

	# 4) Renderizar el post-process del ojo elegido (aplica el shader).
	var vp_post := _vp_post_left if eye_to_capture == "left" else _vp_post_right
	vp_post.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw

	# 5) Sacar imagen del viewport post-procesado.
	var img := vp_post.get_texture().get_image()
	if img == null or img.is_empty():
		_capturing = false
		return
	if img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)

	_pending_image = img
	_pending_header = header
	WorkerThreadPool.add_task(_encode_jpg_on_worker)


func _encode_jpg_on_worker() -> void:
	var img := _pending_image
	if img == null:
		return
	var jpg := img.save_jpg_to_buffer(JPG_QUALITY)
	# Prepend del byte de header.
	var out := PackedByteArray()
	out.resize(jpg.size() + 1)
	out[0] = _pending_header
	for i in range(jpg.size()):
		out[i + 1] = jpg[i]
	call_deferred("_on_jpg_encoded", out)


func _on_jpg_encoded(bytes: PackedByteArray) -> void:
	if bytes.size() > 1:
		StreamingServer.broadcast_binary(bytes)
		_last_jpg_size = bytes.size()
		_frames_sent += 1
	_pending_image = null
	_capturing = false


func get_last_jpg_size() -> int:
	return _last_jpg_size


func get_frames_sent() -> int:
	return _frames_sent
