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

const ROAD_OBJ := "res://assets/scenarios/ruta_noche/road2/source/road.obj"
const LAMP_OBJ := "res://assets/scenarios/ruta_noche/street-light/source/Untitled_3/Untitled_3.obj"
const CAR_MODEL := "res://assets/scenarios/ruta_noche/auto-nuevo/interior.fbx"

@export_group("Carretera")
## Escala uniforme aplicada al modelo (mismo factor para ruta y farolas).
@export var scale_factor: float = 0.016
## Cantidad de tiles enlazados a lo largo de la ruta.
@export var tiles: int = 3
## Brillo propio (emisión) de las marcas viales (línea central punteada + bordes)
## para que se vean a lo largo de TODA la ruta de noche, no solo las primeras: el
## asfalto lejano queda muy oscuro y los guiones desaparecían tras el tercero.
## 0 = sin autoiluminación. Solo afecta a las marcas blancas (ver máscara abajo).
@export var line_emission: float = 0.6

@export_group("Farolas")
## Separación entre farolas a lo largo de la ruta (metros de mundo).
@export var lamp_spacing_m: float = 12.0
## Energía emisiva de la luminaria. ALTA a propósito: con Filmic/AGX la luminaria
## debe quedar muy brillante para superar el umbral de halo (~0.72) y que el
## efecto de la lente aparezca sobre cada farola.
@export var lamp_emission: float = 18.0
## Radio (m) desde el paciente dentro del cual las farolas llevan SpotLight real.
@export var lamp_light_radius_m: float = 30.0
## Solo las farolas DELANTE del paciente (que mira a -Z) llevan SpotLight real.
## Las de atrás conservan su cabezal emisivo (siguen brillando + bloom), pero no
## gastan una luz en tiempo real iluminando asfalto fuera de la vista de conducción.
## Optimización Quest: ~50% menos luces real-time sin afectar la vista al frente.
@export var lamp_lights_only_ahead: bool = true
## Intensidad del SpotLight que ilumina la calzada.
@export var lamp_energy: float = 8.0
## Alcance del SpotLight.
@export var lamp_range_m: float = 16.0

@export_group("Auto del conductor")
## Escala uniforme del modelo del auto. El modelo viene a ~0.6× de un auto real;
## ~1.5 lo lleva a proporciones reales (ancho de cabina ~1.6 m) para que un
## usuario sentado quepa cómodo. Es la CABINA interior (tablero, volante, consola,
## displays): modelo "simple", sin techo/pilares/vidrios/puertas.
@export var car_scale: float = 1.5
## Punto del MODELO (m, sin escalar) que representa el OJO del conductor. El auto
## se posiciona para que este punto caiga SOBRE el paciente (origen) en horizontal
## y el ojo quede a ~0.97 m del asfalto (a esta escala). Derivado de la geometría:
## volante en (-0.17, 0.52, -0.27). El frente mira a -Z, así que +X = derecha:
## subir X corre la cámara a la derecha; bajar Y baja la cámara. Conducción IZQ.
@export var driver_eye_local: Vector3 = Vector3(-0.13, 0.72, 0.0)

@export_subgroup("Luz del tablero (torpedo)")
## Luz suave que ilumina el tablero/torpedo para verlo de noche sin quemar la escena.
@export var dash_light_enabled: bool = true
## Energía de la luz del tablero (suave: no debe lavar la calzada ni disparar halos).
@export var dash_light_energy: float = 2.0
## Alcance (m) de la luz del tablero (corto: que quede sobre el torpedo).
@export var dash_light_range_m: float = 1.4
## Color de la luz del tablero (cálido, tipo iluminación de cabina).
@export var dash_light_color: Color = Color(1.0, 0.93, 0.82)
## Posición de la luz RELATIVA al ojo del conductor (m, espacio mundo):
## +x derecha, +y arriba, -z adelante (hacia el torpedo).
@export var dash_light_offset: Vector3 = Vector3(0.22, -0.02, -0.42)

# Piso del modelo del auto (AABB y-min en espacio de modelo): se apoya sobre el
# asfalto (y=0). Medido del modelo (min y = 0.0718).
const CAR_FLOOR_LOCAL_Y := 0.0718
# Altura cabeza-sobre-asiento que usa main.gd (_position_rig_for_scenario) para
# recentrar el HMD sobre el marker "SeatSpawn". DEBE coincidir con
# main.gd:SEATED_HEAD_ABOVE_SEAT (0.77).
const SEATED_HEAD_ABOVE_SEAT := 0.77

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


# TEST TEMPORAL: true = escena noche MÍNIMA (1 farola + 1 auto pasando, cabina del
# jugador oculta) para diagnosticar el dentado con la escena casi vacía. Poner en
# false para volver a la escena completa normal.
const TEST_MINIMAL_NIGHT := false


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
	# === TEST TEMPORAL: dejar SOLO el auto del conductor ===
	# Saltea ruta, faroles y tráfico para ver si con la escena casi vacía mejora la
	# nitidez/dentado (libera GPU => el visor sube la resolución). Mantiene la luna y
	# la luz del tablero para que la cabina se vea. Poner en false para volver atrás.
	_spawn_moonlight()
	if not TEST_MINIMAL_NIGHT:
		_spawn_road_tiles(road_mesh, tile_len)
	_spawn_lamps(lamp_mesh, tile_len, road_half_x)
	_spawn_traffic(tile_len, road_half_x)
	_spawn_car()
	_setup_standalone_preview()
	if TEST_MINIMAL_NIGHT:
		print("TEST: ruta_noche MÍNIMA (1 farola + 1 auto, SIN ruta ni cabina)")


## Tráfico nocturno: separa los 10 autos del FBX y los hace circular por la ruta.
func _spawn_traffic(tile_len: float, road_half_x: float) -> void:
	var traffic := Node3D.new()
	traffic.name = "Traffic"
	traffic.set_script(load("res://features/scenarios/ruta_noche/ruta_traffic.gd"))
	traffic.set("road_half_z", tile_len * float(tiles) * 0.5)
	traffic.set("lane_x", road_half_x * 0.32)
	if TEST_MINIMAL_NIGHT:
		traffic.set("max_cars", 1)  # un solo auto pasando a la vez
	add_child(traffic)


## Auto del conductor: el paciente "maneja" desde adentro. El modelo ya mira a -Z
## (el frente/tablero apunta a -Z), igual que el paciente, así que NO se rota. Se
## escala a proporciones reales (ver car_scale) y se ubica para que el ASIENTO DEL
## CONDUCTOR (lado izquierdo, detrás del volante) quede SOBRE el origen del mundo
## —donde ya está el paciente— con el piso de la cabina sobre el asfalto. El
## paciente conserva su ubicación actual: solo se arma el auto a su alrededor.
func _spawn_car() -> void:
	var packed := load(CAR_MODEL) as PackedScene
	if packed == null:
		push_warning("RutaNoche: no se pudo cargar el auto (%s)." % CAR_MODEL)
		return
	var car := packed.instantiate() as Node3D
	if car == null:
		push_warning("RutaNoche: el auto no instanció un Node3D.")
		return
	car.name = "Car"
	car.scale = Vector3.ONE * car_scale
	# Sin rotación (el frente ya apunta a -Z). Traslación tal que el ojo del
	# conductor quede en (0, *, 0) horizontal y el piso del auto sobre y=0:
	#   pos = -scale * eye    (en X,Z; lleva el ojo al origen)
	#   pos.y = -scale * piso (apoya la cabina sobre el asfalto)
	car.position = Vector3(
		-car_scale * driver_eye_local.x,
		-car_scale * CAR_FLOOR_LOCAL_Y,
		-car_scale * driver_eye_local.z)
	add_child(car)
	if TEST_MINIMAL_NIGHT:
		car.visible = false  # ocultar la cabina del jugador (test mínimo)

	# Apagar cualquier luz que traiga el modelo: de noche una luz embebida (p.ej.
	# el GLB anterior traía un point light de intensidad ~54000) quemaría la
	# imagen. La iluminación la dan la luna + las farolas; la cabina queda en
	# penumbra realista. (Este FBX no trae luces, pero queda robusto ante cambios.)
	for light in car.find_children("*", "Light3D", true, false):
		light.queue_free()

	# Filtrado ANISOTRÓPICO en los materiales del auto. El tablero/CarPlay se ven
	# en ángulo oblicuo desde el asiento; con el filtro lineal simple del FBX las
	# texturas quedan borrosas a distancia y solo nítidas pegado (se nota incluso
	# SIN lentes). El anisotrópico mantiene la nitidez en superficies inclinadas.
	# Materiales compartidos entre mallas -> dedup para no reasignar de más.
	var seen_mats := {}
	for node in car.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for s in range(mi.mesh.get_surface_count()):
			var bm := mi.mesh.surface_get_material(s) as BaseMaterial3D
			if bm != null and not seen_mats.has(bm):
				seen_mats[bm] = true
				bm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

	# Marker para que el rig VR (main.gd) recentre la CABEZA del usuario en la
	# posición del CONDUCTOR, sin importar su altura física ni la de su silla
	# (igual mecanismo que la silla del consultorio). El ojo del conductor queda
	# en y = scale·(eye.y - piso); el marker va 0.77 m por debajo (SEATED_HEAD_
	# ABOVE_SEAT) y en x,z = 0, así el paciente CONSERVA su ubicación (centro de
	# la ruta) y sólo se fija su pose dentro del auto.
	var driver_eye_world_y := car_scale * (driver_eye_local.y - CAR_FLOOR_LOCAL_Y)
	var seat := Marker3D.new()
	seat.name = "SeatSpawn"
	seat.position = Vector3(0.0, driver_eye_world_y - SEATED_HEAD_ABOVE_SEAT, 0.0)
	add_child(seat)

	# Luz suave del tablero (torpedo): omni de alcance corto sobre el salpicadero
	# para verlo de noche. Va en la ESCENA (sin escala) para que su alcance NO
	# herede el ×1.5 del auto. Energía baja para no lavar la calzada ni disparar
	# el halo del post-proceso (umbral nocturno 0.72). Posición = ojo + offset.
	if dash_light_enabled and not TEST_MINIMAL_NIGHT:
		var dash := OmniLight3D.new()
		dash.name = "DashLight"
		dash.light_color = dash_light_color
		dash.light_energy = dash_light_energy
		dash.omni_range = dash_light_range_m
		dash.shadow_enabled = false
		dash.position = Vector3(0.0, driver_eye_world_y, 0.0) + dash_light_offset
		add_child(dash)


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
	# Filtro anisotrópico: la calzada se ve en ángulo MUY rasante (se extiende al
	# horizonte). Sin anisotropía, las texturas/líneas en la lejanía aliasean y
	# "caminan". Con mipmaps (ya habilitados en el import) + anisotrópico, las marcas
	# viales y el asfalto lejano quedan estables.
	_road_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_road_mat.albedo_texture = load("res://assets/scenarios/ruta_noche/road2/textures/road_Polygon_1_BaseColor.png")
	_road_mat.normal_enabled = true
	_road_mat.normal_texture = load("res://assets/scenarios/ruta_noche/road2/textures/road_Polygon_1_Normal.png")
	_road_mat.roughness_texture = load("res://assets/scenarios/ruta_noche/road2/textures/road_Polygon_1_Roughness.png")

	# Marcas viales autoiluminadas: de noche el asfalto lejano queda muy oscuro y la
	# línea central se perdía tras el tercer guión. Una máscara que solo prende los
	# píxeles BLANCOS de la textura (línea central + bordes; generada offline desde
	# el BaseColor con min(r,g,b)>0.55 -> road_line_emission_mask.png) hace que esas
	# marcas brillen y se vean a lo largo de toda la ruta, SIN levantar el asfalto.
	# EMISSION_OP_MULTIPLY es clave: la emisión = color*energía*máscara, así el
	# asfalto (máscara=0) no emite. En ADD (default) el color se sumaría a TODA la
	# superficie y lavaría la calzada entera.
	if line_emission > 0.0:
		_road_mat.emission_enabled = true
		_road_mat.emission_texture = load("res://assets/scenarios/ruta_noche/road2/textures/road_line_emission_mask.png")
		_road_mat.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
		# Gris (no blanco puro): la pintura vial luce desgastada/realista de noche y
		# no "relumbra". El brillo final = este color * line_emission.
		_road_mat.emission = Color(0.6, 0.6, 0.6)
		_road_mat.emission_energy_multiplier = line_emission

	_lamp_metal_mat = StandardMaterial3D.new()
	_lamp_metal_mat.albedo_texture = load("res://assets/scenarios/ruta_noche/street-light/textures/Untitled_1_DefaultMaterial_BaseColor.png")
	_lamp_metal_mat.metallic_texture = load("res://assets/scenarios/ruta_noche/street-light/textures/Untitled_1_DefaultMaterial_Metallic.png")
	_lamp_metal_mat.roughness_texture = load("res://assets/scenarios/ruta_noche/street-light/textures/Untitled_1_DefaultMaterial_Roughness.png")
	_lamp_metal_mat.normal_enabled = true
	_lamp_metal_mat.normal_texture = load("res://assets/scenarios/ruta_noche/street-light/textures/Untitled_1_DefaultMaterial_Normal.png")

	# Luminaria: emisiva (em.png marca en blanco la zona que brilla). Es la fuente
	# de los halos: cuanto más alta la emisión, más supera el umbral del shader.
	_lamp_lum_mat = StandardMaterial3D.new()
	_lamp_lum_mat.albedo_texture = load("res://assets/scenarios/ruta_noche/street-light/textures/BaseColor.png")
	_lamp_lum_mat.emission_enabled = true
	_lamp_lum_mat.emission_texture = load("res://assets/scenarios/ruta_noche/street-light/textures/em.png")
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
	# Ancla del glare: centroide del cabezal ponderado por la textura EMISIVA
	# (em.png). El cabezal entero mide ~2 m a lo largo del brazo pero solo la
	# punta brilla: el centroide geometrico puro dejaba el halo corrido ~0.56 m
	# hacia el poste respecto de la luz visible. Fallback sin ponderar si la
	# textura no se puede muestrear (p.ej. compresion sin decode en el device).
	var em_img: Image = null
	var em_tex := _lamp_lum_mat.emission_texture as Texture2D
	if em_tex != null:
		em_img = em_tex.get_image()
		if em_img != null and em_img.is_compressed():
			if em_img.decompress() != OK:
				em_img = null
	var head_sum := Vector3.ZERO
	var head_n := 0
	var em_sum := Vector3.ZERO
	var em_w := 0.0

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
				if em_img != null and su.size() > 0:
					var uvc: Vector2 = (su[a] + su[b] + su[c]) / 3.0
					var e := em_img.get_pixel(
						clampi(int(uvc.x * float(em_img.get_width())), 0, em_img.get_width() - 1),
						clampi(int(uvc.y * float(em_img.get_height())), 0, em_img.get_height() - 1)).r
					var area := (sv[b] - sv[a]).cross(sv[c] - sv[a]).length() * 0.5
					em_sum += centroid * (e * area)
					em_w += e * area

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
	if em_w > 0.001:
		_head_local_positions.append((em_sum / em_w) - base)
	elif head_n > 0:
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

	# Reunir TODAS las ubicaciones primero, para dimensionar el MultiMesh.
	# Cada entrada: {pos, yaw, light}.
	var placements: Array[Dictionary] = []
	if TEST_MINIMAL_NIGHT:
		# UNA sola farola adelante del jugador (con su SpotLight), nada más.
		placements.append({"pos": Vector3(-edge_x, 0.0, -12.0), "yaw": 0.0, "light": true})
	else:
		for i in range(count):
			var z: float = start_z + float(i) * lamp_spacing_m
			# Evitar plantar una farola justo encima de la cámara/paciente (origen).
			if absf(z) < 3.0:
				continue
			# El paciente mira a -Z: "delante" = z negativo (margen chico para no
			# encender la farola apenas detrás del hombro). Las de atrás quedan
			# emisivas sin SpotLight -> ahorro de luces real-time en Quest.
			var ahead: bool = z <= 2.0
			var with_light: bool = absf(z) <= lamp_light_radius_m \
				and (ahead or not lamp_lights_only_ahead)
			# Hilera izquierda (brazo +x hacia el centro) y derecha (rotada 180°).
			placements.append({"pos": Vector3(-edge_x, 0.0, z), "yaw": 0.0, "light": with_light})
			placements.append({"pos": Vector3(edge_x, 0.0, z), "yaw": 180.0, "light": with_light})

	if placements.is_empty():
		return

	# UN MultiMesh para TODAS las farolas: colapsa N draw calls (una por farola y por
	# superficie) en solo surface_count (metal + luminaria) draw calls instanciados.
	# Es la optimización de draw calls clave de la escena en Quest. Malla, glare y
	# SpotLights quedan idénticos: solo cambia CÓMO se emite la geometría repetida. La
	# luminaria sigue siendo emisiva (alimenta el glow/bloom); el glare por lente lo
	# ponen los billboards de GlareSource (abajo), igual que antes.
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = lamp_mesh
	mm.instance_count = placements.size()
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Lamps"
	mmi.multimesh = mm
	add_child(mmi)

	for i in range(placements.size()):
		var p: Dictionary = placements[i]
		var pos: Vector3 = p["pos"]
		var yaw: float = p["yaw"]
		# La malla se escalaba con scale_factor en un hijo; ahora va en la transform de
		# la instancia (escala uniforme => el orden rotación/escala es indistinto).
		var basis := Basis(Vector3.UP, deg_to_rad(yaw)).scaled(Vector3.ONE * scale_factor)
		mm.set_instance_transform(i, Transform3D(basis, pos))
		_spawn_lamp_fixtures(pos, yaw, p["light"])


func _spawn_lamp_fixtures(pos: Vector3, yaw_deg: float, with_light: bool) -> void:
	# La GEOMETRÍA la dibuja el MultiMesh; aca van solo los nodos que necesitan
	# posición propia: el glare por lente (todas las farolas) y el SpotLight real
	# (solo las cercanas). Contenedor SIN escala: el SpotLight no debe heredar el
	# 0.016 (escalar una luz reduce su rango). Replica la transform del root anterior.
	var root := Node3D.new()
	root.name = "LampFixtures"
	root.position = pos
	root.rotation_degrees = Vector3(0.0, yaw_deg, 0.0)
	add_child(root)

	# Glare procedural en cada cabezal (TODAS las farolas, tambien las
	# emisivas sin SpotLight): el halo/starburst por lente vive aca, no en
	# el post-proceso (los mips del backbuffer no existen en Quest).
	for head_local in _head_local_positions:
		GlareSource.attach(root, head_local * scale_factor,
				Color(1.0, 0.95, 0.82), 0.85)

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
	# A la altura del ojo del conductor (mismo punto que recentra el rig VR), para
	# que el preview en PC muestre la POV del conductor.
	var eye_y := car_scale * (driver_eye_local.y - CAR_FLOOR_LOCAL_Y)
	cam.position = Vector3(0.0, eye_y, 0.0)
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
