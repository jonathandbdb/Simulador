extends Node
## StreamingCapture — Sprint 6 (F3 PoC GO/NO-GO bloqueante)
##
## Crea un SubViewport dedicado de 256x256 con render_target_update_mode=ONCE,
## disparado por un Timer a 10 Hz. Cada tick:
##   1. Sincroniza la Camera3D del SubViewport con el global_transform del
##      XRCamera3D para que vea lo mismo que el ojo izquierdo del paciente.
##   2. Pide UPDATE_ONCE al SubViewport y espera un frame_post_draw.
##   3. get_image() -> [WorkerThreadPool] save_jpg_to_buffer -> broadcast.
##
## NO se aplica el shader de post-procesado del Sprint 2: este SubViewport
## ve la escena "raw" para minimizar el costo de captura. El stream sirve
## como vista de control para el operador, no como representacion fiel
## de lo que ve el paciente en VR.
##
## Optimizaciones aplicadas tras medir caida a 30-40 FPS en Quest:
##   - Resolucion 512 -> 256 (4x menos pixels).
##   - Tick 15 Hz -> 10 Hz.
##   - JPG quality 0.5 -> 0.4.
##   - JPG encoding en WorkerThreadPool (sale del main thread).
##
## Criterio GO Sprint 6: el visor mantiene >=72 FPS con streaming activo.

const CAPTURE_SIZE := Vector2i(256, 256)
const CAPTURE_HZ := 10.0
const JPG_QUALITY := 0.4

@export var camera_to_follow: NodePath
@export var enabled: bool = true

var _viewport: SubViewport
var _camera: Camera3D
var _timer: Timer
var _capturing: bool = false  # evita reentrancia si la captura se atrasa
var _last_jpg_size: int = 0
var _frames_sent: int = 0
# Encoding async: imagen pendiente para el thread del pool.
var _pending_image: Image = null


func _ready() -> void:
	if not enabled:
		print("StreamingCapture: deshabilitado.")
		return

	_viewport = SubViewport.new()
	_viewport.size = CAPTURE_SIZE
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_viewport.transparent_bg = false
	add_child(_viewport)

	_camera = Camera3D.new()
	_camera.fov = 75.0
	_camera.near = 0.05
	_camera.far = 100.0
	_camera.current = true
	_viewport.add_child(_camera)

	_timer = Timer.new()
	_timer.wait_time = 1.0 / CAPTURE_HZ
	_timer.one_shot = false
	_timer.autostart = true
	_timer.timeout.connect(_on_capture_tick)
	add_child(_timer)

	print("StreamingCapture: SubViewport %dx%d @ %d Hz (thread-pool JPG)." % [
		CAPTURE_SIZE.x, CAPTURE_SIZE.y, int(CAPTURE_HZ),
	])


func _on_capture_tick() -> void:
	if _capturing:
		return
	if StreamingServer.get_open_client_count() == 0:
		# Sin clientes no gastamos GPU ni CPU.
		return
	_capturing = true

	# 1. Sincronizar pose con la camara XR.
	var follow := get_node_or_null(camera_to_follow)
	if follow is Node3D:
		_camera.global_transform = (follow as Node3D).global_transform

	# 2. Forzar un render fresco y esperar a que termine el draw.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw

	# 3. Sacar imagen del viewport (esto SI debe estar en main thread).
	var img := _viewport.get_texture().get_image()
	if img == null or img.is_empty():
		_capturing = false
		return
	if img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)

	# 4. Encoding JPG en thread aparte para no bloquear el frame de VR.
	_pending_image = img
	WorkerThreadPool.add_task(_encode_jpg_on_worker)


func _encode_jpg_on_worker() -> void:
	# Corre en un thread del pool. NO tocar nodos de escena aca, solo Image.
	var img := _pending_image
	if img == null:
		return
	var bytes := img.save_jpg_to_buffer(JPG_QUALITY)
	# Volver al main thread para tocar el server WebSocket.
	call_deferred("_on_jpg_encoded", bytes)


func _on_jpg_encoded(bytes: PackedByteArray) -> void:
	if bytes.size() > 0:
		StreamingServer.broadcast_binary(bytes)
		_last_jpg_size = bytes.size()
		_frames_sent += 1
	_pending_image = null
	_capturing = false


func get_last_jpg_size() -> int:
	return _last_jpg_size


func get_frames_sent() -> int:
	return _frames_sent
