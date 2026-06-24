class_name CoopRPC extends RefCounted



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

static func interact_pattern(on_client_submit: Callable, on_local_execute: Callable, on_host_broadcast: Callable) -> void:
	if not CoopAuthority.is_active():
		on_local_execute.call()
		return
	if CoopAuthority.is_client():
		on_client_submit.call()
		return
	on_local_execute.call()
	on_host_broadcast.call()


static func host_only(cb: Callable) -> void:
	if CoopAuthority.is_host():
		cb.call()


static func client_only(cb: Callable) -> void:
	if CoopAuthority.is_client():
		cb.call()


static func active_only(cb: Callable) -> void:
	if CoopAuthority.is_active():
		cb.call()


static func host_applies_and_broadcasts(on_apply: Callable, on_broadcast: Callable) -> void:
	if not CoopAuthority.is_host():
		return
	on_apply.call()
	if CoopAuthority.is_active():
		on_broadcast.call()
