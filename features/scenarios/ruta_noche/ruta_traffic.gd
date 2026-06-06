extends Node3D
## RutaTraffic — tráfico nocturno para ruta_noche
##
## El FBX `autos/source/fab.fbx` trae 10 autos en una sola escena (carrocerías
## "* Body" + ruedas "Wheel_*" sueltas, en grilla, cada una a un yaw distinto).
## Este script:
##   1. Separa los 10 autos: agrupa cada carrocería con sus 4 ruedas (cercanía).
##   2. ORIENTA cada auto: el FRENTE (lado de los faros) se detecta porque los
##      PILOTOS (rojos en lights.jpg) están siempre atrás; el frente apunta en
##      sentido opuesto al centroide de los píxeles rojos. Se rota para que el
##      frente quede sobre +Z. Así ningún auto circula "en marcha atrás".
##   3. LUCES = la propia superficie de luces del modelo (la que usa lights.jpg),
##      hecha EMISIVA con esa misma textura. Así los faros/pilotos tienen la
##      FORMA y el COLOR reales (blanco adelante, rojo atrás), pegados al auto,
##      y el post-proceso los convierte en halos/destellos según la lente.
##   4. Tráfico continuo de hasta `max_cars` autos en dos carriles.
##
## Los autos van por el eje Z (la ruta). El paciente (origen) mira hacia -Z.

const FBX := "res://autos/source/fab.fbx"
const LIGHTS_TEX := "res://autos/textures/lights.jpg"

## Máximo de autos simultáneos (pocos y espaciados).
@export var max_cars: int = 3
## Mitad del largo de la ruta (límite de aparición/desaparición), en metros.
@export var road_half_z: float = 36.0
## Margen extra fuera de la ruta donde aparecen/desaparecen.
@export var spawn_margin: float = 8.0
## Offset lateral de los carriles respecto al centro.
@export var lane_x: float = 2.6
## Rango de velocidad (m/s).
@export var speed_min: float = 14.0
@export var speed_max: float = 22.0
## Segundos entre intentos de aparición (más alto = autos más espaciados).
@export var spawn_interval: float = 3.0
## Energía emisiva de las luces del auto. Alta porque la geometría real de los
## faros del modelo es pequeña: necesita brillar fuerte para superar el umbral de
## halo y que el efecto de la lente se note sobre ellos.
@export var car_light_emission: float = 24.0

var _templates: Array[Node3D] = []
var _active: Array = []          # [{node, speed, dir}]
var _spawn_timer: float = 0.0
var _lights_mat: StandardMaterial3D
var _lights_img: Image


func _ready() -> void:
	# Material emisivo de las luces, compartido por todos los autos: usa lights.jpg
	# como mapa de emisión (blanco -> faro blanco, rojo -> piloto rojo).
	var tex: Texture2D = load(LIGHTS_TEX)
	_lights_mat = StandardMaterial3D.new()
	_lights_mat.albedo_texture = tex
	_lights_mat.emission_enabled = true
	_lights_mat.emission = Color.WHITE
	_lights_mat.emission_texture = tex
	_lights_mat.emission_energy_multiplier = car_light_emission
	# Imagen (descomprimida) para detectar el frente por el color de los píxeles.
	if tex != null:
		_lights_img = tex.get_image()
		if _lights_img != null and _lights_img.is_compressed():
			_lights_img.decompress()
	_build_templates()


# ----------------------------------------------------------------------
# Separación + orientación de los 10 autos
# ----------------------------------------------------------------------
func _build_templates() -> void:
	var ps := load(FBX) as PackedScene
	if ps == null:
		push_warning("RutaTraffic: no se pudo cargar el FBX de autos.")
		return
	var inst := ps.instantiate()

	var bodies: Array[MeshInstance3D] = []
	var wheels: Array[MeshInstance3D] = []
	for n in inst.get_children():
		var mi := n as MeshInstance3D
		if mi == null:
			continue
		var nm := String(mi.name).to_lower()
		if nm.ends_with("body"):
			bodies.append(mi)
		elif nm.begins_with("wheel"):
			wheels.append(mi)

	# Asignar cada rueda a la carrocería más cercana (en XZ).
	var groups: Dictionary = {}
	for b in bodies:
		groups[b] = []
	for w in wheels:
		var best: MeshInstance3D = null
		var best_d := INF
		for b in bodies:
			var d: float = Vector2(w.position.x - b.position.x, w.position.z - b.position.z).length_squared()
			if d < best_d:
				best_d = d; best = b
		if best != null:
			groups[best].append(w)

	for b in bodies:
		var car := Node3D.new()
		car.name = String(b.name).replace(" ", "_")
		var center: Vector3 = b.position
		var pivot := Node3D.new()
		pivot.name = "Body"
		pivot.rotation.y = _front_yaw(b, center, groups[b])
		car.add_child(pivot)
		var body_mi := _copy_mesh_into(pivot, b, center)
		_make_lights_emissive(body_mi)
		for w in groups[b]:
			_copy_mesh_into(pivot, w, center)
		_templates.append(car)

	inst.free()
	print("RutaTraffic: %d autos separados." % _templates.size())


## Índice de la superficie de luces (la que usa lights.jpg) en la malla, o -1.
func _lights_surface(mi: MeshInstance3D) -> int:
	var m: Mesh = mi.mesh
	for i in range(m.get_surface_count()):
		var mat := mi.get_active_material(i) as StandardMaterial3D
		if mat != null and mat.albedo_texture != null \
				and mat.albedo_texture.resource_path.ends_with("lights.jpg"):
			return i
	return -1


## Yaw (Y) para que el FRENTE del auto quede sobre +Z.
## El EJE del largo lo da el PCA de las ruedas (siempre confiable). El SENTIDO
## (cuál extremo es el frente) se decide proyectando, sobre ese eje, los píxeles
## BLANCOS (faros) vs ROJOS (pilotos) de lights.jpg: el frente es el extremo
## donde predomina el blanco. Robusto aunque haya luces de reversa blancas atrás.
func _front_yaw(body: MeshInstance3D, center: Vector3, wheels: Array) -> float:
	# El LARGO del auto es el eje LOCAL MÁS LARGO de la malla (casi todos en Y,
	# pero p.ej. el Coupe está modelado con el largo en X). Llevado a mundo por el
	# basis de la carrocería da la dirección del largo, robusto y consistente.
	var sz: Vector3 = body.mesh.get_aabb().size
	var local_len := Vector3(0.0, 1.0, 0.0)
	if sz.x >= sz.y and sz.x >= sz.z:
		local_len = Vector3(1.0, 0.0, 0.0)
	elif sz.z >= sz.x and sz.z >= sz.y:
		local_len = Vector3(0.0, 0.0, 1.0)
	var ydir: Vector3 = body.transform.basis * local_len
	var axis := Vector2(ydir.x, ydir.z)
	if axis.length() < 0.1:
		axis = _wheel_axis(wheels, center)   # fallback si +Y quedó vertical
	if axis.length() < 0.001:
		return 0.0
	axis = axis.normalized()
	var s := _front_sign(body, center, axis)
	var fwd := axis * s
	return atan2(fwd.y, fwd.x) - PI * 0.5


## +1 si el frente coincide con +axis, -1 si es -axis. Proyecta verts blancos y
## rojos de la superficie de luces sobre el eje; el frente está donde el blanco
## se proyecta más adelante que el rojo.
func _front_sign(body: MeshInstance3D, center: Vector3, axis: Vector2) -> float:
	var li := _lights_surface(body)
	if li < 0 or _lights_img == null:
		return 1.0
	var arr: Array = body.mesh.surface_get_arrays(li)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
	var w := _lights_img.get_width()
	var h := _lights_img.get_height()
	var white_sum := 0.0; var white_n := 0
	var red_sum := 0.0; var red_n := 0
	for i in range(verts.size()):
		var uv: Vector2 = uvs[i]
		var px := int(clamp(fposmod(uv.x, 1.0) * w, 0, w - 1))
		var py := int(clamp(fposmod(uv.y, 1.0) * h, 0, h - 1))
		var col: Color = _lights_img.get_pixel(px, py)
		var rel: Vector3 = (body.transform * verts[i]) - center
		var proj: float = rel.x * axis.x + rel.z * axis.y   # posición a lo largo del eje
		if col.r > 0.45 and col.r - max(col.g, col.b) > 0.22:        # rojo = piloto (atrás)
			red_sum += proj; red_n += 1
		elif col.r > 0.5 and col.g > 0.5 and col.b > 0.45:           # blanco = faro (frente)
			white_sum += proj; white_n += 1
	if white_n > 0 and red_n > 0:
		var mw := white_sum / float(white_n)
		var mr := red_sum / float(red_n)
		return 1.0 if mw >= mr else -1.0
	if red_n > 0:
		return -1.0 if (red_sum / float(red_n)) >= 0.0 else 1.0   # frente lejos del rojo
	return 1.0


## Eje principal de las 4 ruedas ASIGNADAS a este auto (dirección del largo).
func _wheel_axis(wheels: Array, center: Vector3) -> Vector2:
	var sxx := 0.0; var szz := 0.0; var sxz := 0.0
	for w in wheels:
		var mi := w as MeshInstance3D
		if mi == null:
			continue
		var dx: float = mi.position.x - center.x
		var dz: float = mi.position.z - center.z
		sxx += dx * dx; szz += dz * dz; sxz += dx * dz
	var theta := 0.5 * atan2(2.0 * sxz, sxx - szz)
	# Asegurar el eje de MAYOR varianza (el LARGO del auto, no el ancho): si la
	# varianza perpendicular es mayor, girar 90°. (Sin esto el auto sale de costado.)
	var ct := cos(theta); var st := sin(theta)
	var v_along := sxx * ct * ct + 2.0 * sxz * ct * st + szz * st * st
	var v_perp := sxx * st * st - 2.0 * sxz * ct * st + szz * ct * ct
	if v_along < v_perp:
		theta += PI * 0.5
	return Vector2(cos(theta), sin(theta))


## Convierte la superficie de luces del modelo en EMISIVA (forma y color reales).
func _make_lights_emissive(body_mi: MeshInstance3D) -> void:
	if body_mi == null:
		return
	var li := _lights_surface(body_mi)
	if li >= 0:
		body_mi.set_surface_override_material(li, _lights_mat)


## Copia un MeshInstance3D (malla + materiales + transform) dentro de `parent`,
## trasladado para que `center` quede en el origen del auto. Devuelve la copia.
func _copy_mesh_into(parent: Node3D, src: MeshInstance3D, center: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = src.mesh
	mi.transform = src.transform
	mi.position = src.position - center
	if src.mesh != null:
		for i in range(src.mesh.get_surface_count()):
			mi.set_surface_override_material(i, src.get_active_material(i))
	parent.add_child(mi)
	return mi


# ----------------------------------------------------------------------
# Tráfico
# ----------------------------------------------------------------------
func _process(delta: float) -> void:
	if _templates.is_empty():
		return

	var limit := road_half_z + spawn_margin
	for i in range(_active.size() - 1, -1, -1):
		var car: Dictionary = _active[i]
		var node: Node3D = car["node"]
		node.position.z += car["speed"] * car["dir"] * delta
		if absf(node.position.z) > limit:
			node.queue_free()
			_active.remove_at(i)

	_spawn_timer += delta
	if _spawn_timer >= spawn_interval and _active.size() < max_cars:
		_spawn_timer = 0.0
		_spawn_car()


func _spawn_car() -> void:
	var tmpl: Node3D = _templates[randi() % _templates.size()]
	var node: Node3D = tmpl.duplicate()

	# Carril + dirección: izquierda viene hacia el paciente (+Z), derecha se aleja (-Z).
	var oncoming := randf() < 0.5
	var dir := 1.0 if oncoming else -1.0
	var x := -lane_x if oncoming else lane_x
	var start_z := -(road_half_z + spawn_margin) if oncoming else (road_half_z + spawn_margin)
	node.position = Vector3(x, 0.0, start_z)
	# El frente (+Z local) mira al sentido de avance: oncoming +Z (sin rotar),
	# el que se aleja -Z (rotado 180°). El frente real ya quedó sobre +Z.
	node.rotation_degrees = Vector3(0.0, 0.0 if oncoming else 180.0, 0.0)

	add_child(node)
	_active.append({
		"node": node,
		"speed": randf_range(speed_min, speed_max),
		"dir": dir,
	})
