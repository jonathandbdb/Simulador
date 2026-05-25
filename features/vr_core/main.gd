extends Node3D
## Escena raiz del Sprint 2 — PoC GO/NO-GO de F2.
##
## Aplica un preset asimetrico de lentes para validar:
##   1. El shader screen-reading funciona en VR estereo.
##   2. VIEW_INDEX bifurca correctamente (un ojo blureado distinto al otro).
##   3. La conversion DEPTH_TEXTURE -> metros con INV_PROJECTION_MATRIX
##      produce DoF coherente con la geometria de la escena.
##   4. El frame time GPU se mantiene <11 ms en Quest 2 (criterio GO).

const TARGET_PHYSICS_TICKS := 90

# Preset que se aplica al arrancar:
# Ojo izquierdo: PanOptix simulado (multifocal, halos, DoF leve en todos los planos).
# Ojo derecho:  Vivity simulado (EDOF, foco lejos, halo bajo, blur cerca alto).
const PRESET := {
	"left": {
		"blur_near": 0.5,
		"blur_medium": 0.2,
		"blur_far": 0.1,
		"halo_intensity": 0.7,
	},
	"right": {
		"blur_near": 0.8,
		"blur_medium": 0.1,
		"blur_far": 0.0,
		"halo_intensity": 0.2,
	},
}

@onready var post_process_quad: MeshInstance3D = $XROrigin3D/XRCamera3D/PostProcessQuad
@onready var fps_label: Label3D = $XROrigin3D/XRCamera3D/FpsHud

var xr_interface: XRInterface
var fps_accumulator: float = 0.0
var fps_frames: int = 0


func _ready() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface == null or not xr_interface.is_initialized():
		push_error("OpenXR no inicializado. Sprint 2 corre solo en modo VR.")
		return

	get_viewport().use_xr = true
	# NOTA: FSR scaling esta desactivado por ahora. La combinacion FSR + multiview +
	# screen-reading shader rompe el framebuffer en Quest Link (Godot 4.6).
	# Si el render funciona en Quest standalone (APK sideload), reactivarlo con:
	#   get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	#   get_viewport().scaling_3d_scale = 0.85
	Engine.physics_ticks_per_second = TARGET_PHYSICS_TICKS

	_apply_preset()
	print("Sprint 2 OK: preset asimetrico aplicado.")
	print("Ojo izquierdo: blur cerca=%.2f medio=%.2f lejos=%.2f, halo=%.2f" % [
		PRESET.left.blur_near, PRESET.left.blur_medium, PRESET.left.blur_far, PRESET.left.halo_intensity
	])
	print("Ojo derecho:  blur cerca=%.2f medio=%.2f lejos=%.2f, halo=%.2f" % [
		PRESET.right.blur_near, PRESET.right.blur_medium, PRESET.right.blur_far, PRESET.right.halo_intensity
	])


func _apply_preset() -> void:
	var mat := post_process_quad.get_active_material(0) as ShaderMaterial
	if mat == null:
		push_error("PostProcessQuad sin ShaderMaterial.")
		return
	mat.set_shader_parameter("blur_near_l",   PRESET.left.blur_near)
	mat.set_shader_parameter("blur_medium_l", PRESET.left.blur_medium)
	mat.set_shader_parameter("blur_far_l",    PRESET.left.blur_far)
	mat.set_shader_parameter("halo_intensity_l", PRESET.left.halo_intensity)
	mat.set_shader_parameter("blur_near_r",   PRESET.right.blur_near)
	mat.set_shader_parameter("blur_medium_r", PRESET.right.blur_medium)
	mat.set_shader_parameter("blur_far_r",    PRESET.right.blur_far)
	mat.set_shader_parameter("halo_intensity_r", PRESET.right.halo_intensity)


func _process(delta: float) -> void:
	# HUD FPS: actualiza cada 0.5 s para no saturar el sampling.
	fps_accumulator += delta
	fps_frames += 1
	if fps_accumulator >= 0.5:
		var fps := fps_frames / fps_accumulator
		var frame_ms := (fps_accumulator / fps_frames) * 1000.0
		fps_label.text = "FPS: %d\nFrame: %.2f ms" % [int(fps), frame_ms]
		fps_accumulator = 0.0
		fps_frames = 0
