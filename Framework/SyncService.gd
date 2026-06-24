class_name SyncService extends Node


signal sync_registered(key: String, module: Node)
signal sync_unregistered(key: String)


var _modules: Dictionary = {}


func register(key: String, module: Node) -> void:
	if _modules.has(key):
		push_warning("[SyncService] '%s' already registered; overwriting" % key)
	_modules[key] = module
	sync_registered.emit(key, module)


func unregister(key: String) -> void:
	if not _modules.has(key):
		return
	_modules.erase(key)
	sync_unregistered.emit(key)


func get_module(key: String) -> Node:
	return _modules.get(key, null)


func has_module(key: String) -> bool:
	return _modules.has(key)


func modules() -> Dictionary:
	return _modules
