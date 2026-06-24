class_name BaseSync extends "res://mods/RTVCoop/Framework/SyncAdapter.gd"


const RTVCoop = preload("res://mods/RTVCoop/Game/Coop.gd")


func _host_do_and_broadcast(local_fn: Callable, broadcast_fn: Callable) -> void:
	if not CoopAuthority.is_host():
		return
	local_fn.call()
	if CoopAuthority.is_active():
		broadcast_fn.call()


func _sync(key: String) -> Node:
	var coop := RTVCoop.get_instance()
	return coop.get_sync(key) if coop else null
