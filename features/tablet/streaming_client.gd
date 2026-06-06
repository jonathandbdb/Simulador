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
@onready var scenario_list: HBoxContainer = $Margin/HBox/ControlPanel/VBox/ScenarioList
@onready var control_vbox: VBoxContainer = $Margin/HBox/ControlPanel/VBox

var _peer := WebSocketPeer.new()
# Texturas separadas por ojo (el visor manda streams independientes en
# modo blend). En modo "both" ambas referencian al mismo Image refresh.
var _texture_left: ImageTexture
var _texture_right: ImageTexture
var _frames_received: int = 0
var _bytes_received: int = 0

# Astigmatismo (canal independiente del catalogo de lentes). Controles propios
# en la tablet; se envia con el comando "set_astigmatism".
var _astig_enabled_check: CheckButton
var _astig_mag_slider: HSlider
var _astig_mag_label: Label
var _astig_angle_slider: HSlider
var _astig_angle_label: Label
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

# Escenarios disponibles (recibidos en hello.scenarios).
var _available_scenarios: Array = []
var _current_scenario_id: String = ""

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

	# Controles de astigmatismo (canal aparte del catalogo).
	_build_astigmatism_controls()


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
			_available_scenarios = parsed.get("scenarios", [])
			_current_scenario_id = String(parsed.get("scenario", ""))
			_rebuild_lens_list()
			_rebuild_scenario_list()
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
	# Recorremos en orden clinico (focos primero); cualquier param extra que no
	# este en PARAM_ORDER se agrega despues, respetando el orden del catalogo.
	var ordered_keys: Array = []
	for k in PARAM_ORDER:
		if params_def.has(k):
			ordered_keys.append(k)
	for k in params_def.keys():
		if not ordered_keys.has(k):
			ordered_keys.append(k)
	for key in ordered_keys:
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


# Metadata clinica por parametro:
#   label  -> texto principal del slider
#   hint   -> descripcion corta del efecto (tooltip debajo del slider)
#   unit   -> sufijo de la unidad ("m", "rayos", "%", "")
#   fmt    -> formato del numero (default "%.2f")
# Las claves siguen siendo las del catalogo/shader (no afecta protocolo).
const PARAM_META := {
	"foco_lejos_m": {
		"label": "Foco lejano",
		"hint": "Distancia donde el paciente ve nitido a lejos. 6 m ≈ infinito optico. 0 = desactivado.",
		"unit": "m", "fmt": "%.2f",
	},
	"foco_intermedio_m": {
		"label": "Foco intermedio",
		"hint": "Distancia del segundo plano nitido (PC, tablero del auto). 0 = sin foco intermedio.",
		"unit": "m", "fmt": "%.2f",
	},
	"foco_cerca_m": {
		"label": "Foco cercano",
		"hint": "Distancia de lectura nitida (libro, celular). Tipico 35-45 cm. 0 = sin foco cercano.",
		"unit": "m", "fmt": "%.2f",
	},
	"profundidad_foco_m": {
		"label": "Profundidad de foco",
		"hint": "Ancho de la zona nitida alrededor de cada foco. Bajo = pico estrecho (trifocal). Alto = plateau ancho (EDOF).",
		"unit": "m", "fmt": "%.2f",
	},
	"desenfoque_max": {
		"label": "Desenfoque maximo",
		"hint": "Cuanto se borronea fuera de toda zona de foco (0 = nunca borroso, 1 = maximo).",
		"unit": "", "fmt": "%.2f",
	},
	"halo_intensity": {
		"label": "Intensidad de halos",
		"hint": "Tamano e intensidad del halo difractivo alrededor de fuentes brillantes. Trifocal alto, monofocal casi nulo.",
		"unit": "", "fmt": "%.2f",
	},
	"halo_extra_rings": {
		"label": "Dilatacion pupilar (noche)",
		"hint": "Pupila mesopica/escotopica. Agranda el halo y agrega tinte azulado (efecto Purkinje). Subir en escena nocturna.",
		"unit": "", "fmt": "%.2f",
	},
	"contrast_loss": {
		"label": "Perdida de contraste",
		"hint": "Reduccion de sensibilidad al contraste (imagen mas lavada). Trifocal pierde mas que EDOF, EDOF mas que monofocal.",
		"unit": "", "fmt": "%.2f",
	},
	"destello_intensity": {
		"label": "Intensidad de starburst",
		"hint": "Rayos radiales desde fuentes brillantes (disfotopsia difractiva). 0 = sin destello.",
		"unit": "", "fmt": "%.2f",
	},
	"destello_rayos": {
		"label": "Cantidad de rayos",
		"hint": "Cantidad de spokes del starburst. Pacientes con trifocal reportan 8-12 rayos visibles.",
		"unit": "rayos", "fmt": "%.0f",
	},
}

# Orden clinico de presentacion: primero los focos, despues blur, despues
# disfotopsias (halo, starburst, contraste). Parametros del catalogo que no
# esten aca se agregan al final preservando el orden del catalogo.
const PARAM_ORDER := [
	"foco_lejos_m", "foco_intermedio_m", "foco_cerca_m",
	"profundidad_foco_m", "desenfoque_max",
	"halo_intensity", "halo_extra_rings",
	"destello_intensity", "destello_rayos",
	"contrast_loss",
]


func _param_label(param_name: String) -> String:
	var meta: Dictionary = PARAM_META.get(param_name, {})
	return meta.get("label", param_name)


func _param_hint(param_name: String) -> String:
	var meta: Dictionary = PARAM_META.get(param_name, {})
	return meta.get("hint", "")


func _format_param_value(param_name: String, value: float) -> String:
	var meta: Dictionary = PARAM_META.get(param_name, {})
	# Distancias en metros: 0 = foco desactivado.
	if meta.get("unit", "") == "m" and value <= 0.001:
		return "off"
	var fmt: String = meta.get("fmt", "%.2f")
	var unit: String = meta.get("unit", "")
	if unit == "":
		return fmt % value
	return ("%s %s" % [fmt % value, unit]).strip_edges()


func _add_param_row(param_name: String, min_val: float, max_val: float, value: float) -> void:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)

	var header := HBoxContainer.new()
	var name_lbl := Label.new()
	name_lbl.text = _param_label(param_name)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color", Color(0.78, 0.82, 0.9))
	# Tooltip clinico al mantener pulsado o pasar el cursor.
	var hint := _param_hint(param_name)
	if hint != "":
		name_lbl.tooltip_text = hint
	header.add_child(name_lbl)

	var value_lbl := Label.new()
	value_lbl.text = _format_param_value(param_name, value)
	value_lbl.add_theme_font_size_override("font_size", 13)
	value_lbl.add_theme_color_override("font_color", Color(0.6, 0.85, 0.7))
	header.add_child(value_lbl)
	row.add_child(header)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	# Para `destello_rayos` queremos pasos enteros; para el resto, ~200 pasos.
	if PARAM_META.get(param_name, {}).get("fmt", "") == "%.0f":
		slider.step = 1.0
	else:
		slider.step = max((max_val - min_val) / 200.0, 0.001)
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if hint != "":
		slider.tooltip_text = hint
	slider.value_changed.connect(_on_param_slider_changed.bind(param_name))
	row.add_child(slider)

	# Sublabel descriptivo (tamano chico, color tenue) para que el doctor no
	# tenga que esperar el tooltip: el sentido clinico del parametro queda a
	# la vista debajo del slider.
	if hint != "":
		var hint_lbl := Label.new()
		hint_lbl.text = hint
		hint_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint_lbl.add_theme_font_size_override("font_size", 11)
		hint_lbl.add_theme_color_override("font_color", Color(0.55, 0.6, 0.7))
		row.add_child(hint_lbl)

	params_list.add_child(row)
	_param_sliders[param_name] = slider
	_param_value_labels[param_name] = value_lbl


func _on_param_slider_changed(value: float, param_name: String) -> void:
	if _param_value_labels.has(param_name):
		_param_value_labels[param_name].text = _format_param_value(param_name, value)
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
			_param_value_labels[key].text = _format_param_value(key, def_val)
		all_defaults[key] = def_val
	if eye != "" and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		var cmd := {
			"cmd": "override_params",
			"eye": eye,
			"params": all_defaults,
		}
		_peer.send_text(JSON.stringify(cmd))



# ====================================================================
# Cambio de escena
# ====================================================================
func _rebuild_scenario_list() -> void:
	for child in scenario_list.get_children():
		child.queue_free()
	for scenario_id in _available_scenarios:
		var sid: String = String(scenario_id)
		var btn := Button.new()
		btn.text = _scenario_label(sid)
		btn.custom_minimum_size = Vector2(90, 44)
		btn.toggle_mode = true
		btn.button_pressed = (sid == _current_scenario_id)
		btn.pressed.connect(_on_scenario_button_pressed.bind(sid))
		scenario_list.add_child(btn)


func _scenario_label(sid: String) -> String:
	match sid:
		"consultorio": return "Consultorio"
		"ruta_noche":  return "Ruta Noche"
		_:             return sid.capitalize()


func _on_scenario_button_pressed(scenario_id: String) -> void:
	if _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		_update_status("no hay conexion para enviar comando")
		return
	_current_scenario_id = scenario_id
	# Actualizar apariencia de botones (toggle visual).
	for child in scenario_list.get_children():
		if child is Button:
			child.button_pressed = (_scenario_label(scenario_id) == child.text or scenario_id == _btn_sid(child.text))
	var cmd := {"cmd": "load_scenario", "scenario": scenario_id}
	_peer.send_text(JSON.stringify(cmd))
	_update_state_label()


func _btn_sid(label_text: String) -> String:
	match label_text:
		"Consultorio": return "consultorio"
		"Ruta Noche":  return "ruta_noche"
		_:             return label_text.to_lower()


func _update_state_label() -> void:
	var left_id: String = _vision_state.get("left", {}).get("lens_id", "?")
	var right_id: String = _vision_state.get("right", {}).get("lens_id", "?")
	var is_blend := left_id != right_id
	var blend := " (Blend)" if is_blend else ""
	state_label.text = "Estado actual:\n  Escena: %s\n  L: %s\n  R: %s%s" % [
		_scenario_label(_current_scenario_id) if _current_scenario_id != "" else "-",
		left_id, right_id, blend]
	# Split del stream: si ambos ojos comparten lente -> panel unico.
	# Si hay blend -> dos paneles lado a lado con su lente arriba.
	if is_blend:
		right_eye_pane.visible = true
		left_eye_label.text = "OI Izquierdo — %s" % left_id
		right_eye_label.text = "OD Derecho — %s" % right_id
	else:
		right_eye_pane.visible = false
		left_eye_label.text = "Ambos ojos — %s" % left_id


# ====================================================================
# Astigmatismo (set_astigmatism) — canal independiente del catalogo
# ====================================================================
## Construye la seccion de astigmatismo al final del panel de control. Es un
## defecto refractivo (no una propiedad de la IOL), por eso vive aparte del
## catalogo de lentes. Aplica al ojo elegido en el selector "Aplicar a:".
func _build_astigmatism_controls() -> void:
	if control_vbox == null:
		return

	var sep := HSeparator.new()
	control_vbox.add_child(sep)

	var title := Label.new()
	title.text = "Astigmatismo"
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", Color(0.82, 0.86, 0.95))
	control_vbox.add_child(title)

	# Activar / desactivar.
	_astig_enabled_check = CheckButton.new()
	_astig_enabled_check.text = "Activar"
	_astig_enabled_check.tooltip_text = "Estira las fuentes brillantes en una linea (streak) sobre el eje elegido. Simula astigmatismo no corregido."
	_astig_enabled_check.toggled.connect(func(_p: bool) -> void: _send_astigmatism())
	control_vbox.add_child(_astig_enabled_check)

	# Magnitud (largo del streak en px).
	var mag_header := HBoxContainer.new()
	var mag_name := Label.new()
	mag_name.text = "Magnitud"
	mag_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mag_name.add_theme_font_size_override("font_size", 13)
	mag_name.add_theme_color_override("font_color", Color(0.78, 0.82, 0.9))
	mag_header.add_child(mag_name)
	_astig_mag_label = Label.new()
	_astig_mag_label.add_theme_font_size_override("font_size", 13)
	_astig_mag_label.add_theme_color_override("font_color", Color(0.6, 0.85, 0.7))
	mag_header.add_child(_astig_mag_label)
	control_vbox.add_child(mag_header)

	_astig_mag_slider = HSlider.new()
	_astig_mag_slider.min_value = 0.0
	_astig_mag_slider.max_value = 50.0
	_astig_mag_slider.step = 1.0
	_astig_mag_slider.value = 25.0
	_astig_mag_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_astig_mag_slider.value_changed.connect(func(_v: float) -> void: _on_astig_changed())
	control_vbox.add_child(_astig_mag_slider)

	# Angulo del eje (grados; se convierte a radianes al enviar).
	var ang_header := HBoxContainer.new()
	var ang_name := Label.new()
	ang_name.text = "Eje"
	ang_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ang_name.add_theme_font_size_override("font_size", 13)
	ang_name.add_theme_color_override("font_color", Color(0.78, 0.82, 0.9))
	ang_header.add_child(ang_name)
	_astig_angle_label = Label.new()
	_astig_angle_label.add_theme_font_size_override("font_size", 13)
	_astig_angle_label.add_theme_color_override("font_color", Color(0.6, 0.85, 0.7))
	ang_header.add_child(_astig_angle_label)
	control_vbox.add_child(ang_header)

	_astig_angle_slider = HSlider.new()
	_astig_angle_slider.min_value = 0.0
	_astig_angle_slider.max_value = 180.0
	_astig_angle_slider.step = 1.0
	_astig_angle_slider.value = 0.0
	_astig_angle_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_astig_angle_slider.value_changed.connect(func(_v: float) -> void: _on_astig_changed())
	control_vbox.add_child(_astig_angle_slider)

	_update_astig_labels()


func _on_astig_changed() -> void:
	_update_astig_labels()
	# Solo reenviar en vivo si esta activo (mover sliders apagado no hace nada).
	if _astig_enabled_check != null and _astig_enabled_check.button_pressed:
		_send_astigmatism()


func _update_astig_labels() -> void:
	if _astig_mag_label != null and _astig_mag_slider != null:
		_astig_mag_label.text = "%.0f px" % _astig_mag_slider.value
	if _astig_angle_label != null and _astig_angle_slider != null:
		_astig_angle_label.text = "%.0f°" % _astig_angle_slider.value


func _send_astigmatism() -> void:
	if _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		_update_status("no hay conexion para enviar comando")
		return
	if _astig_enabled_check == null:
		return
	var eye_map := {0: "both", 1: "left", 2: "right"}
	var eye: String = eye_map.get(eye_option.selected, "both")
	var cmd := {
		"cmd": "set_astigmatism",
		"eye": eye,
		"enabled": _astig_enabled_check.button_pressed,
		"magnitude": _astig_mag_slider.value,
		"angle": deg_to_rad(_astig_angle_slider.value),
	}
	_peer.send_text(JSON.stringify(cmd))


func _update_status(text: String) -> void:
	if status_label != null:
		status_label.text = "%s | frames=%d | %.1f KB" % [
			text, _frames_received, _bytes_received / 1024.0,
		]
