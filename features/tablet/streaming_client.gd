extends Control
## StreamingClient — Sprint 6 (PoC bloqueante F3)
##
## Cliente Godot minimo que se conecta al WebSocket del visor en :9090
## y muestra los JPGs binarios entrantes en un TextureRect.
##
## Como correrlo desde PC (no requiere export, se ejecuta con el binario
## de Godot directamente):
##
##   & "C:\Path\To\Godot_v4.6.1-stable_win64.exe" --path . \
##       features/tablet/streaming_client.tscn --visor-host 192.168.2.12
##
## o simplemente abriendo features/tablet/streaming_client.tscn desde el
## editor y corriendola con F6. La host por defecto es 192.168.2.12 (la
## misma LAN de desarrollo que el backend).

const DEFAULT_HOST := "192.168.2.12"
const DEFAULT_PORT := 9090

@onready var texture_rect: TextureRect = $VBox/TextureRect
@onready var status_label: Label = $VBox/StatusLabel
@onready var host_edit: LineEdit = $VBox/HBox/HostEdit
@onready var connect_button: Button = $VBox/HBox/ConnectButton

var _peer := WebSocketPeer.new()
var _texture: ImageTexture
var _last_image: Image
var _frames_received: int = 0
var _bytes_received: int = 0
var _connecting: bool = false


func _ready() -> void:
	# Permitir override por CLI: --visor-host <ip>
	var args := OS.get_cmdline_args()
	var host := DEFAULT_HOST
	for i in range(args.size()):
		if args[i] == "--visor-host" and i + 1 < args.size():
			host = args[i + 1]
	host_edit.text = host
	connect_button.pressed.connect(_on_connect_pressed)
	_update_status("desconectado")


func _on_connect_pressed() -> void:
	var host := host_edit.text.strip_edges()
	if host == "":
		host = DEFAULT_HOST
	var url := "ws://%s:%d" % [host, DEFAULT_PORT]
	_update_status("conectando a %s..." % url)
	var err := _peer.connect_to_url(url)
	if err != OK:
		_update_status("connect_to_url fallo: %d" % err)
		return
	_connecting = true


func _process(_delta: float) -> void:
	if not _connecting and _peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		return
	_peer.poll()
	var state := _peer.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if _connecting:
			_connecting = false
			_update_status("conectado")
		while _peer.get_available_packet_count() > 0:
			var data := _peer.get_packet()
			if _peer.was_string_packet():
				# Texto: no usado en Sprint 6. Lo logueamos por completitud.
				print("StreamingClient: texto recibido: %s" % data.get_string_from_utf8())
			else:
				_on_frame_received(data)
	elif state == WebSocketPeer.STATE_CLOSED:
		if _connecting:
			_connecting = false
			_update_status("desconectado (code=%d, reason=%s)" % [
				_peer.get_close_code(), _peer.get_close_reason(),
			])


func _on_frame_received(data: PackedByteArray) -> void:
	var img := Image.new()
	var err := img.load_jpg_from_buffer(data)
	if err != OK:
		print("StreamingClient: JPG invalido (err=%d, %d bytes)" % [err, data.size()])
		return
	if _texture == null:
		_texture = ImageTexture.create_from_image(img)
		texture_rect.texture = _texture
	else:
		_texture.update(img)
	_last_image = img
	_frames_received += 1
	_bytes_received += data.size()
	_update_status("conectado | frames=%d | total=%.1f KB | last=%.1f KB" % [
		_frames_received,
		_bytes_received / 1024.0,
		data.size() / 1024.0,
	])


func _update_status(text: String) -> void:
	if status_label != null:
		status_label.text = text
