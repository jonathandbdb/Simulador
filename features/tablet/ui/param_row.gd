extends VBoxContainer
## Fila de ajuste en vivo de un parametro de lente: nombre + valor formateado,
## slider touch-friendly y hint clinico visible debajo.

signal param_changed(param_name: String, value: float)

@onready var name_label: Label = $Header/NameLabel
@onready var value_label: Label = $Header/ValueLabel
@onready var slider: HSlider = $Slider
@onready var hint_label: Label = $HintLabel

var param_name: String = ""


func _ready() -> void:
	slider.value_changed.connect(_on_slider_changed)


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
