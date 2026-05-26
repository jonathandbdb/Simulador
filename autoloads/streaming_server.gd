extends Node
## StreamingServer (Autoload Singleton) — Sprint 6
##
## Servidor WebSocket que corre en el Visor. Acepta clientes (la tablet de
## control en el futuro, hoy solo un cliente PC de prueba) y les hace
## broadcast del stream de video (JPGs binarios) capturado por
## features/tablet/streaming_capture.gd.
##
## Sprint 6 (PoC bloqueante): un solo canal binario, sin autenticacion.
## Sprint 7 agregara handshake con device_id, canal JSON de control y
## la UI dinamica de la tablet.
##
## Decision F3 #4 (PLAN.md): Opcion A (video real). PoC valida throughput
## sin matar el frame time del Quest (>=72 FPS con streaming activo).

const LISTEN_PORT := 9090

signal client_connected(peer_id: int, host: String)
signal client_disconnected(peer_id: int)
signal stream_ready(total_bytes_sent: int)
## Sprint 7: comando JSON entrante desde la tablet. La payload ya viene
## parseada (Dictionary). El listener (main.gd) decide que hacer con ella.
signal command_received(cmd: Dictionary, peer_id: int)

var _tcp := TCPServer.new()
var _peers: Dictionary = {}  # int -> WebSocketPeer
var _peer_hosts: Dictionary = {}  # int -> String (host del stream)
var _peer_handshaked: Dictionary = {}  # int -> bool (true tras STATE_OPEN)
var _next_peer_id: int = 1
var _total_bytes_sent: int = 0
var _listening: bool = false


func _ready() -> void:
	# En la build de tablet no levantamos el server (es solo cliente).
	if OS.has_feature("tablet"):
		set_process(false)
		return
	var err := _tcp.listen(LISTEN_PORT)
	if err != OK:
		push_error("StreamingServer: no se pudo escuchar en :%d (err=%d)" % [LISTEN_PORT, err])
		return
	_listening = true
	print("StreamingServer: escuchando en :%d" % LISTEN_PORT)


func _process(_delta: float) -> void:
	if not _listening:
		return

	# Aceptar conexiones entrantes y promoverlas a WebSocket.
	while _tcp.is_connection_available():
		var stream := _tcp.take_connection()
		if stream == null:
			break
		var peer := WebSocketPeer.new()
		var err := peer.accept_stream(stream)
		if err != OK:
			push_warning("StreamingServer: accept_stream fallo (err=%d)" % err)
			continue
		var pid := _next_peer_id
		_next_peer_id += 1
		_peers[pid] = peer
		_peer_hosts[pid] = "%s" % stream.get_connected_host()
		_peer_handshaked[pid] = false
		print("StreamingServer: TCP aceptado (pid=%d) desde %s, esperando handshake WS..." % [
			pid, _peer_hosts[pid],
		])

	# Poll a cada peer + limpiar los cerrados + emitir client_connected
	# RECIEN cuando el handshake WebSocket termino (STATE_OPEN).
	var to_remove: Array[int] = []
	for pid in _peers.keys():
		var peer: WebSocketPeer = _peers[pid]
		peer.poll()
		var state := peer.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			to_remove.append(pid)
			continue
		# Transicion CONNECTING -> OPEN: ahora si emitimos client_connected.
		if state == WebSocketPeer.STATE_OPEN and not _peer_handshaked[pid]:
			_peer_handshaked[pid] = true
			print("StreamingServer: cliente %d listo (WS handshake OK)" % pid)
			client_connected.emit(pid, _peer_hosts[pid])
		# Drenar paquetes entrantes. Sprint 7: si es texto -> JSON -> command_received.
		while peer.get_available_packet_count() > 0:
			var packet := peer.get_packet()
			if peer.was_string_packet():
				_handle_text_packet(pid, packet.get_string_from_utf8())

	for pid in to_remove:
		var was_open: bool = _peer_handshaked.get(pid, false)
		_peers.erase(pid)
		_peer_hosts.erase(pid)
		_peer_handshaked.erase(pid)
		if was_open:
			client_disconnected.emit(pid)
		print("StreamingServer: cliente %d desconectado" % pid)


## Envia un PackedByteArray binario a todos los clientes en STATE_OPEN.
## Llamado por streaming_capture.gd ~15 veces por segundo con un JPG.
func broadcast_binary(data: PackedByteArray) -> void:
	if data.is_empty() or _peers.is_empty():
		return
	for pid in _peers.keys():
		var peer: WebSocketPeer = _peers[pid]
		if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
			continue
		# WebSocketPeer.send() con PackedByteArray envia frame binario.
		peer.send(data)
	_total_bytes_sent += data.size()
	stream_ready.emit(_total_bytes_sent)


## Cantidad de clientes actualmente en STATE_OPEN. Util para HUD.
func get_open_client_count() -> int:
	var n := 0
	for pid in _peers.keys():
		var peer: WebSocketPeer = _peers[pid]
		if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			n += 1
	return n


func is_listening() -> bool:
	return _listening


## Envia texto (UTF8) a un cliente especifico. Devuelve true si pudo enviar.
## Usado por main.gd para enviar el catalogo de lentes al conectarse.
func send_text_to(peer_id: int, text: String) -> bool:
	if not _peers.has(peer_id):
		return false
	var peer: WebSocketPeer = _peers[peer_id]
	if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	peer.send_text(text)
	return true


## Envia texto (UTF8) a TODOS los clientes en STATE_OPEN.
func broadcast_text(text: String) -> void:
	for pid in _peers.keys():
		var peer: WebSocketPeer = _peers[pid]
		if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			peer.send_text(text)


func _handle_text_packet(peer_id: int, text: String) -> void:
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("StreamingServer: paquete texto no-JSON o no-Dict de peer %d: %s" % [peer_id, text])
		return
	command_received.emit(parsed, peer_id)
