extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

var gameData: Resource = preload("res://Resources/GameData.tres")


func _setup_hooks() -> void:
	CoopHook.register(self, "catfeeder-tryfeeding-pre", _on_tryfeeding_pre)
	CoopHook.register(self, "catfeeder-tryfeeding-post", _on_tryfeeding_post)


func _on_tryfeeding_pre() -> void:
	pass


func _on_tryfeeding_post() -> void:
	if not CoopAuthority.is_active() or world == null:
		return
	var tree = get_tree()
	if tree == null:
		return
	await tree.create_timer(0.1).timeout
	if get_tree() == null:
		return
	if CoopAuthority.is_host():
		world.BroadcastCatState.rpc(gameData.catFound, gameData.catDead, gameData.cat)
	else:
		world.RequestCatState.rpc_id(1, gameData.catFound, gameData.catDead, gameData.cat)
