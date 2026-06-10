extends Button
## Card de lente intraocular: nombre humano, descripcion clinica y chips
## OD/OI que indican en que ojo(s) esta aplicada. Tap = aplicar la lente.

signal lens_selected(lens_id: String)

@onready var name_label: Label = $Margin/VBox/TopRow/NameLabel
@onready var chip_od: Label = $Margin/VBox/TopRow/ChipOD
@onready var chip_oi: Label = $Margin/VBox/TopRow/ChipOI
@onready var desc_label: Label = $Margin/VBox/DescLabel

var lens_id: String = ""


func _ready() -> void:
	pressed.connect(func() -> void: lens_selected.emit(lens_id))


## Configura la card desde una entrada del catalogo. Tolera claves faltantes
## o extra (el backend puede agregar campos como "tipo").
func setup(lens: Dictionary) -> void:
	lens_id = String(lens.get("id", "?"))
	var nombre := String(lens.get("nombre", "")).strip_edges()
	var tipo := String(lens.get("tipo", "")).strip_edges()
	var titulo := nombre
	if titulo == "":
		titulo = tipo if tipo != "" else lens_id
	name_label.text = titulo
	var desc := String(lens.get("descripcion", "")).strip_edges()
	if desc == "" and tipo != "" and tipo != titulo:
		desc = tipo
	desc_label.text = desc
	desc_label.visible = desc != ""
	# La descripcion completa queda como tooltip (la card la clampa a 2 lineas).
	tooltip_text = desc


## Enciende los chips segun el estado de vision y resalta la card si la lente
## esta aplicada en algun ojo.
func set_eye_state(on_od: bool, on_oi: bool) -> void:
	chip_od.visible = on_od
	chip_oi.visible = on_oi
	theme_type_variation = &"CardButtonActive" if (on_od or on_oi) else &"CardButton"
