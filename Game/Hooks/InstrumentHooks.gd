extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

func _setup_hooks() -> void:
	CoopHook.register(self, "instrument-_physics_process-post", _on_instrument_physics_post)
	CoopHook.register(self, "instrument-_exit_tree-post", _on_instrument_exit_tree_post)


func _on_instrument_physics_post(_delta: float) -> void:
	var inst := CoopHook.caller()
	if inst == null or not CoopAuthority.is_active() or world == null:
		return
	if not ("audioPlayer" in inst) or inst.audioPlayer == null:
		return
	var now_playing: bool = inst.audioPlayer.playing
	var was_playing: bool = inst.get_meta("_coop_audio_was_playing", false)
	if now_playing == was_playing:
		return
	inst.set_meta("_coop_audio_was_playing", now_playing)

	if now_playing:
		var clip = inst.audioPlayer.stream
		var clip_path: String = clip.resource_path if clip else ""
		if clip_path == "":
			return
		if CoopAuthority.is_host():
			world.BroadcastInstrumentPlay.rpc(multiplayer.get_unique_id(), clip_path)
		else:
			world.RequestInstrumentPlay.rpc_id(1, clip_path)
	else:
		if CoopAuthority.is_host():
			world.BroadcastInstrumentStop.rpc(multiplayer.get_unique_id())
		else:
			world.RequestInstrumentStop.rpc_id(1)


func _on_instrument_exit_tree_post() -> void:
	var inst := CoopHook.caller()
	if inst == null or not CoopAuthority.is_active() or world == null:
		return
	if not inst.get_meta("_coop_audio_was_playing", false):
		return
	inst.set_meta("_coop_audio_was_playing", false)
	if CoopAuthority.is_host():
		world.BroadcastInstrumentStop.rpc(multiplayer.get_unique_id())
	else:
		world.RequestInstrumentStop.rpc_id(1)
