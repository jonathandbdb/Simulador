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

## Modelos cuyo frente la detección automática deja al revés (frente y trasera
## casi idénticos). Se les fuerza un giro de 180°. Clave = substring del nombre.
const FRONT_FLIP := {"coupe": true}

## Modelos que NO se spawnean: su faro delantero está pintado en la textura del
## cuerpo (sin geometría de luz frontal real), así que de frente no deslumbran.
## Se excluyen del tráfico hasta resolver esos faros. Clave = substring del nombre.
const SKIP_MODELS := {"sport": true, "compact": true}

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
var _headlight_mat: StandardMaterial3D   # frente: blanco
var _taillight_mat: StandardMaterial3D   # atrás: rojo forzado
var _hidden_mat: StandardMaterial3D      # oculta la superficie de luces original
var _lights_img: Image


func _ready() -> void:
	var tex: Texture2D = load(LIGHTS_TEX)
	# Frente: emisión BLANCA con la textura como máscara de forma (faros blancos).
	_headlight_mat = _emissive(tex, Color.WHITE, car_light_emission)
	# Atrás: emisión ROJA FORZADA. emission_color rojo MULTIPLICA la textura: el
	# verde/azul del pixel (que con energía alta desaturaban el piloto a blanco)
	# quedan ~0 -> rojo puro, sin importar que la textura del piloto sea clara o
	# tenga luz de reversa blanca. La textura sigue dando la FORMA del piloto.
	_taillight_mat = _emissive(tex, Color(1.0, 0.04, 0.03), car_light_emission * 0.8)
	# Oculta la superficie de luces original del modelo (la reemplaza el split).
	_hidden_mat = StandardMaterial3D.new()
	_hidden_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hidden_mat.albedo_color = Color(0.0, 0.0, 0.0, 0.0)
	# Imagen (descomprimida) para detectar el frente por el color de los píxeles.
	if tex != null:
		_lights_img = tex.get_image()
		if _lights_img != null and _lights_img.is_compressed():
			_lights_img.decompress()
	_build_templates()


func _emissive(tex: Texture2D, color: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.emission_enabled = true
	m.emission = color
	m.emission_texture = tex
	m.emission_energy_multiplier = energy
	return m


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
		# Saltar los modelos excluidos (faros delanteros pintados, no geométricos).
		var bname := String(b.name).to_lower()
		var skip := false
		for key in SKIP_MODELS:
			if bname.contains(key):
				skip = true
				break
		if skip:
			continue

		var car := Node3D.new()
		car.name = String(b.name).replace(" ", "_")
		# Recentrar SOLO en X/Z por el centro geométrico de la carrocería (el origen
		# del nodo de varios modelos está desplazado y los dejaba "corridos" fuera
		# del carril). El eje Y se mantiene en el origen del nodo: centrar también
		# en Y hundía los autos medio cuerpo bajo el asfalto (las ruedas deben
		# quedar sobre la calzada, no el centro del auto en el piso).
		var gc: Vector3 = b.transform * b.mesh.get_aabb().get_center()
		var center: Vector3 = Vector3(gc.x, b.position.y, gc.z)
		var pivot := Node3D.new()
		pivot.name = "Body"
		pivot.rotation.y = _front_yaw(b, center, groups[b])
		car.add_child(pivot)
		var body_mi := _copy_mesh_into(pivot, b, center)
		_split_car_lights(body_mi, pivot)
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
	# EJE DEL LARGO: el tren de ruedas lo define con precisión (las 4 ruedas en las
	# esquinas). Es el método primario. El "eje más largo del AABB" falla cuando la
	# malla está rotada dentro de su espacio local (p.ej. el Coupe ~15°), así que
	# queda solo como fallback si faltan ruedas.
	var axis := _wheel_axis(wheels)
	if axis.length() < 0.001:
		var sz: Vector3 = body.mesh.get_aabb().size
		var local_len := Vector3(0.0, 1.0, 0.0)
		if sz.x >= sz.y and sz.x >= sz.z:
			local_len = Vector3(1.0, 0.0, 0.0)
		elif sz.z >= sz.x and sz.z >= sz.y:
			local_len = Vector3(0.0, 0.0, 1.0)
		var ydir: Vector3 = body.transform.basis * local_len
		axis = Vector2(ydir.x, ydir.z)
	if axis.length() < 0.001:
		return 0.0
	axis = axis.normalized()
	var s := _front_sign(body, center, axis)
	# Override por modelo: en algunos modelos estilizados (frente y trasera casi
	# idénticos, p.ej. el Coupe) la detección automática queda invertida. Se gira
	# 180° forzado; como el split de luces se recalcula con la orientación final,
	# faros y pilotos se invierten JUNTO con la carrocería.
	for key in FRONT_FLIP:
		if String(body.name).to_lower().contains(key):
			s = -s
			break
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


## Eje principal (dirección del LARGO) de las ruedas asignadas, vía PCA medido
## desde el CENTROIDE de las ruedas (translation-invariant). Devuelve (0,0) si
## hay menos de 3 ruedas (entonces _front_yaw usa el fallback del AABB).
func _wheel_axis(wheels: Array) -> Vector2:
	# Centroide de las ruedas.
	var c := Vector2.ZERO
	var n := 0
	for w in wheels:
		var mi := w as MeshInstance3D
		if mi == null:
			continue
		c += Vector2(mi.position.x, mi.position.z)
		n += 1
	if n < 3:
		return Vector2.ZERO
	c /= float(n)
	var sxx := 0.0; var szz := 0.0; var sxz := 0.0
	for w in wheels:
		var mi := w as MeshInstance3D
		if mi == null:
			continue
		var dx: float = mi.position.x - c.x
		var dz: float = mi.position.z - c.y
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


## Separa la superficie de luces del modelo en FRENTE (faros, +Z) y ATRÁS
## (pilotos, -Z) según el eje del auto, y crea una malla de 2 superficies: faros
## blancos y pilotos ROJOS forzados. Así los pilotos son siempre rojos aunque la
## textura del modelo los tenga claros. Oculta la superficie de luces original.
func _split_car_lights(body_mi: MeshInstance3D, pivot: Node3D) -> void:
	if body_mi == null:
		return
	var li := _lights_surface(body_mi)
	if li < 0:
		return
	var arr: Array = body_mi.mesh.surface_get_arrays(li)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if arr[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()

	# Transform a espacio FINAL del auto (frente = +Z) para clasificar triángulos.
	var m: Transform3D = pivot.transform * body_mi.transform
	var pivot_inv: Transform3D = pivot.transform.inverse()
	var front := _new_lbuf()
	var back := _new_lbuf()
	# Centroides por cluster (frente/atrás × derecha/izquierda en espacio final)
	# para anclar un billboard de glare a CADA luz fisica del auto.
	var csum: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	var cn: Array[int] = [0, 0, 0, 0]
	var tri_count: int = (idx.size() if idx.size() > 0 else verts.size()) / 3
	for tri in range(tri_count):
		var a: int; var b2: int; var c: int
		if idx.size() > 0:
			a = idx[tri * 3]; b2 = idx[tri * 3 + 1]; c = idx[tri * 3 + 2]
		else:
			a = tri * 3; b2 = tri * 3 + 1; c = tri * 3 + 2
		var centroid: Vector3 = (verts[a] + verts[b2] + verts[c]) / 3.0
		var fpos: Vector3 = m * centroid
		var is_front: bool = fpos.z >= 0.0
		var t: Dictionary = front if is_front else back
		var ci: int = (0 if is_front else 2) + (0 if fpos.x >= 0.0 else 1)
		# Acumular en espacio del PIVOT (donde se cuelga el billboard).
		csum[ci] += pivot_inv * fpos
		cn[ci] += 1
		for vi in [a, b2, c]:
			t["v"].append(verts[vi])
			if norms.size() > 0:
				t["n"].append(norms[vi])
			if uvs.size() > 0:
				t["u"].append(uvs[vi])

	var am := ArrayMesh.new()
	_commit_lbuf(am, front, _headlight_mat)
	_commit_lbuf(am, back, _taillight_mat)
	if am.get_surface_count() == 0:
		return
	var lights := MeshInstance3D.new()
	lights.name = "CarLights"
	lights.mesh = am
	lights.transform = body_mi.transform   # alineada con la geometría original
	pivot.add_child(lights)
	# Ocultar la superficie de luces original (la reemplaza la malla split).
	body_mi.set_surface_override_material(li, _hidden_mat)

	# Billboards de glare procedural: faros blancos (frente) deslumbran mas
	# que los pilotos rojos. Uno por cluster con triangulos suficientes.
	# DIRECCIONALES: el haz del faro apunta al frente (+Z en espacio final del
	# auto) y el del piloto hacia atras; el shader apaga el glare cuando la luz
	# no mira a la camara (un auto de frente solo muestra halos BLANCOS, nunca
	# los rojos de sus pilotos). La direccion se pasa en espacio del pivot
	# (donde cuelga el billboard).
	var fwd_local: Vector3 = (pivot_inv.basis * Vector3(0.0, 0.0, 1.0)).normalized()
	for ci in range(4):
		if cn[ci] < 2:
			continue
		var pos: Vector3 = csum[ci] / float(cn[ci])
		if ci < 2:
			GlareSource.attach(pivot, pos, Color(1.0, 0.98, 0.92), 1.0, fwd_local)
		else:
			GlareSource.attach(pivot, pos, Color(1.0, 0.06, 0.04), 0.7, -fwd_local)


func _new_lbuf() -> Dictionary:
	return {"v": PackedVector3Array(), "n": PackedVector3Array(), "u": PackedVector2Array()}


func _commit_lbuf(am: ArrayMesh, buf: Dictionary, mat: Material) -> void:
	var v: PackedVector3Array = buf["v"]
	if v.is_empty():
		return
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = v
	if buf["n"].size() == v.size():
		a[Mesh.ARRAY_NORMAL] = buf["n"]
	if buf["u"].size() == v.size():
		a[Mesh.ARRAY_TEX_UV] = buf["u"]
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	am.surface_set_material(am.get_surface_count() - 1, mat)


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
