extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

var gameData: Resource = preload("res://Resources/GameData.tres")


func _setup_hooks() -> void:
	var coop_instance = RTVCoop.get_instance()
	if coop_instance:
		coop_instance.set_meta("AISpawnerHooks", self)

	CoopHook.register_replace_or_post(self, "aispawner-_ready", _replace_aispawner_ready, _post_aispawner_ready)
	CoopHook.register_replace_or_post(self, "aispawner-initialize", _replace_aispawner_initialize, _post_aispawner_initialize)
	CoopHook.register(self, "aispawner-initialize-post", _post_aispawner_initialize)
	CoopHook.register_replace_or_post(self, "aispawner-_physics_process", _replace_aispawner_physics, _post_aispawner_physics)
	CoopHook.register_replace_or_post(self, "aispawner-spawnwanderer", _replace_spawn_wanderer, _post_spawn_wanderer)
	CoopHook.register_replace_or_post(self, "aispawner-spawnguard", _replace_spawn_guard, _post_spawn_guard)
	CoopHook.register_replace_or_post(self, "aispawner-spawnhider", _replace_spawn_hider, _post_spawn_hider)
	CoopHook.register_replace_or_post(self, "aispawner-spawnminion", _replace_spawn_minion, _post_spawn_minion)
	CoopHook.register_replace_or_post(self, "aispawner-spawnboss", _replace_spawn_boss, _post_spawn_boss)



# v0.5: 스폰 곱을 "스폰될 인원이 정해진 뒤"에 적용 (모드 불가지론). 이전엔 aispawner-_ready-pre(이른
# 시점)에서 spawnPool만 곱했는데, ASO 등이 그 뒤 Initialize에서 spawnPool/spawnLimit를 자기 값으로
# 덮어써 곱이 무효화됨(저무 발견). → initialize-post(vanilla·ASO 등 모든 Initialize 끝난 뒤)에 최종값을 곱함.
# spawnPool(풀크기)·spawnLimit(활성상한) 둘 다 곱 → 어느 쪽이 binding이든 커버.
func _apply_spawn_scaling(spawner: Node) -> void:
	if spawner == null or not CoopAuthority.is_active() or not CoopAuthority.is_host():
		return
	var player_count: int = _get_active_player_count()
	var auto_mult: float = pow(1.5, float(max(0, player_count - 1)))
	var manual_mult: float = settings.Get("ai_multiplier", 1.0) if settings else 1.0
	var total_mult: float = auto_mult * manual_mult
	if total_mult == 1.0:
		return
	var msg: String = ""
	if "spawnLimit" in spawner and int(spawner.spawnLimit) > 0:
		var ol: int = int(spawner.spawnLimit)
		spawner.spawnLimit = max(1, roundi(float(ol) * total_mult))
		msg += " limit %d→%d" % [ol, spawner.spawnLimit]
	if "spawnPool" in spawner and int(spawner.spawnPool) > 0:
		var op: int = int(spawner.spawnPool)
		spawner.spawnPool = max(1, roundi(float(op) * total_mult))
		msg += " pool %d→%d" % [op, spawner.spawnPool]
	if msg != "":
		print("[AISpawner] post-init scale (players=%d ×%.2f):%s" % [player_count, total_mult, msg])


func _get_active_player_count() -> int:
	var coop_ref := RTVCoop.get_instance()
	if coop_ref == null or coop_ref.players == null:
		return 1
	var p = coop_ref.players
	if not ("peer_names" in p):
		return 1
	var count: int = p.peer_names.size()
	return max(1, count)


func _replace_aispawner_ready() -> void:
	if CoopAuthority.is_active() and not CoopAuthority.is_host():
		CoopHook.skip_super()

func _post_aispawner_ready() -> void:
	pass

func _replace_aispawner_initialize() -> void:
	if CoopAuthority.is_active() and not CoopAuthority.is_host():
		CoopHook.skip_super()


func _post_aispawner_initialize() -> void:
	# v0.5: vanilla/ASO 등 Initialize가 spawnPool/spawnLimit를 최종 결정한 뒤 인원비례 곱 적용.
	_apply_spawn_scaling(CoopHook.caller())


func _replace_aispawner_physics(_delta: float) -> void:
	if CoopAuthority.is_active() and not CoopAuthority.is_host():
		CoopHook.skip_super()


func _post_aispawner_physics(_delta: float) -> void:
	pass


func _read_actual_equipment(agent: Node) -> Dictionary:
	var variant: Dictionary = {}
	if agent.weapon and agent.weapon.slotData and agent.weapon.slotData.itemData:
		variant["weaponFile"] = agent.weapon.slotData.itemData.file
		variant["weaponCondition"] = agent.weapon.slotData.condition
		variant["weaponAmount"] = agent.weapon.slotData.amount
	if agent.backpack and agent.backpack.slotData and agent.backpack.slotData.itemData:
		variant["backpackRoll"] = 0
		variant["backpackFile"] = agent.backpack.slotData.itemData.file
	else:
		variant["backpackRoll"] = 100
	if agent.mesh:
		var mat = agent.mesh.get_surface_override_material(0)
		if mat and mat.resource_path != "":
			variant["clothingPath"] = mat.resource_path
	return variant


func _generate_variant(agent: Node) -> Dictionary:
	var variant: Dictionary = {}
	if agent.weapons and agent.weapons.get_child_count() > 0:
		var index: int = randi_range(0, agent.weapons.get_child_count() - 1)
		var chosen = agent.weapons.get_child(index)
		variant["weaponCondition"] = randi_range(5, 50)
		if chosen and chosen.slotData and chosen.slotData.itemData:
			variant["weaponFile"] = chosen.slotData.itemData.file
			var mag_size: int = chosen.slotData.itemData.magazineSize
			variant["weaponAmount"] = randi_range(1, max(1, mag_size))

	variant["backpackRoll"] = randi_range(0, 100)
	if variant["backpackRoll"] < 10 and agent.backpacks and agent.backpacks.get_child_count() > 0:
		var bp_index: int = randi_range(0, agent.backpacks.get_child_count() - 1)
		var chosen_bp = agent.backpacks.get_child(bp_index)
		if chosen_bp and chosen_bp.has_method("get") and chosen_bp.get("slotData") and chosen_bp.slotData.itemData:
			variant["backpackFile"] = chosen_bp.slotData.itemData.file
		else:
			variant["backpackFile"] = chosen_bp.name if chosen_bp else ""

	if agent.clothing and agent.clothing.size() > 0:
		var cloth_index: int = randi_range(0, agent.clothing.size() - 1)
		var cloth_mat = agent.clothing[cloth_index]
		if cloth_mat and cloth_mat.resource_path != "":
			variant["clothingPath"] = cloth_mat.resource_path

	return variant


func _register_agent_host(agent: Node, spawn_type: String, spawn_pos: Vector3, spawn_rot: Vector3, variant: Dictionary) -> void:
	if ai == null or players == null:
		return
	ai._ensure_ai_visible(agent)
	var uuid: int = ai.GenerateAiUuid()
	agent.set_meta("network_uuid", uuid)
	agent.set_meta("coop_spawn_variant", variant)
	players.world_ai[uuid] = agent
	ai.BroadcastAISpawn.rpc(uuid, spawn_type, spawn_pos, spawn_rot, variant)


func _spawn_pattern(spawn_type: String, pos_getter: Callable, activator: String) -> void:
	var spawner := CoopHook.caller()
	if spawner == null:
		return
	if CoopAuthority.is_active() and not CoopAuthority.is_host():
		CoopHook.skip_super()
		return


	var pool: Node = spawner.BPool if spawn_type == "Boss" else spawner.APool
	if pool.get_child_count() == 0:
		return

	var pos_rot: Dictionary = pos_getter.call(spawner)
	if pos_rot.is_empty():
		return

	var new_agent: Node = pool.get_child(0)
	new_agent.reparent(spawner.agents)
	if pos_rot.has("transform"):
		new_agent.global_transform = pos_rot["transform"]
		new_agent.currentPoint = pos_rot.get("currentPoint", null)
	else:
		new_agent.global_position = pos_rot["pos"]
		if pos_rot.has("currentPoint"):
			new_agent.currentPoint = pos_rot["currentPoint"]
	if pos_rot.has("lastKnown"):
		new_agent.lastKnownLocation = pos_rot["lastKnown"]

	match activator:
		"ActivateWanderer": new_agent.ActivateWanderer()
		"ActivateGuard": new_agent.ActivateGuard()
		"ActivateHider": new_agent.ActivateHider()
		"ActivateMinion": new_agent.ActivateMinion()
		"ActivateBoss": new_agent.ActivateBoss()
	spawner.activeAgents += 1

	var variant: Dictionary = {}
	if CoopAuthority.is_host() and CoopAuthority.is_active():
		variant = _read_actual_equipment(new_agent)
	new_agent.set_meta("coop_spawn_variant", variant)

	if CoopAuthority.is_host() and CoopAuthority.is_active():
		_register_agent_host(new_agent, spawn_type, new_agent.global_position, new_agent.global_rotation, variant)

	CoopHook.skip_super()


func _replace_spawn_wanderer() -> void:
	_spawn_pattern("Wanderer", _wanderer_pos, "ActivateWanderer")


func _wanderer_pos(spawner: Node) -> Dictionary:
	var reference_pos: Vector3 = gameData.playerPosition
	if CoopAuthority.is_active() and ai:
		reference_pos = ai.GetNearestPlayerPosition(spawner.global_position)
	var valid: Array = []
	for point in spawner.spawns:
		if point.global_position.distance_to(reference_pos) > spawner.spawnDistance:
			valid.append(point)
	if valid.is_empty():
		return {}
	var chosen = valid[randi_range(0, valid.size() - 1)]
	return {"transform": chosen.global_transform, "currentPoint": chosen}


func _post_spawn_wanderer() -> void:
	pass


func _replace_spawn_guard() -> void:
	_spawn_pattern("Guard", _guard_pos, "ActivateGuard")


func _guard_pos(spawner: Node) -> Dictionary:
	if spawner.patrols.size() == 0:
		return {}
	var chosen = spawner.patrols[randi_range(0, spawner.patrols.size() - 1)]
	return {"transform": chosen.global_transform, "currentPoint": chosen}


func _post_spawn_guard() -> void:
	pass


func _replace_spawn_hider() -> void:
	_spawn_pattern("Hider", _hider_pos, "ActivateHider")


func _hider_pos(spawner: Node) -> Dictionary:
	if spawner.hides.size() == 0:
		return {}
	var chosen = spawner.hides[randi_range(0, spawner.hides.size() - 1)]
	return {"transform": chosen.global_transform, "currentPoint": chosen}


func _post_spawn_hider() -> void:
	pass


func _replace_spawn_minion(spawn_pos: Vector3) -> void:
	var spawner := CoopHook.caller()
	_spawn_pattern("Minion", func(_s): return {
		"pos": spawn_pos,
		"currentPoint": spawner.waypoints.pick_random() if spawner.waypoints.size() > 0 else null,
	}, "ActivateMinion")


func _post_spawn_minion(_spawn_pos: Vector3) -> void:
	pass


func _replace_spawn_boss(spawn_pos: Vector3) -> void:
	var spawner := CoopHook.caller()
	_spawn_pattern("Boss", func(_s): return {
		"pos": spawn_pos,
		"currentPoint": spawner.waypoints.pick_random() if spawner.waypoints.size() > 0 else null,
	}, "ActivateBoss")


func _post_spawn_boss(_spawn_pos: Vector3) -> void:
	pass


