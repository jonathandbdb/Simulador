extends Node3D
## PhoneHolder — auto_noche
##
## Versión del BookHolder adaptada para el celular con mapa que el paciente
## sostiene en la mano izquierda dentro del auto. Calcula la distancia del
## celular a la cámara VR cada frame y la pasa al uniform book_distance_m
## del shader post-proceso (mismo mecanismo que BookHolder en el consultorio).

@export var post_process_quad_path: NodePath
@export var xr_camera_path: NodePath
## Nodo del celular (Node3D). Si no se asigna, se busca un hijo "PhoneMesh".
@export var phone_node_path: NodePath

@export var smoothing: float = 8.0

var _post_quad: MeshInstance3D
var _camera: XRCamera3D
var _phone: Node3D
var _shader_mat: ShaderMaterial

var _smoothed_distance_m: float = 0.0


func _ready() -> void:
	_post_quad = get_node_or_null(post_process_quad_path) as MeshInstance3D
	_camera    = get_node_or_null(xr_camera_path) as XRCamera3D

	if phone_node_path != NodePath():
		_phone = get_node_or_null(phone_node_path) as Node3D
	if _phone == null:
		_phone = get_node_or_null("PhoneMesh") as Node3D
	if _phone == null:
		_phone = self

	if _post_quad == null:
		push_warning("PhoneHolder: post_process_quad no encontrado (%s)." % post_process_quad_path)
		return
	_shader_mat = _post_quad.get_active_material(0) as ShaderMaterial
	if _shader_mat == null:
		push_warning("PhoneHolder: el quad de post-process no tiene ShaderMaterial.")


func _process(delta: float) -> void:
	if _shader_mat == null or _camera == null or _phone == null:
		return

	var cam_pos: Vector3  = _camera.global_position
	var phone_pos: Vector3 = _phone.global_position
	var raw_dist: float    = cam_pos.distance_to(phone_pos)
	raw_dist = clamp(raw_dist, 0.05, 20.0)

	_smoothed_distance_m = lerp(_smoothed_distance_m, raw_dist, clamp(smoothing * delta, 0.0, 1.0))
	_shader_mat.set_shader_parameter("book_distance_m", _smoothed_distance_m)

	# Máscara UV del celular en pantalla (radio pequeño para un teléfono).
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	if viewport_size.x > 0.0 and viewport_size.y > 0.0:
		var proj: Projection = _camera.get_camera_projection()
		var local_pos: Vector3 = _camera.global_transform.affine_inverse() * phone_pos
		if local_pos.z < 0.0:
			var clip: Vector4 = proj * Vector4(local_pos.x, local_pos.y, local_pos.z, 1.0)
			if abs(clip.w) > 0.0001:
				var ndc: Vector2 = Vector2(clip.x, clip.y) / clip.w
				var screen_uv: Vector2 = (ndc * Vector2(0.5, -0.5)) + Vector2(0.5, 0.5)
				_shader_mat.set_shader_parameter("book_screen_uv", screen_uv)
				# Radio aproximado en UV: un celular ocupa ~0.06 del FOV.
				_shader_mat.set_shader_parameter("book_screen_radius", 0.06)
				return
	# Fuera de pantalla: deshabilitar máscara.
	_shader_mat.set_shader_parameter("book_screen_radius", 0.0)
