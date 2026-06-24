extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

var _coop_event_id: int = 0


func _setup_hooks() -> void:
	CoopHook.register(self, "eventsystem-_ready-post", _on_event_system_ready_post)
	CoopHook.register_replace_or_post(self, "eventsystem-fighterjet", _replace_fighter_jet, _noop)
	CoopHook.register(self, "eventsystem-fighterjet-post", _post_fighter_jet)
	CoopHook.register_replace_or_post(self, "eventsystem-airdrop", _replace_airdrop, _noop)
	CoopHook.register(self, "eventsystem-airdrop-post", _post_airdrop)
	CoopHook.register_replace_or_post(self, "eventsystem-helicopter", _replace_helicopter, _noop)
	CoopHook.register(self, "eventsystem-helicopter-post", _post_helicopter)
	CoopHook.register_replace_or_post(self, "eventsystem-police", _replace_police, _noop)
	CoopHook.register(self, "eventsystem-police-post", _post_police)
	CoopHook.register_replace_or_post(self, "eventsystem-btr", _replace_btr, _noop)
	CoopHook.register(self, "eventsystem-btr-post", _post_btr)
	CoopHook.register_replace_or_post(self, "eventsystem-crashsite", _replace_crash, _noop)
	CoopHook.register(self, "eventsystem-crashsite-post", _post_crash)
	CoopHook.register_replace_or_post(self, "eventsystem-cat", _replace_cat, _noop)
	CoopHook.register(self, "eventsystem-cat-post", _post_cat)
	CoopHook.register(self, "eventsystem-transmission-post", _on_transmission_post)


func _noop() -> void:
	pass


func _register_event_containers(root: Node) -> void:
	if root == null or players == null:
		return
	for child in root.get_children():
		if child is LootContainer:
			if not child.is_in_group("CoopLootContainer"):
				child.add_to_group("CoopLootContainer")
			if not child.has_meta("coop_container_id"):
				child.set_meta("coop_container_id", players.nextContainerId)
				players.nextContainerId += 1
		_register_event_containers(child)


func _next_name(base: String) -> String:
	_coop_event_id += 1
	return base + "_coop_" + str(_coop_event_id)


func _on_event_system_ready_post() -> void:
	var es := CoopHook.caller()
	if es == null:
		return
	if not es.is_in_group("EventSystem"):
		es.add_to_group("EventSystem")


func _host_skip_for_client() -> bool:
	return CoopAuthority.is_active() and not CoopAuthority.is_host()


func _broadcast(event_name: String, params: Dictionary) -> void:
	if not (CoopAuthority.is_active() and CoopAuthority.is_host()):
		return
	if event:
		event.BroadcastEvent.rpc(event_name, params)


func _replace_fighter_jet() -> void:
	if _host_skip_for_client():
		CoopHook.skip_super()


func _post_fighter_jet() -> void:
	var es := CoopHook.caller()
	if es == null or not CoopAuthority.is_host() or not CoopAuthority.is_active():
		return
	var children: Array = es.get_children()
	if children.is_empty():
		return
	var instance: Node = children[children.size() - 1]
	var cname: String = _next_name("FighterJet")
	instance.name = cname
	_broadcast("FighterJet", {"pos": instance.global_position, "rot": instance.global_rotation, "_cname": cname})


func _replace_airdrop() -> void:
	if _host_skip_for_client():
		CoopHook.skip_super()


func _post_airdrop() -> void:
	var es := CoopHook.caller()
	if es == null or not CoopAuthority.is_host() or not CoopAuthority.is_active():
		return
	var children: Array = es.get_children()
	if children.is_empty():
		return
	var instance: Node = children[children.size() - 1]
	var cname: String = _next_name("CASA")
	instance.name = cname
	var start_cid: int = players.nextContainerId if players else 0
	_register_event_containers(instance)
	_broadcast("Airdrop", {
		"pos": instance.global_position,
		"rot": instance.global_rotation,
		"dropThreshold": instance.dropThreshold,
		"_cname": cname,
		"_startCid": start_cid,
	})


func _replace_helicopter() -> void:
	if _host_skip_for_client():
		CoopHook.skip_super()


func _post_helicopter() -> void:
	var es := CoopHook.caller()
	if es == null or not CoopAuthority.is_host() or not CoopAuthority.is_active():
		return
	var children: Array = es.get_children()
	if children.is_empty():
		return
	var instance: Node = children[children.size() - 1]
	var cname: String = _next_name("Helicopter")
	instance.name = cname
	_broadcast("Helicopter", {"pos": instance.global_position, "rot": instance.global_rotation, "_cname": cname})


func _replace_police() -> void:
	if _host_skip_for_client():
		CoopHook.skip_super()


func _post_police() -> void:
	_broadcast_path_event("Police")


func _replace_btr() -> void:
	if _host_skip_for_client():
		CoopHook.skip_super()


func _post_btr() -> void:
	_broadcast_path_event("BTR")


func _broadcast_path_event(event_name: String) -> void:
	var es := CoopHook.caller()
	if es == null or not CoopAuthority.is_host() or not CoopAuthority.is_active():
		return
	var children: Array = es.get_children()
	if children.is_empty():
		return
	var instance: Node = children[children.size() - 1]
	var cname: String = _next_name(event_name)
	instance.name = cname
	var path_index: int = instance.selectedPath.get_index() if instance.get("selectedPath") else 0
	_broadcast(event_name, {
		"pathIndex": path_index,
		"inverse": instance.inversePath if "inversePath" in instance else false,
		"_cname": cname,
	})


func _replace_crash() -> void:
	if _host_skip_for_client():
		CoopHook.skip_super()


func _post_crash() -> void:
	var es := CoopHook.caller()
	if es == null or not CoopAuthority.is_host() or not CoopAuthority.is_active():
		return
	var crashes_node: Node = es.get_node_or_null("Crashes")
	if crashes_node == null:
		return
	for i in crashes_node.get_child_count():
		var crash_point: Node = crashes_node.get_child(i)
		if crash_point.get_child_count() > 0:
			var last_child: Node = crash_point.get_child(crash_point.get_child_count() - 1)
			if last_child.scene_file_path.find("Helicopter_Crash") != -1:
				var start_cid: int = players.nextContainerId if players else 0
				_register_event_containers(last_child)
				_broadcast("CrashSite", {"crashIndex": i, "_startCid": start_cid})
				return


func _replace_cat() -> void:
	if _host_skip_for_client():
		CoopHook.skip_super()


func _post_cat() -> void:
	var es := CoopHook.caller()
	if es == null or not CoopAuthority.is_host() or not CoopAuthority.is_active():
		return
	var wells: Array = get_tree().get_nodes_in_group("Well")
	if wells.is_empty():
		return
	for i in wells.size():
		var well: Node = wells[i]
		var bottom: Node = well.get_node_or_null("Bottom")
		if bottom and bottom.get_child_count() > 0:
			_broadcast("Cat", {"wellIndex": i})
			return


func _on_transmission_post() -> void:
	if not CoopAuthority.is_host() or not CoopAuthority.is_active():
		return
	_broadcast("Transmission", {})
