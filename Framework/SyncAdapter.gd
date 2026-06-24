class_name SyncAdapter extends Node


const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")


func _enter_tree() -> void:
	var svc := _sync_service()
	if svc:
		svc.register(_sync_key(), self)


func _exit_tree() -> void:
	var svc := _sync_service()
	if svc and svc.get_module(_sync_key()) == self:
		svc.unregister(_sync_key())


func _sync_key() -> String:
	push_error("[SyncAdapter] _sync_key() not overridden in %s" % get_script().resource_path)
	return get_script().resource_path.get_file().get_basename().to_lower()


func _sync_service() -> Node:
	if not Engine.has_meta("Coop"):
		return null
	var coop: Node = Engine.get_meta("Coop")
	return coop.sync_service if "sync_service" in coop else null


func get_sync(key: String) -> Node:
	var svc := _sync_service()
	return svc.get_module(key) if svc else null


static func coop_walk(node: Node, visitor: Callable) -> bool:
	if node == null:
		return false
	if visitor.call(node):
		return true
	for child in node.get_children():
		if coop_walk(child, visitor):
			return true
	return false
