extends Node3D
## Escena raiz del simulador VR (Sprint 1).
##
## Responsabilidades:
##  - Inicializar la interfaz OpenXR.
##  - Redirigir el renderizado al HMD (use_xr = true).
##  - Ajustar physics ticks al refresh rate del visor (90/120 Hz).
##
## La validacion del Sprint 1 es visual: el ojo izquierdo debe ver rojo
## y el ojo derecho azul gracias al shader eye_test.gdshader montado
## en el Quad hijo de XRCamera3D.

const TARGET_PHYSICS_TICKS := 90

var xr_interface: XRInterface


func _ready() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface == null:
		push_error("OpenXR interface no encontrada. Verificar Project Settings > XR.")
		return

	if not xr_interface.is_initialized():
		push_error("OpenXR no se inicializo correctamente. Verificar que el visor este conectado y el runtime activo.")
		return

	# Redirige el rendering al HMD.
	get_viewport().use_xr = true

	# El HMD maneja su propia sincronizacion (no tocar VSYNC aca; ya esta en project.godot).
	# Ajustamos physics para que vaya a la par del refresh.
	Engine.physics_ticks_per_second = TARGET_PHYSICS_TICKS

	print("Sprint 1 OK: OpenXR inicializado. ojo izquierdo=rojo, ojo derecho=azul.")
	print("XR interface: %s" % xr_interface.get_name())
