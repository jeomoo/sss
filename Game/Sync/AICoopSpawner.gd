extends "res://mods/RTVCoop/Game/Sync/BaseSync.gd"

# RTVCoop 자체 AI 스폰 및 Proximity 관리자 (AICoopSpawner.gd)

const PROXIMITY_SPAWN_DIST: float = 200.0   # 스폰 활성화 반경 (m)
const PROXIMITY_DESPAWN_DIST: float = 250.0 # 디스폰 반경 (m)
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
		if is_instance_valid(ai) and not ai.get("dead", false):
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
		if not is_instance_valid(ai_node) or ai_node.get("dead", false):
			despawn_list.append(uuid)
			continue
		
		var nearest_dist: float = INF
		for p in player_nodes:
			var d = ai_node.global_position.distance_to(p.global_position)
			if d < nearest_dist:
				nearest_dist = d
		
		if nearest_dist > PROXIMITY_DESPAWN_DIST:
			despawn_list.append(uuid)

	for uuid in despawn_list:
		var data = _spawned_ai[uuid]
		var ai_node = data["ai_node"]
		var point_idx = data["point_index"]
		
		# Cooldown 부여 (재소환 억제)
		var point_type = "Wanderer"
		if point_idx >= 0 and point_idx < _spawn_points.size():
			_spawn_points[point_idx]["cooldown"] = 30.0 # 30초 쿨다운
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

	# 2. 스폰 검사 (플레이어와의 거리가 100m 이내이고 쿨다운이 끝난 지점 스폰)
	var spawner = _get_ai_spawner()
	var ai_sync = _sync("ai")
	if spawner == null or ai_sync == null:
		return

	# 현재 소환되어 있는 총 액티브 AI 갯수 상한 체크 (호스트 스포너의 spawnLimit 사용)
	var active_limit: int = 15
	if "spawnLimit" in spawner:
		active_limit = int(spawner.spawnLimit)
	
	var current_active: int = 0
	for uuid in _spawned_ai:
		var node = _spawned_ai[uuid]["ai_node"]
		if is_instance_valid(node) and not node.get("dead", false):
			current_active += 1

	if current_active >= active_limit:
		return

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
			var d = p["pos"].distance_to(player.global_position)
			if d < nearest_dist:
				nearest_dist = d

		# 100m 이내로 들어왔을 때 스폰
		if nearest_dist <= PROXIMITY_SPAWN_DIST:
			_spawn_at_point(i)
			current_active += 1
			if current_active >= active_limit:
				break


func _spawn_at_point(point_idx: int) -> void:
	var p = _spawn_points[point_idx]
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
