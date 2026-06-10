class_name ParamMeta
extends RefCounted
## Metadata clinica de los parametros de lente que llegan en el catalogo.
## Movida fuera del controlador de la tablet para que param_row y cualquier
## otra vista la consuman. Las claves son las del catalogo/shader (no afecta
## al protocolo).

## Metadata por parametro:
##   label  -> texto principal del slider
##   hint   -> descripcion corta del efecto clinico
##   unit   -> sufijo de la unidad ("m", "rayos", "")
##   fmt    -> formato del numero (default "%.2f")
const META := {
	"foco_lejos_m": {
		"label": "Foco lejano",
		"hint": "Distancia donde el paciente ve nitido a lejos. 6 m ≈ infinito optico. 0 = desactivado.",
		"unit": "m", "fmt": "%.2f",
	},
	"foco_intermedio_m": {
		"label": "Foco intermedio",
		"hint": "Distancia del segundo plano nitido (PC, tablero del auto). 0 = sin foco intermedio.",
		"unit": "m", "fmt": "%.2f",
	},
	"foco_cerca_m": {
		"label": "Foco cercano",
		"hint": "Distancia de lectura nitida (libro, celular). Tipico 35-45 cm. 0 = sin foco cercano.",
		"unit": "m", "fmt": "%.2f",
	},
	"profundidad_foco_m": {
		"label": "Profundidad de foco",
		"hint": "Ancho de la zona nitida alrededor de cada foco. Bajo = pico estrecho (trifocal). Alto = plateau ancho (EDOF).",
		"unit": "m", "fmt": "%.2f",
	},
	"desenfoque_max": {
		"label": "Desenfoque maximo",
		"hint": "Cuanto se borronea fuera de toda zona de foco (0 = nunca borroso, 1 = maximo).",
		"unit": "", "fmt": "%.2f",
	},
	"halo_intensity": {
		"label": "Intensidad de halos",
		"hint": "Tamano e intensidad del halo difractivo alrededor de fuentes brillantes. Trifocal alto, monofocal casi nulo.",
		"unit": "", "fmt": "%.2f",
	},
	"halo_extra_rings": {
		"label": "Dilatacion pupilar (noche)",
		"hint": "Pupila mesopica/escotopica. Agranda el halo y agrega tinte azulado (efecto Purkinje). Subir en escena nocturna.",
		"unit": "", "fmt": "%.2f",
	},
	"contrast_loss": {
		"label": "Perdida de contraste",
		"hint": "Reduccion de sensibilidad al contraste (imagen mas lavada). Trifocal pierde mas que EDOF, EDOF mas que monofocal.",
		"unit": "", "fmt": "%.2f",
	},
	"destello_intensity": {
		"label": "Intensidad de starburst",
		"hint": "Rayos radiales desde fuentes brillantes (disfotopsia difractiva). 0 = sin destello.",
		"unit": "", "fmt": "%.2f",
	},
	"destello_rayos": {
		"label": "Cantidad de rayos",
		"hint": "Cantidad de spokes del starburst. Pacientes con trifocal reportan 8-12 rayos visibles.",
		"unit": "rayos", "fmt": "%.0f",
	},
}

## Orden clinico de presentacion: primero los focos, despues blur, despues
## disfotopsias (halo, starburst, contraste). Parametros del catalogo que no
## esten aca se agregan al final preservando el orden del catalogo.
const ORDER := [
	"foco_lejos_m", "foco_intermedio_m", "foco_cerca_m",
	"profundidad_foco_m", "desenfoque_max",
	"halo_intensity", "halo_extra_rings",
	"destello_intensity", "destello_rayos",
	"contrast_loss",
]


static func label_for(param_name: String) -> String:
	var meta: Dictionary = META.get(param_name, {})
	return meta.get("label", param_name)


static func hint_for(param_name: String) -> String:
	var meta: Dictionary = META.get(param_name, {})
	return meta.get("hint", "")


## True si el parametro se edita en pasos enteros (formato "%.0f").
static func is_integer_param(param_name: String) -> bool:
	return META.get(param_name, {}).get("fmt", "") == "%.0f"


static func format_value(param_name: String, value: float) -> String:
	var meta: Dictionary = META.get(param_name, {})
	# Distancias en metros: 0 = foco desactivado.
	if meta.get("unit", "") == "m" and value <= 0.001:
		return "off"
	var fmt: String = meta.get("fmt", "%.2f")
	var unit: String = meta.get("unit", "")
	if unit == "":
		return fmt % value
	return ("%s %s" % [fmt % value, unit]).strip_edges()
