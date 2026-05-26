extends Node
## DiscoveryBeacon — Sprint 7 (Opcion A: UDP broadcast LAN discovery)
##
## En el visor: envia cada 2s un broadcast UDP a 255.255.255.255:9091 con
## un JSON {"app","device_id","ws_port","ts"} para que cualquier cliente
## tablet en la misma LAN lo descubra sin tener que pedir IP manual.
##
## En la tablet (mismo autoload, modo listen): bindea :9091 en wildcard
## y escucha broadcasts. Cada paquete valido se reporta por la senal
## `visor_discovered(host, payload)`.
##
## Modo de operacion automatico:
##   - Si existe la feature "tablet" (export AndroidTablet) -> listen.
##   - Si no -> broadcast (es el visor).

const BEACON_PORT := 9091
const BROADCAST_ADDR := "255.255.255.255"
const BROADCAST_INTERVAL := 2.0
const APP_TAG := "simulador-vr"

signal visor_discovered(host: String, payload: Dictionary)

var _udp: PacketPeerUDP
var _is_listener: bool = false
var _broadcast_timer: Timer

# Cache de hosts vistos recientemente (host -> ultimo timestamp recibido).
# Permite que la UI muestre dispositivos "online".
var _seen_hosts: Dictionary = {}


func _ready() -> void:
	_udp = PacketPeerUDP.new()
	_is_listener = OS.has_feature("tablet")

	if _is_listener:
		_start_listening()
	else:
		_start_broadcasting()


# ====================================================================
# Visor: emite beacons
# ====================================================================
func _start_broadcasting() -> void:
	_udp.set_broadcast_enabled(true)
	# El visor no necesita bindear puerto local; solo manda.
	var err := _udp.set_dest_address(BROADCAST_ADDR, BEACON_PORT)
	if err != OK:
		push_warning("DiscoveryBeacon: set_dest_address fallo: %d" % err)
		return

	_broadcast_timer = Timer.new()
	_broadcast_timer.wait_time = BROADCAST_INTERVAL
	_broadcast_timer.one_shot = false
	_broadcast_timer.autostart = true
	_broadcast_timer.timeout.connect(_send_beacon)
	add_child(_broadcast_timer)
	# Primer beacon inmediato.
	_send_beacon()
	print("DiscoveryBeacon: broadcasting cada %.1fs a %s:%d" % [
		BROADCAST_INTERVAL, BROADCAST_ADDR, BEACON_PORT,
	])


func _send_beacon() -> void:
	var payload := {
		"app": APP_TAG,
		"device_id": _get_device_id(),
		"ws_port": 9090,
		"ts": Time.get_unix_time_from_system(),
	}
	var bytes := JSON.stringify(payload).to_utf8_buffer()
	var err := _udp.put_packet(bytes)
	if err != OK and err != ERR_UNAVAILABLE:
		# ERR_UNAVAILABLE puede aparecer si no hay red; no spam de warnings.
		push_warning("DiscoveryBeacon: put_packet err=%d" % err)


func _get_device_id() -> String:
	# Reaprovecha lo que ya conocemos. En Sprint 9 vendra de la licencia.
	return OS.get_unique_id()


# ====================================================================
# Tablet: escucha beacons
# ====================================================================
func _start_listening() -> void:
	# Bindear en wildcard para recibir broadcasts.
	var err := _udp.bind(BEACON_PORT, "0.0.0.0")
	if err != OK:
		push_warning("DiscoveryBeacon: bind %d fallo: %d" % [BEACON_PORT, err])
		return
	print("DiscoveryBeacon: listening en :%d" % BEACON_PORT)
	set_process(true)


func _process(_delta: float) -> void:
	if not _is_listener:
		return
	while _udp.get_available_packet_count() > 0:
		var pkt := _udp.get_packet()
		var host := _udp.get_packet_ip()
		var text := pkt.get_string_from_utf8()
		var parsed = JSON.parse_string(text)
		if not (parsed is Dictionary):
			continue
		if parsed.get("app", "") != APP_TAG:
			continue
		_seen_hosts[host] = Time.get_unix_time_from_system()
		visor_discovered.emit(host, parsed)


## Devuelve la lista de hosts vistos en los ultimos `max_age` segundos.
func get_active_hosts(max_age: float = 6.0) -> Array:
	var now := Time.get_unix_time_from_system()
	var alive: Array = []
	for host in _seen_hosts.keys():
		if now - _seen_hosts[host] <= max_age:
			alive.append(host)
	return alive
