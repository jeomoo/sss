extends "res://mods/RTVCoop/Game/Sync/BaseSync.gd"

# RTVCoop 자체 AI 스폰 및 Proximity 관리자 (AICoopSpawner.gd)

const PROXIMITY_SPAWN_DIST: float = 100.0   # 스폰 활성화 반경 (m)
const PROXIMITY_DESPAWN_DIST: float = 130.0 # 디스폰 반경 (m)
const SCAN_INTERVAL: float = 1.5           # 스폰 체크 주기 (초)

var _scan_timer: float = 0.0
var _spawn_points: Array = []   # { "pos": Vector3, "rot": Vector3, "type": String, "point_node": Node, "cooldown": float }
var _spawned_ai: Dictionary = {} # uuid -> { "ai_node": Node, "point_index": int }


func _sync_key() -> String:
	return "coop_spawner"


func _ready() -> void:
	print("[AICoopSpawner] _ready initialized.")
	# 씬 전환 신호 구독
	var coop := RTVCoop.get_instance()
	if coop and coop.events:
		coop.events.map_loaded.connect(_on_scene_loaded)
		print("[AICoopSpawner] Connected to coop.events.map_loaded successfully.")
	else:
		push_error("[AICoopSpawner] Failed to find coop or coop.events!")
	
	var net = get_node_or_null("/root/RTVCoop/Net")
	if net and net.has_signal("peer_connected"):
		net.peer_connected.connect(_on_peer_connected)
	
	# 레이스 컨디션 방지: 이미 로드된 씬이 있으면 수동 호출
	var current_scene = get_tree().current_scene if get_tree() else null
	if current_scene:
		print("[AICoopSpawner] Current scene already exists: %s" % current_scene.name)
		_on_scene_loaded(current_scene.name)


func _on_peer_connected(id: int) -> void:
	if not CoopAuthority.is_host():
		return
	var ai_sync = _sync("ai")
	if ai_sync == null: return
	var coop_inst = RTVCoop.get_instance()
	var players_ref = coop_inst.players if coop_inst else null
	if players_ref == null: return
	
	# 새로운 클라이언트에게 기존 스폰되어 있던 AI 리스트를 전송
	for uuid in players_ref.world_ai:
		var ai = players_ref.world_ai[uuid]
		if is_instance_valid(ai) and ai.is_inside_tree() and not ai.get("dead", false):
			var type = "Wanderer"
			if _spawned_ai.has(uuid):
				var idx = _spawned_ai[uuid]["point_index"]
				if idx >= 0 and idx < _spawn_points.size():
					type = _spawn_points[idx]["type"]
			var variant = ai.get_meta("coop_spawn_variant", {})
			# RPC 호출 (해당 peer에게만)
			ai_sync.BroadcastAISpawn.rpc_id(id, uuid, type, ai.global_position, ai.global_rotation, variant)
			print("[AICoopSpawner] Late-joiner sync: sent AI uuid=%d to peer=%d" % [uuid, id])


func _physics_process(delta: float) -> void:
	# Cooldown 감소
	for p in _spawn_points:
		if p["cooldown"] > 0.0:
			p["cooldown"] -= delta

	_scan_timer += delta
	if _scan_timer >= SCAN_INTERVAL:
		_scan_timer = 0.0
		_tick_proximity_spawning()


func _on_scene_loaded(_scene_name: String) -> void:
	if not CoopAuthority.is_host():
		return
	print("[AICoopSpawner] _on_scene_loaded called for: %s" % _scene_name)
	_spawn_points.clear()
	_spawned_ai.clear()
	
	# 씬이 완전히 로드되고 물리 프레임이 안정화된 뒤 스폰 지점 파싱
	var tree = get_tree()
	if tree == null:
		return
	await tree.physics_frame
	if not is_instance_valid(self) or get_tree() == null:
		return
	_collect_spawn_points()


func _collect_spawn_points() -> void:
	var spawner = _get_ai_spawner()
	if spawner == null:
		print("[AICoopSpawner] _collect_spawn_points aborted: AI Spawner node not found.")
		return
	
	# 1. Wanderer 지점들 수집
	if "spawns" in spawner and spawner.spawns != null:
		for point in spawner.spawns:
			_spawn_points.append({
				"pos": point.global_position,
				"rot": point.global_rotation,
				"type": "Wanderer",
				"point_node": point,
				"cooldown": 0.0
			})
	
	# 2. Guard 지점들 수집
	if "patrols" in spawner and spawner.patrols != null:
		for point in spawner.patrols:
			_spawn_points.append({
				"pos": point.global_position,
				"rot": point.global_rotation,
				"type": "Guard",
				"point_node": point,
				"cooldown": 0.0
			})

	# 3. Hider 지점들 수집
	if "hides" in spawner and spawner.hides != null:
		for point in spawner.hides:
			_spawn_points.append({
				"pos": point.global_position,
				"rot": point.global_rotation,
				"type": "Hider",
				"point_node": point,
				"cooldown": 0.0
			})

	print("[AICoopSpawner] Collected %d spawn points from scene." % _spawn_points.size())


func _get_ai_spawner() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var scene := tree.current_scene
	if scene == null:
		return null
	
	# 1. Direct child check
	var spawner = scene.get_node_or_null("AI")
	if spawner:
		print("[AICoopSpawner] Found AI Spawner as direct child of scene root: %s" % spawner.get_path())
		return spawner
		
	# 2. Absolute path fallback
	spawner = tree.root.get_node_or_null("Map/AI")
	if spawner:
		print("[AICoopSpawner] Found AI Spawner at absolute path: %s" % spawner.get_path())
		return spawner
		
	# 3. Recursive lookup fallback
	spawner = _find_node_by_name(scene, "AI")
	if spawner:
		print("[AICoopSpawner] Found AI Spawner via recursive search: %s" % spawner.get_path())
		return spawner
		
	print("[AICoopSpawner] AI Spawner NOT found under current scene root: %s" % scene.name)
	return null


func _find_node_by_name(root: Node, target_name: String) -> Node:
	if root == null:
		return null
	if root.name == target_name:
		return root
	for child in root.get_children():
		var found = _find_node_by_name(child, target_name)
		if found != null:
			return found
	return null


func _tick_proximity_spawning() -> void:
	var spawner = _get_ai_spawner()
	if spawner == null:
		_spawn_points.clear()
		_spawned_ai.clear()
		return

	var coop_inst := RTVCoop.get_instance()
	var players_ref = coop_inst.players if coop_inst else null
	if players_ref == null:
		return
	
	# 활성 플레이어 리스트 구성
	var player_nodes: Array = []
	var local_ctrl = players_ref.GetLocalController() if players_ref.has_method("GetLocalController") else null
	if local_ctrl and is_instance_valid(local_ctrl) and not local_ctrl.get("isDead", false):
		player_nodes.append(local_ctrl)
	
	for id in players_ref.remote_players:
		var puppet = players_ref.remote_players[id]
		if is_instance_valid(puppet) and not puppet.get("isDead", false) and not puppet.get("isDowned", false):
			player_nodes.append(puppet)
	
	if player_nodes.is_empty():
		return

	# 1. 디스폰 검사 (모든 플레이어로부터 140m 이상 벗어난 AI 비활성화 및 풀로 반환)
	var despawn_list: Array = []
	for uuid in _spawned_ai:
		var data = _spawned_ai[uuid]
		var ai_node = data["ai_node"]
		if not is_instance_valid(ai_node) or not ai_node.is_inside_tree() or ai_node.get("dead", false):
			despawn_list.append(uuid)
			continue
		
		var nearest_dist: float = INF
		for p in player_nodes:
			if is_instance_valid(p) and p.is_inside_tree():
				var d = ai_node.global_position.distance_to(p.global_position)
				if d < nearest_dist:
					nearest_dist = d
		
		if nearest_dist > PROXIMITY_DESPAWN_DIST:
			despawn_list.append(uuid)

	for uuid in despawn_list:
		var data = _spawned_ai[uuid]
		var ai_node = data["ai_node"]
		var point_idx = data["point_index"]
		
		# Cooldown 부여 (재소환 억제 및 무한리필 방지)
		var point_type = "Wanderer"
		if point_idx >= 0 and point_idx < _spawn_points.size():
			var is_dead: bool = (not is_instance_valid(ai_node)) or ai_node.get("dead", false)
			
			var new_cooldown: float = 0.0
			if is_dead:
				# 적이 처치된 경우: 동일 장소에서 즉시 보충되지 않도록 5~8분간 쿨다운 지정
				new_cooldown = randf_range(300.0, 480.0)
			else:
				# 단순 플레이어 이격으로 인한 디스폰: 2~3분간 재소환 억제
				new_cooldown = randf_range(120.0, 180.0)
				
			# 기존 쿨타임이 더 길면 축소시키지 않고 보존
			_spawn_points[point_idx]["cooldown"] = max(_spawn_points[point_idx]["cooldown"], new_cooldown)
			point_type = _spawn_points[point_idx]["type"]
		
		if is_instance_valid(ai_node) and not ai_node.get("dead", false):
			# AI를 풀(APool 또는 BPool)로 반환하여 재사용 (오브젝트 풀링)
			var spawner = _get_ai_spawner()
			if spawner:
				var pool = spawner.BPool if point_type == "Boss" else spawner.APool
				ai_node.reparent(pool)
				
				# 상태 비활성화 및 숨김
				ai_node.hide()
				ai_node.pause = true
				ai_node.process_mode = Node.PROCESS_MODE_DISABLED
				if "skeleton" in ai_node and ai_node.skeleton:
					ai_node.skeleton.process_mode = Node.PROCESS_MODE_DISABLED
				if "animator" in ai_node and ai_node.animator:
					ai_node.animator.active = false
					
				# AICoopManager 등록 해제
				var manager = _sync("coop_manager")
				if manager and manager.has_method("unregister_ai"):
					manager.unregister_ai(ai_node.get_instance_id())

			var ai_sync = _sync("ai")
			if ai_sync and ai_sync.has_method("BroadcastAIRemove"):
				ai_sync.BroadcastAIRemove.rpc(PackedInt32Array([uuid]))
			
			if players_ref.world_ai.has(uuid):
				players_ref.world_ai.erase(uuid)
			if players_ref.ai_targets.has(uuid):
				players_ref.ai_targets.erase(uuid)
		
		_spawned_ai.erase(uuid)

	# 2. 스폰 검사 (플레��어와의 거리가 100m 이내이고 쿨다운이 끝난 지점 스폰)
	var spawner = _get_ai_spawner()
	var ai_sync = _sync("ai")
	if spawner == null or ai_sync == null:
		return

	# 동적 소환 한도 관리 (5~12마리 사이로 매 주기마다 유동적 조절되도록 보장)
	if not has_meta("_dynamic_limit_timer"):
		set_meta("_dynamic_limit_timer", 0.0)
		set_meta("_dynamic_limit", randi_range(5, 12))
	
	var limit_timer = get_meta("_dynamic_limit_timer") + SCAN_INTERVAL
	var active_limit = get_meta("_dynamic_limit")
	
	# 45초마다 새로운 적정 마릿수 목표(5~12) 롤링하여 스폰 비효율 및 과부하 방지
	if limit_timer >= 45.0:
		limit_timer = 0.0
		active_limit = randi_range(5, 12)
		set_meta("_dynamic_limit", active_limit)
		print("[AICoopSpawner] Dynamic AI spawn limit rolled to: %d" % active_limit)
	set_meta("_dynamic_limit_timer", limit_timer)
	
	var current_active: int = 0
	for uuid in _spawned_ai:
		var node = _spawned_ai[uuid]["ai_node"]
		if is_instance_valid(node) and not node.get("dead", false):
			current_active += 1

	if current_active >= active_limit:
		return

	# 후보군 인덱스 수집
	var candidates: Array = []
	for i in range(_spawn_points.size()):
		var p = _spawn_points[i]
		if p["cooldown"] > 0.0:
			continue
		
		# 해당 지점에 이미 스폰된 AI가 연결되어 있는지 체크
		var already_spawned: bool = false
		for uuid in _spawned_ai:
			if _spawned_ai[uuid]["point_index"] == i:
				already_spawned = true
				break
		if already_spawned:
			continue

		# 플레이어와의 최단 거리 검사
		var nearest_dist: float = INF
		for player in player_nodes:
			if is_instance_valid(player) and player.is_inside_tree():
				var d = p["pos"].distance_to(player.global_position)
				if d < nearest_dist:
					nearest_dist = d

		# 너무 가깝거나(35m 이내) 너무 먼 경우(100m 초과) 필터링하여 갑툭튀 차단
		if nearest_dist >= 35.0 and nearest_dist <= PROXIMITY_SPAWN_DIST:
			candidates.append(i)

	# 특정 지역 쏠림 및 인덱스 편향 방지를 위해 후보지 셔플
	candidates.shuffle()

	# 야외(Wanderer) 지점의 압도적 개수로 인해 실내가 완전히 묻히는 것을 방지
	# 대기열 정렬: 실내/엄폐 요충지(Guard, Hider) 후보 지점들을 앞으로 우선 배치
	var sorted_candidates: Array = []
	var outer_candidates: Array = []
	for idx in candidates:
		var p_type = _spawn_points[idx]["type"]
		if p_type == "Guard" or p_type == "Hider":
			sorted_candidates.append(idx)
		else:
			outer_candidates.append(idx)
	sorted_candidates.append_array(outer_candidates)

	# 결정된 동적 한도만큼 스폰 실행 (인접 지역 쏠림 및 중첩 스폰 원천 방지)
	var spawned_positions_this_tick: Array = []
	for point_idx in sorted_candidates:
		if current_active >= active_limit:
			break
			
		var p = _spawn_points[point_idx]
		
		# 이미 필드에 살아있는 다른 AI들과 너무 가까운지 검사 (최소 15m 거리 유지)
		var too_close_to_alive: bool = false
		for uuid in _spawned_ai:
			var node = _spawned_ai[uuid]["ai_node"]
			if is_instance_valid(node) and node.is_inside_tree() and not node.get("dead", false):
				if p["pos"].distance_to(node.global_position) < 15.0:
					too_close_to_alive = true
					break
		if too_close_to_alive:
			continue

		# 이번 틱에서 소환하기로 결정된 위치들과 너무 가까운지 검사 (최소 15m 거리 유지)
		var too_close: bool = false
		for pos in spawned_positions_this_tick:
			if p["pos"].distance_to(pos) < 15.0:
				too_close = true
				break
		if too_close:
			continue
			
		_spawn_at_point(point_idx)
		spawned_positions_this_tick.append(p["pos"])
		current_active += 1


func _spawn_at_point(point_idx: int) -> void:
	var p = _spawn_points[point_idx]
	
	# 스폰 직후 해당 지점에 긴 재스폰 쿨다운(Cooldown) 부여하여 다차원적인 분산 보장
	# 야외(Wanderer)는 스폰 지점이 너무 많아 쏠리기 쉬우므로 더 긴 3~5분 쿨다운을 적용하고,
	# 실내/구석 요충지(Guard, Hider)는 1.5~3분의 빠른 재순환을 보장합니다.
	if p["type"] == "Wanderer":
		p["cooldown"] = randf_range(180.0, 300.0)
	else:
		p["cooldown"] = randf_range(90.0, 180.0)

	var spawner = _get_ai_spawner()
	var ai_sync = _sync("ai")
	var coop_inst := RTVCoop.get_instance()
	var players_ref = coop_inst.players if coop_inst else null
	if spawner == null or ai_sync == null or players_ref == null:
		return

	var pool: Node = spawner.BPool if p["type"] == "Boss" else spawner.APool
	if pool.get_child_count() == 0:
		# 풀이 비어있으면 강제로 하나 생성
		if ai_sync.has_method("_grow_pool"):
			ai_sync._grow_pool(spawner, pool, p["type"])
	
	if pool.get_child_count() == 0:
		return

	var new_agent: Node = pool.get_child(0)
	new_agent.reparent(spawner.agents)
	new_agent.global_position = p["pos"]
	new_agent.global_rotation = p["rot"]
	new_agent.currentPoint = p["point_node"]

	# 세부 장비 프리셋 구성
	var variant: Dictionary = {}
	var spawner_hooks = get_node_or_null("/root/RTVCoop/AISpawnerHooks")
	if spawner_hooks and spawner_hooks.has_method("_generate_variant"):
		variant = spawner_hooks._generate_variant(new_agent)

	var uuid: int = ai_sync.GenerateAiUuid()
	new_agent.set_meta("network_uuid", uuid)
	new_agent.set_meta("coop_spawn_variant", variant)
	
	# [안전장치] 스폰 즉시 멀리서 플레이어를 투시/인지하고 저격하는 오류 방지
	if "playerVisible" in new_agent: new_agent.playerVisible = false
	if "targetPosition" in new_agent: new_agent.targetPosition = p["pos"]
	if "playerPosition" in new_agent: new_agent.playerPosition = p["pos"]
	if "LKL" in new_agent: new_agent.LKL = p["pos"]
	if "lastKnownLocation" in new_agent: new_agent.lastKnownLocation = p["pos"]
	
	players_ref.world_ai[uuid] = new_agent
	_spawned_ai[uuid] = {
		"ai_node": new_agent,
		"point_index": point_idx
	}
	spawner.activeAgents += 1

	# 중앙 매니저에 즉시 등록
	var manager = _sync("coop_manager")
	if manager and manager.has_method("register_ai"):
		manager.register_ai(new_agent)

	# 바닐라 FSM 상태 활성화 및 초기 전이
	new_agent.show()
	new_agent.pause = false
	new_agent.process_mode = Node.PROCESS_MODE_INHERIT
	if new_agent.skeleton:
		new_agent.skeleton.show_rest_only = false
		new_agent.skeleton.process_mode = Node.PROCESS_MODE_INHERIT
	if new_agent.animator:
		new_agent.animator.active = true

	# 지점 타입별 상태 결정
	match p["type"]:
		"Wanderer": new_agent.ChangeState("Wander")
		"Guard": new_agent.ChangeState("Guard")
		"Hider": new_agent.ChangeState("Ambush")
		_: new_agent.ChangeState("Combat")

	# 클라이언트에 스폰 브로드캐스트 RPC 전송
	ai_sync.BroadcastAISpawn.rpc(uuid, p["type"], p["pos"], p["rot"], variant)
	print("[AICoopSpawner] Spawned AI uuid=%d type=%s at point %d" % [uuid, p["type"], point_idx])
