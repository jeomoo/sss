class_name CoopAPI extends RefCounted


const _Coop = preload("res://mods/RTVCoop/Game/Coop.gd")
const _Auth = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")


# ── Session state ────────────────────────────────────────────────

static func is_active() -> bool:
	return _Auth.is_active()

static func is_host() -> bool:
	return _Auth.is_host()

static func is_client() -> bool:
	return _Auth.is_client()

static func local_peer_id() -> int:
	return _Auth.local_peer_id()

static func get_peer_ids() -> Array:
	var coop := _Coop.get_instance()
	if coop == null or coop.net == null:
		return []
	return coop.net.GetPeerIds() if coop.net.has_method("GetPeerIds") else []

static func get_peer_name(peer_id: int) -> String:
	var coop := _Coop.get_instance()
	if coop == null or coop.players == null:
		return "Player %d" % peer_id
	return coop.players.GetPlayerName(peer_id) if coop.players.has_method("GetPlayerName") else "Player %d" % peer_id


# ── Events ───────────────────────────────────────────────────────
# Convenience wrappers around CoopEvents signals.
# Usage: CoopAPI.on("peer_joined", my_callback)

static func events() -> Node:
	var coop := _Coop.get_instance()
	return coop.events if coop else null

static func on(signal_name: String, callback: Callable) -> bool:
	var ev := events()
	if ev == null or not ev.has_signal(signal_name):
		return false
	if not ev.is_connected(signal_name, callback):
		ev.connect(signal_name, callback)
	return true

static func off(signal_name: String, callback: Callable) -> void:
	var ev := events()
	if ev and ev.is_connected(signal_name, callback):
		ev.disconnect(signal_name, callback)


# ── Custom mod events (RPC bridge) ───────────────────────────────
# Send arbitrary data to all peers or a specific peer.
# Usage:
#   CoopAPI.send_mod_event("my_mod:something_found", {"pos": pos})
#   CoopAPI.on_mod_event("my_mod:something_found", _on_something)

static func _bridge() -> Node:
	var coop := _Coop.get_instance()
	return coop.get_sync("mod_bridge") if coop else null

static func send_mod_event(event_name: String, data: Dictionary = {}) -> void:
	var bridge := _bridge()
	if bridge and bridge.has_method("send_event"):
		bridge.send_event(event_name, data)

static func send_mod_event_to(peer_id: int, event_name: String, data: Dictionary = {}) -> void:
	var bridge := _bridge()
	if bridge and bridge.has_method("send_event_to"):
		bridge.send_event_to(peer_id, event_name, data)

static func on_mod_event(event_name: String, callback: Callable) -> void:
	var bridge := _bridge()
	if bridge and bridge.has_method("register_listener"):
		bridge.register_listener(event_name, callback)

static func off_mod_event(event_name: String, callback: Callable) -> void:
	var bridge := _bridge()
	if bridge and bridge.has_method("unregister_listener"):
		bridge.unregister_listener(event_name, callback)


# ── Players ──────────────────────────────────────────────────────

static func get_local_controller() -> Node:
	var coop := _Coop.get_instance()
	if coop == null or coop.players == null:
		return null
	return coop.players.GetLocalController() if coop.players.has_method("GetLocalController") else null

static func get_local_interface() -> Node:
	var coop := _Coop.get_instance()
	if coop == null or coop.players == null:
		return null
	return coop.players.GetLocalInterface() if coop.players.has_method("GetLocalInterface") else null

static func get_puppet(peer_id: int) -> Node:
	var coop := _Coop.get_instance()
	if coop == null or coop.players == null:
		return null
	return coop.players.GetPuppet(peer_id) if coop.players.has_method("GetPuppet") else null

static func get_all_puppets() -> Dictionary:
	var coop := _Coop.get_instance()
	if coop == null or coop.players == null:
		return {}
	return coop.players.remote_players if "remote_players" in coop.players else {}


# ── Scene ────────────────────────────────────────────────────────

static func get_map() -> Node:
	var coop := _Coop.get_instance()
	return coop.scene.get_map() if coop and coop.scene else null

static func get_core_ui() -> Node:
	var coop := _Coop.get_instance()
	return coop.scene.core_ui() if coop and coop.scene else null


# ── Settings ─────────────────────────────────────────────────────

static func get_setting(key: String, default_value: float = 0.0) -> float:
	var coop := _Coop.get_instance()
	if coop == null or coop.settings == null:
		return default_value
	return coop.settings.Get(key, default_value) if coop.settings.has_method("Get") else default_value

static func set_setting(key: String, value: float) -> void:
	var coop := _Coop.get_instance()
	if coop and coop.settings and coop.settings.has_method("Set"):
		coop.settings.Set(key, value)


# ── Sync modules ─────────────────────────────────────────────────

static func get_sync(key: String) -> Node:
	var coop := _Coop.get_instance()
	return coop.get_sync(key) if coop else null

static func register_sync(key: String, module: Node) -> void:
	var coop := _Coop.get_instance()
	if coop:
		coop.register_sync(key, module)


# ── Item serialization ───────────────────────────────────────────

static func serialize_slot(slot_data) -> Dictionary:
	var ss := get_sync("slot_serializer")
	if ss and ss.has_method("SerializeSlotData"):
		return ss.SerializeSlotData(slot_data)
	return {}

static func deserialize_slot(dict: Dictionary):
	var ss := get_sync("slot_serializer")
	if ss and ss.has_method("DeserializeSlotData"):
		return ss.DeserializeSlotData(dict)
	return null
