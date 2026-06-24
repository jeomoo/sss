class_name CoopHook extends RefCounted



const CoopFrameworksReady = preload("res://mods/RTVCoop/HookKit/CoopFrameworksReady.gd")

static func register(owner: Node, hook_name: String, callback: Callable, priority: int = 100) -> int:
	if not CoopFrameworksReady.is_available():
		push_warning("[CoopHook] RTVModLib missing; '%s' skipped" % hook_name)
		return -1
	var id: int = CoopFrameworksReady.lib().hook(hook_name, callback, priority)
	if id != -1:
		_track(owner, id)
	return id


static func register_replace_or_post(owner: Node, hook_base: String, replace_cb: Callable, post_cb: Callable, priority: int = 100) -> int:
	if not CoopFrameworksReady.is_available():
		return -1
	var lib = CoopFrameworksReady.lib()
	var id: int = lib.hook(hook_base, replace_cb, priority)
	if id != -1:
		_track(owner, id)
		return id
	var fallback_id: int = lib.hook(hook_base + "-post", post_cb, priority)
	if fallback_id != -1:
		_track(owner, fallback_id)
		push_warning("[CoopHook] '%s' replace owned by id=%d; fell back to -post" % [hook_base, lib.get_replace_owner(hook_base)])
	return fallback_id


static func unhook_all(owner: Node) -> void:
	if not CoopFrameworksReady.is_available():
		return
	var lib = CoopFrameworksReady.lib()
	var ids: Array = owner.get_meta("_coop_hook_ids", [])
	for id in ids:
		lib.unhook(id)
	owner.set_meta("_coop_hook_ids", [])


static func caller() -> Node:
	if not CoopFrameworksReady.is_available():
		return null
	return CoopFrameworksReady.lib()._caller


static func skip_super() -> void:
	if CoopFrameworksReady.is_available():
		CoopFrameworksReady.lib().skip_super()


static func has_replace(hook_base: String) -> bool:
	if not CoopFrameworksReady.is_available():
		return false
	return CoopFrameworksReady.lib().has_replace(hook_base)


static func _track(owner: Node, id: int) -> void:
	var ids: Array = owner.get_meta("_coop_hook_ids", [])
	ids.append(id)
	owner.set_meta("_coop_hook_ids", ids)
