extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

func _setup_hooks() -> void:
	CoopHook.register_replace_or_post(self, "bed-interact", _replace_bed_interact, _post_bed_interact)
	CoopHook.register_replace_or_post(self, "bed-updatetooltip", _replace_bed_update_tooltip, _post_bed_update_tooltip)


func _replace_bed_interact() -> void:
	var bed := CoopHook.caller()
	if bed == null:
		return
	if not bed.canSleep:
		CoopHook.skip_super()
		return
	if not CoopAuthority.is_active() or event == null:
		CoopHook.skip_super()
		return
	if CoopAuthority.is_host():
		event.HostToggleSleepReady(multiplayer.get_unique_id(), bed.randomSleep)
	else:
		event.RequestSleepReady.rpc_id(1, bed.randomSleep)
	CoopHook.skip_super()


func _post_bed_interact() -> void:
	pass


func _replace_bed_update_tooltip() -> void:
	var bed := CoopHook.caller()
	if bed == null or not CoopAuthority.is_active():
		return
	var gd: Resource = load("res://Resources/GameData.tres")
	if gd == null:
		return
	if not bed.canSleep:
		gd.tooltip = ""
		CoopHook.skip_super()
		return
	var my_id: int = multiplayer.get_unique_id()
	if event and event._sleep_ready.has(my_id):
		gd.tooltip = "Sleep [Cancel]"
	else:
		gd.tooltip = "Sleep (Random: 6-12h) [Ready]"
	CoopHook.skip_super()


func _post_bed_update_tooltip() -> void:
	pass
