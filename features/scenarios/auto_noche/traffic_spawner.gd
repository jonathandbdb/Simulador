extends Node3D
## TrafficSpawner — auto_noche
##
## Genera 5 autos que pasan de izquierda a derecha (desde el punto de vista del
## paciente sentado en el asiento del conductor). Cada auto lleva dos SpotLight3D
## como faros delanteros. La velocidad simula ~60 km/h en la escala de Godot
## (1 unidad ≈ 1 metro).
##
## Los autos se distribuyen uniformemente en la trayectoria (Path3D) y se
## envuelven en loop continuo para que el efecto de tráfico no se interrumpa.

## Nodo Path3D que define la trayectoria. Debe estar configurado en la escena
## padre (auto_noche.tscn) con una curva que va de izquierda a derecha, a unos
## 3.5 m del paciente y a unos -0.5 m de altura (carretera).
@export var traffic_path: NodePath

## Velocidad de los autos en m/s. 60 km/h ≈ 16.67 m/s.
@export var speed_mps: float = 16.67

## Número de autos activos simultáneamente.
@export var car_count: int = 5

## Color de los faros (blanco-azulado, LED moderno).
@export var headlight_color: Color = Color(0.9, 0.95, 1.0)
@export var headlight_energy: float = 8.0
@export var headlight_range: float = 18.0

## UID del recurso de malla del auto. Si es null se usa una caja placeholder.
@export var car_mesh: Mesh = null

var _path: Path3D
var _followers: Array[PathFollow3D] = []
var _path_length: float = 0.0


func _ready() -> void:
	_path = get_node_or_null(traffic_path) as Path3D
	if _path == null:
		push_warning("TrafficSpawner: traffic_path no asignado.")
		return

	_path_length = _path.curve.get_baked_length()
	if _path_length < 0.1:
		push_warning("TrafficSpawner: la curva del Path3D parece vacía.")
		return

	for i in range(car_count):
		_spawn_car(i)


func _spawn_car(index: int) -> void:
	var follower := PathFollow3D.new()
	follower.loop = true
	follower.rotation_mode = PathFollow3D.ROTATION_ORIENTED
	# Distribuir uniformemente en la trayectoria.
	follower.progress_ratio = float(index) / float(car_count)
	_path.add_child(follower)
	_followers.append(follower)

	# Cuerpo del auto.
	var car_body := MeshInstance3D.new()
	car_body.name = "CarBody_%d" % index
	if car_mesh != null:
		car_body.mesh = car_mesh
	else:
		# Placeholder: caja ~4.5 m largo × 1.8 m ancho × 1.4 m alto.
		var box := BoxMesh.new()
		box.size = Vector3(1.8, 1.4, 4.5)
		car_body.mesh = box
		# Material oscuro para que el cuerpo no aporte luz; los faros son lo visual.
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.05, 0.05, 0.05)
		mat.metallic = 0.6
		mat.roughness = 0.4
		car_body.material_override = mat
	follower.add_child(car_body)

	# Luces traseras: OmniLight3D rojo tenue en la parte posterior.
	var tail_light := OmniLight3D.new()
	tail_light.name = "TailLight_%d" % index
	tail_light.light_color = Color(1.0, 0.05, 0.05)
	tail_light.light_energy = 2.0
	tail_light.omni_range = 4.0
	tail_light.position = Vector3(0.0, 0.5, 2.4)
	follower.add_child(tail_light)

	# Faro izquierdo.
	_add_headlight(follower, index, Vector3(-0.7, 0.5, -2.4))
	# Faro derecho.
	_add_headlight(follower, index, Vector3( 0.7, 0.5, -2.4))


func _add_headlight(parent: Node3D, index: int, offset: Vector3) -> void:
	var spot := SpotLight3D.new()
	spot.name = "Headlight_%d" % index
	spot.light_color = headlight_color
	spot.light_energy = headlight_energy
	spot.spot_range = headlight_range
	spot.spot_angle = 28.0
	spot.spot_angle_attenuation = 0.5
	# Apunta hacia adelante (−Z en espacio local del PathFollow3D).
	spot.rotation_degrees = Vector3(-5.0, 0.0, 0.0)
	spot.position = offset
	parent.add_child(spot)


func _process(delta: float) -> void:
	if _path_length < 0.1:
		return
	for follower in _followers:
		follower.progress += speed_mps * delta
