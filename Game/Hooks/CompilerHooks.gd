extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

func _setup_hooks() -> void:
	CoopHook.register_replace_or_post(self, "compiler-spawn", _replace_compiler_spawn, _post_compiler_spawn)


func _replace_compiler_spawn() -> void:
	var compiler := CoopHook.caller()
	if compiler == null or not CoopAuthority.is_active() or CoopAuthority.is_host():
		return
	CoopHook.skip_super()
	_coop_client_spawn(compiler)


func _coop_client_spawn(compiler: Node) -> void:
	var map: Node = coop.scene.get_map() if coop and coop.scene else null
	if map == null:
		return

	var map_name: String = str(map.get("mapName")) if map.get("mapName") else ""
	if map_name == "Tutorial":
		Simulation.simulate = false
		if compiler.get("controller"):
			compiler.controller.global_position = Vector3(0, 3, 12)
	else:
		Simulation.simulate = true

	if players:
		players.set_meta("coop_loading", true)
		if players.has_method("LoadClientCharacterBuffer"):
			await players.LoadClientCharacterBuffer()
		if players.coopCharacterBuffer == null and players.has_method("GiveClientStarterKit"):
			await players.GiveClientStarterKit()
		players.set_meta("coop_loading", false)

	var gd: Resource = load("res://Resources/GameData.tres")
	if gd:
		gd.isTransitioning = false
		gd.isSleeping = false
		gd.isOccupied = false
		gd.freeze = false


func _post_compiler_spawn() -> void:
	pass
