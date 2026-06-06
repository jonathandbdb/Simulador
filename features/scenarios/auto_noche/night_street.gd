extends Node3D
## NightStreet — auto_noche
##
## Carga el modelo de carretera (export SketchUp .dae) y coloca farolas con luz
## REAL (SpotLight3D apuntando a la calzada + esfera emisiva como bombilla).
## Las bombillas emisivas son fuentes puntuales brillantes: el shader
## post-process (sprint2_blur_test.gdshader) las convierte en halos, destellos
## y rayos cuando hay una lente con esos defectos activada.
##
## Todo es configurable desde el inspector del editor (no hace falta tocar
## código para ajustar posición/escala del modelo ni la disposición de farolas).

# ----------------------------------------------------------------------
# Modelo de carretera
# ----------------------------------------------------------------------
@export_group("Modelo de carretera")
## PackedScene del modelo. Si es null se carga ROAD_SCENE_PATH por código.
@export var road_scene: PackedScene = null
## Mostrar/ocultar el modelo (útil para depurar sin la geometría pesada).
@export var show_road: bool = true
## Posición del modelo respecto al paciente (que está en el origen).
## La calle del modelo va de X≈12 a X≈132 m, así que se desplaza -72 en X para
## que el paciente quede en el medio de la cuadra. Y = altura del suelo.
@export var road_position: Vector3 = Vector3(-72.0, -1.0, 0.0)
## Rotación en grados. El modelo SketchUp es Z_UP, por eso por defecto se gira
## -90 en X para que quede de pie. Ajustá el eje Y para orientar la calle
## (la calzada corre a lo largo de un eje horizontal).
@export var road_rotation_deg: Vector3 = Vector3(-90.0, 0.0, 0.0)
## Escala uniforme. El modelo está en pulgadas (~137 m de largo), por eso se
## escala a 0.0254 (pulgada→metro). Ajustá si querés la calle más corta/larga.
@export var road_scale: float = 0.0254

# ----------------------------------------------------------------------
# Suelo base (reemplaza el suelo/entorno local)
# ----------------------------------------------------------------------
@export_group("Suelo base")
## Crea una base de asfalto plana bajo el modelo. Es el "suelo" real de la
## escena: garantiza que nunca quede un abismo negro debajo del auto aunque
## el modelo de carretera importe torcido o desalineado.
@export var show_ground: bool = true
## Tamaño del suelo (lado del plano cuadrado, en metros).
@export var ground_size_m: float = 60.0
## Altura (Y) del suelo. Debe coincidir con la superficie de la calzada.
@export var ground_y_m: float = -1.0
## Color del asfalto nocturno.
@export var ground_color: Color = Color(0.04, 0.04, 0.05)

# ----------------------------------------------------------------------
# Farolas (street lights)
# ----------------------------------------------------------------------
@export_group("Farolas")
## Encender las farolas del modelo: coloca una luz REAL + bombilla emisiva en
## la posición exacta de cada poste del modelo (extraídas del .dae original).
@export var lamp_enabled: bool = true
## Altura del cabezal de la farola sobre su base, en metros. El poste del modelo
## mide ~6.4 m, así que la luz va cerca del extremo superior.
@export var lamp_head_height_m: float = 6.2
## Cuánto se extiende el brazo hacia el centro de la calle (metros).
@export var lamp_arm_reach_m: float = 2.0
## Cuánto se extiende el brazo hacia la vereda (lado opuesto a la calle).
## Cada poste tiene dos cabezales: uno sobre la calzada y otro sobre la vereda.
@export var lamp_sidewalk_reach_m: float = 2.0
## Color de la luz. Blanco cálido (alumbrado LED moderno).
@export var lamp_color: Color = Color(1.0, 0.95, 0.85)
## Intensidad de la luz que ilumina la calzada. Moderada: hay ~36 cabezales en
## la cuadra; con valores altos la suma quema la escena aun con tonemap AGX.
@export var lamp_energy: float = 6.0
## Alcance de la luz.
@export var lamp_range_m: float = 14.0
## Brillo de la bombilla emisiva (fuente de los halos/destellos del shader).
@export var lamp_bulb_emission: float = 10.0
## Dibujar una bombilla emisiva como fuente de los halos. Activada: cada farola
## es un punto brillante que, al cambiar de lente, genera halo/destello. Sin
## esto las farolas solo proyectan luz al piso y no disparan el efecto óptico.
@export var lamp_show_bulb: bool = true

# ----------------------------------------------------------------------
# Líneas viales (señalización de la calzada)
# ----------------------------------------------------------------------
@export_group("Líneas viales")
## Pintar líneas de calzada (centro, bordes y senda peatonal).
@export var markings_enabled: bool = true
## Y (a lo ancho de la calle, espacio del modelo) del centro de la calzada.
## Si las líneas no quedan centradas, ajustá este valor.
@export var road_center_y_m: float = 0.28
## Mitad del ancho de calzada: distancia del centro a las líneas blancas de
## borde (metros). Las líneas blancas marcan los extremos del asfalto.
@export var road_half_width_m: float = 4.0
## Separación entre las dos líneas amarillas centrales (doble línea, metros).
@export var center_line_gap_m: float = 0.18
## Ancho de cada línea pintada (metros).
@export var line_width_m: float = 0.14
## Posición X (largo de la calle) donde se pinta la senda peatonal.
@export var crosswalk_x_m: float = 72.0
## Color de las líneas centrales (doble línea amarilla).
@export var center_line_color: Color = Color(0.5, 0.42, 0.08)
## Color de las líneas de borde y la senda peatonal. Gris medio (no blanco): de
## noche la pintura reflejada por las farolas no debe saturar ni competir con las
## fuentes de luz reales (si no, genera halos/streaks falsos en la calzada).
@export var side_line_color: Color = Color(0.45, 0.45, 0.45)
## Brillo emisivo de la pintura. BAJO a propósito: la pintura vial NO es una
## fuente de luz, así que debe quedar por debajo del umbral de halo del shader
## (~0.55 de noche). Con valores altos las líneas cercanas generaban halos y
## starbursts falsos (como si fueran faros). Si se necesitara que se vean más,
## subir la luz de las farolas, no esto.
@export var line_emission: float = 0.12

const ROAD_SCENE_PATH := "res://assets/scenarios/auto_noche/road/model.glb"

## Posiciones de las farolas en el espacio LOCAL del modelo (metros, antes de
## aplicar road_position/road_rotation/road_scale). Extraídas del .dae original
## (nodos "Japanese_street_light_2"). Z es la base del poste (modelo Z_UP).
const LAMP_POSITIONS_M: Array[Vector3] = [
	Vector3(40.06, -6.53, 0.23),
	Vector3(52.94, -6.53, 0.23),
	Vector3(23.89, -6.53, 0.23),
	Vector3(65.50, -6.53, 0.23),
	Vector3(79.39, -6.53, 0.23),
	Vector3(103.07, -6.53, 0.23),
	Vector3(115.59, -6.53, 0.23),
	Vector3(128.12, -6.53, 0.23),
	Vector3(70.33, 7.08, 0.23),
	Vector3(107.90, 7.08, 0.23),
	Vector3(82.85, 7.08, 0.23),
	Vector3(97.05, 7.08, 0.23),
	Vector3(131.54, 7.08, 0.23),
	Vector3(28.72, 7.08, 0.23),
	Vector3(44.90, 7.08, 0.23),
	Vector3(57.77, 7.08, 0.23),
	Vector3(120.43, 7.08, 0.23),
	Vector3(11.77, 7.08, 0.23),
]


func _ready() -> void:
	if show_ground:
		_spawn_ground()
	if show_road:
		_load_road()
	if lamp_enabled:
		_spawn_lamps()
	if markings_enabled:
		_spawn_lane_markings()
	_setup_standalone_preview()


## Cuando la escena se corre SOLA en PC (no instanciada bajo main.tscn) no hay
## cámara XR ni post-proceso. Para poder revisar la geometría/tráfico/luces de
## forma standalone se agrega una cámara fija en el asiento del conductor y un
## entorno nocturno básico con glow. Si la escena corre dentro de main (existe el
## grupo "xr_camera"), no se hace nada y se respeta el rig real.
func _setup_standalone_preview() -> void:
	if get_tree().get_first_node_in_group("xr_camera") != null:
		return  # corriendo dentro de main: el rig real maneja cámara y entorno.

	var cam := Camera3D.new()
	cam.name = "DebugCamera"
	cam.position = Vector3(0.0, 0.2, 0.2)
	cam.rotation_degrees = Vector3(-2.0, 0.0, 0.0)
	cam.current = true
	add_child(cam)

	var we := WorldEnvironment.new()
	we.name = "DebugEnvironment"
	we.environment = _make_night_environment()
	add_child(we)


## Entorno nocturno básico para el preview standalone (espejo aproximado de
## NIGHT_PARAMS de main.gd + glow). No se usa cuando corre dentro de main.
func _make_night_environment() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.015, 0.015, 0.03)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.08, 0.09, 0.14)
	env.ambient_light_energy = 0.4
	env.glow_enabled = true
	env.glow_intensity = 0.8
	env.glow_strength = 1.0
	env.glow_bloom = 0.15
	env.glow_hdr_threshold = 1.2
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 0.5
	env.tonemap_white = 8.0
	return env


func _spawn_ground() -> void:
	# Suelo de asfalto: reemplaza el suelo/entorno local placeholder.
	var floor := MeshInstance3D.new()
	floor.name = "GroundBase"
	var plane := PlaneMesh.new()
	plane.size = Vector2(ground_size_m, ground_size_m)
	floor.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ground_color
	mat.roughness = 0.9
	mat.metallic = 0.0
	floor.material_override = mat
	floor.position = Vector3(0.0, ground_y_m, 0.0)
	add_child(floor)


func _load_road() -> void:
	var packed: PackedScene = road_scene
	if packed == null:
		packed = load(ROAD_SCENE_PATH) as PackedScene
	if packed == null:
		push_warning("NightStreet: no se pudo cargar el modelo '%s'." % ROAD_SCENE_PATH)
		return

	var road := packed.instantiate() as Node3D
	if road == null:
		push_warning("NightStreet: el modelo cargado no es un Node3D.")
		return

	road.name = "RoadModel"
	road.position = road_position
	road.rotation = Vector3(
		deg_to_rad(road_rotation_deg.x),
		deg_to_rad(road_rotation_deg.y),
		deg_to_rad(road_rotation_deg.z))
	road.scale = Vector3.ONE * road_scale
	add_child(road)


func _spawn_lamps() -> void:
	# Coloca las luces en las posiciones reales de los postes del modelo.
	# LAMP_POSITIONS_M ya está en METROS reales (mundo), igual que el modelo una
	# vez aplicado road_scale sobre sus pulgadas. Por eso aquí solo aplicamos
	# road_rotation y road_position: NO se vuelve a multiplicar por road_scale.
	var rot := Vector3(
		deg_to_rad(road_rotation_deg.x),
		deg_to_rad(road_rotation_deg.y),
		deg_to_rad(road_rotation_deg.z))
	var basis := Basis.from_euler(rot)
	# Centro de la calle (eje Y del modelo): promedio de las dos hileras de postes.
	var center_y := 0.0
	for p in LAMP_POSITIONS_M:
		center_y += p.y
	center_y /= float(LAMP_POSITIONS_M.size())
	for i in range(LAMP_POSITIONS_M.size()):
		var base := LAMP_POSITIONS_M[i]
		# Cada poste tiene DOS cabezales: uno apunta a la calle y otro a la vereda.
		var dir_to_center: float = signf(center_y - base.y)
		# Cabezal sobre la calzada.
		var head_street := Vector3(
			base.x,
			base.y + dir_to_center * lamp_arm_reach_m,
			base.z + lamp_head_height_m)
		_spawn_lamp_at("%d_calle" % i, road_position + basis * head_street)
		# Cabezal sobre la vereda (lado opuesto).
		var head_walk := Vector3(
			base.x,
			base.y - dir_to_center * lamp_sidewalk_reach_m,
			base.z + lamp_head_height_m)
		_spawn_lamp_at("%d_vereda" % i, road_position + basis * head_walk)


func _spawn_lamp_at(suffix: String, head_pos: Vector3) -> void:
	var root := Node3D.new()
	root.name = "Lamp_%s" % suffix
	root.position = head_pos
	add_child(root)

	# Bombilla: esfera emisiva PEQUEÑA. Es solo el punto-fuente que dispara el
	# halo/destello del shader; si es grande se ve como un disco postizo pegado
	# sobre el cabezal del modelo (el "círculo superpuesto").
	if lamp_show_bulb:
		var bulb := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.04
		sm.height = 0.08
		bulb.mesh = sm
		var bulb_mat := StandardMaterial3D.new()
		bulb_mat.albedo_color = lamp_color
		bulb_mat.emission_enabled = true
		bulb_mat.emission = lamp_color
		bulb_mat.emission_energy_multiplier = lamp_bulb_emission
		bulb_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		bulb.material_override = bulb_mat
		# Apunta hacia abajo, justo en el foco del cabezal.
		bulb.position = Vector3(0.0, -0.05, 0.0)
		root.add_child(bulb)

	# Luz real apuntando hacia abajo a la calzada.
	var light := SpotLight3D.new()
	light.light_color = lamp_color
	light.light_energy = lamp_energy
	light.spot_range = lamp_range_m
	light.spot_angle = 60.0
	light.spot_angle_attenuation = 1.0
	light.shadow_enabled = false
	light.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	root.add_child(light)


func _spawn_lane_markings() -> void:
	# Contenedor con la misma transformación que el modelo, así las líneas se
	# definen en el espacio del modelo (X = a lo largo de la calle, Y = a lo
	# ancho, Z = arriba) y quedan pegadas a la calzada.
	var markings := Node3D.new()
	markings.name = "LaneMarkings"
	markings.position = road_position
	markings.rotation = Vector3(
		deg_to_rad(road_rotation_deg.x),
		deg_to_rad(road_rotation_deg.y),
		deg_to_rad(road_rotation_deg.z))
	add_child(markings)

	# Largo de la calle: rango X de los postes con un margen.
	var x_min := INF
	var x_max := -INF
	for p in LAMP_POSITIONS_M:
		x_min = minf(x_min, p.x)
		x_max = maxf(x_max, p.x)
	var x_center := (x_min + x_max) * 0.5
	var length := (x_max - x_min) + 8.0
	var z_surface := 0.06  # apenas por encima del asfalto para evitar z-fighting.

	var cy := road_center_y_m

	# Doble línea amarilla central.
	_add_line(markings, x_center, cy - center_line_gap_m * 0.5, z_surface,
		length, line_width_m, center_line_color)
	_add_line(markings, x_center, cy + center_line_gap_m * 0.5, z_surface,
		length, line_width_m, center_line_color)

	# Líneas blancas de borde.
	_add_line(markings, x_center, cy - road_half_width_m, z_surface,
		length, line_width_m, side_line_color)
	_add_line(markings, x_center, cy + road_half_width_m, z_surface,
		length, line_width_m, side_line_color)

	# Senda peatonal (cebra) blanca, franjas a lo ancho de la calzada.
	_add_crosswalk(markings, crosswalk_x_m, cy, z_surface)


func _add_line(parent: Node3D, xc: float, yc: float, zc: float,
		length: float, width: float, color: Color) -> void:
	var strip := MeshInstance3D.new()
	var box := BoxMesh.new()
	# X = largo de la línea, Y = ancho, Z = espesor (chato).
	box.size = Vector3(length, width, 0.02)
	strip.mesh = box
	strip.material_override = _line_material(color)
	strip.position = Vector3(xc, yc, zc)
	parent.add_child(strip)


func _add_crosswalk(parent: Node3D, xc: float, yc: float, zc: float) -> void:
	# Franjas blancas perpendiculares a la calle (cebra).
	var stripe_count := 7
	var stripe_len := road_half_width_m * 1.6   # cubre el ancho de la calzada.
	var stripe_w := 0.4                          # ancho de cada franja (en X).
	var gap := 0.5                               # separación entre franjas.
	var total := float(stripe_count) * stripe_w + float(stripe_count - 1) * gap
	var start := xc - total * 0.5
	for i in range(stripe_count):
		var sx := start + float(i) * (stripe_w + gap) + stripe_w * 0.5
		var strip := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(stripe_w, stripe_len, 0.02)
		strip.mesh = box
		strip.material_override = _line_material(side_line_color)
		strip.position = Vector3(sx, yc, zc)
		parent.add_child(strip)


func _line_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	# UNSHADED: la pintura vial NO recibe iluminacion dinamica. Se ve con su color
	# constante (mate), pero NUNCA refleja la luz de las farolas/faros ni produce
	# highlights brillantes en angulo rasante. Asi no dispara halos/destellos/
	# streaks falsos en la calzada (pedido explicito: la luz NO debe reflejarse en
	# las lineas de la calle). El color es gris/amarillo OSCURO para quedar muy por
	# debajo del umbral de glare del shader de lentes.
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat
