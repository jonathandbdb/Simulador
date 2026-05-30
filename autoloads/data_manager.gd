extends Node
## DataManager (Autoload Singleton) — Sprint 4
##
## Responsabilidades:
##  1. Cargar catalogo de lentes al arrancar:
##     a) Intenta user://lentes.json (cache de ultima sync con backend).
##     b) Si no existe o esta corrupto, fallback a res://defaults/lentes.json.
##     c) En background, intenta GET /api/lenses al backend; si trae una version
##        nueva, sobrescribe user://lentes.json y emite catalog_synced.
##  2. Mantener el estado binocular: current_vision_state = {left:{}, right:{}}.
##  3. Exponer senales para UI/HUD: catalog_loaded, catalog_synced_with_backend,
##     catalog_sync_failed.

# Backend hardcodeado temporalmente (LAN de desarrollo).
# TODO: volver al resolver runtime cuando se valide conectividad desde Quest.
# IMPORTANTE: esta IP debe coincidir con la del PC que corre el backend (docker).
# Si cambias de red/router, actualiza esta IP (ver 'ipconfig' del PC).
const BACKEND_URL := "http://192.168.10.44:8080"
const CATALOG_ENDPOINT := "/api/lenses"
const SYNC_TIMEOUT_SECONDS := 5.0

const DEFAULT_CATALOG_PATH := "res://defaults/lentes.json"
const USER_CATALOG_PATH := "user://lentes.json"

# ====================================================================
# Senales
# ====================================================================
## Emitida cuando se carga un catalogo (de cualquier fuente).
## source: "cache" | "defaults" | "backend".
signal catalog_loaded(version: String, source: String, lens_count: int)
## Emitida si la sync con el backend tuvo exito (catalogo actualizado o no).
signal catalog_synced_with_backend(version: String)
## Emitida si la sync fallo (offline, 5xx, timeout). El simulador sigue
## funcionando con cache o defaults.
signal catalog_sync_failed(reason: String)
## Emitida cuando cambia el estado de vision de un ojo.
signal vision_state_changed(eye: String, params: Dictionary)

# ====================================================================
# Estado
# ====================================================================
var catalog: Dictionary = {}
var catalog_source: String = ""  # "cache" | "defaults" | "backend"
var last_sync_time: float = 0.0  # Time.get_unix_time_from_system() al ultimo sync OK
var current_vision_state: Dictionary = {
	"left":  {},
	"right": {},
}
var blend_mode_enabled: bool = false

var _http: HTTPRequest


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = SYNC_TIMEOUT_SECONDS
	_http.use_threads = true
	_http.request_completed.connect(_on_sync_completed)
	add_child(_http)

	_load_local_catalog()
	# Sync en background. No bloquea el arranque del simulador.
	_try_sync_with_backend()


# ====================================================================
# Carga local
# ====================================================================
func _load_local_catalog() -> void:
	# Prioridad: user:// (cache) -> res://defaults/lentes.json
	if _try_load_from_path(USER_CATALOG_PATH, "cache"):
		return
	if _try_load_from_path(DEFAULT_CATALOG_PATH, "defaults"):
		return
	catalog_sync_failed.emit("No hay catalogo cache ni defaults disponibles.")
	push_error("DataManager: no se encontro ningun catalogo local.")


func _try_load_from_path(path: String, source: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var text := FileAccess.get_file_as_string(path)
	var parsed := _parse_catalog_json(text)
	if parsed.is_empty():
		push_warning("DataManager: catalogo invalido en %s, ignorando." % path)
		return false
	catalog = parsed
	catalog_source = source
	var version: String = catalog.get("version", "unknown")
	var lens_count := _count_lenses(catalog)
	catalog_loaded.emit(version, source, lens_count)
	print("DataManager: catalogo v%s cargado desde %s (%d lentes)." % [version, source, lens_count])
	return true


func _parse_catalog_json(text: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(text) != OK:
		return {}
	var data = json.get_data()
	if not (data is Dictionary):
		return {}
	if not data.has("catalogo") or not (data["catalogo"] is Array):
		return {}
	return data


func _count_lenses(cat: Dictionary) -> int:
	if not cat.has("catalogo"):
		return 0
	return (cat["catalogo"] as Array).size()


# ====================================================================
# Sync con backend
# ====================================================================
func _try_sync_with_backend() -> void:
	var url := BACKEND_URL + CATALOG_ENDPOINT
	print("DataManager: sync con backend -> %s" % url)
	var err := _http.request(url, [], HTTPClient.METHOD_GET)
	if err != OK:
		catalog_sync_failed.emit("HTTPRequest.request() fallo: %d" % err)
		return


func _on_sync_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		catalog_sync_failed.emit("Backend inalcanzable (result=%d). Usando catalogo local." % result)
		return
	if response_code != 200:
		catalog_sync_failed.emit("Backend respondio %d. Usando catalogo local." % response_code)
		return

	var text := body.get_string_from_utf8()
	var parsed := _parse_catalog_json(text)
	if parsed.is_empty():
		catalog_sync_failed.emit("Backend devolvio JSON invalido. Usando catalogo local.")
		return

	# Sobrescribir cache y memoria con la version del backend.
	_save_to_cache(text)
	catalog = parsed
	catalog_source = "backend"
	last_sync_time = Time.get_unix_time_from_system()

	var version: String = catalog.get("version", "unknown")
	var lens_count := _count_lenses(catalog)
	catalog_loaded.emit(version, "backend", lens_count)
	catalog_synced_with_backend.emit(version)
	print("DataManager: catalogo v%s sincronizado desde backend (%d lentes)." % [version, lens_count])


func _save_to_cache(text: String) -> void:
	var f := FileAccess.open(USER_CATALOG_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("DataManager: no se pudo escribir %s" % USER_CATALOG_PATH)
		return
	f.store_string(text)


# ====================================================================
# API publica de consulta
# ====================================================================
## Devuelve la definicion de una lente por id, o {} si no existe.
func get_lens(lens_id: String) -> Dictionary:
	if not catalog.has("catalogo"):
		return {}
	for lens in (catalog["catalogo"] as Array):
		if lens is Dictionary and lens.get("id") == lens_id:
			return lens
	return {}


## Devuelve todos los ids del catalogo, en orden.
func get_lens_ids() -> Array:
	var ids: Array = []
	if not catalog.has("catalogo"):
		return ids
	for lens in (catalog["catalogo"] as Array):
		if lens is Dictionary and lens.has("id"):
			ids.append(lens.id)
	return ids


## Aplica una lente a un ojo (o a ambos).
## eye: "left" | "right" | "both".
func apply_lens(lens_id: String, eye: String = "both") -> void:
	var lens := get_lens(lens_id)
	if lens.is_empty():
		push_warning("DataManager: lente '%s' no encontrada" % lens_id)
		return

	var params := _params_to_defaults(lens.get("params", {}))
	params["lens_id"] = lens_id

	# Respetar SIEMPRE el ojo solicitado. blend_mode_enabled es solo un flag
	# informativo: se considera activo cuando los dos ojos tienen distintas
	# lentes; no condiciona quien recibe el apply.
	if eye == "left" or eye == "both":
		current_vision_state["left"] = params.duplicate()
		vision_state_changed.emit("left", current_vision_state["left"])
	if eye == "right" or eye == "both":
		current_vision_state["right"] = params.duplicate()
		vision_state_changed.emit("right", current_vision_state["right"])

	# Actualizar el flag Blend en base al estado actual.
	var left_id: String = current_vision_state["left"].get("lens_id", "")
	var right_id: String = current_vision_state["right"].get("lens_id", "")
	blend_mode_enabled = left_id != "" and right_id != "" and left_id != right_id


## Aplica un override de parametros en tiempo real sobre el estado de vision de
## uno o ambos ojos. SOLO modifica current_vision_state en memoria: NO toca el
## catalogo, ni la cache user://, ni los defaults. Pensado para que la tablet
## ajuste valores de una lente ya aplicada sin alterar la base de datos.
## params: { "blur_near": 0.42, "halo_intensity": 0.7, ... }
## eye: "left" | "right" | "both".
func override_params(params: Dictionary, eye: String = "both") -> void:
	if params.is_empty():
		return
	var targets := ["left", "right"] if eye == "both" else [eye]
	for e in targets:
		if not current_vision_state.has(e):
			continue
		var state: Dictionary = current_vision_state[e]
		# Si no hay lente aplicada en ese ojo, no hay nada que ajustar.
		if state.is_empty():
			continue
		for key in params.keys():
			state[key] = params[key]
		current_vision_state[e] = state
		vision_state_changed.emit(e, state)


func _params_to_defaults(params_def: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in params_def.keys():
		var entry = params_def[key]
		if entry is Dictionary and entry.has("default"):
			result[key] = entry["default"]
		else:
			# Soporta valores directos (ej: focal_distances_m como Array).
			result[key] = entry
	return result


## Forza una nueva sincronizacion con el backend (UI / debug).
func refresh_from_backend() -> void:
	_try_sync_with_backend()
