extends Node3D
## PhoneHolder — auto_noche (Sprint 11)
##
## Equivalente al BookHolder del consultorio, pero para el celular con un mapa
## que el paciente sostiene dentro del auto. Dos responsabilidades:
##
##   1. Alimentar el uniform `book_distance_m` del shader post-proceso con la
##      distancia celular→cámara (misma curva de focos/dioptrías que el libro),
##      más la máscara en pantalla del celular (book_screen_uv/radius).
##   2. Permitir "agarrar" el celular con el GRIP del control izquierdo y
##      acercarlo/alejarlo de la cara; al soltar, vuelve al tablero. Así se ve
##      en vivo cómo cambia el desenfoque de cerca según la lente.
##
## Como esta escena se instancia DENTRO de main.tscn (en ScenarioContainer), el
## quad de post-proceso, la cámara XR y la mano izquierda NO son alcanzables por
## una NodePath relativa. Se localizan por GRUPO en runtime
## ("post_process_quad", "xr_camera", "left_hand"), con las NodePath exportadas
## como fallback opcional. La fuente de verdad del estado de lentes sigue siendo
## DataManager; este script solo mide distancia y mueve el celular.

# Fallbacks opcionales (si se setean en el inspector tienen prioridad sobre los
# grupos). Normalmente quedan vacíos y todo se resuelve por grupo.
@export var post_process_quad_path: NodePath
@export var xr_camera_path: NodePath
@export var left_hand_path: NodePath
## Nodo del celular (Node3D con el mesh). Si no se setea se busca "PhoneMesh".
@export var phone_node_path: NodePath

## Suavizado temporal de la distancia (evita parpadeos de blur por jitter).
@export var smoothing: float = 8.0
## Suavizado del movimiento del celular al agarrar/soltar.
@export var grab_smoothing: float = 12.0
## Botón del control izquierdo que agarra el celular.
@export var grab_button: String = "grip_click"
## Pose del celular relativa a la mano izquierda cuando está agarrado.
@export var grab_offset: Vector3 = Vector3(0.0, 0.02, -0.18)

var _post_quad: MeshInstance3D
var _camera: XRCamera3D
var _left_hand: XRController3D
var _phone: Node3D
var _shader_mat: ShaderMaterial

var _smoothed_distance_m: float = 0.0
# Transform global de reposo del celular (apoyado en el tablero).
var _rest_global: Transform3D
var _grabbed: bool = false


func _ready() -> void:
	_resolve_refs()

	if phone_node_path != NodePath():
		_phone = get_node_or_null(phone_node_path) as Node3D
	if _phone == null:
		_phone = get_node_or_null("PhoneMesh") as Node3D
	if _phone == null:
		_phone = self  # fallback: usar la propia posición del nodo

	# La pose de reposo es donde el editor dejó el celular sobre el tablero.
	_rest_global = _phone.global_transform

	if _post_quad == null:
		push_warning("PhoneHolder: PostProcessQuad no encontrado (grupo 'post_process_quad').")
		return
	_shader_mat = _post_quad.get_active_material(0) as ShaderMaterial
	if _shader_mat == null:
		push_warning("PhoneHolder: el quad de post-process no tiene ShaderMaterial.")


## Resuelve cámara/quad/mano por NodePath exportada (si existe) o por grupo.
func _resolve_refs() -> void:
	if post_process_quad_path != NodePath():
		_post_quad = get_node_or_null(post_process_quad_path) as MeshInstance3D
	if _post_quad == null:
		_post_quad = get_tree().get_first_node_in_group("post_process_quad") as MeshInstance3D

	if xr_camera_path != NodePath():
		_camera = get_node_or_null(xr_camera_path) as XRCamera3D
	if _camera == null:
		_camera = get_tree().get_first_node_in_group("xr_camera") as XRCamera3D

	if left_hand_path != NodePath():
		_left_hand = get_node_or_null(left_hand_path) as XRController3D
	if _left_hand == null:
		_left_hand = get_tree().get_first_node_in_group("left_hand") as XRController3D


func _process(delta: float) -> void:
	_update_grab(delta)
	_update_shader(delta)


## Mueve el celular: agarrado sigue al control izquierdo; suelto vuelve al tablero.
func _update_grab(delta: float) -> void:
	if _phone == null or _phone == self:
		return

	var want_grab := false
	if _left_hand != null:
		want_grab = _left_hand.is_button_pressed(grab_button)
	_grabbed = want_grab

	var target: Transform3D = _rest_global
	if _grabbed and _left_hand != null:
		# Pose en la mano: trasladada por grab_offset en el espacio de la mano.
		target = _left_hand.global_transform.translated_local(grab_offset)

	var a: float = clampf(delta * grab_smoothing, 0.0, 1.0)
	_phone.global_transform = _phone.global_transform.interpolate_with(target, a)


## Escribe distancia + máscara del celular en el shader (mismos uniforms que el libro).
func _update_shader(delta: float) -> void:
	if _shader_mat == null or _camera == null or _phone == null:
		return

	var distance_m: float = _phone.global_position.distance_to(_camera.global_position)
	distance_m = clampf(distance_m, 0.05, 20.0)

	var alpha: float = clampf(delta * smoothing, 0.0, 1.0)
	if _smoothed_distance_m <= 0.0:
		_smoothed_distance_m = distance_m
	else:
		_smoothed_distance_m = lerp(_smoothed_distance_m, distance_m, alpha)

	_shader_mat.set_shader_parameter("book_distance_m", _smoothed_distance_m)
	_update_phone_screen_mask()


## Máscara UV del celular en pantalla. Radio chico (un teléfono ocupa poco FOV).
func _update_phone_screen_mask() -> void:
	var viewport := get_viewport()
	if viewport == null:
		return
	var viewport_size: Vector2 = viewport.get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	if _camera.is_position_behind(_phone.global_position):
		_shader_mat.set_shader_parameter("book_screen_radius", 0.0)
		return
	var screen_pos: Vector2 = _camera.unproject_position(_phone.global_position)
	var uv := Vector2(screen_pos.x / viewport_size.x, screen_pos.y / viewport_size.y)
	_shader_mat.set_shader_parameter("book_screen_uv", uv)
	_shader_mat.set_shader_parameter("book_screen_radius", 0.12)


## Distancia actual celular→cámara (debug/HUD opcional).
func get_distance_m() -> float:
	if _camera == null or _phone == null:
		return -1.0
	return _phone.global_position.distance_to(_camera.global_position)
