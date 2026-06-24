class_name CoopAuthority extends RefCounted



const RTVCoop = preload("res://mods/RTVCoop/Game/Coop.gd")

static func _net() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.net if coop else null


static func is_active() -> bool:
	var n := _net()
	return n != null and n.has_method("IsActive") and n.IsActive()


static func is_host() -> bool:
	if not is_active():
		return true
	var n := _net()
	return n.IsHost() if n.has_method("IsHost") else true


static func is_client() -> bool:
	if not is_active():
		return false
	var n := _net()
	return n.IsClient() if n.has_method("IsClient") else false


static func local_peer_id() -> int:
	var n := _net()
	if n == null or not n.has_method("GetLocalPeerId"):
		return 1
	return n.GetLocalPeerId()


static func is_local_authority(node: Node) -> bool:
	if not is_active():
		return true
	if node == null or not node.is_inside_tree():
		return false
	return node.is_multiplayer_authority()
