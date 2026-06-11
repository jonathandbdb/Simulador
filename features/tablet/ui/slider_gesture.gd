class_name SliderGesture
extends RefCounted
## Maquina de gestos tactiles compartida para HSliders en listas scrolleables.
##
## El control DUEÑO (una fila/seccion con mouse_filter = PASS y sus sliders en
## MOUSE_FILTER_IGNORE) delega aca su _gui_input. La intencion del gesto se
## decide con los primeros ~14 px de arrastre:
##   - HORIZONTAL sobre un slider -> ajusta su valor (se consume el evento)
##   - VERTICAL -> no se consume: burbujea al ScrollContainer, que panea
##   - tap corto sobre un slider -> setea el valor en ese punto
## Usada por param_row.gd (ajuste fino) y slider_strip.gd (astigmatismo).

## Pixeles de arrastre para decidir la intencion del gesto.
const INTENT_PX := 14.0

var _owner: Control
## Callable(global_pos: Vector2) -> HSlider o null: que slider cae bajo el dedo.
var _resolver: Callable

var _active: HSlider = null
var _adjusting := false
var _start := Vector2.ZERO


func _init(owner: Control, slider_resolver: Callable) -> void:
	_owner = owner
	_resolver = slider_resolver


## Llamar desde el _gui_input del dueño con cada evento.
func handle(event: InputEvent) -> void:
	# En la tablet el mismo gesto llega DOS veces: como touch nativo y como
	# mouse emulado (device == DEVICE_ID_EMULATION). Procesamos solo el touch
	# nativo; el mouse REAL (escritorio, para pruebas) tambien se procesa.
	if event is InputEventScreenTouch:
		if event.pressed:
			_press(event.position)
		else:
			_release(event.position)
	elif event is InputEventScreenDrag:
		_drag(event.position)
	elif event is InputEventMouseButton and event.device != InputEvent.DEVICE_ID_EMULATION:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press(event.position)
			else:
				_release(event.position)
	elif event is InputEventMouseMotion and event.device != InputEvent.DEVICE_ID_EMULATION:
		if event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_drag(event.position)
	elif event is InputEventMouseMotion and _adjusting:
		# Mouse EMULADO del mismo gesto: mientras se ajusta se consume para que
		# el ScrollContainer no panee en paralelo (su paneo tactil escucha
		# justamente el mouse emulado del touch).
		_owner.accept_event()


func _to_global(pos: Vector2) -> Vector2:
	return _owner.get_global_transform() * pos


func _press(pos: Vector2) -> void:
	# Solo gestiona toques que caen sobre un slider; el resto del area queda
	# libre para el scroll del contenedor. NO se consume el press: el
	# ScrollContainer lo necesita para armar su seguimiento tactil.
	_active = _resolver.call(_to_global(pos))
	_adjusting = false
	_start = pos


func _drag(pos: Vector2) -> void:
	if _active == null:
		return
	if not _adjusting:
		var delta := pos - _start
		if absf(delta.x) >= INTENT_PX and absf(delta.x) > absf(delta.y):
			_adjusting = true
		elif absf(delta.y) >= INTENT_PX:
			# Gesto vertical: es un scroll. Soltamos el gesto sin tocar el
			# slider y dejamos que los drags burbujeen al contenedor.
			_active = null
			return
	if _adjusting:
		_set_from_x(pos)
		_owner.accept_event()   # el contenedor no debe panear durante el ajuste


func _release(pos: Vector2) -> void:
	if _active != null and not _adjusting:
		# Tap corto sobre el slider: setear el valor en ese punto.
		_set_from_x(pos)
	_active = null
	_adjusting = false


func _set_from_x(pos: Vector2) -> void:
	var r := _active.get_global_rect()
	if r.size.x <= 0.0:
		return
	var t := clampf((_to_global(pos).x - r.position.x) / r.size.x, 0.0, 1.0)
	# El setter de value snapea al step y emite value_changed si cambio.
	_active.value = _active.min_value + t * (_active.max_value - _active.min_value)
