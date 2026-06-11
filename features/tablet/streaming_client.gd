extends Control
## TabletClient — control de consultorio para el oftalmologo.
##
## Cliente de control + stream para la tablet (o la PC durante desarrollo).
## Se conecta por WebSocket al visor (puerto 9090) y:
##   1. Recibe un mensaje "hello" con el catalogo de lentes y el estado
##      actual de vision por ojo. Con eso arma la UI dinamicamente.
##   2. Muestra el stream binario (JPGs) en uno o dos paneles (modo blend).
##   3. Envia comandos cuando el doctor opera la UI.
##
## La UI tiene dos estados: ConnectScreen (descubrimiento/conexion) y Main
## (consulta). Tema claro/oscuro generado por TabletTheme; preferencia
## persistida best-effort en user://ui_prefs.cfg.
##
## Protocolo (texto JSON en ambos sentidos, binario solo visor->tablet):
##   visor -> tablet:
##     { "type": "hello",
##       "catalog_version": "1.0.0",
##       "lenses": [ { "id": "monofocal", ... }, ... ],
##       "vision_state": { "left": {...}, "right": {...} },
##       "scenario": "consultorio", "scenarios": [...] }
##   tablet -> visor:
##     { "cmd": "apply_lens" | "override_params" | "set_astigmatism"
##             | "load_scenario", ... }

const DEFAULT_HOST := "192.168.2.30"
const DEFAULT_PORT := 9090
const PREFS_PATH := "user://ui_prefs.cfg"

const LENS_CARD_SCENE := preload("res://features/tablet/ui/lens_card.tscn")
const PARAM_ROW_SCENE := preload("res://features/tablet/ui/param_row.tscn")
const ICON_WIFI := preload("res://assets/icons/ui/wifi.svg")
const ICON_SUN := preload("res://assets/icons/ui/sun.svg")
const ICON_MOON := preload("res://assets/icons/ui/moon.svg")

const HEADER_BOTH := 0x42  # 'B'
const HEADER_LEFT := 0x4C  # 'L'
const HEADER_RIGHT := 0x52 # 'R'

# --- Pantalla de conexion ---
@onready var connect_screen: CenterContainer = $ConnectScreen
@onready var logo_icon: TextureRect = $ConnectScreen/VBox/LogoIcon
@onready var discovered_list: VBoxContainer = $ConnectScreen/VBox/DiscoveredList
@onready var connect_status_label: Label = $ConnectScreen/VBox/ConnectStatusLabel
@onready var advanced_toggle: Button = $ConnectScreen/VBox/AdvancedToggle
@onready var advanced_box: HBoxContainer = $ConnectScreen/VBox/AdvancedBox
@onready var host_edit: LineEdit = $ConnectScreen/VBox/AdvancedBox/HostEdit
@onready var connect_button: Button = $ConnectScreen/VBox/AdvancedBox/ConnectButton

# --- Pantalla principal: header ---
@onready var main_screen: VBoxContainer = $Main
@onready var header_icon: TextureRect = $Main/HeaderBar/HBox/HeaderIcon
@onready var scenario_list: HBoxContainer = $Main/HeaderBar/HBox/ScenarioList
@onready var theme_toggle: Button = $Main/HeaderBar/HBox/ThemeToggle
@onready var status_dot: Label = $Main/HeaderBar/HBox/StatusBadge/HBox/StatusDot
@onready var status_text: Label = $Main/HeaderBar/HBox/StatusBadge/HBox/StatusText
@onready var disconnect_button: Button = $Main/HeaderBar/HBox/DisconnectButton

# --- Pantalla principal: stream ---
@onready var texture_rect: TextureRect = $Main/BodyMargin/Body/StreamPanel/EyesContainer/LeftEyePane/TextureRect
@onready var right_texture_rect: TextureRect = $Main/BodyMargin/Body/StreamPanel/EyesContainer/RightEyePane/TextureRect
@onready var left_eye_label: Label = $Main/BodyMargin/Body/StreamPanel/EyesContainer/LeftEyePane/LeftEyeLabel
@onready var right_eye_label: Label = $Main/BodyMargin/Body/StreamPanel/EyesContainer/RightEyePane/RightEyeLabel
@onready var right_eye_pane: VBoxContainer = $Main/BodyMargin/Body/StreamPanel/EyesContainer/RightEyePane

# --- Pantalla principal: panel de control ---
@onready var eye_both: Button = $Main/BodyMargin/Body/ControlScroll/ControlVBox/EyeCard/VBox/EyeSelector/EyeBoth
@onready var eye_od: Button = $Main/BodyMargin/Body/ControlScroll/ControlVBox/EyeCard/VBox/EyeSelector/EyeOD
@onready var eye_oi: Button = $Main/BodyMargin/Body/ControlScroll/ControlVBox/EyeCard/VBox/EyeSelector/EyeOI
@onready var lens_list: VBoxContainer = $Main/BodyMargin/Body/ControlScroll/ControlVBox/LensesCard/VBox/LensList
@onready var params_toggle: Button = $Main/BodyMargin/Body/ControlScroll/ControlVBox/ParamsCard/VBox/Header/ParamsToggle
@onready var params_chevron: TextureRect = $Main/BodyMargin/Body/ControlScroll/ControlVBox/ParamsCard/VBox/Header/ParamsChevron
@onready var params_content: VBoxContainer = $Main/BodyMargin/Body/ControlScroll/ControlVBox/ParamsCard/VBox/ParamsContent
@onready var editing_lens_label: Label = $Main/BodyMargin/Body/ControlScroll/ControlVBox/ParamsCard/VBox/ParamsContent/EditingLensLabel
@onready var params_list: VBoxContainer = $Main/BodyMargin/Body/ControlScroll/ControlVBox/ParamsCard/VBox/ParamsContent/ParamsList
@onready var reset_button: Button = $Main/BodyMargin/Body/ControlScroll/ControlVBox/ParamsCard/VBox/ParamsContent/ResetButton
@onready var astig_toggle: Button = $Main/BodyMargin/Body/ControlScroll/ControlVBox/AstigCard/VBox/Header/AstigToggle
@onready var astig_chevron: TextureRect = $Main/BodyMargin/Body/ControlScroll/ControlVBox/AstigCard/VBox/Header/AstigChevron
@onready var astig_content: VBoxContainer = $Main/BodyMargin/Body/ControlScroll/ControlVBox/AstigCard/VBox/AstigContent
@onready var astig_enabled: CheckButton = $Main/BodyMargin/Body/ControlScroll/ControlVBox/AstigCard/VBox/AstigContent/AstigEnabled
@onready var astig_mag_value: Label = $Main/BodyMargin/Body/ControlScroll/ControlVBox/AstigCard/VBox/AstigContent/MagHeader/MagValue
@onready var astig_mag_slider: HSlider = $Main/BodyMargin/Body/ControlScroll/ControlVBox/AstigCard/VBox/AstigContent/MagSlider
@onready var astig_angle_value: Label = $Main/BodyMargin/Body/ControlScroll/ControlVBox/AstigCard/VBox/AstigContent/AngleHeader/AngleValue
@onready var astig_angle_slider: HSlider = $Main/BodyMargin/Body/ControlScroll/ControlVBox/AstigCard/VBox/AstigContent/AngleSlider

# --- Footer ---
@onready var footer_label: Label = $Main/Footer/FooterLabel

var _peer := WebSocketPeer.new()
# Texturas separadas por ojo (el visor manda streams independientes en
# modo blend). En modo "both" ambas referencian al mismo Image refresh.
var _texture_left: ImageTexture
var _texture_right: ImageTexture
var _frames_received: int = 0
var _bytes_received: int = 0
var _frames_last_tick: int = 0

var _connecting: bool = false
var _session_active: bool = false
var _manual_disconnect: bool = false
var _current_host: String = ""
var _catalog_lenses: Array = []
var _lenses_by_id: Dictionary = {}
var _vision_state: Dictionary = {}
var _lens_cards: Dictionary = {}  # lens_id -> LensCard

# Ajuste en vivo: lente cuyos parametros se estan editando y sus filas.
var _editing_lens_id: String = ""
var _param_rows: Dictionary = {}  # param_name -> ParamRow
var _param_defaults: Dictionary = {}  # param_name -> float (default de la lente)

# Escenarios disponibles (recibidos en hello.scenarios).
var _available_scenarios: Array = []
var _current_scenario_id: String = ""

# Tema activo (claro/oscuro) y su paleta, para los colores aplicados por codigo.
var _is_dark: bool = true
var _palette: Dictionary = TabletTheme.DARK


func _ready() -> void:
	_apply_theme(_load_theme_pref())

	# CLI override: --visor-host <ip>
	var args := OS.get_cmdline_args()
	var host := DEFAULT_HOST
	for i in range(args.size()):
		if args[i] == "--visor-host" and i + 1 < args.size():
			host = args[i + 1]
	host_edit.text = host

	# Conexion.
	connect_button.pressed.connect(_on_connect_pressed)
	host_edit.text_submitted.connect(func(_t: String) -> void: _on_connect_pressed())
	advanced_toggle.toggled.connect(func(on: bool) -> void: advanced_box.visible = on)
	disconnect_button.pressed.connect(_on_disconnect_pressed)

	# Tema claro/oscuro.
	theme_toggle.pressed.connect(_on_theme_toggle_pressed)

	# Selector de ojo: los SegmentButton comparten ButtonGroup (exclusivos).

	# Colapsables.
	params_toggle.toggled.connect(func(on: bool) -> void:
		params_content.visible = on
		params_chevron.flip_v = on)
	astig_toggle.toggled.connect(func(on: bool) -> void:
		astig_content.visible = on
		astig_chevron.flip_v = on)

	# Ajuste en vivo.
	reset_button.pressed.connect(_on_reset_params_pressed)

	# Astigmatismo (canal aparte del catalogo de lentes).
	astig_enabled.toggled.connect(func(_p: bool) -> void: _send_astigmatism())
	astig_mag_slider.value_changed.connect(func(_v: float) -> void: _on_astig_changed())
	astig_angle_slider.value_changed.connect(func(_v: float) -> void: _on_astig_changed())
	_update_astig_labels()

	# Discovery (UDP broadcast :9091): el autoload DiscoveryBeacon (modo
	# listener con feature "tablet") cachea los hosts vistos.
	DiscoveryBeacon.visor_discovered.connect(_on_visor_discovered)
	_refresh_discovered()
	var refresh_timer := Timer.new()
	refresh_timer.wait_time = 2.0
	refresh_timer.autostart = true
	refresh_timer.timeout.connect(_refresh_discovered)
	add_child(refresh_timer)

	# Footer: contadores discretos actualizados 1 vez por segundo.
	var footer_timer := Timer.new()
	footer_timer.wait_time = 1.0
	footer_timer.autostart = true
	footer_timer.timeout.connect(_update_footer)
	add_child(footer_timer)

	_show_connect_screen("Buscando visores en la red...")


# ====================================================================
# Tema claro / oscuro
# ====================================================================
func _apply_theme(dark: bool) -> void:
	_is_dark = dark
	_palette = TabletTheme.palette_for(dark)
	theme = TabletTheme.build(_palette)
	# El icono del toggle muestra el modo al que se va a cambiar.
	theme_toggle.icon = ICON_SUN if dark else ICON_MOON
	logo_icon.self_modulate = _palette.accent
	header_icon.self_modulate = _palette.accent
	params_chevron.self_modulate = _palette.text_secondary
	astig_chevron.self_modulate = _palette.text_secondary
	if _session_active:
		_set_badge(_palette.ok, _connected_badge_text())


func _connected_badge_text() -> String:
	if _current_host == "":
		return "Conectado"
	return "Conectado · %s" % _current_host


func _on_theme_toggle_pressed() -> void:
	_apply_theme(not _is_dark)
	_save_theme_pref()


## Preferencia guardada -> modo del sistema -> oscuro (fallback).
func _load_theme_pref() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(PREFS_PATH) == OK and cfg.has_section_key("ui", "dark_mode"):
		return bool(cfg.get_value("ui", "dark_mode", true))
	if DisplayServer.is_dark_mode_supported():
		return DisplayServer.is_dark_mode()
	return true


func _save_theme_pref() -> void:
	# Best-effort: si user:// no es escribible (scoped storage), no rompe.
	var cfg := ConfigFile.new()
	cfg.load(PREFS_PATH)
	cfg.set_value("ui", "dark_mode", _is_dark)
	cfg.save(PREFS_PATH)


# ====================================================================
# Pantallas
# ====================================================================
func _show_connect_screen(message: String, is_error: bool = false) -> void:
	connect_screen.visible = true
	main_screen.visible = false
	_set_connect_status(message, is_error)


func _show_main_screen() -> void:
	connect_screen.visible = false
	main_screen.visible = true
	_set_badge(_palette.ok, _connected_badge_text())


func _set_connect_status(text: String, is_error: bool = false) -> void:
	connect_status_label.text = text
	if is_error:
		connect_status_label.add_theme_color_override("font_color", _palette.error)
	else:
		connect_status_label.remove_theme_color_override("font_color")


func _set_badge(color: Color, text: String) -> void:
	status_dot.add_theme_color_override("font_color", color)
	status_text.text = text


# ====================================================================
# Discovery + conexion
# ====================================================================
func _on_visor_discovered(_host: String, _payload: Dictionary) -> void:
	# El cache de hosts esta en el autoload; aca solo pedimos refresco UI.
	_refresh_discovered()


func _refresh_discovered() -> void:
	if not connect_screen.visible:
		return
	var hosts: Array = DiscoveryBeacon.get_active_hosts(6.0)
	# Reconstruir cards (lista corta, costo bajo).
	for child in discovered_list.get_children():
		child.queue_free()
	if hosts.is_empty():
		if not _connecting:
			_set_connect_status("Buscando visores en la red...")
		return
	for host in hosts:
		var btn := Button.new()
		btn.text = "Visor Quest  ·  %s" % host
		btn.icon = ICON_WIFI
		btn.expand_icon = false
		btn.add_theme_constant_override("icon_max_width", 24)
		btn.add_theme_constant_override("h_separation", 12)
		btn.custom_minimum_size = Vector2(0, 64)
		btn.pressed.connect(_on_discovered_pressed.bind(String(host)))
		discovered_list.add_child(btn)
	if not _connecting:
		_set_connect_status("Tocá un visor para conectarte.")


func _on_discovered_pressed(host: String) -> void:
	host_edit.text = host
	_on_connect_pressed()


func _on_connect_pressed() -> void:
	var host := host_edit.text.strip_edges()
	if host == "":
		host = DEFAULT_HOST
	_current_host = host
	var url := "ws://%s:%d" % [host, DEFAULT_PORT]
	_set_connect_status("Conectando a %s..." % host)
	var err := _peer.connect_to_url(url)
	if err != OK:
		_set_connect_status("No se pudo iniciar la conexión (error %d)." % err, true)
		return
	_connecting = true


func _on_disconnect_pressed() -> void:
	_manual_disconnect = true
	_peer.close()


func _process(_delta: float) -> void:
	if not _connecting and not _session_active \
			and _peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		return
	_peer.poll()
	var state := _peer.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if _connecting:
			_connecting = false
			_set_connect_status("Conectado. Esperando catálogo del visor...")
		while _peer.get_available_packet_count() > 0:
			var data := _peer.get_packet()
			if _peer.was_string_packet():
				_on_text_received(data.get_string_from_utf8())
			else:
				_on_frame_received(data)
	elif state == WebSocketPeer.STATE_CLOSED:
		if _connecting:
			_connecting = false
			_set_connect_status("No se pudo conectar con %s (código %d)." % [
				_current_host, _peer.get_close_code()], true)
		elif _session_active:
			# Caida post-conexion (visor apagado, wifi, etc.).
			_session_active = false
			if _manual_disconnect:
				_show_connect_screen("Sesión finalizada.")
			else:
				_show_connect_screen("Se perdió la conexión con el visor.", true)
		_manual_disconnect = false


# ====================================================================
# Protocolo: mensajes de texto + frames binarios
# ====================================================================
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
			_refresh_vision_ui()
			_session_active = true
			_show_main_screen()
		"vision_state":
			# Estado real del visor (incluye overrides persistidos): refresca
			# chips y sincroniza los sliders del ajuste fino sin re-emitir.
			_vision_state = parsed.get("vision_state", {})
			_refresh_vision_ui()
			_sync_param_rows_from_state()
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


# ====================================================================
# Lentes
# ====================================================================
## Nombre humano de una lente para mostrar en la UI (nunca IDs crudos).
func _lens_display_name(lens_id: String) -> String:
	var lens: Dictionary = _lenses_by_id.get(lens_id, {})
	var nombre := String(lens.get("nombre", "")).strip_edges()
	if nombre != "":
		return nombre
	var tipo := String(lens.get("tipo", "")).strip_edges()
	return tipo if tipo != "" else lens_id


func _rebuild_lens_list() -> void:
	for child in lens_list.get_children():
		child.queue_free()
	_lens_cards.clear()
	for lens_dict in _catalog_lenses:
		if not (lens_dict is Dictionary):
			continue
		var card := LENS_CARD_SCENE.instantiate()
		lens_list.add_child(card)
		card.setup(lens_dict)
		card.lens_selected.connect(_on_lens_selected)
		_lens_cards[card.lens_id] = card


## Eje seleccionado en el segmento "Ojo a tratar" (OD = right, OI = left).
func _selected_eye() -> String:
	if eye_od.button_pressed:
		return "right"
	if eye_oi.button_pressed:
		return "left"
	return "both"


func _on_lens_selected(lens_id: String) -> void:
	var eye := _selected_eye()
	if _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		_set_badge(_palette.warn, "Sin conexión")
		return
	var cmd := {"cmd": "apply_lens", "lens_id": lens_id, "eye": eye}
	_peer.send_text(JSON.stringify(cmd))
	# Actualizacion optimista del estado local.
	if eye == "left" or eye == "both":
		_vision_state["left"] = {"lens_id": lens_id}
	if eye == "right" or eye == "both":
		_vision_state["right"] = {"lens_id": lens_id}
	_refresh_vision_ui()
	# Al aplicar la lente, el visor la cargo con sus valores por defecto:
	# reconstruimos los sliders de ajuste en vivo desde esos defaults.
	_build_params_editor(lens_id)


## Refresca todo lo que depende del estado de vision: chips OD/OI de las
## cards, resaltado, y los rotulos sobre el stream (split en modo blend).
func _refresh_vision_ui() -> void:
	var left_id: String = _vision_state.get("left", {}).get("lens_id", "")
	var right_id: String = _vision_state.get("right", {}).get("lens_id", "")
	var is_blend := left_id != right_id

	for lens_id in _lens_cards.keys():
		_lens_cards[lens_id].set_eye_state(lens_id == right_id, lens_id == left_id)

	# Split del stream: si ambos ojos comparten lente -> panel unico.
	if is_blend:
		right_eye_pane.visible = true
		left_eye_label.text = "OI · %s" % _lens_display_name(left_id)
		right_eye_label.text = "OD · %s" % _lens_display_name(right_id)
	else:
		right_eye_pane.visible = false
		if left_id == "":
			left_eye_label.text = "Ambos ojos"
		else:
			left_eye_label.text = "Ambos ojos · %s" % _lens_display_name(left_id)


# ====================================================================
# Ajuste en vivo de parametros (no afecta base de datos ni cache)
# ====================================================================
func _build_params_editor(lens_id: String) -> void:
	_editing_lens_id = lens_id
	_param_rows.clear()
	_param_defaults.clear()
	for child in params_list.get_children():
		child.queue_free()

	params_toggle.text = "Ajuste fino · %s" % _lens_display_name(lens_id)

	var lens: Dictionary = _lenses_by_id.get(lens_id, {})
	var params_def = lens.get("params", {})
	if not (params_def is Dictionary) or params_def.is_empty():
		reset_button.disabled = true
		editing_lens_label.text = "Esta lente no tiene parámetros editables."
		return

	# Recorremos en orden clinico (focos primero); cualquier param extra que
	# no este en ParamMeta.ORDER se agrega despues, en orden del catalogo.
	var ordered_keys: Array = []
	for k in ParamMeta.ORDER:
		if params_def.has(k):
			ordered_keys.append(k)
	for k in params_def.keys():
		if not ordered_keys.has(k):
			ordered_keys.append(k)

	var added := 0
	for key in ordered_keys:
		var entry = params_def[key]
		# Solo parametros numericos con default/min/max son editables.
		if not (entry is Dictionary) or not entry.has("default") \
				or not entry.has("min") or not entry.has("max"):
			continue
		var def_val := float(entry["default"])
		_param_defaults[key] = def_val
		var row := PARAM_ROW_SCENE.instantiate()
		params_list.add_child(row)
		# Valor inicial: el estado REAL del visor si esta lente esta puesta
		# (incluye los overrides persistidos), no el default del catalogo.
		row.setup(String(key), float(entry["min"]), float(entry["max"]),
				_current_param_value(String(key), def_val))
		row.param_changed.connect(_on_param_changed)
		_param_rows[key] = row
		added += 1

	reset_button.disabled = added == 0
	if added == 0:
		editing_lens_label.text = "Esta lente no tiene parámetros editables."
	else:
		editing_lens_label.text = "Los ajustes se aplican al ojo que tiene esta lente."


## Valor efectivo de un parametro para la lente en edicion segun el estado del
## visor (el ojo que la tiene puesta); fallback al default del catalogo.
func _current_param_value(key: String, def_val: float) -> float:
	for eye in ["left", "right"]:
		var state: Dictionary = _vision_state.get(eye, {})
		if state.get("lens_id", "") == _editing_lens_id and state.has(key):
			return float(state[key])
	return def_val


## Sincroniza los sliders existentes con el estado recibido del visor, sin
## emitir param_changed (no re-enviar lo que el visor acaba de confirmar).
func _sync_param_rows_from_state() -> void:
	for key in _param_rows.keys():
		var v := _current_param_value(String(key), _param_defaults.get(key, 0.0))
		_param_rows[key].set_value_silent(v)


func _on_param_changed(param_name: String, value: float) -> void:
	_send_param_override(param_name, value)


## Devuelve a que ojos aplica un ajuste de la lente en edicion: el override
## sigue a la LENTE, no al selector "Ojo a tratar". Si ambos ojos tienen la
## misma lente -> "both"; si solo uno la tiene (modo blend) -> ese ojo; si
## ninguno la tiene -> "" (no se envia nada).
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
	# Reaplicar todos los defaults: actualiza filas + manda un solo override.
	# El reset sigue a la lente en edicion (mismos ojos que los ajustes).
	var eye := _eyes_for_editing_lens()
	var all_defaults: Dictionary = {}
	for key in _param_defaults.keys():
		var def_val: float = _param_defaults[key]
		if _param_rows.has(key):
			_param_rows[key].set_value_silent(def_val)
		all_defaults[key] = def_val
	if eye != "" and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		var cmd := {
			"cmd": "override_params",
			"eye": eye,
			"params": all_defaults,
		}
		_peer.send_text(JSON.stringify(cmd))


# ====================================================================
# Cambio de escenario
# ====================================================================
func _rebuild_scenario_list() -> void:
	for child in scenario_list.get_children():
		child.queue_free()
	for scenario_id in _available_scenarios:
		var sid := String(scenario_id)
		var btn := Button.new()
		btn.text = _scenario_label(sid)
		btn.theme_type_variation = &"SegmentButton"
		btn.custom_minimum_size = Vector2(120, 48)
		btn.toggle_mode = true
		btn.set_pressed_no_signal(sid == _current_scenario_id)
		btn.set_meta("scenario_id", sid)
		btn.pressed.connect(_on_scenario_button_pressed.bind(sid))
		scenario_list.add_child(btn)


func _scenario_label(sid: String) -> String:
	match sid:
		"consultorio": return "Consultorio"
		"ruta_noche":  return "Ruta nocturna"
		_:             return sid.capitalize()


func _on_scenario_button_pressed(scenario_id: String) -> void:
	if _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		_set_badge(_palette.warn, "Sin conexión")
		return
	_current_scenario_id = scenario_id
	# Toggle visual exclusivo: la identidad vive en metadata, no en el texto.
	for child in scenario_list.get_children():
		if child is Button:
			child.set_pressed_no_signal(
					String(child.get_meta("scenario_id", "")) == scenario_id)
	var cmd := {"cmd": "load_scenario", "scenario": scenario_id}
	_peer.send_text(JSON.stringify(cmd))


# ====================================================================
# Astigmatismo (set_astigmatism) — canal independiente del catalogo
# ====================================================================
func _on_astig_changed() -> void:
	_update_astig_labels()
	# Solo reenviar en vivo si esta activo (mover sliders apagado no hace nada).
	if astig_enabled.button_pressed:
		_send_astigmatism()


func _update_astig_labels() -> void:
	astig_mag_value.text = "%.0f px" % astig_mag_slider.value
	astig_angle_value.text = "%.0f°" % astig_angle_slider.value


func _send_astigmatism() -> void:
	if _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		_set_badge(_palette.warn, "Sin conexión")
		return
	var cmd := {
		"cmd": "set_astigmatism",
		"eye": _selected_eye(),
		"enabled": astig_enabled.button_pressed,
		"magnitude": astig_mag_slider.value,
		"angle": deg_to_rad(astig_angle_slider.value),
	}
	_peer.send_text(JSON.stringify(cmd))


# ====================================================================
# Footer (contadores discretos, 1 Hz)
# ====================================================================
func _update_footer() -> void:
	if not _session_active:
		footer_label.text = ""
		return
	var fps := _frames_received - _frames_last_tick
	_frames_last_tick = _frames_received
	footer_label.text = "%d fps · %.1f MB recibidos" % [
		fps, _bytes_received / 1048576.0,
	]
