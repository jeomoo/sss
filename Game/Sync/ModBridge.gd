extends "res://mods/RTVCoop/Game/Sync/BaseSync.gd"


var _listeners: Dictionary = {}


func _sync_key() -> String:
	return "mod_bridge"


func register_listener(event_name: String, callback: Callable) -> void:
	if not _listeners.has(event_name):
		_listeners[event_name] = []
	var list: Array = _listeners[event_name]
	if not list.has(callback):
		list.append(callback)


func unregister_listener(event_name: String, callback: Callable) -> void:
	if not _listeners.has(event_name):
		return
	_listeners[event_name].erase(callback)
	if _listeners[event_name].is_empty():
		_listeners.erase(event_name)


func send_event(event_name: String, data: Dictionary = {}) -> void:
	if not CoopAuthority.is_active():
		_dispatch_local(event_name, data)
		return
	if CoopAuthority.is_host():
		BroadcastModEvent.rpc(event_name, data)
	else:
		SubmitModEvent.rpc_id(1, event_name, data)


func send_event_to(peer_id: int, event_name: String, data: Dictionary = {}) -> void:
	if not CoopAuthority.is_active():
		_dispatch_local(event_name, data)
		return
	if CoopAuthority.is_host():
		DeliverModEvent.rpc_id(peer_id, event_name, data)
	else:
		SubmitModEventTo.rpc_id(1, peer_id, event_name, data)


@rpc("any_peer", "reliable", "call_remote")
func SubmitModEvent(event_name: String, data: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	BroadcastModEvent.rpc(event_name, data)


@rpc("any_peer", "reliable", "call_remote")
func SubmitModEventTo(target_peer: int, event_name: String, data: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	DeliverModEvent.rpc_id(target_peer, event_name, data)


@rpc("authority", "reliable", "call_local")
func BroadcastModEvent(event_name: String, data: Dictionary) -> void:
	_dispatch_local(event_name, data)


@rpc("authority", "reliable", "call_remote")
func DeliverModEvent(event_name: String, data: Dictionary) -> void:
	_dispatch_local(event_name, data)


func _dispatch_local(event_name: String, data: Dictionary) -> void:
	if not _listeners.has(event_name):
		return
	for callback in _listeners[event_name]:
		if callback.is_valid():
			callback.call(data)
