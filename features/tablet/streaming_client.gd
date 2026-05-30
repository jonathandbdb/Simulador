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

@onready var texture_rect: TextureRect = $Margin/HBox/StreamPanel/VBox/StreamFrame/EyesContainer/LeftEyePane/TextureRect
@onready var right_texture_rect: TextureRect = $Margin/HBox/StreamPanel/VBox/StreamFrame/EyesContainer/RightEyePane/TextureRect
@onready var left_eye_label: Label = $Margin/HBox/StreamPanel/VBox/StreamFrame/EyesContainer/LeftEyePane/LeftEyeLabel
@onready var right_eye_label: Label = $Margin/HBox/StreamPanel/VBox/StreamFrame/EyesContainer/RightEyePane/RightEyeLabel
@onready var right_eye_pane: VBoxContainer = $Margin/HBox/StreamPanel/VBox/StreamFrame/EyesContainer/RightEyePane
@onready var status_label: Label = $Margin/HBox/StreamPanel/VBox/StatusLabel
@onready var host_edit: LineEdit = $Margin/HBox/StreamPanel/VBox/TopBar/HostEdit
@onready var connect_button: Button = $Margin/HBox/StreamPanel/VBox/TopBar/ConnectButton
@onready var discovered_list: HBoxContainer = $Margin/HBox/StreamPanel/VBox/DiscoveredList
@onready var eye_option: OptionButton = $Margin/HBox/ControlPanel/VBox/EyeOption
@onready var lens_list: VBoxContainer = $Margin/HBox/ControlPanel/VBox/LensListScroll/LensList
@onready var params_list: VBoxContainer = $Margin/HBox/ControlPanel/VBox/ParamsScroll/ParamsList
@onready var reset_button: Button = $Margin/HBox/ControlPanel/VBox/ParamsHeader/ResetButton
@onready var state_label: Label = $Margin/HBox/ControlPanel/VBox/StateLabel

var _peer := WebSocketPeer.new()
# Texturas separadas por ojo (el visor manda streams independientes en
# modo blend). En modo "both" ambas referencian al mismo Image refresh.
var _texture_left: ImageTexture
var _texture_right: ImageTexture
var _frames_received: int = 0
var _bytes_received: int = 0
var _connecting: bool = false
var _catalog_lenses: Array = []
var _lenses_by_id: Dictionary = {}
var _vision_state: Dictionary = {}

# Ajuste en vivo: lente cuyos parametros se estan editando en los sliders,
# y mapa param->control para poder restaurar/leer valores.
var _editing_lens_id: String = ""
var _param_sliders: Dictionary = {}  # param_name -> HSlider
var _param_value_labels: Dictionary = {}  # param_name -> Label
var _param_defaults: Dictionary = {}  # param_name -> float (default de la lente)

const HEADER_BOTH := 0x42  # 'B'
const HEADER_LEFT := 0x4C  # 'L'
const HEADER_RIGHT := 0x52 # 'R'


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

	# Sin shader client-side: el visor ya manda streams con el efecto de
	# lente aplicado server-side (StreamingCapture / eye_preview_spatial).
	texture_rect.material = null
	right_texture_rect.material = null

	connect_button.pressed.connect(_on_connect_pressed)
	_update_status("desconectado")

	# Boton para restaurar los valores por defecto de la lente en edicion.
	reset_button.pressed.connect(_on_reset_params_pressed)

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
			_lenses_by_id.clear()
			for lens in _catalog_lenses:
				if lens is Dictionary and lens.has("id"):
					_lenses_by_id[String(lens["id"])] = lens
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
	if data.size() < 2:
		return
	# Header de 1 byte: 'B' compartido, 'L' ojo izquierdo, 'R' ojo derecho.
	var header := data[0]
	var jpg := data.slice(1)
	var img := Image.new()
	var err := img.load_jpg_from_buffer(jpg)
	if err != OK:
		return
	match header:
		HEADER_LEFT:
			if _texture_left == null:
				_texture_left = ImageTexture.create_from_image(img)
				texture_rect.texture = _texture_left
			else:
				_texture_left.update(img)
		HEADER_RIGHT:
			if _texture_right == null:
				_texture_right = ImageTexture.create_from_image(img)
				right_texture_rect.texture = _texture_right
			else:
				_texture_right.update(img)
		_:
			# HEADER_BOTH o desconocido -> mismo frame en ambos paneles.
			if _texture_left == null:
				_texture_left = ImageTexture.create_from_image(img)
				texture_rect.texture = _texture_left
			else:
				_texture_left.update(img)
			if _texture_right == null:
				_texture_right = ImageTexture.create_from_image(img)
				right_texture_rect.texture = _texture_right
			else:
				_texture_right.update(img)
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
		var nombre: String = String(lens.get("nombre", "")).strip_edges()
		var tipo: String = String(lens.get("tipo", "")).strip_edges()
		# Mostramos el nombre humano arriba; si la lente no tiene nombre,
		# caemos al tipo y como ultimo recurso al id.
		var titulo := nombre
		if titulo == "":
			titulo = tipo if tipo != "" else lens_id
		var subtitulo := tipo if (tipo != "" and tipo != titulo) else lens_id
		btn.text = "%s\n[%s]" % [titulo, subtitulo]
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
	# Al aplicar la lente, el visor la cargo con sus valores por defecto:
	# reconstruimos los sliders de ajuste en vivo desde esos defaults.
	_build_params_editor(lens_id)


# ====================================================================
# Ajuste en vivo de parametros (no afecta base de datos ni cache)
# ====================================================================
func _build_params_editor(lens_id: String) -> void:
	_editing_lens_id = lens_id
	_param_sliders.clear()
	_param_value_labels.clear()
	_param_defaults.clear()
	for child in params_list.get_children():
		child.queue_free()

	var lens: Dictionary = _lenses_by_id.get(lens_id, {})
	var params_def = lens.get("params", {})
	if not (params_def is Dictionary) or params_def.is_empty():
		reset_button.disabled = true
		var lbl := Label.new()
		lbl.text = "(esta lente no tiene parametros editables)"
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", Color(0.5, 0.55, 0.65))
		params_list.add_child(lbl)
		return

	var added := 0
	for key in params_def.keys():
		var entry = params_def[key]
		# Solo parametros numericos con default/min/max son editables.
		if not (entry is Dictionary) or not entry.has("default") \
				or not entry.has("min") or not entry.has("max"):
			continue
		var def_val := float(entry["default"])
		var min_val := float(entry["min"])
		var max_val := float(entry["max"])
		_param_defaults[key] = def_val
		_add_param_row(String(key), min_val, max_val, def_val)
		added += 1

	reset_button.disabled = added == 0
	if added == 0:
		var lbl := Label.new()
		lbl.text = "(esta lente no tiene parametros editables)"
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", Color(0.5, 0.55, 0.65))
		params_list.add_child(lbl)


func _add_param_row(param_name: String, min_val: float, max_val: float, value: float) -> void:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)

	var header := HBoxContainer.new()
	var name_lbl := Label.new()
	name_lbl.text = param_name
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color", Color(0.78, 0.82, 0.9))
	header.add_child(name_lbl)

	var value_lbl := Label.new()
	value_lbl.text = "%.3f" % value
	value_lbl.add_theme_font_size_override("font_size", 13)
	value_lbl.add_theme_color_override("font_color", Color(0.6, 0.85, 0.7))
	header.add_child(value_lbl)
	row.add_child(header)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = max((max_val - min_val) / 200.0, 0.001)
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(_on_param_slider_changed.bind(param_name))
	row.add_child(slider)

	params_list.add_child(row)
	_param_sliders[param_name] = slider
	_param_value_labels[param_name] = value_lbl


func _on_param_slider_changed(value: float, param_name: String) -> void:
	if _param_value_labels.has(param_name):
		_param_value_labels[param_name].text = "%.3f" % value
	_send_param_override(param_name, value)


## Devuelve a que ojos aplica un ajuste de la lente en edicion: el override
## sigue a la LENTE, no al selector "Aplicar a:". Si ambos ojos tienen la misma
## lente -> "both"; si solo uno la tiene (modo blend) -> ese ojo; si ninguno la
## tiene -> "" (no se envia nada).
func _eyes_for_editing_lens() -> String:
	var left_id: String = _vision_state.get("left", {}).get("lens_id", "")
	var right_id: String = _vision_state.get("right", {}).get("lens_id", "")
	var on_left := left_id == _editing_lens_id
	var on_right := right_id == _editing_lens_id
	if on_left and on_right:
		return "both"
	if on_left:
		return "left"
	if on_right:
		return "right"
	return ""


func _send_param_override(param_name: String, value: float) -> void:
	if _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var eye := _eyes_for_editing_lens()
	if eye == "":
		return
	var cmd := {
		"cmd": "override_params",
		"eye": eye,
		"params": {param_name: value},
	}
	_peer.send_text(JSON.stringify(cmd))


func _on_reset_params_pressed() -> void:
	if _editing_lens_id == "" or _param_defaults.is_empty():
		return
	# Reaplicar todos los defaults: actualiza sliders + manda override.
	# El reset sigue a la lente en edicion (mismos ojos que los ajustes).
	var eye := _eyes_for_editing_lens()
	var all_defaults: Dictionary = {}
	for key in _param_defaults.keys():
		var def_val: float = _param_defaults[key]
		if _param_sliders.has(key):
			# set_value_no_signal evita disparar un override por cada slider.
			_param_sliders[key].set_value_no_signal(def_val)
		if _param_value_labels.has(key):
			_param_value_labels[key].text = "%.3f" % def_val
		all_defaults[key] = def_val
	if eye != "" and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		var cmd := {
			"cmd": "override_params",
			"eye": eye,
			"params": all_defaults,
		}
		_peer.send_text(JSON.stringify(cmd))




func _update_state_label() -> void:
	var left_id: String = _vision_state.get("left", {}).get("lens_id", "?")
	var right_id: String = _vision_state.get("right", {}).get("lens_id", "?")
	var is_blend := left_id != right_id
	var blend := " (Blend)" if is_blend else ""
	state_label.text = "Estado actual:\n  L: %s\n  R: %s%s" % [left_id, right_id, blend]
	# Split del stream: si ambos ojos comparten lente -> panel unico.
	# Si hay blend -> dos paneles lado a lado con su lente arriba.
	if is_blend:
		right_eye_pane.visible = true
		left_eye_label.text = "OI Izquierdo — %s" % left_id
		right_eye_label.text = "OD Derecho — %s" % right_id
	else:
		right_eye_pane.visible = false
		left_eye_label.text = "Ambos ojos — %s" % left_id


func _update_status(text: String) -> void:
	if status_label != null:
		status_label.text = "%s | frames=%d | %.1f KB" % [
			text, _frames_received, _bytes_received / 1024.0,
		]
