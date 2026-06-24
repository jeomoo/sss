extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

func _setup_hooks() -> void:
	CoopHook.register(self, "trader-_ready-post", _on_trader_ready_post)
	CoopHook.register_replace_or_post(self, "trader-completetask", _replace_trader_complete, _post_trader_complete)


func _on_trader_ready_post() -> void:
	var trader := CoopHook.caller()
	if trader == null or not CoopAuthority.is_active() or quest == null:
		return
	if CoopAuthority.is_host():
		var completed: Array = quest.get_completed(trader.traderData.name)
		trader.tasksCompleted.clear()
		for task_name in completed:
			trader.tasksCompleted.append(task_name)
	else:
		trader.tasksCompleted.clear()
		if quest.has_state_for(trader.traderData.name):
			for task_name in quest.get_completed(trader.traderData.name):
				trader.tasksCompleted.append(task_name)
		quest.RequestTraderState.rpc_id(1, trader.traderData.name)


func _replace_trader_complete(task_data) -> void:
	var trader := CoopHook.caller()
	if trader == null or not CoopAuthority.is_active() or quest == null:
		return
	if CoopAuthority.is_host():
		return

	if not quest.has_state_for(trader.traderData.name):
		Loader.Message("상인 상태 동기화 중… 잠시 후 다시 시도하세요.", Color.ORANGE)
		CoopHook.skip_super()
		return
	if quest.get_completed(trader.traderData.name).has(task_data.name):
		Loader.Message("이미 완료된 임무입니다.", Color.ORANGE)
		CoopHook.skip_super()
		return
	trader.PlayTraderTask()
	Loader.Message("임무 완료: " + task_data.name, Color.GREEN)
	quest.SubmitTaskCompletion.rpc_id(1, trader.traderData.name, task_data.name)
	CoopHook.skip_super()


func _post_trader_complete(task_data) -> void:
	var trader := CoopHook.caller()
	if trader == null or not CoopAuthority.is_active() or quest == null:
		return
	if CoopAuthority.is_host():
		quest.coop_trader_state[trader.traderData.name] = trader.tasksCompleted.duplicate()
		quest._persist_host()
		quest.BroadcastTaskCompletion.rpc(trader.traderData.name, task_data.name)
		return
	# v0.13.22: 클라 측 _replace_trader_complete가 fire 안 되는 케이스 보완 (메모리 미해결 #1 패턴).
	# replace가 안 잡힌 frame엔 vanilla CompleteTask가 그대로 진행 → 클라는 보상 받지만 호스트는 모름
	# → 다음 trader 진입 시 _on_trader_ready_post가 호스트 빈 state로 tasksCompleted 덮음 → 0/10.
	# post는 vanilla 후 fire되므로 여기서 호스트에 sync RPC 발사. SubmitTaskCompletion 측 중복 체크 있음.
	if quest.has_method("SubmitTaskCompletion") and trader.traderData and trader.traderData.name:
		quest.SubmitTaskCompletion.rpc_id(1, trader.traderData.name, task_data.name)
		print("[TraderHooks/CLIENT] vanilla CompleteTask fired (replace fail) — sync RPC sent trader=%s task=%s" % [trader.traderData.name, task_data.name])
