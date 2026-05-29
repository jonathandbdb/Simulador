extends Node3D
## BookHolder — Sprint 10
##
## Responsabilidades:
##   1. Mantener el libro 3D anclado al controller derecho (ya como hijo
##      en la escena, este nodo solo aporta logica).
##   2. Cada frame calcular la distancia desde el libro hasta la camara VR.
##   3. Comparar esa distancia con `focal_distance_m` de la lente activa de
##      cada ojo (leida desde DataManager.current_vision_state) y traducirla
##      a un error focal normalizado 0..1.
##   4. Empujar ese error a los uniforms `runtime_focus_error_l/r` del
##      ShaderMaterial del post-process del ojo correspondiente.
##
## Patron: la fuente de verdad del estado de lentes sigue siendo DataManager.
## Este script no escribe en `current_vision_state`; solo lee `focal_distance_m`
## y modula un uniform separado del shader. De esa forma el modo Blend (lentes
## distintas por ojo) sigue funcionando: cada ojo computa su propio error.

@export var post_process_quad_path: NodePath
@export var xr_camera_path: NodePath
## Nodo del libro (Node3D que contiene el mesh). Si no se setea, se asume
## que el libro es un hijo directo de este BookHolder llamado "BookMesh".
@export var book_node_path: NodePath

## Cuanto error focal (en metros) corresponde a `runtime_focus_error = 1.0`.
## A partir de esta diferencia se considera completamente fuera de foco. Un valor
## chico hace que el desenfoque sature rapido: una monofocal (foco a 1.5 m) deja
## el libro sostenido a ~40 cm claramente borroso, mientras una multifocal con
## foco cercano lo mantiene nitido.
@export var error_saturation_m: float = 1.5

## Rango alrededor de la distancia focal que se considera nitido. Esto evita
## que el texto parpadee o quede borroso por pequenos movimientos de la mano.
@export var clear_radius_m: float = 0.2

## Suavizado temporal para evitar parpadeos de blur si el controller tiembla.
@export var smoothing: float = 8.0

var _post_quad: MeshInstance3D
var _camera: XRCamera3D
var _book: Node3D
var _debug_label: Label3D
var _shader_mat: ShaderMaterial

# Error suavizado de cada ojo (lo que efectivamente se escribe al shader).
var _smoothed_err_l: float = 0.0
var _smoothed_err_r: float = 0.0


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

	var err_l := _compute_focus_error("left", distance_m)
	var err_r := _compute_focus_error("right", distance_m)

	# Suavizado exponencial — evita saltos por jitter del controller.
	var alpha: float = clampf(delta * smoothing, 0.0, 1.0)
	_smoothed_err_l = lerp(_smoothed_err_l, err_l, alpha)
	_smoothed_err_r = lerp(_smoothed_err_r, err_r, alpha)

	_shader_mat.set_shader_parameter("runtime_focus_error_l", _smoothed_err_l)
	_shader_mat.set_shader_parameter("runtime_focus_error_r", _smoothed_err_r)
	_update_book_screen_mask()
	_update_debug_label(distance_m)


func _compute_focus_error(eye: String, distance_m: float) -> float:
	if DataManager == null:
		return 0.0
	var state: Dictionary = DataManager.current_vision_state.get(eye, {})
	if state.is_empty():
		return 0.0
	# Permitir multifocal: focal_distances_m es un Array de focos (cerca,
	# intermedio, lejos). Si no esta, usar focal_distance_m como unico foco.
	var focals: Array = []
	var raw_focals = state.get("focal_distances_m", null)
	if raw_focals is Array and (raw_focals as Array).size() > 0:
		for f in raw_focals:
			focals.append(float(f))
	else:
		focals.append(float(state.get("focal_distance_m", 6.0)))
	# Error = distancia al foco mas cercano. Lente multifocal queda nitida en
	# multiples zonas.
	var best_err: float = INF
	for f in focals:
		var e: float = absf(distance_m - f)
		if e < best_err:
			best_err = e
	return smoothstep(clear_radius_m, max(error_saturation_m, clear_radius_m + 0.001), best_err)


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
	var screen_pos := _camera.unproject_position(_book.global_position)
	var viewport_size := viewport.get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var uv := Vector2(screen_pos.x / viewport_size.x, screen_pos.y / viewport_size.y)
	if not _camera.is_position_behind(_book.global_position):
		_shader_mat.set_shader_parameter("book_screen_uv", uv)
		_shader_mat.set_shader_parameter("book_screen_radius", 0.42)
	else:
		_shader_mat.set_shader_parameter("book_screen_radius", 0.0)


func _update_debug_label(distance_m: float) -> void:
	if _debug_label == null:
		return
	_debug_label.text = "%.2fm\nL %.2f R %.2f" % [distance_m, _smoothed_err_l, _smoothed_err_r]
