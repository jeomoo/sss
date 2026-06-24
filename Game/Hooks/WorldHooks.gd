extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

func _setup_hooks() -> void:
	CoopHook.register_replace_or_post(self, "radio-interact", _replace_radio_interact, _post_radio_interact)
	CoopHook.register_replace_or_post(self, "television-interact", _replace_television_interact, _post_television_interact)
	CoopHook.register(self, "catrescue-interact-post", _on_catrescue_interact_post)


func _replace_radio_interact() -> void:
	var radio := CoopHook.caller()
	if radio == null or radio.has_meta("_coop_in_remote_interact"):
		return
	_try_coop_route_toggle(radio)


func _post_radio_interact() -> void:
	pass


func _replace_television_interact() -> void:
	var tv := CoopHook.caller()
	if tv == null or tv.has_meta("_coop_in_remote_interact"):
		return
	_try_coop_route_toggle(tv)


func _post_television_interact() -> void:
	pass


func _try_coop_route_toggle(node: Node) -> void:
	if world == null:
		return
	if world.CoopRouteInteractToggle(node.get_path()):
		CoopHook.skip_super()


func _on_catrescue_interact_post() -> void:
	var cr := CoopHook.caller()
	if cr == null or not CoopAuthority.is_active() or world == null:
		return
	if not ("gameData" in cr):
		return
	var gd: Variant = cr.gameData
	if gd == null or not gd.catFound:
		return
	if CoopAuthority.is_host():
		world.BroadcastCatState.rpc(true, gd.catDead, gd.cat)
	else:
		world.RequestCatState.rpc_id(1, true, gd.catDead, gd.cat)
