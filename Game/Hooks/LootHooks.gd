extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

func _log(msg: String) -> void:
	var l = Engine.get_meta("CoopLogger", null)
	if l: l.log_msg("LootHooks", msg)

func _setup_hooks() -> void:
	CoopHook.register(self, "lootcontainer-_ready-pre", _on_loot_container_ready_pre)
	CoopHook.register_replace_or_post(self, "lootcontainer-_ready", _replace_loot_container_ready, _post_loot_container_ready)
	CoopHook.register_replace_or_post(self, "lootcontainer-interact", _replace_loot_container_interact, _post_loot_container_interact)
	CoopHook.register_replace_or_post(self, "lootsimulation-_ready", _replace_loot_simulation_ready, _post_loot_simulation_ready)
	CoopHook.register_replace_or_post(self, "pickup-interact", _replace_pickup_interact, _post_pickup_interact)
	CoopHook.register_replace_or_post(self, "uimanager-opencontainer", _replace_uimanager_open, _post_uimanager_open)
	CoopHook.register(self, "uimanager-_input-post", _post_uimanager_input)


func _on_loot_container_ready_pre() -> void:
	var lc := CoopHook.caller()
	if lc == null:
		return
	lc.add_to_group("CoopLootContainer")
	if not CoopAuthority.is_active() or players == null:
		return
	var s: int = players.CoopSeedForNode(lc)
	if s != 0:
		seed(s)
		lc.set_meta("_coop_lc_seeded", true)


func _replace_loot_container_ready() -> void:
	var lc := CoopHook.caller()
	if lc == null or not CoopAuthority.is_active():
		return

	if CoopAuthority.is_client():
		lc.ClearBuckets()
		lc.loot.clear()
		lc.storage.clear()
		lc.storaged = false
		if lc.stash:
			lc.process_mode = Node.PROCESS_MODE_DISABLED
			lc.hide()
		CoopHook.skip_super()
		return

	var loot_mult: float = 1.0
	if settings:
		loot_mult = settings.Get("loot_multiplier", 1.0)

	if lc.custom.is_empty() and not lc.locked and not lc.furniture:
		lc.ClearBuckets()
		lc.FillBuckets()
		_generate_loot_scaled(lc, loot_mult)

	if not lc.custom.is_empty() and not lc.force:
		lc.table = lc.custom.pick_random()
		lc.ClearBuckets()
		lc.FillBucketsCustom()
		_generate_loot_scaled(lc, loot_mult)

	if not lc.custom.is_empty() and lc.force:
		lc.table = lc.custom.pick_random()
		for index in lc.table.items.size():
			lc.CreateLoot(lc.table.items[index])

	if lc.stash:
		if randi_range(0, 100) > 10:
			lc.process_mode = Node.PROCESS_MODE_DISABLED
			lc.hide()

	CoopHook.skip_super()


func _post_loot_container_ready() -> void:
	var lc := CoopHook.caller()
	if lc != null and lc.has_meta("_coop_lc_seeded"):
		randomize()
		lc.remove_meta("_coop_lc_seeded")


func _generate_loot_scaled(lc: Node, mult: float) -> void:
	var full_passes: int = int(mult)
	var frac: float = mult - float(full_passes)
	for _i in full_passes:
		lc.GenerateLoot()
	if frac > 0.0 and randf() < frac:
		lc.GenerateLoot()


func _replace_loot_container_interact() -> void:
	var lc := CoopHook.caller()
	_log("_replace_loot_container_interact FIRED lc=%s" % str(lc))
	if lc == null:
		return
	if lc.locked:
		_log("  → locked, skip")
		CoopHook.skip_super()
		return
	if not CoopAuthority.is_active():
		_log("  → not active, fallthrough to vanilla")
		return
	_log("  → calling TryOpenContainer (players=%s, has_method=%s)" % [str(players != null), str(players.has_method("TryOpenContainer") if players else false)])
	if players and players.has_method("TryOpenContainer"):
		players.TryOpenContainer(lc)
		CoopHook.skip_super()


func _post_loot_container_interact() -> void:
	pass


func _replace_loot_simulation_ready() -> void:
	var ls := CoopHook.caller()
	if ls == null or not CoopAuthority.is_active() or CoopAuthority.is_host():
		return
	if ls.get_child_count() > 0:
		ls.get_child(0).queue_free()
	CoopHook.skip_super()


func _post_loot_simulation_ready() -> void:
	pass


func _replace_pickup_interact() -> void:
	var pu := CoopHook.caller()
	if pu == null or not CoopAuthority.is_active():
		return
	# v0.11.2: v0.8 도둑질 차단 + 하단 토스트 제거. 우리 디자인 = 훔침 허용 + chat 경고 + 가드 보복
	# (GuardSync.BroadcastTheftAggro). InteractorHooks._on_interactor_physics_post가 trader display
	# interact 감지 → GuardSync 트리거 + chat broadcast.
	var uuid: int = int(pu.get_meta("network_uuid", -1))
	if uuid < 0:
		# v0.11.9: trader display item은 network_uuid 없음 (RegisterSceneItems skip).
		# 우리 디자인 = 훔침 허용 + 가드 보복. vanilla 통과.
		if players and players._is_trader_display_item(pu):
			# v0.11.10: 도둑질 감지 + aggro 트리거 (vanilla picking 전 fire하므로 target 유효)
			var perp_id: int = multiplayer.get_unique_id()
			print("[LootHooks] THEFT detected — peer=%d target=%s guard=%s is_host=%s" % [perp_id, str(pu.name), str(guard != null), str(CoopAuthority.is_host())])
			if guard != null:
				if CoopAuthority.is_host():
					guard._activate_aggro()
					guard.BroadcastTheftAggro.rpc()
					print("[LootHooks] aggro activated + broadcast sent")
				else:
					guard.SubmitTheft.rpc_id(1, perp_id)
					print("[LootHooks] SubmitTheft sent to host")
			else:
				push_warning("[LootHooks] guard sync is NULL — aggro skipped")
			return  # skip_super 안 호출 → vanilla Pickup.Interact 실행
		# 그 외 uuid 없는 item = buggy. PlayError.
		if pu.get("interface") and pu.interface.has_method("PlayError"):
			pu.interface.PlayError()
		CoopHook.skip_super()
		return
	if players and players.has_method("RequestPickup"):
		players.RequestPickup(uuid)
	CoopHook.skip_super()


func _post_pickup_interact() -> void:
	pass


func _replace_uimanager_open(_c) -> void:
	if not CoopAuthority.is_active() or players == null:
		return
	if players.container_open_bypassed:
		return
	if container:
		container.TryOpenContainer(_c)
		CoopHook.skip_super()


func _post_uimanager_open(_c) -> void:
	pass


func _post_uimanager_input(event) -> void:
	# v0.13.71: 다운(쓰러짐) 중 ESC 설정메뉴가 안 열리던 버그 fix.
	# 다운 시 _coop_enter_downed가 gameData.isDead=true로 두는데, vanilla UIManager._input은
	# 맨 앞에서 isDead면 return → ESC("settings" 액션=ESC키)로 메뉴를 못 엶. isDead는 다운
	# 상태 유지에 필요(여러 vanilla 시스템이 체크)라 제거 불가 → 다운 중일 때만 ESC→설정메뉴
	# 토글을 우리가 직접 처리. (post 훅: vanilla _input은 이미 isDead로 early-return한 뒤임)
	if not CoopAuthority.is_active() or downed == null or not downed.is_local_downed():
		return
	if event == null or not event.is_action_pressed("settings"):
		return
	var ui := CoopHook.caller()
	if ui == null:
		return
	var gd = ui.gameData
	if gd.interface or gd.isInspecting:
		return
	if ui.has_method("PlayClick"):
		ui.PlayClick()
	if gd.settings:
		ui.Return()
	else:
		ui.ToggleSettings()
	# ToggleSettings/Return 의 UIClose()가 freeze=false 로 풀어버림 →
	# 아직 다운 중이면 freeze 복원(안 그러면 메뉴 닫는 순간 다운 상태인데 움직여짐).
	if downed.is_local_downed():
		gd.freeze = true
