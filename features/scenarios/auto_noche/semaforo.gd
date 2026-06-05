extends Node3D
## Semaforo — auto_noche (Sprint 11)
##
## Cicla el semáforo del frente (rojo → verde → amarillo) encendiendo una luz a
## la vez. Cada color es una fuente puntual brillante distinta, así el paciente
## ve cómo el halo/destello de su lente cambia de color y posición. Útil para que
## el oftalmólogo muestre la disfotopsia sobre varias longitudes de onda.
##
## Espera tres OmniLight3D hijos: "LuzRoja", "LuzAmarilla", "LuzVerde", y
## opcionalmente meshes "GloboRojo"/"GloboAmarillo"/"GloboVerde" con material
## emisivo, cuyo brillo se sincroniza con la luz activa.

## Segundos en verde (se mantiene un rato).
@export var green_time: float = 7.0
## Segundos en amarillo (transición breve).
@export var yellow_time: float = 2.5
## Segundos en rojo (se mantiene un rato).
@export var red_time: float = 7.0
## Energía de la luz encendida.
@export var on_energy: float = 4.0
## Energía emisiva del globo encendido (alta: debe generar halo con la lente).
@export var bulb_on_emission: float = 9.0
## Energía emisiva del globo apagado (tenue, no negro, como un farol real).
@export var bulb_off_emission: float = 0.04

var _lights: Dictionary = {}   # color -> OmniLight3D
var _bulbs: Dictionary = {}    # color -> StandardMaterial3D
var _order: Array[String] = ["green", "yellow", "red"]
var _times: Dictionary = {}
var _idx: int = 0
var _elapsed: float = 0.0


func _ready() -> void:
	# find_child (recursivo) para que funcione aunque las luces estén anidadas
	# en un nodo "Head" rotado (orientación del cabezal).
	_lights = {
		"red":    find_child("LuzRoja", true, false),
		"yellow": find_child("LuzAmarilla", true, false),
		"green":  find_child("LuzVerde", true, false),
	}
	_bulbs = {
		"red":    _bulb_material("GloboRojo"),
		"yellow": _bulb_material("GloboAmarillo"),
		"green":  _bulb_material("GloboVerde"),
	}
	_times = {"green": green_time, "yellow": yellow_time, "red": red_time}
	_apply_state(_order[_idx])


func _bulb_material(node_name: String) -> StandardMaterial3D:
	var mesh := find_child(node_name, true, false) as MeshInstance3D
	if mesh == null:
		return null
	var mat := mesh.get_active_material(0)
	if mat is StandardMaterial3D:
		return mat as StandardMaterial3D
	return null


func _process(delta: float) -> void:
	_elapsed += delta
	var current: String = _order[_idx]
	if _elapsed >= float(_times.get(current, 4.0)):
		_elapsed = 0.0
		_idx = (_idx + 1) % _order.size()
		_apply_state(_order[_idx])


## Estado actual del semáforo ("green" | "yellow" | "red").
func current_color() -> String:
	return _order[_idx]


## ¿Pueden avanzar los autos? Solo en verde (en amarillo/rojo frenan).
func is_go() -> bool:
	return _order[_idx] == "green"


func _apply_state(active: String) -> void:
	for color in _lights.keys():
		var light := _lights[color] as Light3D
		if light != null:
			light.light_energy = on_energy if color == active else 0.0
		var bulb := _bulbs[color] as StandardMaterial3D
		if bulb != null:
			bulb.emission_energy_multiplier = bulb_on_emission if color == active else bulb_off_emission
