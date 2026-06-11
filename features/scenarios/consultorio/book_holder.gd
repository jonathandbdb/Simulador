extends Node3D
## BookHolder — Sprint 10
##
## Responsabilidades:
##   1. Mantener el libro 3D anclado al controller derecho (ya como hijo
##      en la escena, este nodo solo aporta logica).
##   2. Cada frame calcular la distancia desde el libro hasta la camara VR.
##   3. Pasar esa distancia (suavizada) al uniform `book_distance_m` del shader,
##      junto con la mascara en pantalla del libro. El shader aplica la MISMA
##      curva de focos por ojo que usa para el resto de la escena, asi que el
##      libro queda nitido si su distancia cae dentro de la profundidad de foco
##      de algun foco de la lente. Toda la logica focal vive ahora en el shader.
##
## Patron: la fuente de verdad del estado de lentes sigue siendo DataManager.
## Este script NO escribe en `current_vision_state` ni interpreta los focos: solo
## mide la distancia del libro y la entrega al shader. El modo Blend (lentes
## distintas por ojo) sigue funcionando porque el shader tiene los focos por ojo.

@export var post_process_quad_path: NodePath
@export var xr_camera_path: NodePath
## Nodo del libro (Node3D que contiene el mesh). Si no se setea, se asume
## que el libro es un hijo directo de este BookHolder llamado "BookMesh".
@export var book_node_path: NodePath

## Suavizado temporal para evitar parpadeos de blur si el controller tiembla.
@export var smoothing: float = 8.0

var _post_quad: MeshInstance3D
var _camera: XRCamera3D
var _book: Node3D
var _debug_label: Label3D
var _shader_mat: ShaderMaterial
# Mitad del lado mayor del libro (m), medida del AABB de sus mallas. Define el
# radio ANGULAR de la mascara en pantalla (antes era un radio fijo 0.42 que
# cubria media pantalla y emborronaba todo alrededor del libro).
var _book_half_m: float = 0.18

# Distancia suavizada del libro a la camara (lo que se escribe al shader).
var _smoothed_distance_m: float = 0.0


func _ready() -> void:
	_post_quad = get_node_or_null(post_process_quad_path) as MeshInstance3D
	_camera = get_node_or_null(xr_camera_path) as XRCamera3D
	if book_node_path != NodePath():
		_book = get_node_or_null(book_node_path) as Node3D
	if _book == null:
		_book = get_node_or_null("BookMesh") as Node3D
	if _book == null:
		_book = self  # fallback: usar la propia posicion del nodo
	_debug_label = get_node_or_null("ReadableBook/FocusDebug") as Label3D

	# Nitidez del texto a distancia: forzar filtrado trilineal + anisotropico en
	# las texturas del libro. Con mipmaps (ya generados en el import) esto evita
	# el shimmer/pixelado de los glifos cuando el libro se aleja.
	_apply_anisotropic_filtering(_book)
	_book_half_m = _measure_book_half_size()

	if _post_quad == null:
		push_warning("BookHolder: post_process_quad no encontrado (%s)." % post_process_quad_path)
		return
	_shader_mat = _post_quad.get_active_material(0) as ShaderMaterial
	if _shader_mat == null:
		push_warning("BookHolder: el quad de post-process no tiene ShaderMaterial.")


func _process(delta: float) -> void:
	if _shader_mat == null or _camera == null or _book == null:
		return

	var distance_m: float = _book.global_position.distance_to(_camera.global_position)

	# Suavizado exponencial — evita saltos por jitter del controller.
	var alpha: float = clampf(delta * smoothing, 0.0, 1.0)
	if _smoothed_distance_m <= 0.0:
		_smoothed_distance_m = distance_m
	else:
		_smoothed_distance_m = lerp(_smoothed_distance_m, distance_m, alpha)

	_shader_mat.set_shader_parameter("book_distance_m", _smoothed_distance_m)
	_update_book_screen_mask()
	_update_debug_label(distance_m)


## Recorre el subarbol del libro y fuerza filtrado anisotropico con mipmaps en
## los materiales (StandardMaterial3D) de cada MeshInstance3D. Mejora la nitidez
## del texto cuando el libro se ve a distancia, sin costo de render apreciable.
## Ademas desactiva la EMISION de las paginas: el asset trae texturas de emision
## que hacen brillar la pagina por si sola, lo que con multifocal (contraste
## lavado) se percibe como "luz molesta" al leer. Sin emision, el libro queda
## iluminado solo por las luces de la escena, mucho mas comodo de leer.
func _apply_anisotropic_filtering(root: Node) -> void:
	if root is MeshInstance3D:
		var mi := root as MeshInstance3D
		var surface_count := 0
		if mi.mesh != null:
			surface_count = mi.mesh.get_surface_count()
		for i in surface_count:
			var mat := mi.get_active_material(i)
			if mat is BaseMaterial3D:
				var bm := mat as BaseMaterial3D
				bm.texture_filter = \
					BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
				# Apagar la emision de las paginas (fuente del brillo molesto).
				if bm.emission_enabled:
					bm.emission_enabled = false
					bm.emission_energy_multiplier = 0.0
	for child in root.get_children():
		_apply_anisotropic_filtering(child)


## Devuelve la distancia actual en metros (debug / HUD opcional).
func get_distance_m() -> float:
	if _camera == null or _book == null:
		return -1.0
	return _book.global_position.distance_to(_camera.global_position)


func _update_book_screen_mask() -> void:
	var viewport := get_viewport()
	if viewport == null:
		return
	var viewport_size := viewport.get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	if _camera.is_position_behind(_book.global_position):
		_shader_mat.set_shader_parameter("book_screen_radius", 0.0)
		return
	var center: Vector3 = _book.global_position
	var screen_pos := _camera.unproject_position(center)
	var uv := Vector2(screen_pos.x / viewport_size.x, screen_pos.y / viewport_size.y)
	# Radio segun el tamano ANGULAR real del libro: se proyecta un punto a
	# medio-libro del centro y se mide en pantalla. Con el radio fijo anterior
	# (0.42) la mascara cubria casi media pantalla y el fondo alrededor del
	# libro heredaba la distancia CERCANA del libro -> con monofocal todo ese
	# circulo quedaba borroso aunque el fondo estuviera en foco.
	var up: Vector3 = _camera.global_transform.basis.y
	var edge_pos := _camera.unproject_position(center + up * _book_half_m)
	var radius_uv: float = screen_pos.distance_to(edge_pos) / viewport_size.y
	radius_uv = clampf(radius_uv * 1.45, 0.06, 0.45)
	_shader_mat.set_shader_parameter("book_screen_uv", uv)
	_shader_mat.set_shader_parameter("book_screen_radius", radius_uv)


## Mitad del lado mayor (m) del AABB combinado de las mallas del libro.
func _measure_book_half_size() -> float:
	var largest := 0.0
	var stack: Array[Node] = [_book]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var sz: Vector3 = mi.get_aabb().size * mi.global_transform.basis.get_scale()
			largest = maxf(largest, sz[sz.max_axis_index()])
		stack.append_array(n.get_children())
	if largest <= 0.0:
		return 0.18
	return clampf(largest * 0.5, 0.10, 0.35)


func _update_debug_label(distance_m: float) -> void:
	if _debug_label == null:
		return
	_debug_label.text = "%.2f m" % distance_m
