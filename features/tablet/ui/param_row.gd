extends VBoxContainer
## Fila de ajuste en vivo de un parametro de lente: nombre + valor formateado,
## slider touch-friendly y hint clinico visible debajo.
##
## Gesto tactil (tablet): el HSlider NO captura el input directamente — antes,
## cualquier toque sobre la fila quedaba atrapado por el slider y la unica forma
## de scrollear la lista era la barra de desplazamiento (y un swipe vertical
## encima de un slider ademas cambiaba el valor sin querer). La desambiguacion
## (horizontal = ajustar, vertical = scrollear, tap = setear) vive en
## SliderGesture, compartida con los sliders de astigmatismo.

signal param_changed(param_name: String, value: float)

@onready var name_label: Label = $Header/NameLabel
@onready var value_label: Label = $Header/ValueLabel
@onready var slider: HSlider = $Slider
@onready var hint_label: Label = $HintLabel

var param_name: String = ""
var _gesture: SliderGesture


func _ready() -> void:
	slider.value_changed.connect(_on_slider_changed)
	# El slider no recibe input: la fila decide el gesto y mueve el valor.
	slider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# PASS: la fila ve el input y lo NO consumido burbujea al ScrollContainer.
	mouse_filter = Control.MOUSE_FILTER_PASS
	_gesture = SliderGesture.new(self, _slider_at)


func _slider_at(global_pos: Vector2) -> HSlider:
	if slider.get_global_rect().grow(4.0).has_point(global_pos):
		return slider
	return null


func _gui_input(event: InputEvent) -> void:
	_gesture.handle(event)


## Configura la fila desde el rango del catalogo. Llamar despues de add_child.
func setup(p_name: String, min_val: float, max_val: float, value: float) -> void:
	param_name = p_name
	name_label.text = ParamMeta.label_for(p_name)
	value_label.text = ParamMeta.format_value(p_name, value)
	slider.min_value = min_val
	slider.max_value = max_val
	# Pasos enteros para conteos (rayos); ~200 pasos para el resto.
	if ParamMeta.is_integer_param(p_name):
		slider.step = 1.0
	else:
		slider.step = max((max_val - min_val) / 200.0, 0.001)
	slider.set_value_no_signal(value)
	var hint := ParamMeta.hint_for(p_name)
	hint_label.text = hint
	hint_label.visible = hint != ""
	name_label.tooltip_text = hint
	slider.tooltip_text = hint


## Actualiza slider + valor sin emitir param_changed (reset a defaults).
func set_value_silent(value: float) -> void:
	slider.set_value_no_signal(value)
	value_label.text = ParamMeta.format_value(param_name, value)


func _on_slider_changed(value: float) -> void:
	value_label.text = ParamMeta.format_value(param_name, value)
	param_changed.emit(param_name, value)
