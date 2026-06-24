extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

func _setup_hooks() -> void:
	CoopHook.register(self, "fire-_ready-pre", _on_fire_ready_pre)
	CoopHook.register(self, "fire-_ready-post", _on_fire_ready_post)
	CoopHook.register_replace_or_post(self, "fire-interact", _replace_fire_interact, _post_fire_interact)


func _on_fire_ready_pre() -> void:
	var fire := CoopHook.caller()
	if fire == null or not CoopAuthority.is_active() or players == null:
		return
	var s: int = players.CoopSeedForNode(fire)
	if s != 0:
		seed(s)
		fire.set_meta("_coop_fire_seeded", true)


func _on_fire_ready_post() -> void:
	var fire := CoopHook.caller()
	if fire != null and fire.has_meta("_coop_fire_seeded"):
		randomize()
		fire.remove_meta("_coop_fire_seeded")


func _replace_fire_interact() -> void:
	var fire := CoopHook.caller()
	if fire == null or not CoopAuthority.is_active() or event == null:
		return

	if CoopAuthority.is_host():
		if not fire.active:
			if fire.MatchCheck():
				fire.ConsumeMatch()
				fire.active = true
				fire.Activate()
				fire.IgniteAudio()
				event.BroadcastFireState.rpc(fire.get_path(), true)
		else:
			fire.active = false
			fire.Deactivate()
			fire.ExtinguishAudio()
			event.BroadcastFireState.rpc(fire.get_path(), false)
		CoopHook.skip_super()
		return

	if not fire.active and not fire.MatchCheck():
		CoopHook.skip_super()
		return
	event.RequestFireToggle.rpc_id(1, fire.get_path())
	CoopHook.skip_super()


func _post_fire_interact() -> void:
	pass
