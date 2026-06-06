extends Node3D
## TrafficSpawner — auto_noche
##
## Enfoque centrado en la EXPERIENCIA DEL PACIENTE: pocos autos, que aparecen con
## una frecuencia ALEATORIA (no un flujo constante). Cada auto cruza una sola vez
## el campo de visión —entra lejos por un lado, pasa cerca al frente del paciente
## y se aleja por el otro— y al salir se oculta y espera un tiempo random antes de
## volver a entrar. Asi el paciente ve cómo el halo/destello de las luces (faros,
## traseras) cambia con la distancia segun la lente activa, sin saturar la escena.
##
## Hay dos carriles:
##   - principal: autos que se ALEJAN (el paciente ve sus luces traseras rojas).
##   - contrario: autos que vienen DE FRENTE (faros blancos que deslumbran).
## El semáforo es solo una fuente de luz decorativa; no detiene el tráfico (con
## tan pocos autos, frenarlos dejaría la escena vacía).

@export var traffic_path: NodePath

## Velocidad base de los autos en m/s (~43 km/h urbano). Cada pasada la varía un
## poco para que no todos vayan igual.
@export var speed_mps: float = 12.0

## Autos del carril que se aleja (luces traseras rojas hacia el paciente).
@export var car_count: int = 2
## Autos del carril contrario (faros de frente hacia el paciente).
@export var oncoming_count: int = 1

## Pausa ALEATORIA (segundos) entre que un auto sale de cuadro y vuelve a entrar.
## Da la frecuencia irregular pedida: a veces pasan seguidos, a veces hay un hueco.
@export var gap_min_s: float = 2.5
@export var gap_max_s: float = 8.0

## Color de los faros (blanco-azulado, LED moderno).
@export var headlight_color: Color = Color(0.9, 0.95, 1.0)
@export var headlight_energy: float = 8.0
@export var headlight_range: float = 18.0

## Desplazamiento (Z, hacia el paciente) del carril contrario respecto al principal.
@export var oncoming_lane_offset_z: float = 2.2
## Brillo emisivo de los faros de frente (deslumbran más que las luces que se alejan).
@export var oncoming_headlight_emission: float = 18.0

## Malla opcional del auto. Si es null se usa una caja placeholder.
@export var car_mesh: Mesh = null

# Estado interno: un registro por auto, con su PathFollow, el largo de su traza,
# su velocidad de esta pasada y el tiempo de espera restante (>0 = oculto).
var _cars: Array = []   # [{ f: PathFollow3D, len: float, speed: float, wait: float }]
var _main_path: Path3D
var _oncoming_path: Path3D


func _ready() -> void:
	randomize()  # semilla para los tiempos/velocidades aleatorios

	# Carril que CRUZA de izquierda a derecha frente al paciente (más lejano).
	_main_path = get_node_or_null(traffic_path) as Path3D
	if _main_path == null:
		push_warning("TrafficSpawner: traffic_path no asignado.")
		return
	_build_curve(_main_path, -4.0, false)

	# Carril contrario que CRUZA de derecha a izquierda (un poco más cerca del
	# paciente). Asi en el cruce se ven autos en ambos sentidos.
	_oncoming_path = Path3D.new()
	_oncoming_path.name = "OncomingPath"
	add_child(_oncoming_path)
	_build_curve(_oncoming_path, -2.6, true)

	for i in range(car_count):
		_spawn_car(_main_path, i, false)
	for i in range(oncoming_count):
		_spawn_car(_oncoming_path, i, true)


## Construye la traza de un carril que CRUZA la calle frente al paciente (eje X),
## a profundidad z fija. El auto entra lejos por un lado (~25 m), pasa cerca al
## frente del paciente (en x=0, a |z| m) y se aleja por el otro lado: asi el
## paciente ve el glare de sus luces crecer y decrecer con la distancia.
##   right_to_left=false: cruza de izquierda (-x) a derecha (+x).
##   right_to_left=true : cruza de derecha (+x) a izquierda (-x).
func _build_curve(path: Path3D, z: float, right_to_left: bool) -> void:
	var x0 := -25.0
	var x1 := 25.0
	if right_to_left:
		x0 = 25.0
		x1 = -25.0
	var t := (x1 - x0) * 0.25   # tangente a lo largo de X (signo segun sentido)
	var curve := Curve3D.new()
	curve.add_point(Vector3(x0, -0.9, z), Vector3.ZERO, Vector3(t, 0, 0))
	curve.add_point(Vector3(0.0, -0.9, z), Vector3(-t, 0, 0), Vector3(t, 0, 0))
	curve.add_point(Vector3(x1, -0.9, z), Vector3(-t, 0, 0), Vector3.ZERO)
	path.curve = curve


func _spawn_car(path: Path3D, index: int, oncoming: bool) -> void:
	var follower := PathFollow3D.new()
	follower.loop = false   # manejamos la reaparición manualmente
	follower.rotation_mode = PathFollow3D.ROTATION_ORIENTED
	path.add_child(follower)

	# Cuerpo del auto.
	var car_body := MeshInstance3D.new()
	car_body.name = ("OncomingBody_%d" if oncoming else "CarBody_%d") % index
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

	if oncoming:
		# Faros de frente (deslumbran al paciente).
		_add_headlight(follower, Vector3(-0.6, 0.45, -2.3), oncoming_headlight_emission)
		_add_headlight(follower, Vector3( 0.6, 0.45, -2.3), oncoming_headlight_emission)
	else:
		# Luces traseras rojas (el paciente las ve alejarse) + faros tenues.
		_add_taillight(follower, Vector3(-0.55, 0.45, 2.3))
		_add_taillight(follower, Vector3( 0.55, 0.45, 2.3))
		_add_headlight(follower, Vector3(-0.6, 0.45, -2.3), 12.0)
		_add_headlight(follower, Vector3( 0.6, 0.45, -2.3), 12.0)

	# Entra oculto, con una espera inicial escalonada + aleatoria, para que los
	# autos no aparezcan todos juntos al arrancar la escena.
	follower.visible = false
	var car := {
		"f": follower,
		"len": path.curve.get_baked_length(),
		"speed": _rand_speed(),
		"wait": float(index) * 2.5 + randf_range(0.0, gap_max_s),
	}
	_cars.append(car)


func _rand_speed() -> float:
	return speed_mps * randf_range(0.8, 1.25)


func _process(delta: float) -> void:
	for car in _cars:
		var f: PathFollow3D = car["f"]
		if car["wait"] > 0.0:
			# Esperando fuera de cuadro: contar el tiempo y, al llegar a 0, entrar.
			car["wait"] -= delta
			if car["wait"] <= 0.0:
				f.progress = 0.0
				car["speed"] = _rand_speed()
				f.visible = true
			continue
		f.progress += car["speed"] * delta
		if f.progress >= car["len"]:
			# Salió de cuadro: ocultar y programar la próxima entrada (random).
			f.visible = false
			car["wait"] = randf_range(gap_min_s, gap_max_s)


## Luz trasera: SpotLight rojo + globo emisivo (fuente del halo/destello).
func _add_taillight(parent: Node3D, offset: Vector3) -> void:
	var spot := SpotLight3D.new()
	spot.light_color = Color(1.0, 0.04, 0.04)
	spot.light_energy = 3.0
	spot.spot_range = 6.0
	spot.spot_angle = 35.0
	spot.spot_angle_attenuation = 0.6
	spot.rotation_degrees = Vector3(0.0, 180.0, 0.0)
	spot.position = offset
	parent.add_child(spot)

	var glow := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.045
	sm.height = 0.09
	glow.mesh = sm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(1.0, 0.05, 0.05)
	gm.emission_enabled = true
	gm.emission = Color(1.0, 0.05, 0.05)
	gm.emission_energy_multiplier = 7.0
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.material_override = gm
	glow.position = offset
	parent.add_child(glow)


## Faro delantero: SpotLight que ilumina la calzada + globo emisivo (fuente del
## halo/destello). emission controla cuánto deslumbra (más alto = de frente).
func _add_headlight(parent: Node3D, offset: Vector3, emission: float) -> void:
	var spot := SpotLight3D.new()
	spot.light_color = headlight_color
	spot.light_energy = headlight_energy
	spot.spot_range = headlight_range
	spot.spot_angle = 28.0
	spot.spot_angle_attenuation = 0.5
	spot.rotation_degrees = Vector3(-5.0, 0.0, 0.0)
	spot.position = offset
	parent.add_child(spot)

	var glow := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.055
	sm.height = 0.11
	glow.mesh = sm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = headlight_color
	gm.emission_enabled = true
	gm.emission = headlight_color
	gm.emission_energy_multiplier = emission
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.material_override = gm
	glow.position = offset
	parent.add_child(glow)
