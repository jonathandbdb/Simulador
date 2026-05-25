extends Node
## DataManager (Autoload Singleton)
##
## Responsabilidades (Fase 1):
##  - Cargar el catalogo de lentes al arrancar:
##      1) Intentar user://lentes.json (cache de la ultima sync con /api/lenses).
##      2) Si no existe o esta corrupto, fallback a res://defaults/lentes.json (embebido en APK).
##  - Mantener el estado binocular actual: current_vision_state = { left: {...}, right: {...} }.
##  - Exponer senales cuando cambia el estado de vision.
##
## NOTA: Esqueleto Sprint 0. Logica completa se implementa en Sprint 4.

const DEFAULT_CATALOG_PATH := "res://defaults/lentes.json"
const USER_CATALOG_PATH := "user://lentes.json"

signal catalog_loaded(version: String, lens_count: int)
signal catalog_load_failed(reason: String)
signal vision_state_changed(eye: String, params: Dictionary)

var catalog: Dictionary = {}
var current_vision_state: Dictionary = {
	"left":  {},
	"right": {},
}
var blend_mode_enabled: bool = false


func _ready() -> void:
	_load_catalog()


func _load_catalog() -> void:
	# TODO Sprint 4: intentar primero user:// y luego fallback a defaults.
	var path := DEFAULT_CATALOG_PATH
	if not FileAccess.file_exists(path):
		catalog_load_failed.emit("Catalogo por defecto no encontrado: %s" % path)
		push_error("DataManager: catalogo por defecto no encontrado en %s" % path)
		return

	var text := FileAccess.get_file_as_string(path)
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		catalog_load_failed.emit("JSON invalido: linea %d" % json.get_error_line())
		push_error("DataManager: JSON invalido en %s linea %d" % [path, json.get_error_line()])
		return

	catalog = json.get_data()
	var lens_count := 0
	if catalog.has("catalogo") and catalog["catalogo"] is Array:
		lens_count = (catalog["catalogo"] as Array).size()
	var version: String = catalog.get("version", "unknown")
	catalog_loaded.emit(version, lens_count)
	print("DataManager: catalogo %s cargado (%d lentes)" % [version, lens_count])


## Devuelve la definicion de una lente por id, o {} si no existe.
func get_lens(lens_id: String) -> Dictionary:
	if not catalog.has("catalogo"):
		return {}
	for lens in (catalog["catalogo"] as Array):
		if lens is Dictionary and lens.get("id") == lens_id:
			return lens
	return {}


## Aplica una lente a un ojo (o a ambos si blend_mode esta desactivado).
## eye: "left", "right", o "both".
func apply_lens(lens_id: String, eye: String = "both") -> void:
	var lens := get_lens(lens_id)
	if lens.is_empty():
		push_warning("DataManager: lente '%s' no encontrada" % lens_id)
		return

	var params := _params_to_defaults(lens.get("params", {}))
	params["lens_id"] = lens_id

	if eye == "left" or eye == "both" or not blend_mode_enabled:
		current_vision_state["left"] = params.duplicate()
		vision_state_changed.emit("left", current_vision_state["left"])
	if eye == "right" or eye == "both" or not blend_mode_enabled:
		current_vision_state["right"] = params.duplicate()
		vision_state_changed.emit("right", current_vision_state["right"])


func _params_to_defaults(params_def: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in params_def.keys():
		var entry = params_def[key]
		if entry is Dictionary and entry.has("default"):
			result[key] = entry["default"]
	return result
