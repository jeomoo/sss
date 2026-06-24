class_name CoopNet extends Node



const RTVCoop = preload("res://mods/RTVCoop/Game/Coop.gd")

const DEFAULT_PORT := 27015
const DEFAULT_MAX_PEERS := 4
const DEFAULT_ADDRESS := "127.0.0.1"
const PEER_TIMEOUT_MS := 90000


enum Mode { NONE, HOST, CLIENT }
enum Transport { ENET, STEAM }


signal hosted
signal joined
signal disconnected
signal peer_joined(id: int)
signal peer_left(id: int)
signal connection_failed_signal


var mode: Mode = Mode.NONE
var transport: Transport = Transport.ENET
var peer = null


func _enter_tree() -> void:
	var coop := RTVCoop.get_instance()
	if coop:
		coop.net = self


func _exit_tree() -> void:
	var coop := RTVCoop.get_instance()
	if coop and coop.net == self:
		coop.net = null


func _ready() -> void:
	if ClassDB.class_exists("SteamMultiplayerPeer"):
		transport = Transport.STEAM
		print("[CoopNet] Transport: SteamMultiplayerPeer (NAT-traversal via SDR)")
	else:
		transport = Transport.ENET
		print("[CoopNet] Transport: ENetMultiplayerPeer (direct IP)")
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	print("[CoopNet] Ready at " + str(get_path()))


func HostGame(port: int = DEFAULT_PORT, max_peers: int = DEFAULT_MAX_PEERS) -> bool:
	if mode != Mode.NONE:
		push_warning("[CoopNet] already active; Disconnect() first")
		return false
	if transport == Transport.STEAM:
		# fix4: if Steam class is registered but the lobby/init phase failed earlier, _host_steam
		# can crash the game when it touches the uninitialised peer. Fall back to ENet on any
		# failure rather than letting the host action take the process down.
		if _host_steam(max_peers):
			return true
		push_warning("[CoopNet] Steam host path failed — falling back to ENet loopback")
		return _host_enet(port, max_peers)
	return _host_enet(port, max_peers)


func HostGameEnet(port: int = DEFAULT_PORT, max_peers: int = DEFAULT_MAX_PEERS) -> bool:
	if mode != Mode.NONE:
		push_warning("[CoopNet] already active; Disconnect() first")
		return false
	return _host_enet(port, max_peers)


func _host_steam(max_peers: int) -> bool:
	# fix4: hard-gate on ClassDB so a stale Transport.STEAM (from an aborted GodotSteam load)
	# can't reach the instantiate path. Without this, instantiate("SteamMultiplayerPeer") may
	# crash on a partially-registered class.
	if not ClassDB.class_exists("SteamMultiplayerPeer"):
		push_error("[CoopNet] SteamMultiplayerPeer class not registered — Steam transport unavailable")
		return false
	var p = ClassDB.instantiate("SteamMultiplayerPeer")
	if p == null:
		push_error("[CoopNet] SteamMultiplayerPeer instantiate failed")
		return false
	var err: int = p.create_host(0)
	if err != OK:
		push_error("[CoopNet] Steam host failed (err %d)" % err)
		return false
	peer = p
	multiplayer.multiplayer_peer = peer
	mode = Mode.HOST
	var coop := RTVCoop.get_instance()
	if coop:
		coop.set_meta("coop_active", true)
	print("[CoopNet] HOSTING via Steam (max %d peers, my id %d)" % [max_peers, multiplayer.get_unique_id()])
	var _l = Engine.get_meta("CoopLogger", null)
	if _l: _l.set_peer_label("HOST")
	hosted.emit()
	_notify_authority_changed()
	return true


func _host_enet(port: int, max_peers: int) -> bool:
	var p := ENetMultiplayerPeer.new()
	var err: int = p.create_server(port, max_peers)
	if err != OK:
		push_error("[CoopNet] ENet host failed (err %d)" % err)
		return false
	peer = p
	multiplayer.multiplayer_peer = peer
	mode = Mode.HOST
	var coop := RTVCoop.get_instance()
	if coop:
		coop.set_meta("coop_active", true)
	SetPeerTimeouts()
	print("[CoopNet] HOSTING on port %d (max %d, my id %d)" % [port, max_peers, multiplayer.get_unique_id()])
	var _l = Engine.get_meta("CoopLogger", null)
	if _l: _l.set_peer_label("HOST")
	hosted.emit()
	_notify_authority_changed()
	return true


func JoinGame(address: String = DEFAULT_ADDRESS, port: int = DEFAULT_PORT) -> bool:
	if mode != Mode.NONE:
		push_warning("[CoopNet] already active; Disconnect() first")
		return false
	return _join_enet(address, port)


func JoinSteam(host_id: int) -> bool:
	if mode != Mode.NONE:
		push_warning("[CoopNet] already active; Disconnect() first")
		return false
	if transport != Transport.STEAM:
		push_error("[CoopNet] Steam transport unavailable")
		return false
	var p = ClassDB.instantiate("SteamMultiplayerPeer")
	if p == null:
		push_error("[CoopNet] SteamMultiplayerPeer instantiate failed")
		return false
	var err: int = p.create_client(host_id, 0)
	if err != OK:
		push_error("[CoopNet] Steam join failed (err %d)" % err)
		return false
	peer = p
	multiplayer.multiplayer_peer = peer
	mode = Mode.CLIENT
	print("[CoopNet] JOINING Steam host %d..." % host_id)
	var _l = Engine.get_meta("CoopLogger", null)
	if _l: _l.set_peer_label("CLIENT")
	return true


func _join_enet(address: String, port: int) -> bool:
	var p := ENetMultiplayerPeer.new()
	var err: int = p.create_client(address, port)
	if err != OK:
		push_error("[CoopNet] ENet join failed (err %d)" % err)
		return false
	peer = p
	multiplayer.multiplayer_peer = peer
	mode = Mode.CLIENT
	print("[CoopNet] JOINING %s:%d..." % [address, port])
	var _l = Engine.get_meta("CoopLogger", null)
	if _l: _l.set_peer_label("CLIENT")
	return true


func Disconnect() -> void:
	if mode == Mode.NONE:
		return
	if peer:
		peer.close()
	peer = null
	multiplayer.multiplayer_peer = null
	mode = Mode.NONE
	var coop := RTVCoop.get_instance()
	if coop:
		coop.set_meta("coop_active", false)
	print("[CoopNet] disconnected")
	disconnected.emit()
	_notify_authority_changed()
	_notify_event(&"transport_disconnected", [])


func SetPeerTimeouts() -> void:
	if peer == null or not (peer is ENetMultiplayerPeer):
		return
	if not peer.host:
		return
	for p in peer.host.get_peers():
		p.set_timeout(0, PEER_TIMEOUT_MS, PEER_TIMEOUT_MS)


func IsHost() -> bool: return mode == Mode.HOST
func IsClient() -> bool: return mode == Mode.CLIENT
func IsActive() -> bool: return mode != Mode.NONE
func IsSteamTransport() -> bool: return transport == Transport.STEAM


func GetPeerIds() -> Array:
	return multiplayer.get_peers() if mode != Mode.NONE else []


func GetLocalPeerId() -> int:
	return multiplayer.get_unique_id() if mode != Mode.NONE else 1


func _on_peer_connected(id: int) -> void:
	print("[CoopNet] peer connected (%d)" % id)
	SetPeerTimeouts()
	peer_joined.emit(id)


func _on_peer_disconnected(id: int) -> void:
	print("[CoopNet] peer disconnected (%d)" % id)
	peer_left.emit(id)


func _on_connected_to_server() -> void:
	print("[CoopNet] connected to host (my id = %d)" % multiplayer.get_unique_id())
	var coop := RTVCoop.get_instance()
	if coop:
		coop.set_meta("coop_active", true)
		var ai_sync = coop.get_sync("ai")
		if ai_sync and ai_sync.has_method("_proactive_disable_module_hub"):
			ai_sync._proactive_disable_module_hub()
	SetPeerTimeouts()
	joined.emit()
	_notify_authority_changed()
	_notify_event(&"transport_connected", [transport])


func _on_connection_failed() -> void:
	print("[CoopNet] connection failed")
	peer = null
	multiplayer.multiplayer_peer = null
	mode = Mode.NONE
	var coop := RTVCoop.get_instance()
	if coop:
		coop.set_meta("coop_active", false)
	connection_failed_signal.emit()


func _on_server_disconnected() -> void:
	print("[CoopNet] host disconnected — returning to main menu")
	peer = null
	multiplayer.multiplayer_peer = null
	mode = Mode.NONE
	var coop := RTVCoop.get_instance()
	if coop:
		coop.set_meta("coop_active", false)
	disconnected.emit()
	_notify_authority_changed()
	_notify_event(&"transport_disconnected", [])
	# v0.9: return client to main menu instead of stranding in dummy world
	if Loader and Loader.gameData and not Loader.gameData.menu:
		Loader.Message("호스트가 종료했습니다 — 메인 메뉴로 복귀", Color.ORANGE)
		Loader.LoadScene("Menu")


func _notify_authority_changed() -> void:
	var coop := RTVCoop.get_instance()
	if coop and coop.events:
		coop.events.authority_changed.emit(IsHost())


func _notify_event(signal_name: StringName, args: Array) -> void:
	var coop := RTVCoop.get_instance()
	if coop == null or coop.events == null:
		return
	if not coop.events.has_signal(signal_name):
		return
	if args.is_empty():
		coop.events.emit_signal(signal_name)
	else:
		coop.events.emit_signal(signal_name, args[0])


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_F9:
			print("[CoopNet] F9 — ENet host (loopback test)")
			HostGameEnet()
		elif event.physical_keycode == KEY_F10:
			print("[CoopNet] F10 — ENet join %s (loopback test)" % DEFAULT_ADDRESS)
			JoinGame()
		elif event.physical_keycode == KEY_F11:
			print("[CoopNet] F11 — Disconnect")
			Disconnect()
