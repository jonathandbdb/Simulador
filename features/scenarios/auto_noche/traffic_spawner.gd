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

	# Construir la curva siempre por código — evita problemas de
	# serialización de Curve3D._data en el formato TSCN de Godot 4.
	_build_default_curve()

	_path_length = _path.curve.get_baked_length()
	if _path_length < 0.1:
		push_warning("TrafficSpawner: la curva del Path3D quedó vacía.")
		return

	for i in range(car_count):
		_spawn_car(i)


## Construye la trayectoria de tráfico por código.
## El camino va de izquierda (x=-20) a derecha (x=20),
## a ~3.5 m delante del paciente (z=-3.5) y ~0.9 m bajo su posición (y=-0.9).
func _build_default_curve() -> void:
	if _path.curve == null:
		_path.curve = Curve3D.new()
	else:
		_path.curve.clear_points()
	# add_point(position, in_tangent, out_tangent)
	# Tangentes apuntan a lo largo del eje X para una curva suave izq→der.
	_path.curve.add_point(
		Vector3(-20.0, -0.9, -3.5),
		Vector3.ZERO,
		Vector3( 6.0,  0.0,  0.0))
	_path.curve.add_point(
		Vector3(  0.0, -0.9, -3.5),
		Vector3(-6.0,  0.0,  0.0),
		Vector3( 6.0,  0.0,  0.0))
	_path.curve.add_point(
		Vector3( 20.0, -0.9, -2.5),
		Vector3(-6.0,  0.0,  0.0),
		Vector3.ZERO)


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
		var box := BoxMesh.new()
		box.size = Vector3(1.8, 1.4, 4.5)
		car_body.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.05, 0.05, 0.05)
		mat.metallic = 0.6
		mat.roughness = 0.4
		car_body.material_override = mat
	follower.add_child(car_body)

	# Luces traseras: dos SpotLight3D apuntando hacia atrás (+Z).
	_add_taillight(follower, index, Vector3(-0.55, 0.45,  2.3))
	_add_taillight(follower, index, Vector3( 0.55, 0.45,  2.3))

	# Faros delanteros: SpotLight3D con punto emisivo (sin cono).
	_add_headlight(follower, index, Vector3(-0.6, 0.45, -2.3))
	_add_headlight(follower, index, Vector3( 0.6, 0.45, -2.3))


## Luz trasera: SpotLight rojo apuntando al +Z (posterior del auto).
func _add_taillight(parent: Node3D, index: int, offset: Vector3) -> void:
	var spot := SpotLight3D.new()
	spot.light_color    = Color(1.0, 0.04, 0.04)
	spot.light_energy   = 4.0
	spot.spot_range     = 8.0
	spot.spot_angle     = 35.0
	spot.spot_angle_attenuation = 0.6
	# Apunta hacia atrás (+Z en espacio local del PathFollow3D).
	spot.rotation_degrees = Vector3(0.0, 180.0, 0.0)
	spot.position = offset
	parent.add_child(spot)

	# Punto emisivo rojo para hacer la luz más credible.
	var glow := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.045
	sm.height = 0.09
	glow.mesh = sm
	var gm := StandardMaterial3D.new()
	gm.albedo_color               = Color(1.0, 0.05, 0.05)
	gm.emission_enabled           = true
	gm.emission                   = Color(1.0, 0.05, 0.05)
	gm.emission_energy_multiplier = 6.0
	gm.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.material_override = gm
	glow.position = offset
	parent.add_child(glow)


func _add_headlight(parent: Node3D, index: int, offset: Vector3) -> void:
	# SpotLight para iluminar la carretera.
	var spot := SpotLight3D.new()
	spot.light_color            = headlight_color
	spot.light_energy           = headlight_energy
	spot.spot_range             = headlight_range
	spot.spot_angle             = 28.0
	spot.spot_angle_attenuation = 0.5
	spot.rotation_degrees       = Vector3(-5.0, 0.0, 0.0)
	spot.position               = offset
	parent.add_child(spot)

	# Punto emisivo blanco-azulado: es la fuente visible que genera halos/destellos
	# en el shader post-process. Radio pequeño para que sea una fuente puntual.
	var glow := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.055
	sm.height = 0.11
	glow.mesh = sm
	var gm := StandardMaterial3D.new()
	gm.albedo_color               = headlight_color
	gm.emission_enabled           = true
	gm.emission                   = headlight_color
	gm.emission_energy_multiplier = 12.0
	gm.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.material_override = gm
	glow.position = offset
	parent.add_child(glow)


func _process(delta: float) -> void:
	if _path_length < 0.1:
		return
	for follower in _followers:
		follower.progress += speed_mps * delta
