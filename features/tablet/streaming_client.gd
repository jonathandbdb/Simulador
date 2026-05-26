extends Control
## TabletClient — Sprint 7
##
## Cliente de control + stream para la tablet (o para la PC durante el
## desarrollo). Se conecta por WebSocket al visor (puerto 9090) y:
##   1. Recibe un mensaje "hello" con el catalogo de lentes y el estado
##      actual de vision por ojo. Con eso arma la UI dinamicamente.
##   2. Muestra el stream binario (JPGs) en un TextureRect.
##   3. Envia comandos "apply_lens" cuando el usuario toca un boton de
##      lente, eligiendo el ojo objetivo desde un OptionButton (Left/
##      Right/Both).
##
## Protocolo (texto JSON en ambos sentidos, binario solo visor->tablet):
##   visor -> tablet:
##     { "type": "hello",
##       "catalog_version": "1.0.0",
##       "lenses": [ { "id": "monofocal", "tipo": "...", ... }, ... ],
##       "vision_state": { "left": {...}, "right": {...} } }
##   tablet -> visor:
##     { "cmd": "apply_lens", "lens_id": "panoptix", "eye": "left|right|both" }

const DEFAULT_HOST := "192.168.2.30"
const DEFAULT_PORT := 9090

@onready var texture_rect: TextureRect = $Margin/HBox/StreamPanel/VBox/StreamFrame/TextureRect
@onready var status_label: Label = $Margin/HBox/StreamPanel/VBox/StatusLabel
@onready var host_edit: LineEdit = $Margin/HBox/StreamPanel/VBox/TopBar/HostEdit
@onready var connect_button: Button = $Margin/HBox/StreamPanel/VBox/TopBar/ConnectButton
@onready var discovered_list: HBoxContainer = $Margin/HBox/StreamPanel/VBox/DiscoveredList
@onready var eye_option: OptionButton = $Margin/HBox/ControlPanel/VBox/EyeOption
@onready var lens_list: VBoxContainer = $Margin/HBox/ControlPanel/VBox/LensListScroll/LensList
@onready var state_label: Label = $Margin/HBox/ControlPanel/VBox/StateLabel

var _peer := WebSocketPeer.new()
var _texture: ImageTexture
var _frames_received: int = 0
var _bytes_received: int = 0
var _connecting: bool = false
var _catalog_lenses: Array = []
var _vision_state: Dictionary = {}


func _ready() -> void:
	# CLI override: --visor-host <ip>
	var args := OS.get_cmdline_args()
	var host := DEFAULT_HOST
	for i in range(args.size()):
		if args[i] == "--visor-host" and i + 1 < args.size():
			host = args[i + 1]
	host_edit.text = host

	# Selector de ojo.
	eye_option.add_item("Ambos", 0)
	eye_option.add_item("Izquierdo", 1)
	eye_option.add_item("Derecho", 2)
	eye_option.selected = 0

	connect_button.pressed.connect(_on_connect_pressed)
	_update_status("desconectado")

	# Discovery (Opcion A): UDP broadcast en :9091. El autoload DiscoveryBeacon
	# (en modo listener cuando feature "tablet" esta activa) cachea hosts vistos.
	DiscoveryBeacon.visor_discovered.connect(_on_visor_discovered)
	_refresh_discovered()
	var refresh_timer := Timer.new()
	refresh_timer.wait_time = 2.0
	refresh_timer.autostart = true
	refresh_timer.timeout.connect(_refresh_discovered)
	add_child(refresh_timer)


func _on_visor_discovered(_host: String, _payload: Dictionary) -> void:
	# El cache de hosts esta en el autoload; aca solo pedimos refresco UI.
	_refresh_discovered()


func _refresh_discovered() -> void:
	var hosts: Array = DiscoveryBeacon.get_active_hosts(6.0)
	# Reconstruir botones (lista corta, costo bajo).
	for child in discovered_list.get_children():
		child.queue_free()
	if hosts.is_empty():
		var lbl := Label.new()
		lbl.text = "(buscando...)"
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", Color(0.5, 0.55, 0.65))
		discovered_list.add_child(lbl)
		return
	for host in hosts:
		var btn := Button.new()
		btn.text = host
		btn.pressed.connect(_on_discovered_pressed.bind(host))
		discovered_list.add_child(btn)


func _on_discovered_pressed(host: String) -> void:
	host_edit.text = host
	_on_connect_pressed()


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
				_on_text_received(data.get_string_from_utf8())
			else:
				_on_frame_received(data)
	elif state == WebSocketPeer.STATE_CLOSED:
		if _connecting:
			_connecting = false
			_update_status("desconectado (code=%d, reason=%s)" % [
				_peer.get_close_code(), _peer.get_close_reason(),
			])


func _on_text_received(text: String) -> void:
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		print("TabletClient: texto no-JSON: %s" % text)
		return
	var msg_type: String = parsed.get("type", "")
	match msg_type:
		"hello":
			_catalog_lenses = parsed.get("lenses", [])
			_vision_state = parsed.get("vision_state", {})
			_rebuild_lens_list()
			_update_state_label()
			_update_status("conectado | catalogo %s | %d lentes" % [
				parsed.get("catalog_version", "?"),
				_catalog_lenses.size(),
			])
		_:
			print("TabletClient: tipo de mensaje desconocido: %s" % msg_type)


func _on_frame_received(data: PackedByteArray) -> void:
	var img := Image.new()
	var err := img.load_jpg_from_buffer(data)
	if err != OK:
		return
	if _texture == null:
		_texture = ImageTexture.create_from_image(img)
		texture_rect.texture = _texture
	else:
		_texture.update(img)
	_frames_received += 1
	_bytes_received += data.size()


func _rebuild_lens_list() -> void:
	# Limpiar lista anterior.
	for child in lens_list.get_children():
		child.queue_free()

	for lens_dict in _catalog_lenses:
		var lens: Dictionary = lens_dict
		var btn := Button.new()
		var lens_id: String = lens.get("id", "?")
		var tipo: String = lens.get("tipo", "")
		btn.text = "%s\n[%s]" % [lens_id, tipo]
		btn.custom_minimum_size = Vector2(0, 60)
		btn.pressed.connect(_on_lens_button_pressed.bind(lens_id))
		lens_list.add_child(btn)


func _on_lens_button_pressed(lens_id: String) -> void:
	var eye_map := {0: "both", 1: "left", 2: "right"}
	var eye: String = eye_map.get(eye_option.selected, "both")
	var cmd := {"cmd": "apply_lens", "lens_id": lens_id, "eye": eye}
	if _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		_update_status("no hay conexion para enviar comando")
		return
	_peer.send_text(JSON.stringify(cmd))
	# Actualizacion optimista del estado local.
	if eye == "left" or eye == "both":
		_vision_state["left"] = {"lens_id": lens_id}
	if eye == "right" or eye == "both":
		_vision_state["right"] = {"lens_id": lens_id}
	_update_state_label()


func _update_state_label() -> void:
	var left_id: String = _vision_state.get("left", {}).get("lens_id", "?")
	var right_id: String = _vision_state.get("right", {}).get("lens_id", "?")
	var blend := " (Blend)" if left_id != right_id else ""
	state_label.text = "Estado actual:\n  L: %s\n  R: %s%s" % [left_id, right_id, blend]


func _update_status(text: String) -> void:
	if status_label != null:
		status_label.text = "%s | frames=%d | %.1f KB" % [
			text, _frames_received, _bytes_received / 1024.0,
		]
