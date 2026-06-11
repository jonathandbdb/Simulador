extends ScrollContainer
## ScrollContainer paneable con el dedo desde cualquier parte del contenido.
##
## El paneo tactil NATIVO de ScrollContainer (con inercia, en Android) solo
## funciona si el press/drag le LLEGA: los PanelContainer de las cards traen
## mouse_filter = STOP por defecto, que no consume el evento pero CORTA la
## propagacion hacia arriba — el scroll nunca se enteraba del gesto y la unica
## forma de desplazarse era la barra. Este script convierte STOP -> PASS en los
## controles NO interactivos de su subarbol (paneles, contenedores, labels),
## dejando intactos botones, sliders, scrollbars e inputs, que deben seguir
## consumiendo sus propios gestos. Cubre tambien los nodos agregados en runtime
## (filas de parametros, cards de lentes).

func _ready() -> void:
	# Umbral (px) antes de empezar a panear: evita el jiggle vertical mientras
	# una fila decide que el gesto es un ajuste horizontal (~14 px de intencion).
	scroll_deadzone = 24
	_make_pass_through(self)
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if node is Control and is_ancestor_of(node):
		_adjust(node)


func _make_pass_through(node: Node) -> void:
	for child in node.get_children():
		if child is Control:
			_adjust(child)
		_make_pass_through(child)


## STOP -> PASS solo en controles no interactivos. Nunca toca IGNORE.
func _adjust(c: Control) -> void:
	if c is BaseButton or c is Range or c is LineEdit or c is TextEdit \
			or c is ItemList or c is Tree or c is RichTextLabel:
		return
	if c.mouse_filter == Control.MOUSE_FILTER_STOP:
		c.mouse_filter = Control.MOUSE_FILTER_PASS
