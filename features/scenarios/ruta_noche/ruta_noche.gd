extends Node3D
## RutaNoche — escenario nocturno de ruta larga (Sprint 11+)
##
## Carretera (road2) tileada 3 veces a lo largo del eje Z para una ruta larga,
## con la cámara/paciente en el centro del SEGUNDO tile (origen del mundo).
## Farolas (street-light) a los costados: sus LUMINARIAS son emisivas y, al ser
## píxeles brillantes, el post-proceso (sprint2_blur_test.gdshader) las convierte
## en halos/destellos según la lente. Algunas farolas cercanas llevan además un
## SpotLight real para iluminar la calzada (las lejanas solo emisivas: barato).
##
## Como el modelo de farola viene como una HILERA de varias farolas en una sola
## malla, se extrae un MÓDULO (corte en una ventana de Z alrededor de z=0) y se
## repite a la separación deseada, alineado a la ruta.
##
## Se instancia dentro de main.tscn (rig VR con post-proceso + lentes) vía el
## ScenarioManager. Corrido solo en PC, se autogenera cámara + entorno nocturno.

const ROAD_OBJ := "res://road2/source/road.obj"
const LAMP_OBJ := "res://street-light/source/Untitled_3/Untitled_3.obj"

@export_group("Carretera")
## Escala uniforme aplicada al modelo (mismo factor para ruta y farolas).
@export var scale_factor: float = 0.016
## Cantidad de tiles enlazados a lo largo de la ruta.
@export var tiles: int = 3

@export_group("Farolas")
## Separación entre farolas a lo largo de la ruta (metros de mundo).
@export var lamp_spacing_m: float = 12.0
## Energía emisiva de la luminaria. ALTA a propósito: con Filmic/AGX la luminaria
## debe quedar muy brillante para superar el umbral de halo (~0.72) y que el
## efecto de la lente aparezca sobre cada farola.
@export var lamp_emission: float = 18.0
## Radio (m) desde el paciente dentro del cual las farolas llevan SpotLight real.
@export var lamp_light_radius_m: float = 30.0
## Intensidad del SpotLight que ilumina la calzada.
@export var lamp_energy: float = 8.0
## Alcance del SpotLight.
@export var lamp_range_m: float = 16.0

# Ventana (en unidades de modelo) alrededor de z=0 para recortar UN módulo de
# farola de la hilera. El modelo tiene farolas cada ~2040 u; 180 aísla la de z≈0.
const LAMP_Z_WINDOW := 180.0
# Solo se conserva el lado derecho del modelo (x > esto) para tener UNA farola;
# luego se instancia espejada en ambos bordes de la calle.
const LAMP_X_MIN := -150.0
# Una superficie cuyo alto (Y) sea menor a esto es la LUMINARIA (cabezal), el
# resto es estructura metálica (poste/brazo). Calibrado con el AABB del modelo.
const HEAD_MAX_Y_SIZE := 100.0

var _road_mat: StandardMaterial3D
var _lamp_metal_mat: StandardMaterial3D
var _lamp_lum_mat: StandardMaterial3D
# Posición del cabezal (luminaria) en espacio de modelo, para anclar SpotLights.
var _head_local_positions: Array[Vector3] = []


func _ready() -> void:
	_build_materials()
	var lamp_mesh := _build_single_lamp_mesh()
	var road_mesh := load(ROAD_OBJ) as Mesh
	if road_mesh == null:
		push_warning("RutaNoche: no se pudo cargar la carretera.")
		return

	var road_aabb := road_mesh.get_aabb()
	var tile_len: float = road_aabb.size.z * scale_factor
	var road_half_x: float = road_aabb.size.x * 0.5 * scale_factor
	_spawn_road_tiles(road_mesh, tile_len)
	_spawn_moonlight()
	_spawn_lamps(lamp_mesh, tile_len, road_half_x)
	_spawn_traffic(tile_len, road_half_x)
	_setup_standalone_preview()


## Tráfico nocturno: separa los 10 autos del FBX y los hace circular por la ruta.
func _spawn_traffic(tile_len: float, road_half_x: float) -> void:
	var traffic := Node3D.new()
	traffic.name = "Traffic"
	traffic.set_script(load("res://features/scenarios/ruta_noche/ruta_traffic.gd"))
	traffic.set("road_half_z", tile_len * float(tiles) * 0.5)
	traffic.set("lane_x", road_half_x * 0.32)
	add_child(traffic)


## Luz de luna tenue (sin sombra) para que el asfalto sea apenas visible de noche
## sin lavar la escena. Las farolas siguen siendo las protagonistas.
func _spawn_moonlight() -> void:
	var moon := DirectionalLight3D.new()
	moon.name = "Moonlight"
	moon.light_color = Color(0.6, 0.7, 1.0)
	moon.light_energy = 0.18
	moon.shadow_enabled = false
	moon.rotation_degrees = Vector3(-60.0, 30.0, 0.0)
	add_child(moon)


# ----------------------------------------------------------------------
# Materiales
# ----------------------------------------------------------------------
func _build_materials() -> void:
	_road_mat = StandardMaterial3D.new()
	_road_mat.albedo_texture = load("res://road2/textures/road_Polygon_1_BaseColor.png")
	_road_mat.normal_enabled = true
	_road_mat.normal_texture = load("res://road2/textures/road_Polygon_1_Normal.png")
	_road_mat.roughness_texture = load("res://road2/textures/road_Polygon_1_Roughness.png")

	_lamp_metal_mat = StandardMaterial3D.new()
	_lamp_metal_mat.albedo_texture = load("res://street-light/textures/Untitled_1_DefaultMaterial_BaseColor.png")
	_lamp_metal_mat.metallic_texture = load("res://street-light/textures/Untitled_1_DefaultMaterial_Metallic.png")
	_lamp_metal_mat.roughness_texture = load("res://street-light/textures/Untitled_1_DefaultMaterial_Roughness.png")
	_lamp_metal_mat.normal_enabled = true
	_lamp_metal_mat.normal_texture = load("res://street-light/textures/Untitled_1_DefaultMaterial_Normal.png")

	# Luminaria: emisiva (em.png marca en blanco la zona que brilla). Es la fuente
	# de los halos: cuanto más alta la emisión, más supera el umbral del shader.
	_lamp_lum_mat = StandardMaterial3D.new()
	_lamp_lum_mat.albedo_texture = load("res://street-light/textures/BaseColor.png")
	_lamp_lum_mat.emission_enabled = true
	_lamp_lum_mat.emission_texture = load("res://street-light/textures/em.png")
	_lamp_lum_mat.emission_energy_multiplier = lamp_emission


# ----------------------------------------------------------------------
# Carretera
# ----------------------------------------------------------------------
func _spawn_road_tiles(road_mesh: Mesh, tile_len: float) -> void:
	# Tiles centrados: el tile del medio (índice (tiles-1)/2) queda en el origen,
	# donde está la cámara/paciente. Con tiles=3 -> el SEGUNDO tile en el centro.
	var half: float = float(tiles - 1) * 0.5
	for i in range(tiles):
		var tile := MeshInstance3D.new()
		tile.name = "RoadTile_%d" % i
		tile.mesh = road_mesh
		tile.scale = Vector3.ONE * scale_factor
		tile.material_override = _road_mat
		tile.position = Vector3(0.0, 0.0, (float(i) - half) * tile_len)
		add_child(tile)


# ----------------------------------------------------------------------
# Farolas
# ----------------------------------------------------------------------
## Extrae UNA farola (un solo lado) de la hilera del modelo: recorta los
## triángulos cuyo centroide cae en una ventana de Z alrededor de 0 y del lado
## derecho (x > LAMP_X_MIN). Recentra el módulo sobre la base del poste (origen),
## conserva normales/UV y separa en metal (poste/brazo) y luminaria (emisiva).
## Registra la posición del cabezal (recentrada) para anclar el SpotLight.
func _build_single_lamp_mesh() -> ArrayMesh:
	var src := load(LAMP_OBJ) as Mesh
	_head_local_positions.clear()
	if src == null:
		push_warning("RutaNoche: no se pudo cargar la farola.")
		return ArrayMesh.new()

	var metal := _new_buffers()
	var lum := _new_buffers()
	var head_sum := Vector3.ZERO
	var head_n := 0

	for s in range(src.get_surface_count()):
		var arr := src.surface_get_arrays(s)
		var sv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var sn: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var su: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if arr[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		var si: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()

		var mn := Vector3(1e18, 1e18, 1e18)
		var mx := -mn
		for v in sv:
			mn = mn.min(v); mx = mx.max(v)
		var is_head: bool = (mx.y - mn.y) < HEAD_MAX_Y_SIZE
		var target: Dictionary = lum if is_head else metal

		var tri_count: int = (si.size() if si.size() > 0 else sv.size()) / 3
		for t in range(tri_count):
			var a: int; var b: int; var c: int
			if si.size() > 0:
				a = si[t * 3]; b = si[t * 3 + 1]; c = si[t * 3 + 2]
			else:
				a = t * 3; b = t * 3 + 1; c = t * 3 + 2
			var centroid: Vector3 = (sv[a] + sv[b] + sv[c]) / 3.0
			# Solo el módulo de la farola de z≈0 y del lado derecho.
			if absf(centroid.z) > LAMP_Z_WINDOW or centroid.x < LAMP_X_MIN:
				continue
			for idx in [a, b, c]:
				target["v"].append(sv[idx])
				if sn.size() > 0:
					target["n"].append(sn[idx])
				if su.size() > 0:
					target["u"].append(su[idx])
			if is_head:
				head_sum += centroid
				head_n += 1

	# Recentrar sobre la base del poste: usar el centro XZ del metal (poste/brazo).
	var base := Vector3.ZERO
	var mv: PackedVector3Array = metal["v"]
	if mv.size() > 0:
		var c := Vector3.ZERO
		for v in mv:
			c += v
		c /= float(mv.size())
		base = Vector3(c.x, 0.0, c.z)
	_recenter(metal["v"], base)
	_recenter(lum["v"], base)
	if head_n > 0:
		_head_local_positions.append((head_sum / float(head_n)) - base)

	var am := ArrayMesh.new()
	_commit_surface(am, metal, _lamp_metal_mat)
	_commit_surface(am, lum, _lamp_lum_mat)
	return am


func _recenter(verts: PackedVector3Array, base: Vector3) -> void:
	for i in range(verts.size()):
		verts[i] = verts[i] - base


func _new_buffers() -> Dictionary:
	return {"v": PackedVector3Array(), "n": PackedVector3Array(), "u": PackedVector2Array()}


func _commit_surface(am: ArrayMesh, buf: Dictionary, mat: Material) -> void:
	var v: PackedVector3Array = buf["v"]
	if v.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	if buf["n"].size() == v.size():
		arrays[Mesh.ARRAY_NORMAL] = buf["n"]
	if buf["u"].size() == v.size():
		arrays[Mesh.ARRAY_TEX_UV] = buf["u"]
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	am.surface_set_material(am.get_surface_count() - 1, mat)


func _spawn_lamps(lamp_mesh: ArrayMesh, tile_len: float, road_half_x: float) -> void:
	if lamp_mesh.get_surface_count() == 0:
		return
	var total_len: float = tile_len * float(tiles)
	var count: int = int(total_len / lamp_spacing_m)
	if count < 1:
		count = 1
	var start_z: float = -total_len * 0.5 + lamp_spacing_m * 0.5
	# Postes en los bordes de la calle (el brazo recentrado apunta a +x, hacia el
	# centro). Lado derecho rotado 180° para que su brazo también apunte adentro.
	var edge_x: float = road_half_x * 0.92

	for i in range(count):
		var z: float = start_z + float(i) * lamp_spacing_m
		# Evitar plantar una farola justo encima de la cámara/paciente (origen).
		if absf(z) < 3.0:
			continue
		var with_light: bool = absf(z) <= lamp_light_radius_m
		# Hilera izquierda (brazo +x hacia el centro).
		_spawn_lamp_side(lamp_mesh, "izq_%d" % i, Vector3(-edge_x, 0.0, z), 0.0, with_light)
		# Hilera derecha (rotada 180°: brazo -x hacia el centro).
		_spawn_lamp_side(lamp_mesh, "der_%d" % i, Vector3(edge_x, 0.0, z), 180.0, with_light)


func _spawn_lamp_side(lamp_mesh: ArrayMesh, suffix: String, pos: Vector3,
		yaw_deg: float, with_light: bool) -> void:
	# Contenedor SIN escala: así el SpotLight hijo no hereda el 0.016 (escalar una
	# luz reduce su rango). La malla va escalada dentro.
	var root := Node3D.new()
	root.name = "Lamp_%s" % suffix
	root.position = pos
	root.rotation_degrees = Vector3(0.0, yaw_deg, 0.0)
	add_child(root)

	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = lamp_mesh
	mi.scale = Vector3.ONE * scale_factor
	root.add_child(mi)

	if not with_light:
		return
	for head_local in _head_local_positions:
		var light := SpotLight3D.new()
		light.light_color = Color(1.0, 0.95, 0.82)
		light.light_energy = lamp_energy
		light.spot_range = lamp_range_m
		light.spot_angle = 55.0
		light.spot_angle_attenuation = 1.0
		light.shadow_enabled = false
		light.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		light.position = head_local * scale_factor
		root.add_child(light)


# ----------------------------------------------------------------------
# Preview standalone (solo si NO corre dentro de main.tscn)
# ----------------------------------------------------------------------
func _setup_standalone_preview() -> void:
	if get_tree().get_first_node_in_group("xr_camera") != null:
		return  # dentro de main: el rig real maneja cámara y entorno.

	var cam := Camera3D.new()
	cam.name = "DebugCamera"
	cam.position = Vector3(0.0, 1.2, 0.0)
	cam.rotation_degrees = Vector3(-3.0, 0.0, 0.0)
	cam.current = true
	add_child(cam)

	var we := WorldEnvironment.new()
	we.name = "DebugEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.015, 0.015, 0.03)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.08, 0.09, 0.14)
	env.ambient_light_energy = 0.35
	env.glow_enabled = true
	env.glow_intensity = 0.8
	env.glow_bloom = 0.15
	env.glow_hdr_threshold = 1.2
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 0.6
	we.environment = env
	add_child(we)
