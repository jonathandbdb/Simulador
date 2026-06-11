extends VBoxContainer
## Contenedor cuyos HSlider hijos usan el gesto tactil compartido
## (SliderGesture): arrastre horizontal ajusta el slider, vertical scrollea la
## lista, tap setea el valor. Usado por AstigContent (sliders de astigmatismo),
## que son HSlider crudos fuera del sistema de param_row.

var _sliders: Array[HSlider] = []
var _gesture: SliderGesture


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	for c in get_children():
		if c is HSlider:
			c.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_sliders.append(c)
	_gesture = SliderGesture.new(self, _slider_at)


func _slider_at(global_pos: Vector2) -> HSlider:
	for s in _sliders:
		if s.get_global_rect().grow(4.0).has_point(global_pos):
			return s
	return null


func _gui_input(event: InputEvent) -> void:
	_gesture.handle(event)
