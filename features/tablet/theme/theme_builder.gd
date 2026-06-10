class_name TabletTheme
extends RefCounted
## Generador del tema de la app de tablet.
##
## Construye un Theme completo a partir de un diccionario de paleta, de modo
## que los modos claro y oscuro compartan exactamente la misma estructura
## (solo cambian los colores). El controlador llama build(DARK) o
## build(LIGHT) y reasigna el theme del nodo raiz para cambiar de modo.
##
## Variaciones de tipo expuestas (usar via theme_type_variation):
##   PanelContainer: Card, HeaderBar, StatusBadge, StreamFrame
##   Label:          TitleLabel, SubtitleLabel, SectionLabel, HintLabel,
##                   ValueLabel, ChipOD, ChipOI, StreamChip
##   Button:         AccentButton, SegmentButton, CardButton, CardButtonActive,
##                   GhostButton

const FONT_REGULAR_PATH := "res://assets/fonts/inter/Inter-Regular.ttf"
const FONT_SEMIBOLD_PATH := "res://assets/fonts/inter/Inter-SemiBold.ttf"
const GRABBER_ICON_PATH := "res://assets/icons/ui/grabber.svg"

## Paleta oscura: consola medica (gris azulado + teal clinico).
const DARK := {
	"name": "dark",
	"bg": Color("#11151C"),
	"surface": Color("#1B212B"),
	"surface_raised": Color("#242C38"),
	"surface_hover": Color("#2B3442"),
	"border": Color("#313C4B"),
	"text_primary": Color("#E9EEF5"),
	"text_secondary": Color("#9AA7B8"),
	"text_hint": Color("#6C7A8C"),
	"accent": Color("#17A398"),
	"accent_pressed": Color("#0F7E76"),
	"accent_soft": Color("#17A39826"),
	"accent_text": Color("#04201D"),
	"ok": Color("#3FCF8E"),
	"warn": Color("#F2B33D"),
	"error": Color("#E5655E"),
	"chip_od": Color("#5B9BD5"),
	"chip_oi": Color("#C58BD8"),
	"stream_bg": Color("#06080C"),
	"icon": Color("#E9EEF5"),
}

## Paleta clara: historia clinica electronica (blanco/gris + azul clinico).
const LIGHT := {
	"name": "light",
	"bg": Color("#F5F7FA"),
	"surface": Color("#FFFFFF"),
	"surface_raised": Color("#EDF1F6"),
	"surface_hover": Color("#E3E9F1"),
	"border": Color("#D5DCE5"),
	"text_primary": Color("#1A2330"),
	"text_secondary": Color("#5A6878"),
	"text_hint": Color("#8895A5"),
	"accent": Color("#2563EB"),
	"accent_pressed": Color("#1D4FBF"),
	"accent_soft": Color("#2563EB1F"),
	"accent_text": Color("#FFFFFF"),
	"ok": Color("#16A34A"),
	"warn": Color("#D97706"),
	"error": Color("#DC2626"),
	"chip_od": Color("#2E6FB7"),
	"chip_oi": Color("#9456B8"),
	"stream_bg": Color("#0B0E13"),
	"icon": Color("#1A2330"),
}


static func palette_for(dark: bool) -> Dictionary:
	return DARK if dark else LIGHT


## Construye el Theme completo para la paleta dada.
static func build(p: Dictionary) -> Theme:
	var theme := Theme.new()
	var font_regular: FontFile = load(FONT_REGULAR_PATH)
	var font_semibold: FontFile = load(FONT_SEMIBOLD_PATH)
	var grabber_icon: Texture2D = load(GRABBER_ICON_PATH)

	theme.default_font = font_regular
	theme.default_font_size = 16

	# ----------------------------------------------------------------
	# Paneles base
	# ----------------------------------------------------------------
	# Fondo general de la app (nodo Background tipo Panel).
	theme.set_stylebox("panel", "Panel", _flat(p.bg, 0))
	# PanelContainer sin variacion: contenedor neutro transparente.
	theme.set_stylebox("panel", "PanelContainer", _flat(Color.TRANSPARENT, 0))

	# Card: superficie principal de contenido.
	theme.set_type_variation("Card", "PanelContainer")
	theme.set_stylebox("panel", "Card",
			_flat(p.surface, 12, p.border, 1, 16, 16))

	# HeaderBar: barra superior, borde inferior sutil.
	theme.set_type_variation("HeaderBar", "PanelContainer")
	var header_sb := _flat(p.surface, 0, p.border, 0, 16, 8)
	header_sb.border_width_bottom = 1
	header_sb.border_color = p.border
	theme.set_stylebox("panel", "HeaderBar", header_sb)

	# StatusBadge: pildora para el estado de conexion.
	theme.set_type_variation("StatusBadge", "PanelContainer")
	theme.set_stylebox("panel", "StatusBadge",
			_flat(p.surface_raised, 99, p.border, 1, 14, 6))

	# StreamFrame: marco oscuro del video (igual en ambos modos).
	theme.set_type_variation("StreamFrame", "PanelContainer")
	theme.set_stylebox("panel", "StreamFrame",
			_flat(p.stream_bg, 10, p.border, 1, 8, 8))

	# ----------------------------------------------------------------
	# Labels
	# ----------------------------------------------------------------
	theme.set_color("font_color", "Label", p.text_primary)

	theme.set_type_variation("TitleLabel", "Label")
	theme.set_font("font", "TitleLabel", font_semibold)
	theme.set_font_size("font_size", "TitleLabel", 22)
	theme.set_color("font_color", "TitleLabel", p.text_primary)

	theme.set_type_variation("SubtitleLabel", "Label")
	theme.set_font_size("font_size", "SubtitleLabel", 15)
	theme.set_color("font_color", "SubtitleLabel", p.text_secondary)

	theme.set_type_variation("SectionLabel", "Label")
	theme.set_font("font", "SectionLabel", font_semibold)
	theme.set_font_size("font_size", "SectionLabel", 17)
	theme.set_color("font_color", "SectionLabel", p.text_primary)

	theme.set_type_variation("HintLabel", "Label")
	theme.set_font_size("font_size", "HintLabel", 13)
	theme.set_color("font_color", "HintLabel", p.text_hint)

	theme.set_type_variation("ValueLabel", "Label")
	theme.set_font("font", "ValueLabel", font_semibold)
	theme.set_font_size("font_size", "ValueLabel", 15)
	theme.set_color("font_color", "ValueLabel", p.accent)

	# Chips de ojo (OD = derecho, OI = izquierdo).
	_chip_label(theme, "ChipOD", p.chip_od, font_semibold)
	_chip_label(theme, "ChipOI", p.chip_oi, font_semibold)

	# Chip overlay sobre el stream (siempre claro sobre fondo oscuro).
	theme.set_type_variation("StreamChip", "Label")
	theme.set_font("font", "StreamChip", font_semibold)
	theme.set_font_size("font_size", "StreamChip", 14)
	theme.set_color("font_color", "StreamChip", Color("#F2F6FB"))
	theme.set_stylebox("normal", "StreamChip",
			_flat(Color(0.0, 0.0, 0.0, 0.55), 99, Color.TRANSPARENT, 0, 12, 4))

	# ----------------------------------------------------------------
	# Botones
	# ----------------------------------------------------------------
	# Boton por defecto: superficie elevada, alto comodo para touch.
	theme.set_font("font", "Button", font_semibold)
	theme.set_font_size("font_size", "Button", 16)
	theme.set_color("font_color", "Button", p.text_primary)
	theme.set_color("font_hover_color", "Button", p.text_primary)
	theme.set_color("font_pressed_color", "Button", p.text_primary)
	theme.set_color("font_disabled_color", "Button", p.text_hint)
	theme.set_color("icon_normal_color", "Button", p.icon)
	theme.set_color("icon_hover_color", "Button", p.icon)
	theme.set_color("icon_pressed_color", "Button", p.icon)
	theme.set_color("icon_disabled_color", "Button", p.text_hint)
	theme.set_stylebox("normal", "Button",
			_flat(p.surface_raised, 8, p.border, 1, 16, 12))
	theme.set_stylebox("hover", "Button",
			_flat(p.surface_hover, 8, p.border, 1, 16, 12))
	theme.set_stylebox("pressed", "Button",
			_flat(p.surface_hover, 8, p.accent, 1, 16, 12))
	theme.set_stylebox("disabled", "Button",
			_flat(p.surface, 8, p.border, 1, 16, 12))
	theme.set_stylebox("focus", "Button", StyleBoxEmpty.new())

	# AccentButton: accion principal.
	theme.set_type_variation("AccentButton", "Button")
	theme.set_color("font_color", "AccentButton", p.accent_text)
	theme.set_color("font_hover_color", "AccentButton", p.accent_text)
	theme.set_color("font_pressed_color", "AccentButton", p.accent_text)
	theme.set_stylebox("normal", "AccentButton",
			_flat(p.accent, 8, Color.TRANSPARENT, 0, 18, 12))
	theme.set_stylebox("hover", "AccentButton",
			_flat(p.accent.lightened(0.06), 8, Color.TRANSPARENT, 0, 18, 12))
	theme.set_stylebox("pressed", "AccentButton",
			_flat(p.accent_pressed, 8, Color.TRANSPARENT, 0, 18, 12))

	# SegmentButton: toggles tipo segmento (selector de ojo, escenarios).
	theme.set_type_variation("SegmentButton", "Button")
	theme.set_color("font_color", "SegmentButton", p.text_secondary)
	theme.set_color("font_hover_color", "SegmentButton", p.text_primary)
	theme.set_color("font_pressed_color", "SegmentButton", p.accent_text)
	theme.set_stylebox("normal", "SegmentButton",
			_flat(p.surface_raised, 8, p.border, 1, 14, 12))
	theme.set_stylebox("hover", "SegmentButton",
			_flat(p.surface_hover, 8, p.border, 1, 14, 12))
	theme.set_stylebox("pressed", "SegmentButton",
			_flat(p.accent, 8, Color.TRANSPARENT, 0, 14, 12))

	# CardButton: card de lente (estado normal / aplicado).
	theme.set_type_variation("CardButton", "Button")
	theme.set_stylebox("normal", "CardButton",
			_flat(p.surface_raised, 10, p.border, 1, 14, 12))
	theme.set_stylebox("hover", "CardButton",
			_flat(p.surface_hover, 10, p.border, 1, 14, 12))
	theme.set_stylebox("pressed", "CardButton",
			_flat(p.surface_hover, 10, p.accent, 1, 14, 12))

	theme.set_type_variation("CardButtonActive", "Button")
	theme.set_stylebox("normal", "CardButtonActive",
			_flat(_mix(p.surface_raised, p.accent, 0.10), 10, p.accent, 2, 14, 12))
	theme.set_stylebox("hover", "CardButtonActive",
			_flat(_mix(p.surface_hover, p.accent, 0.10), 10, p.accent, 2, 14, 12))
	theme.set_stylebox("pressed", "CardButtonActive",
			_flat(_mix(p.surface_hover, p.accent, 0.16), 10, p.accent, 2, 14, 12))

	# GhostButton: acciones secundarias discretas (desconectar, avanzado).
	theme.set_type_variation("GhostButton", "Button")
	theme.set_color("font_color", "GhostButton", p.text_secondary)
	theme.set_color("font_hover_color", "GhostButton", p.text_primary)
	theme.set_color("font_pressed_color", "GhostButton", p.text_primary)
	theme.set_stylebox("normal", "GhostButton",
			_flat(Color.TRANSPARENT, 8, p.border, 1, 14, 10))
	theme.set_stylebox("hover", "GhostButton",
			_flat(p.surface_raised, 8, p.border, 1, 14, 10))
	theme.set_stylebox("pressed", "GhostButton",
			_flat(p.surface_raised, 8, p.accent, 1, 14, 10))

	# ----------------------------------------------------------------
	# Sliders (track grueso + grabber grande para touch)
	# ----------------------------------------------------------------
	var track := _flat(p.surface_raised, 4, p.border, 1)
	track.content_margin_top = 4.0
	track.content_margin_bottom = 4.0
	var fill := _flat(p.accent, 4)
	fill.content_margin_top = 4.0
	fill.content_margin_bottom = 4.0
	theme.set_stylebox("slider", "HSlider", track)
	theme.set_stylebox("grabber_area", "HSlider", fill)
	theme.set_stylebox("grabber_area_highlight", "HSlider", fill)
	theme.set_icon("grabber", "HSlider", grabber_icon)
	theme.set_icon("grabber_highlight", "HSlider", grabber_icon)
	theme.set_icon("grabber_disabled", "HSlider", grabber_icon)
	theme.set_constant("grabber_offset", "HSlider", 0)

	# ----------------------------------------------------------------
	# LineEdit
	# ----------------------------------------------------------------
	theme.set_color("font_color", "LineEdit", p.text_primary)
	theme.set_color("font_placeholder_color", "LineEdit", p.text_hint)
	theme.set_color("caret_color", "LineEdit", p.accent)
	theme.set_stylebox("normal", "LineEdit",
			_flat(p.surface_raised, 8, p.border, 1, 14, 12))
	theme.set_stylebox("focus", "LineEdit",
			_flat(p.surface_raised, 8, p.accent, 2, 14, 12))

	# ----------------------------------------------------------------
	# CheckButton / Tooltip / separadores / scroll
	# ----------------------------------------------------------------
	theme.set_color("font_color", "CheckButton", p.text_primary)
	theme.set_font_size("font_size", "CheckButton", 16)

	theme.set_stylebox("panel", "TooltipPanel",
			_flat(p.surface_raised, 8, p.border, 1, 12, 8))
	theme.set_color("font_color", "TooltipLabel", p.text_primary)
	theme.set_font_size("font_size", "TooltipLabel", 14)

	var sep := StyleBoxLine.new()
	sep.color = p.border
	theme.set_stylebox("separator", "HSeparator", sep)

	var scroll_grabber := _flat(p.border, 6)
	scroll_grabber.content_margin_left = 5.0
	scroll_grabber.content_margin_right = 5.0
	var scroll_bg := _flat(Color.TRANSPARENT, 0)
	scroll_bg.content_margin_left = 5.0
	scroll_bg.content_margin_right = 5.0
	theme.set_stylebox("scroll", "VScrollBar", scroll_bg)
	theme.set_stylebox("grabber", "VScrollBar", scroll_grabber)
	theme.set_stylebox("grabber_highlight", "VScrollBar",
			_with_margins(_flat(p.text_hint, 6), 5.0, 0.0))
	theme.set_stylebox("grabber_pressed", "VScrollBar",
			_with_margins(_flat(p.accent, 6), 5.0, 0.0))

	return theme


## StyleBoxFlat con esquinas redondeadas, borde y margenes de contenido.
static func _flat(bg: Color, radius: int = 8, border: Color = Color.TRANSPARENT,
		border_w: int = 0, margin_h: float = 0.0, margin_v: float = 0.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	if border_w > 0:
		sb.set_border_width_all(border_w)
		sb.border_color = border
	if margin_h > 0.0:
		sb.content_margin_left = margin_h
		sb.content_margin_right = margin_h
	if margin_v > 0.0:
		sb.content_margin_top = margin_v
		sb.content_margin_bottom = margin_v
	return sb


static func _with_margins(sb: StyleBoxFlat, h: float, v: float) -> StyleBoxFlat:
	sb.content_margin_left = h
	sb.content_margin_right = h
	if v > 0.0:
		sb.content_margin_top = v
		sb.content_margin_bottom = v
	return sb


## Variacion de Label tipo "chip" (pildora con fondo suave del color dado).
static func _chip_label(theme: Theme, type_name: String, color: Color,
		font_semibold: Font) -> void:
	theme.set_type_variation(type_name, "Label")
	theme.set_font("font", type_name, font_semibold)
	theme.set_font_size("font_size", type_name, 13)
	theme.set_color("font_color", type_name, color)
	var bg := Color(color, 0.16)
	theme.set_stylebox("normal", type_name,
			_flat(bg, 99, Color(color, 0.55), 1, 10, 3))


## Mezcla lineal entre dos colores (para fondos "tintados" de acento).
static func _mix(a: Color, b: Color, t: float) -> Color:
	return a.lerp(b, t)
