extends "res://mods/RTVCoop/Game/Sync/BaseSync.gd"

const CoopHook = preload("res://mods/RTVCoop/HookKit/CoopHook.gd")

const AI_BROADCAST_RATE := 20.0
const AI_LERP_SPEED := 18.0
const AI_SOUND_FIRE := 0
const AI_SOUND_TAIL := 1
const AI_SOUND_IDLE := 2
const AI_SOUND_COMBAT := 3
const AI_SOUND_DAMAGE := 4
const AI_SOUND_DEATH := 5

const SPAWN_RETRY_INTERVAL := 0.5
const SPAWN_RETRY_MAX := 10
const MANIFEST_CHECK_INTERVAL := 20.0
const REAP_INTERVAL := 2.0


var gameData: Resource = preload("res://Resources/GameData.tres")

var _pending_spawns: Array = []
var _ai_queues: Dictionary = {}
var _ai_accum: float = 0.0
var _manifest_timer: float = 0.0
var _reap_timer: float = 0.0
# v0.13.5: ASO/vanilla 충돌로 ragdoll 안 된 시체 강제 복원용 주기 check
var _ragdoll_check_accum: float = 0.0
const RAGDOLL_CHECK_INTERVAL: float = 5.0
var _perf_diag_accum: float = 0.0  # v0.13.60 프레임드랍 진단(느린 프레임 시 AI 수 로그, 1Hz throttle)
var _spike_fps_ema: float = 0.0    # v0.13.73 fps 롤링평균(EMA) — 갑작스런 드랍 기준선
var _spike_cd: float = 0.0         # spike 로그 쿨다운
const _SPIKE_DROP := 15.0          # 이만큼 fps가 갑자기 떨어지면 모니터 덤프
const _SPIKE_COOLDOWN := 0.5

# v0.5: 위협 가중 타게팅(점수제). 타겟 = (거리점수 0~1) + THREAT_WEIGHT*(위협점수). 위협 = 그 플레이어가
# 이 AI를 최근 쏜 누적(decay). on/off = Engine meta "coop_threat_targeting"(CoopMCM 세팅, 기본 true).
const THREAT_DECAY_TIME := 7.0      # 위협 점수 소멸 시간(초)
const THREAT_WEIGHT := 1.0          # 위협 가중치 (거리점수 0~1 대비)
const THREAT_PER_DAMAGE := 0.04     # 데미지 1당 위협 증가 (8뎀≈0.32)
const THREAT_MAX := 1.5             # 위협 점수 상한 (거리 1.0보다 약간 큼 = 어그로가 거리 override 가능)
const THREAT_MAX_RANGE := 200.0     # 거리점수 정규화 기준(AI 시야)
const TARGET_ACQUIRE_RANGE := 90.0
const TARGET_LOS_MASK := 67
var _ai_threat: Dictionary = {}     # {ai_uuid: {peer_id: {"score":float, "t":float}}}

const COOP_DOOR_OPEN_RANGE: float = 40.0
const _COOP_RETARGET_INTERVAL: float = 0.25
const _LOD_MID_SQ: float = 90.0 * 90.0
const _LOD_FAR_SQ: float = 140.0 * 140.0

var _did_inject: bool = false
var _sv_pp
var _sv_cp
var _sv_ir
var _sv_iw
var _sv_if
var _sv_pv
var _sv_id: bool = false
var _sv_it: bool = false
var _aidbg_stuck_ms: int = 0
var _aidbg_tgt_ms: int = 0



func _sync_key() -> String:
	return "ai"


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	# Proactively find and disable ModuleHub if it already exists in the tree
	call_deferred("_proactive_disable_module_hub")


func _exit_tree() -> void:
	if get_tree() and get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if not CoopAuthority.is_active():
		return

	if not CoopAuthority.is_host():
		if node != null and is_instance_valid(node):
			# 양방향 FSM 로컬 실행 (Dual-Local FSM) 지원: AI 스크립트를 동결하지 않고 허용
			var script = node.get_script()
			if script and script is Script:
				var path: String = script.resource_path
				if path.ends_with("AI.gd"):
					if "pause" in node:
						node.pause = false
					node.process_mode = Node.PROCESS_MODE_INHERIT
					print("[AISync] Client allowing Dual-Local FSM for AI: %s" % node.name)


func _log(msg: String) -> void:
	var l = Engine.get_meta("CoopLogger", null)
	if l: l.log_msg("AISync", msg)


func _get_ai_loot_container(ai: Node) -> Node:
	if ai.container == null:
		return null
	if ai.container is LootContainer:
		return ai.container
	for child in ai.container.get_children():
		if child is LootContainer:
			return child
	return null


func _players() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.players if coop else null


func _slot_serializer() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.get_sync("slot_serializer") if coop else null


func _live_ai(uuid) -> Node:
	var players := _players()
	if players == null:
		return null
	var key: int = int(uuid)
	if not players.world_ai.has(key):
		return null
	var ai: Node = players.world_ai[key]
	if not is_instance_valid(ai) or not ai.is_inside_tree():
		return null
	return ai


func _prune_pending_uuid(uuid: int) -> void:
	for i in range(_pending_spawns.size() - 1, -1, -1):
		if int(_pending_spawns[i].get("uuid", -1)) == uuid:
			_pending_spawns.remove_at(i)


func _make_spawn_entry(uuid: int, pos: Vector3, rot: Vector3, variant: Dictionary, spawn_type: String, is_sync: bool) -> Dictionary:
	var entry := {
		"uuid": uuid,
		"spawnType": spawn_type,
		"pos": pos,
		"rot": rot,
		"variant": variant,
		"isSync": is_sync,
		"retries": 0,
		"timer": 0.0,
	}
	if is_sync:
		entry["aiTarget"] = {"pos": pos, "rot": rot}
	return entry



func _physics_process(delta: float) -> void:
	_watch_frame_spike(delta)  # v0.13.73 항상 실행: 갑작스런 fps 드랍 시 엔진 서브시스템 덤프
	if not CoopAuthority.is_active():
		return

	var players := _players()
	if players == null:
		return

	if CoopAuthority.is_host():
		# v0.13.60 프레임드랍 진단: 느린 프레임(>22ms)일 때 AI 수 로그 (1초당 1회만)
		_perf_diag_accum += delta
		if _perf_diag_accum >= 1.0:
			var ft: float = Performance.get_monitor(Performance.TIME_PROCESS) + Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
			if ft > 0.022:
				var total: int = players.world_ai.size()
				var active: int = 0
				for u in players.world_ai:
					var aiN = players.world_ai[u]
					if is_instance_valid(aiN) and not aiN.dead and aiN.get("sensorActive"):
						active += 1
				print("[PERF] slow %.1fms | world_ai=%d active=%d peers=%d fps=%d" % [ft * 1000.0, total, active, multiplayer.get_peers().size(), Engine.get_frames_per_second()])
			_perf_diag_accum = 0.0
		_ai_accum += delta
		if _ai_accum >= 1.0 / AI_BROADCAST_RATE:
			_ai_accum = 0.0
			# fix6.3: skip AI position broadcast when no peers are connected.
			# BroadcastAIPositions iterates every world AI and packs a payload — the largest
			# per-frame cost while hosting. Doing it with an empty audience is what makes
			# a "1명" lobby stutter.
			if multiplayer.get_peers().size() > 0:
				BroadcastAIPositions()
		_reap_timer += delta
		if _reap_timer >= REAP_INTERVAL:
			_reap_timer = 0.0
			_reap_stale_world_ai()
			_prune_threat()
		_watch_ai_deaths()
		# v0.13.5: ASO 충돌 안전망 — 5초마다 dead AI ragdoll 강제 fallback
		_ragdoll_check_accum += delta
		if _ragdoll_check_accum >= RAGDOLL_CHECK_INTERVAL:
			_ragdoll_check_accum = 0.0
			_force_ragdoll_dead_ai()
	else:
		var now: float = Time.get_ticks_msec() / 1000.0
		var render_time: float = now - 0.1 # 100ms interpolation delay (2 packets at 20Hz)

		for uuid in players.world_ai:
			var ai: Node = players.world_ai.get(uuid)
			if not is_instance_valid(ai) or not ai.is_inside_tree() or ai.dead:
				continue
			if ai.get_meta("coop_ai_asleep", false):
				continue

			var q: Array = _ai_queues.get(uuid, [])
			# Prune entries older than target render_time, leaving at least two entries for interpolation
			while q.size() > 2 and q[1]["time"] < render_time:
				q.remove_at(0)

			if q.size() >= 2:
				var state_A = q[0]
				var state_B = q[1]
				var t: float = 0.0
				var duration: float = state_B["time"] - state_A["time"]
				if duration > 0.001:
					t = clampf((render_time - state_A["time"]) / duration, 0.0, 1.0)
				
				var target_pos = state_A["pos"].lerp(state_B["pos"], t)
				var target_rot_y = lerp_angle(state_A["rot"].y, state_B["rot"].y, t)
				
				# The queue already interpolates between authoritative host samples.
				# A second low-pass lerp makes remote AI trail the sample and then catch up,
				# which looks like over-speed movement at long distance.
				ai.global_position = target_pos
				ai.global_rotation.y = target_rot_y
			else:
				# Fallback to standard lerp if queue is insufficient
				var target = players.ai_targets.get(uuid)
				if target:
					if ai.global_position.distance_squared_to(target["pos"]) > 9.0:
						ai.global_position = target["pos"]
						ai.global_rotation.y = target["rot"].y
					else:
						ai.global_position = ai.global_position.lerp(target["pos"], delta * 3.0)
						ai.global_rotation.y = lerp_angle(ai.global_rotation.y, target["rot"].y, delta * 5.0)

		for uuid in players.world_ai:
			var ai: Node = players.world_ai.get(uuid)
			if not is_instance_valid(ai) or not ai.is_inside_tree() or ai.dead:
				continue
			if ai.get_meta("coop_ai_asleep", false):
				continue
			if not ai.visible:
				ai.show()
				ai.pause = false
				ai.process_mode = Node.PROCESS_MODE_INHERIT
				if ai.skeleton:
					ai.skeleton.process_mode = Node.PROCESS_MODE_INHERIT
					ai.skeleton.show_rest_only = false
				if ai.animator:
					ai.animator.active = true
				ai.set_meta("coop_client_anim_ready", false)

	_process_pending_spawns()

	if CoopAuthority.is_client() and players.scene_ready:
		_manifest_timer += delta
		if _manifest_timer >= MANIFEST_CHECK_INTERVAL:
			_manifest_timer = 0.0
			RequestAIManifest.rpc_id(1)


func _process_pending_spawns() -> void:
	var players := _players()
	if _pending_spawns.is_empty() or players == null or not players.scene_ready:
		return
	var still_pending: Array = []
	var dt: float = get_physics_process_delta_time()
	for entry in _pending_spawns:
		if entry["timer"] > 0.0:
			entry["timer"] -= dt
			still_pending.append(entry)
			continue
		if _try_spawn_agent(entry):
			continue
		entry["retries"] += 1
		if entry["retries"] > SPAWN_RETRY_MAX:
			push_warning("[AISync] giving up on spawn uuid=%d" % entry["uuid"])
			continue
		entry["timer"] = SPAWN_RETRY_INTERVAL
		still_pending.append(entry)
	_pending_spawns = still_pending


func _get_ai_spawner() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
		
	# 3. Absolute path fallback (가장 먼저 시도)
	var spawner = tree.root.get_node_or_null("Map/AI")
	if spawner:
		return spawner
		
	var scene := tree.current_scene
	if scene != null:
		# 1. 스크립트 기반 검색 (가장 확실함)
		spawner = _find_spawner_by_script(scene)
		if spawner:
			return spawner
			
		# 2. Direct child check fallback
		spawner = scene.get_node_or_null("AI")
		if spawner:
			return spawner
			
	return null


func _find_spawner_by_script(root: Node) -> Node:
	if root == null:
		return null
	var script = root.get_script()
	if script and script is Script and script.resource_path.ends_with("AISpawner.gd"):
		return root
	for child in root.get_children():
		var found = _find_spawner_by_script(child)
		if found != null:
			return found
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


func _try_spawn_agent(entry: Dictionary) -> bool:
	var players := _players()
	var uuid: int = entry["uuid"]
	if players.world_ai.has(uuid):
		return true
	if not players.scene_ready:
		return false

	var ai_spawner := _get_ai_spawner()
	if ai_spawner == null:
		print("[AISync] _try_spawn_agent failed: ai_spawner is null")
		return false

	var spawn_type: String = entry.get("spawnType", "")
	var pool_name = "BPool" if spawn_type == "Boss" else "APool"
	var pool: Node = ai_spawner.get(pool_name)
	
	if pool == null:
		pool = Node3D.new()
		pool.name = pool_name
		ai_spawner.add_child(pool)
		ai_spawner.set(pool_name, pool)
		print("[AISync] Created %s dynamically on client" % pool_name)

	if pool.get_child_count() == 0 and not _grow_pool(ai_spawner, pool, spawn_type):
		print("[AISync] _try_spawn_agent failed: _grow_pool returned false")
		return false

	var new_agent: Node = pool.get_child(0)
	
	var agents_node: Node = ai_spawner.get("agents")
	if agents_node == null:
		agents_node = Node3D.new()
		agents_node.name = "agents"
		ai_spawner.add_child(agents_node)
		ai_spawner.set("agents", agents_node)
		print("[AISync] Created 'agents' container dynamically on client")
		
	new_agent.reparent(agents_node)
	new_agent.global_position = entry["pos"]
	new_agent.global_rotation = entry["rot"]
	new_agent.set_meta("network_uuid", uuid)
	new_agent.set_meta("coop_spawn_variant", entry.get("variant", {}))
	
	# [안전장치] 스폰 즉시 멀리서 플레이어를 투시/인지하고 저격하는 오류 방지
	var forward_pos = entry["pos"] - new_agent.global_transform.basis.z * 10.0
	if "playerVisible" in new_agent: new_agent.playerVisible = false
	if "targetPosition" in new_agent: new_agent.targetPosition = forward_pos
	if "playerPosition" in new_agent: new_agent.playerPosition = forward_pos
	if "LKL" in new_agent: new_agent.LKL = forward_pos
	if "lastKnownLocation" in new_agent: new_agent.lastKnownLocation = forward_pos
	
	players.world_ai[uuid] = new_agent
	if entry.has("aiTarget"):
		players.ai_targets[uuid] = entry["aiTarget"]
	ai_spawner.activeAgents += 1
	if uuid >= players.next_ai_uuid:
		players.next_ai_uuid = uuid + 1

	var asleep: bool = entry.get("asleep", false)
	_deferred_activate(new_agent, spawn_type, entry.get("isSync", false), asleep)
	return true


func _grow_pool(ai_spawner: Node, pool: Node, spawn_type: String) -> bool:
	var scene: PackedScene = ai_spawner.punisher if spawn_type == "Boss" else ai_spawner.agent
	if scene == null:
		print("[AISync] _grow_pool failed: ai_spawner.agent (or punisher) is null for type %s. Attempting fallback load." % spawn_type)
		if spawn_type == "Boss":
			scene = load("res://Scenes/Characters/AI_Boss.tscn")
			if scene == null: scene = load("res://Objects/AI/Punisher.tscn")
		else:
			scene = load("res://Scenes/Characters/AI.tscn")
			if scene == null: scene = load("res://Objects/AI/Agent.tscn")
			
		if scene == null:
			push_error("[AISync] _grow_pool FATAL: Fallback load also failed! Cannot load AI scenes.")
			return false
			
	var new_agent = scene.instantiate()
	new_agent.boss = (spawn_type == "Boss")
	new_agent.AISpawner = ai_spawner
	pool.add_child(new_agent, true)
	new_agent.global_position = pool.global_position + Vector3(randf_range(-10, 10), 0, randf_range(-10, 10))
	if new_agent.has_method("Pause"):
		new_agent.Pause()
	print("[AISync] _grow_pool SUCCESS: instantiated new agent into %s" % pool.name)
	return true


# v0.13.73: 갑작스런 fps 드랍(≥15) 감지 시 어느 엔진 서브시스템이 바쁜지 덤프.
# proc=스크립트 _process / phys=_physics_process+물리 / nav=내비 / draw·prim=렌더 / pairs=물리충돌 / nodes·objs=객체수.
# 판독: proc·phys 높으면 스크립트(우리or외부 모드), draw 높으면 렌더(UI/지오메트리), pairs 높으면 물리.
func _watch_frame_spike(delta: float) -> void:
	var fps: float = float(Engine.get_frames_per_second())
	if fps <= 0.0:
		return
	if _spike_fps_ema <= 0.0:
		_spike_fps_ema = fps
		return
	_spike_cd -= delta
	if fps <= _spike_fps_ema - _SPIKE_DROP and _spike_cd <= 0.0:
		_spike_cd = _SPIKE_COOLDOWN
		_dump_spike(fps, _spike_fps_ema)
	_spike_fps_ema = _spike_fps_ema * 0.95 + fps * 0.05


func _dump_spike(fps: float, baseline: float) -> void:
	var P := Performance
	var players := _players()
	var wai: int = players.world_ai.size() if players else 0
	var pc: int = multiplayer.get_peers().size() if multiplayer.has_multiplayer_peer() else 0
	print("[SPIKE] fps=%d (base=%d drop=%d) | proc=%.1fms phys=%.1fms nav=%.2fms | draw=%d prim=%d robj=%d | p3d_active=%d pairs=%d | nodes=%d objs=%d orphan=%d | world_ai=%d peers=%d" % [
		int(fps), int(baseline), int(baseline - fps),
		P.get_monitor(P.TIME_PROCESS) * 1000.0,
		P.get_monitor(P.TIME_PHYSICS_PROCESS) * 1000.0,
		P.get_monitor(P.TIME_NAVIGATION_PROCESS) * 1000.0,
		int(P.get_monitor(P.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(P.get_monitor(P.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		int(P.get_monitor(P.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		int(P.get_monitor(P.PHYSICS_3D_ACTIVE_OBJECTS)),
		int(P.get_monitor(P.PHYSICS_3D_COLLISION_PAIRS)),
		int(P.get_monitor(P.OBJECT_NODE_COUNT)),
		int(P.get_monitor(P.OBJECT_COUNT)),
		int(P.get_monitor(P.OBJECT_ORPHAN_NODE_COUNT)),
		wai, pc,
	])


func _watch_ai_deaths() -> void:
	# v0.6 [3단계]: 폴링 워치독 진입점 — ASO 등이 vanilla death를 안 거치고 죽인 AI를 잡아 처리.
	# 시체 본문은 BuildAndBroadcastAIDeath로 통합(AIHooks._replace_ai_death와 공유). ⚠️world_ai를
	# 순회 중이라 루프 안에서 erase 불가 → stale 모아 후처리(공유 함수는 erase 안 함).
	var players := _players()
	if players == null or players.world_ai.is_empty():
		return
	var stale: Array = []
	for uuid in players.world_ai:
		var ai_node: Node = players.world_ai[uuid]
		if not is_instance_valid(ai_node):
			stale.append(uuid)
			continue
		if not ai_node.dead:
			continue
		if ai_node.has_meta("_coop_death_broadcasted"):
			stale.append(uuid)
			continue
		BuildAndBroadcastAIDeath(ai_node, Vector3.ZERO, 20.0)
		stale.append(uuid)

	for uuid in stale:
		players.world_ai.erase(uuid)
		players.ai_targets.erase(uuid)


# v0.6 [3단계]: AI 시체 처리 단일 본문 = 루팅/무기/배낭/보조 직렬화 + corpse 컨테이너 cid 할당 +
# worldItems uuid 등록(uuid*10+1/2/3) + BroadcastAIDeath RPC. 두 진입점이 공유:
#   1) AIHooks._replace_ai_death  (vanilla ai-death 훅 = 즉시 경로)
#   2) _watch_ai_deaths            (폴링 워치독 = vanilla death 우회한 죽음 대비)
# ⚠️ world_ai/ai_targets erase는 *호출자* 책임 — 워치독은 dict 순회 중이라 여기서 erase 금지.
# 반환 = 처리한 uuid (network_uuid 없거나 players null이면 -1).
func BuildAndBroadcastAIDeath(ai_node: Node, direction, force) -> int:
	var players := _players()
	if players == null or ai_node == null or not ai_node.has_meta("network_uuid"):
		return -1
	var uuid: int = int(ai_node.get_meta("network_uuid"))
	ai_node.set_meta("_coop_death_broadcasted", true)
	var ss := _slot_serializer()
	var container_loot: Array = []
	var lc: Node = _get_ai_loot_container(ai_node)
	if lc and ss:
		for s in lc.loot:
			container_loot.append(ss.SerializeSlotData(s))
	var weapon_dict: Dictionary = ss.SerializeSlotData(ai_node.weapon.slotData) if ss and ai_node.weapon and ai_node.weapon.slotData else {}
	var backpack_dict: Dictionary = ss.SerializeSlotData(ai_node.backpack.slotData) if ss and ai_node.backpack and ai_node.backpack.slotData else {}
	var secondary_dict: Dictionary = ss.SerializeSlotData(ai_node.secondary.slotData) if ss and ai_node.secondary and ai_node.secondary.slotData else {}
	var corpse_cid: int = players.nextContainerId
	players.nextContainerId += 1
	if lc:
		if not lc.is_in_group("CoopLootContainer"):
			lc.add_to_group("CoopLootContainer")
		lc.set_meta("coop_container_id", corpse_cid)
	if ai_node.weapon:
		var w_uuid: int = uuid * 10 + 1
		ai_node.weapon.set_meta("network_uuid", w_uuid)
		players.worldItems[w_uuid] = ai_node.weapon
		if w_uuid >= players.nextUuid:
			players.nextUuid = w_uuid + 1
	if ai_node.backpack:
		var b_uuid: int = uuid * 10 + 2
		ai_node.backpack.set_meta("network_uuid", b_uuid)
		players.worldItems[b_uuid] = ai_node.backpack
		if b_uuid >= players.nextUuid:
			players.nextUuid = b_uuid + 1
	if ai_node.secondary:
		var s_uuid: int = uuid * 10 + 3
		ai_node.secondary.set_meta("network_uuid", s_uuid)
		players.worldItems[s_uuid] = ai_node.secondary
		if s_uuid >= players.nextUuid:
			players.nextUuid = s_uuid + 1
	BroadcastAIDeath.rpc(uuid, ai_node.global_position, ai_node.global_rotation, direction, force, container_loot, weapon_dict, backpack_dict, secondary_dict, corpse_cid)
	return uuid


func _force_ragdoll_dead_ai() -> void:
	# v0.13.5: ASO/vanilla 충돌로 ragdoll 안 된 시체를 강제 복원.
	# 호스트만 fire (호스트 권위). broadcast로 클라들에게 sync.
	var players_ref = _players()
	if players_ref == null:
		return
	var forced: int = 0
	for uuid in players_ref.world_ai:
		var ai = players_ref.world_ai.get(uuid)
		if not is_instance_valid(ai):
			continue
		if not ai.get("dead"):
			continue
		if ai.get_meta("coop_ragdoll_forced", false):
			continue
		if ai.skeleton and ai.skeleton.has_method("Activate"):
			ai.skeleton.Activate(Vector3(0, 0, -1), 5.0)
			if "simulationTime" in ai.skeleton:
				ai.skeleton.simulationTime = 999.0
			ai.set_meta("coop_ragdoll_forced", true)
			BroadcastForceRagdoll.rpc(int(uuid))
			forced += 1
	if forced > 0:
		print("[AISync] forced ragdoll on %d stuck AI corpses (ASO conflict fallback)" % forced)


@rpc("authority", "reliable", "call_local")
func BroadcastForceRagdoll(uuid: int) -> void:
	if multiplayer.is_server():
		return  # 호스트는 이미 처리됨
	var players_ref = _players()
	if players_ref == null:
		return
	var ai = players_ref.world_ai.get(uuid, null)
	if ai and is_instance_valid(ai):
		if ai.skeleton and ai.skeleton.has_method("Activate"):
			ai.skeleton.Activate(Vector3(0, 0, -1), 5.0)
			if "simulationTime" in ai.skeleton:
				ai.skeleton.simulationTime = 999.0
		ai.set_meta("coop_ragdoll_forced", true)


func _reap_stale_world_ai() -> void:
	var players := _players()
	if players == null:
		return
	var stale: Array = []
	for uuid in players.world_ai:
		var ai: Node = players.world_ai[uuid]
		if not is_instance_valid(ai) or not ai.is_inside_tree():
			stale.append(uuid)
	if stale.is_empty():
		return
	for uuid in stale:
		players.world_ai.erase(uuid)
		players.ai_targets.erase(uuid)
		_ai_queues.erase(uuid)
	BroadcastAIRemove.rpc(PackedInt32Array(stale))


func _deferred_activate(agent: Node, spawn_type: String, is_sync: bool, asleep: bool = false) -> void:
	if not is_instance_valid(agent) or not agent.is_inside_tree():
		return
	_log("_deferred_activate type=%s is_sync=%s is_server=%s asleep=%s" % [spawn_type, str(is_sync), str(multiplayer.is_server()), str(asleep)])
	if is_sync or not multiplayer.is_server():
		_full_equipment_from_variant(agent)
		agent.Activate()
		if not multiplayer.is_server():
			_disable_client_sensors(agent)
	else:
		match spawn_type:
			"Wanderer": agent.ActivateWanderer()
			"Guard": agent.ActivateGuard()
			"Hider": agent.ActivateHider()
			"Minion": agent.ActivateMinion()
			"Boss": agent.ActivateBoss()
			
	if not multiplayer.is_server() and asleep:
		agent.set_meta("coop_ai_asleep", true)
		agent.hide()
		agent.process_mode = Node.PROCESS_MODE_DISABLED
		if "skeleton" in agent and agent.skeleton:
			agent.skeleton.process_mode = Node.PROCESS_MODE_DISABLED
		if "animator" in agent and agent.animator:
			agent.animator.active = false
	else:
		_ensure_ai_visible(agent)


func _full_equipment_from_variant(agent: Node) -> void:
	if agent.has_method("DeactivateEquipment"):
		agent.DeactivateEquipment()
	if agent.has_method("DeactivateContainer"):
		agent.DeactivateContainer()
	var variant: Dictionary = agent.get_meta("coop_spawn_variant", {})
	var w_count: int = agent.weapons.get_child_count() if agent.weapons else 0
	var has_clothing: bool = agent.get("allowClothing") == true
	var cloth_count: int = agent.clothing.size() if agent.get("clothing") != null else -1
	var has_mesh: bool = agent.mesh != null
	var container_type: String = str(type_string(typeof(agent.container))) if agent.container else "null"
	var container_is_lc: bool = agent.container is LootContainer if agent.container else false
	_log("_full_equipment_from_variant weapons=%d allowClothing=%s clothingArr=%d mesh=%s container=%s isLC=%s" % [w_count, str(has_clothing), cloth_count, str(has_mesh), container_type, str(container_is_lc)])
	_log("  variant=%s" % str(variant))

	if agent.weapons and agent.weapons.get_child_count() > 0:
		var weapon_file: String = variant.get("weaponFile", "")
		var weapon_index: int = -1
		if weapon_file != "":
			for i in agent.weapons.get_child_count():
				var child: Node = agent.weapons.get_child(i)
				if child.slotData and child.slotData.itemData and child.slotData.itemData.file == weapon_file:
					weapon_index = i
					break
		if weapon_index < 0:
			weapon_index = randi_range(0, agent.weapons.get_child_count() - 1)
		_log("  → weapon selected: index=%d/%d file=%s" % [weapon_index, agent.weapons.get_child_count(), weapon_file])
		agent.weapon = agent.weapons.get_child(weapon_index)
		if agent.weapon:
			agent.weaponData = agent.weapon.slotData.itemData
			agent.weapon.show()
			for child in agent.weapons.get_children():
				if child != agent.weapon:
					child.queue_free()
			agent.muzzle = agent.weapon.get_node_or_null("Muzzle")

			var new_slot = SlotData.new()
			new_slot.itemData = agent.weapon.slotData.itemData
			new_slot.condition = variant.get("weaponCondition", randi_range(5, 50))
			var mag_size: int = new_slot.itemData.magazineSize if "magazineSize" in new_slot.itemData else 10
			new_slot.amount = variant.get("weaponAmount", randi_range(1, max(1, mag_size)))
			new_slot.chamber = true
			agent.weapon.slotData = new_slot

			if new_slot.itemData.weaponType == "Pistol":
				agent.animator["parameters/conditions/Pistol"] = true
				agent.animator["parameters/conditions/Rifle"] = false
			else:
				agent.animator["parameters/conditions/Pistol"] = false
				agent.animator["parameters/conditions/Rifle"] = true

			if agent.weaponData.weaponAction != "Manual" and agent.weaponData.compatible.size() > 0:
				if agent.weaponData.compatible[0].subtype == "Magazine":
					var attachments = agent.weapon.get_node_or_null("Attachments")
					if attachments:
						var magazine = attachments.get_node_or_null(agent.weaponData.compatible[0].file)
						if magazine:
							magazine.show()
					agent.weapon.slotData.nested.append(agent.weaponData.compatible[0])

	if agent.get("allowBackpacks") and agent.backpacks and agent.backpacks.get_child_count() > 0:
		var bp_roll: int = variant.get("backpackRoll", randi_range(0, 100))
		if bp_roll < 10:
			var bp_file: String = variant.get("backpackFile", "")
			var bp_index: int = -1
			if bp_file != "":
				for i in agent.backpacks.get_child_count():
					var child = agent.backpacks.get_child(i)
					if child.get("slotData") and child.slotData.itemData and child.slotData.itemData.file == bp_file:
						bp_index = i
						break
					if bp_index < 0 and child.name == bp_file:
						bp_index = i
						break
			if bp_index < 0:
				bp_index = randi_range(0, agent.backpacks.get_child_count() - 1)
			agent.backpack = agent.backpacks.get_child(bp_index)
			for child in agent.backpacks.get_children():
				if child != agent.backpack:
					child.queue_free()
			var bp_mesh = agent.backpack.get_node_or_null("Mesh")
			if bp_mesh:
				agent.backpack.show()
				bp_mesh.visibility_range_end = 400.0
		else:
			for child in agent.backpacks.get_children():
				child.queue_free()

	var allow_clothing: bool = agent.get("allowClothing") if agent.get("allowClothing") != null else false
	_log("  clothing: allowClothing=%s clothing_count=%d mesh=%s" % [str(allow_clothing), agent.clothing.size() if agent.get("clothing") else 0, str(agent.mesh != null)])
	if allow_clothing and agent.clothing and agent.clothing.size() > 0:
		var clothing_path: String = variant.get("clothingPath", "")
		var cloth_index: int = -1
		if clothing_path != "":
			for i in agent.clothing.size():
				if agent.clothing[i] and agent.clothing[i].resource_path == clothing_path:
					cloth_index = i
					break
		if cloth_index < 0:
			cloth_index = randi_range(0, agent.clothing.size() - 1)
		_log("  → applying clothing index=%d/%d path=%s" % [cloth_index, agent.clothing.size(), clothing_path])
		if agent.mesh:
			agent.mesh.set_surface_override_material(0, agent.clothing[cloth_index])


func _disable_client_sensors(agent: Node) -> void:
	if not is_instance_valid(agent):
		return
	# 양방향 FSM 로컬 실행 시, 클라이언트 측 AI가 플레이어에게 이중 데미지를 입히는 것을 방지하기 위해 사격 판정만 비활성화.
	# LOS, 길찾기(NavMesh), 바닥/정면 장애물 감지는 유지하여 클라이언트가 자연스럽게 이동하도록 합니다.
	if agent.get("fire") and agent.fire is RayCast3D:
		agent.fire.enabled = false


func _ensure_ai_visible(agent: Node) -> void:
	if not is_instance_valid(agent):
		return
	if agent.has_method("HideGizmos"):
		agent.HideGizmos()
	agent.show()
	agent.pause = false
	agent.process_mode = Node.PROCESS_MODE_INHERIT
	
	var is_server: bool = multiplayer.is_server()
	
	if agent.skeleton:
		agent.skeleton.show_rest_only = false
		agent.skeleton.process_mode = Node.PROCESS_MODE_INHERIT
		# [RTVCoop] 클라이언트인 경우에만 PROCESS_MANUAL로 프로세스 모드 설정 (호스트는 IDLE 유지하여 먹통 방지)
		agent.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE if is_server else Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	if agent.animator:
		agent.animator.active = true
		agent.animator.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE if is_server else AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	agent.set_meta("coop_client_anim_ready", false)


func GenerateAiUuid() -> int:
	var players := _players()
	if players == null:
		return 0
	var u: int = players.next_ai_uuid
	players.next_ai_uuid += 1
	return u


func _is_local_downed() -> bool:
	# v0.13.21: 본인 쓰러진 상태 체크. vanilla AI가 호스트 본인을 target으로 잡고 계속 사격하는 거 방지.
	var coop := RTVCoop.get_instance()
	var ds = coop.get_sync("downed") if coop else null
	if ds == null:
		return false
	return ds.is_peer_downed(CoopAuthority.local_peer_id())


func _nearest_player(from: Vector3, use_camera: bool) -> Vector3:
	var players := _players()
	if players == null:
		return Vector3.ZERO
	var best_pos: Vector3 = Vector3.ZERO
	var best_dist: float = INF
	var found: bool = false

	var local_ctrl: Node = players.GetLocalController() if players.has_method("GetLocalController") else null
	# v0.13.21: 본인이 쓰러진 상태면 local target 후보 제외 (remote puppet downed 체크와 대칭).
	if local_ctrl and local_ctrl.is_inside_tree() and not _is_local_downed():
		var d: float = from.distance_squared_to(local_ctrl.global_position)
		if d < best_dist:
			best_dist = d
			best_pos = gameData.cameraPosition if use_camera else local_ctrl.global_position
			found = true

	for id in players.remote_players:
		var puppet: Node = players.remote_players[id]
		if not is_instance_valid(puppet) or not puppet.is_inside_tree():
			continue
		if puppet.get("isDead") or puppet.get("isDowned"):
			continue
		var d: float = from.distance_squared_to(puppet.global_position)
		if d < best_dist:
			best_dist = d
			best_pos = puppet.global_position + (Vector3(0, 1.6, 0) if use_camera else Vector3.ZERO)
			found = true

	return best_pos if found else Vector3.ZERO


func GetNearestPlayerPosition(from: Vector3) -> Vector3:
	return _nearest_player(from, false)


func GetNearestPlayerCamera(from: Vector3) -> Vector3:
	return _nearest_player(from, true)


func GetNearestPlayerState(from: Vector3) -> Dictionary:
	var players := _players()
	if players == null:
		return {}
	var best_dist: float = INF
	var best_peer: int = -1
	var is_local: bool = false

	var local_ctrl: Node = players.GetLocalController() if players.has_method("GetLocalController") else null
	# v0.13.21: 본인이 쓰러진 상태면 local target 후보 제외
	if local_ctrl and local_ctrl.is_inside_tree() and not _is_local_downed():
		var d: float = from.distance_squared_to(local_ctrl.global_position)
		if d < best_dist:
			best_dist = d
			best_peer = CoopAuthority.local_peer_id()
			is_local = true

	for id in players.remote_players:
		var puppet: Node = players.remote_players[id]
		if not is_instance_valid(puppet) or not puppet.is_inside_tree():
			continue
		if puppet.get("isDead") or puppet.get("isDowned"):
			continue
		var d: float = from.distance_squared_to(puppet.global_position)
		if d < best_dist:
			best_dist = d
			best_peer = id
			is_local = false

	if best_peer < 0:
		return {}

	return _state_for_peer(best_peer, is_local)


# v0.5: 선택된 타겟(local/puppet)의 state dict 구성. GetNearestPlayerState·GetBestTargetState 공용.
func _state_for_peer(best_peer: int, is_local: bool) -> Dictionary:
	var players := _players()
	if players == null:
		return {}
	if is_local:
		var local_ctrl: Node = players.GetLocalController() if players.has_method("GetLocalController") else null
		if local_ctrl == null:
			return {}
		return {
			"pos": local_ctrl.global_position,
			"cam": gameData.cameraPosition,
			"is_running": gameData.isRunning,
			"is_walking": gameData.isWalking,
			"is_firing": gameData.isFiring,
			"player_vector": gameData.playerVector,
			"peer": best_peer, "is_local": true,
			"is_dead": gameData.isDead,
			"is_trading": gameData.isTrading,
		}
	var puppet: Node = players.remote_players.get(best_peer)
	if not is_instance_valid(puppet):
		return {}
	var coop := RTVCoop.get_instance()
	var proxy: Node = coop.get_player_proxy(best_peer) if coop else null
	var p_is_running: bool = false
	var p_is_walking: bool = false
	var p_is_firing: bool = false
	var is_crouching: bool = false
	if proxy:
		p_is_firing = proxy.sync_is_firing
		var cond: String = proxy.sync_anim_condition
		var blend: float = proxy.sync_anim_blend
		if cond == "Hunt":
			is_crouching = true
		if cond == "Movement" or cond == "MovementLow":
			if blend >= 4.0:
				p_is_running = true
			elif blend >= 0.5:
				p_is_walking = true
	var fwd := Vector3(sin(puppet.global_rotation.y), 0, cos(puppet.global_rotation.y)).normalized()
	var cam_y: float = 0.9 if is_crouching else 1.6
	return {
		"pos": puppet.global_position,
		"cam": puppet.global_position + Vector3(0, cam_y, 0),
		"is_running": p_is_running,
		"is_walking": p_is_walking,
		"is_firing": p_is_firing,
		"player_vector": fwd,
		"peer": best_peer, "is_local": false,
		"is_dead": puppet.get("isDead") or puppet.get("isDowned"),
		"is_trading": false,
	}


# v0.5: 캐시된 state의 위치(pos/cam) 및 행동 플래그를 *매 프레임 in-place* 갱신 (dict 재할당 X = GC/프레임 부담 0).
# 움직이는 클라를 묵은(0.25s) 위치로 조준하던 뚝뚝회전/뜨문사격 해소 및 반응성 지연 해결.
func RefreshTargetPos(state: Dictionary) -> void:
	if state.is_empty():
		return
	var players := _players()
	if players == null:
		return
	if state.get("is_local", true):
		var lc: Node = players.GetLocalController() if players.has_method("GetLocalController") else null
		if lc and is_instance_valid(lc):
			state["pos"] = lc.global_position
			state["cam"] = gameData.cameraPosition
			state["is_running"] = gameData.isRunning
			state["is_walking"] = gameData.isWalking
			state["is_firing"] = gameData.isFiring
			state["is_dead"] = gameData.isDead
			state["is_trading"] = gameData.isTrading
	else:
		var peer_id = state.get("peer", -1)
		var puppet: Node = players.remote_players.get(peer_id)
		if is_instance_valid(puppet):
			# 이동 벡터 및 속도 예측 계산
			var velocity_vector := Vector3.ZERO
			if "velocity" in puppet:
				velocity_vector = puppet.velocity
			elif "targetPosition" in puppet:
				# targetPosition이 존재하면 다음 동기화 지점과의 차이로 속도 추론
				velocity_vector = (puppet.targetPosition - puppet.global_position) * 15.0 # Lerp 속도 보정값
				
			# 네트워크 핑/딜레이 보정 상수 (예: 0.08초 정도의 미래 위치 예측)
			var prediction_time := 0.08 
			var predicted_offset := velocity_vector * prediction_time
			
			state["pos"] = puppet.global_position + predicted_offset
			var coop := RTVCoop.get_instance()
			var proxy: Node = coop.get_player_proxy(peer_id) if coop else null
			var p_is_running := false
			var p_is_walking := false
			var p_is_firing := false
			var is_crouching := false
			if proxy:
				p_is_firing = proxy.sync_is_firing
				var cond: String = proxy.sync_anim_condition
				if cond == "Hunt":
					is_crouching = true
				if cond in ["Movement", "MovementLow"]:
					if proxy.sync_anim_blend >= 4.0:
						p_is_running = true
					elif proxy.sync_anim_blend >= 0.5:
						p_is_walking = true
			var cam_y: float = 0.9 if is_crouching else 1.6
			state["cam"] = puppet.global_position + predicted_offset + Vector3(0, cam_y, 0)
			state["is_running"] = p_is_running
			state["is_walking"] = p_is_walking
			state["is_firing"] = p_is_firing
			state["is_dead"] = puppet.get("isDead") or puppet.get("isDowned")
			state["is_trading"] = false


# v0.5: 위협 가중 타게팅. nearest 대신 (거리점수 + 위협점수) 최고 플레이어 선정.
# 토글 off거나 AI uuid 없으면(가드 등) nearest로 폴백. AIHooks가 a(AI노드) 넘김.
func _target_belongs_to_hit(hit: Object, target: Node) -> bool:
	var node := hit as Node
	while node != null:
		if node == target:
			return true
		node = node.get_parent()
	return false


func _ai_eye_position(ai_node: Node) -> Vector3:
	if ai_node == null:
		return Vector3.ZERO
	if "eyes" in ai_node and is_instance_valid(ai_node.eyes):
		return ai_node.eyes.global_position
	return ai_node.global_position + Vector3(0.0, 1.5, 0.0)


func _target_has_clear_los(ai_node: Node, target: Node, target_cam: Vector3) -> bool:
	if ai_node == null or target == null or not is_instance_valid(target):
		return false
	if not ai_node.has_method("get_world_3d"):
		return false
	var world = ai_node.get_world_3d()
	# [FIX] 월드맵 등 물리 공간이 완전히 준비되지 않았을 때의 Null 크래시 방지
	if world == null or world.direct_space_state == null:
		return false
	var query := PhysicsRayQueryParameters3D.create(_ai_eye_position(ai_node), target_cam)
	query.collision_mask = TARGET_LOS_MASK
	if ai_node is CollisionObject3D:
		query.exclude = [(ai_node as CollisionObject3D).get_rid()]
	var result: Dictionary = world.direct_space_state.intersect_ray(query)
	if not result.has("collider"):
		return false
	return _target_belongs_to_hit(result.collider, target)


func _can_ai_consider_target(ai_node: Node, target: Node, target_cam: Vector3, distance: float, threat_score: float) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if distance > TARGET_ACQUIRE_RANGE and threat_score <= 0.0:
		return false
	if threat_score > 0.0 and distance <= THREAT_MAX_RANGE:
		return true
	return _target_has_clear_los(ai_node, target, target_cam)


func GetBestTargetState(from: Vector3, ai_node: Node) -> Dictionary:
	if not bool(Engine.get_meta("coop_threat_targeting", true)):
		return GetNearestPlayerState(from)
	var ai_uuid: int = int(ai_node.get_meta("network_uuid", -1)) if (ai_node and ai_node.has_meta("network_uuid")) else -1
	var players := _players()
	if players == null:
		return {}
	var now: float = Time.get_ticks_msec() / 1000.0
	var best_peer: int = -1
	var best_score: float = -INF
	var is_local: bool = false
	var local_ctrl: Node = players.GetLocalController() if players.has_method("GetLocalController") else null
	if local_ctrl and local_ctrl.is_inside_tree() and not local_ctrl.get("isDead") and not _is_local_downed():
		var local_dist: float = from.distance_to(local_ctrl.global_position)
		var local_threat: float = _threat_for(ai_uuid, CoopAuthority.local_peer_id(), now)
		if _can_ai_consider_target(ai_node, local_ctrl, gameData.cameraPosition, local_dist, local_threat):
			var local_score: float = _dist_score(local_dist) + THREAT_WEIGHT * local_threat
			if local_score > best_score:
				best_score = local_score
				best_peer = CoopAuthority.local_peer_id()
				is_local = true
	for id in players.remote_players:
		var puppet: Node = players.remote_players[id]
		if not is_instance_valid(puppet) or not puppet.is_inside_tree():
			continue
		if puppet.get("isDead") or puppet.get("isDowned"):
			continue
		var puppet_dist: float = from.distance_to(puppet.global_position)
		var puppet_threat: float = _threat_for(ai_uuid, id, now)
		var cam: Vector3 = puppet.global_position + Vector3(0.0, 1.6, 0.0)
		if "cameraPosition" in puppet:
			cam = puppet.cameraPosition
		if _can_ai_consider_target(ai_node, puppet, cam, puppet_dist, puppet_threat):
			var puppet_score: float = _dist_score(puppet_dist) + THREAT_WEIGHT * puppet_threat
			if puppet_score > best_score:
				best_score = puppet_score
				best_peer = id
				is_local = false
	if best_peer < 0:
		return {}
	return _state_for_peer(best_peer, is_local)


func _dist_score(d: float) -> float:
	return 1.0 - clampf(d / THREAT_MAX_RANGE, 0.0, 1.0)


# 위협 기록: RequestAIDamage(원격 사수) + HitboxHooks(호스트 자기샷)에서 호출.
func record_threat(ai_uuid: int, attacker_peer: int, damage: float) -> void:
	if ai_uuid < 0 or attacker_peer <= 0 or damage <= 0.0:
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	if not _ai_threat.has(ai_uuid):
		_ai_threat[ai_uuid] = {}
	var by_peer: Dictionary = _ai_threat[ai_uuid]
	var cur: float = _decayed_threat(by_peer.get(attacker_peer, {}), now)
	by_peer[attacker_peer] = {"score": minf(THREAT_MAX, cur + damage * THREAT_PER_DAMAGE), "t": now}

	# [피격 모션 및 활성화 보장]
	var ai := _live_ai(ai_uuid)
	if ai and is_instance_valid(ai):
		# 1. 원거리 피격 시 수면 상태면 즉시 수면 해제 (스나이핑 시 무적/투명 오류 차단)
		if ai.get_meta("coop_ai_asleep", false):
			if has_method("SetAISleepState"):
				SetAISleepState.rpc(ai_uuid, false)
		
		# 2. 피격 애니메이션 및 사운드를 모든 클라이언트에 동기화 브로드캐스트
		if has_method("BroadcastAISound"):
			BroadcastAISound.rpc(ai_uuid, AI_SOUND_DAMAGE)


func _decayed_threat(entry: Dictionary, now: float) -> float:
	if entry.is_empty():
		return 0.0
	var age: float = now - float(entry.get("t", 0.0))
	if age >= THREAT_DECAY_TIME:
		return 0.0
	return float(entry.get("score", 0.0)) * (1.0 - age / THREAT_DECAY_TIME)


func _threat_for(ai_uuid: int, peer_id: int, now: float) -> float:
	if ai_uuid < 0 or not _ai_threat.has(ai_uuid):
		return 0.0
	var by_peer: Dictionary = _ai_threat[ai_uuid]
	if not by_peer.has(peer_id):
		return 0.0
	return _decayed_threat(by_peer[peer_id], now)


func _prune_threat() -> void:
	var players := _players()
	if players == null or _ai_threat.is_empty():
		return
	var stale: Array = []
	for uuid in _ai_threat:
		if not players.world_ai.has(uuid):
			stale.append(uuid)
	for uuid in stale:
		_ai_threat.erase(uuid)


func BroadcastAIPositions() -> void:
	var players := _players()
	if players == null or players.world_ai.is_empty():
		return
	var uuids: Array = []
	var positions := PackedVector3Array()
	var rotations := PackedVector3Array()
	var speeds := PackedFloat32Array()
	var strafe_dirs := PackedFloat32Array()
	var ai_states := PackedInt32Array()
	var target_positions := PackedVector3Array() # [4.2 동적 인지 변수 강제 주입]
	
	for uuid in players.world_ai:
		var ai := _live_ai(uuid)
		if ai == null:
			continue
		if ai.get_meta("coop_ai_asleep", false):
			continue
			
		# [4.2 & 6.0] 호스트에서 타겟을 선점하고 AI 내부에 감각 기반 주입 (의사결정 권위 유지)
		var target_state = GetBestTargetState(ai.global_position, ai)
		var has_target: bool = not target_state.is_empty()
		var target_pos = target_state.get("pos", ai.global_position)
		
		# AI가 플레이어를 발견(playerVisible)했을 때만 타겟 플레이어 위치를 주입합니다.
		# 인지하기 전(순찰/대기/추적 중 시야 상실)에는 실시간 위치를 강제 주입하지 않아 벽투시 감지를 차단합니다.
		var is_aware = false
		if has_target:
			if ai.get("playerVisible") == true:
				is_aware = true
			
		if is_aware and has_target:
			if "playerPosition" in ai: ai.playerPosition = target_pos
			if "targetPosition" in ai: ai.targetPosition = target_pos
			if "LKL" in ai: ai.LKL = target_pos
			if "lastKnownLocation" in ai: ai.lastKnownLocation = target_pos
		else:
			# 살아있는 타겟이 없거나, 아직 인지하지 않은 상태라면 인지 정보를 망각/원격 초기화
			var forward_pos = ai.global_position - ai.global_transform.basis.z * 10.0
			if "playerVisible" in ai: ai.playerVisible = false
			if "targetPosition" in ai: ai.targetPosition = forward_pos
			if "playerPosition" in ai: ai.playerPosition = forward_pos
			if "LKL" in ai: ai.LKL = forward_pos
			if "lastKnownLocation" in ai: ai.lastKnownLocation = forward_pos
			
			# 전투 상태였다가 타겟을 잃었다면(플레이어가 사망했거나 사라짐) Patrol/Wander 상태로 강제 복구
			if ai.get("currentState") in [5, 9, 10]:
				ai.currentState = 1 # Wander/Patrol 상태값
				if ai.has_method("ChangeState"):
					ai.ChangeState("Wander")
		
		uuids.append(uuid)
		positions.append(ai.global_position)
		rotations.append(ai.global_rotation)
		speeds.append(ai.speed)
		strafe_dirs.append(ai.strafeDirection if "strafeDirection" in ai else 0.0)
		ai_states.append(ai.currentState)
		target_positions.append(target_pos)
		
	if uuids.is_empty():
		return
	BroadcastAIStates.rpc(uuids, positions, rotations, speeds, strafe_dirs, ai_states, target_positions)


@rpc("authority", "unreliable_ordered", "call_remote")
func BroadcastAIStates(uuids: Array, positions: PackedVector3Array, rotations: PackedVector3Array, speeds: PackedFloat32Array, strafe_dirs: PackedFloat32Array, states: PackedInt32Array, target_positions: PackedVector3Array) -> void:
	var players := _players()
	if players == null:
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	for i in uuids.size():
		var ai := _live_ai(uuids[i])
		if ai == null:
			continue
		var uuid: int = uuids[i]
		
		# [6. 클라이언트 동기화] 호스트 의사결정 권위 유지 (Target Intent 로컬 주입)
		if target_positions.size() > i:
			# AI가 플레이어를 발견(playerVisible)했을 때만 타겟 위치를 주입합니다.
			var is_aware = false
			if ai.get("playerVisible") == true:
				is_aware = true
				
			if is_aware:
				if "targetPosition" in ai: ai.targetPosition = target_positions[i]
				if "playerPosition" in ai: ai.playerPosition = target_positions[i]
				if "LKL" in ai: ai.LKL = target_positions[i]
				if "lastKnownLocation" in ai: ai.lastKnownLocation = target_positions[i]
			else:
				# 인지되지 않은 상태면 안전하게 망각 처리
				var forward_pos = ai.global_position - ai.global_transform.basis.z * 10.0
				if "playerVisible" in ai: ai.playerVisible = false
				if "targetPosition" in ai: ai.targetPosition = forward_pos
				if "playerPosition" in ai: ai.playerPosition = forward_pos
				if "LKL" in ai: ai.LKL = forward_pos
				if "lastKnownLocation" in ai: ai.lastKnownLocation = forward_pos
			
		players.ai_targets[uuid] = {"pos": positions[i], "rot": rotations[i]}
		
		if not _ai_queues.has(uuid):
			_ai_queues[uuid] = []
		var q: Array = _ai_queues[uuid]
		q.append({"pos": positions[i], "rot": rotations[i], "time": now})
		while q.size() > 5:
			q.remove_at(0)
			
		ai.speed = speeds[i]
		if "strafeDirection" in ai:
			ai.strafeDirection = strafe_dirs[i]
		var prev_state: int = ai.currentState
		ai.currentState = states[i]
		if prev_state != states[i]:
			_apply_client_animator_for_state(ai, states[i])


func _apply_client_animator_for_state(ai: Node, state: int) -> void:
	if not is_instance_valid(ai) or ai.animator == null:
		return
	var anim: AnimationMixer = ai.animator
	anim["parameters/Rifle/conditions/Movement"] = false
	anim["parameters/Pistol/conditions/Movement"] = false
	anim["parameters/Rifle/conditions/Combat"] = false
	anim["parameters/Pistol/conditions/Combat"] = false
	anim["parameters/Rifle/conditions/Guard"] = false
	anim["parameters/Pistol/conditions/Guard"] = false
	anim["parameters/Rifle/conditions/Defend"] = false
	anim["parameters/Pistol/conditions/Defend"] = false
	anim["parameters/Rifle/conditions/Hunt"] = false
	anim["parameters/Pistol/conditions/Hunt"] = false
	match state:
		0, 2:
			anim["parameters/Rifle/conditions/Guard"] = true
			anim["parameters/Pistol/conditions/Guard"] = true
		1, 3, 4, 6, 8, 11, 12, 13:
			anim["parameters/Rifle/conditions/Movement"] = true
			anim["parameters/Pistol/conditions/Movement"] = true
		7:
			anim["parameters/Rifle/conditions/Defend"] = true
			anim["parameters/Pistol/conditions/Defend"] = true
		9:
			anim["parameters/Rifle/conditions/Combat"] = true
			anim["parameters/Pistol/conditions/Combat"] = true
		5, 10:
			anim["parameters/Rifle/conditions/Hunt"] = true
			anim["parameters/Pistol/conditions/Hunt"] = true


@rpc("authority", "reliable", "call_remote")
func BroadcastAISpawn(uuid: int, spawn_type: String, spawn_pos: Vector3, spawn_rot: Vector3, variant: Dictionary) -> void:
	_log("BroadcastAISpawn RECEIVED uuid=%d type=%s variant_keys=%s" % [uuid, spawn_type, str(variant.keys())])
	var players := _players()
	if players.world_ai.has(uuid):
		return
	var entry := _make_spawn_entry(uuid, spawn_pos, spawn_rot, variant, spawn_type, false)
	entry["asleep"] = false
	if not _try_spawn_agent(entry):
		_pending_spawns.append(entry)
	var now: float = Time.get_ticks_msec() / 1000.0
	_ai_queues[uuid] = [{"pos": spawn_pos, "rot": spawn_rot, "time": now}]


@rpc("any_peer", "reliable", "call_remote")
func RequestAISync(uuids: PackedInt32Array = PackedInt32Array()) -> void:
	if not multiplayer.is_server():
		return
	var players := _players()
	var sender: int = multiplayer.get_remote_sender_id()
	var targets: Array = Array(uuids) if uuids.size() > 0 else players.world_ai.keys()
	for uuid in targets:
		var ai := _live_ai(uuid)
		if ai == null:
			continue
		var variant: Variant = ai.get_meta("coop_spawn_variant", {})
		if typeof(variant) != TYPE_DICTIONARY:
			variant = {}
		var asleep: bool = ai.get_meta("coop_ai_asleep", false)
		SyncSingleAI.rpc_id(sender, int(uuid), ai.global_position, ai.global_rotation, variant, asleep)


@rpc("authority", "reliable", "call_remote")
func SyncSingleAI(uuid: int, pos: Vector3, rot: Vector3, variant: Dictionary, asleep: bool = false) -> void:
	var players := _players()
	if players.world_ai.has(uuid):
		return
	var entry := _make_spawn_entry(uuid, pos, rot, variant, "", true)
	entry["asleep"] = asleep
	if not _try_spawn_agent(entry):
		_pending_spawns.append(entry)
	var now: float = Time.get_ticks_msec() / 1000.0
	_ai_queues[uuid] = [{"pos": pos, "rot": rot, "time": now}]


@rpc("authority", "reliable", "call_local")
func SetAISleepState(uuid: int, asleep: bool) -> void:
	var ai_node = _live_ai(uuid)
	if ai_node and is_instance_valid(ai_node):
		ai_node.set_meta("coop_ai_asleep", asleep)
		if asleep:
			ai_node.hide()
			ai_node.process_mode = Node.PROCESS_MODE_DISABLED
			if "skeleton" in ai_node and ai_node.skeleton:
				ai_node.skeleton.process_mode = Node.PROCESS_MODE_DISABLED
			if "animator" in ai_node and ai_node.animator:
				ai_node.animator.active = false
		else:
			ai_node.show()
			ai_node.process_mode = Node.PROCESS_MODE_INHERIT
			if "skeleton" in ai_node and ai_node.skeleton:
				ai_node.skeleton.process_mode = Node.PROCESS_MODE_INHERIT
			if "animator" in ai_node and ai_node.animator:
				ai_node.animator.active = true


@rpc("authority", "reliable", "call_remote")
func BroadcastAISound(uuid: int, sound_type: int, full_auto: bool = false) -> void:
	var ai := _live_ai(uuid)
	if ai == null:
		return
	ai.set_meta("_coop_force_local_play", true)
	
	# 클라이언트 측 AI 본체가 비활성화(disabled) 상태여도 동적 생성 사운드가 재생되도록 추적
	var old_root_children = ai.get_children()
	var eyes = ai.get("eyes")
	var old_eyes_children = eyes.get_children() if eyes else []
	
	match sound_type:
		AI_SOUND_FIRE:
			ai.fullAuto = full_auto
			ai.PlayFire()
			# [RTVCoop] 클라이언트 사이드 총구 화염(Muzzle Flash) 복원
			if ai.has_method("MuzzleVFX"):
				if "_gs_dist_to_cam_sq" in ai:
					var local_player = _players().GetLocalController() if _players() else null
					if local_player:
						ai._gs_dist_to_cam_sq = ai.global_position.distance_squared_to(local_player.global_position)
				ai.MuzzleVFX()
			# [RTVCoop] 클라이언트 사이드 탄착 이펙트(Bullet Decal) 로컬 시뮬레이션
			if ai.get_node_or_null("Muzzle") and ai.fire and ai.fire.is_inside_tree():
				var was_enabled: bool = ai.fire.enabled
				ai.fire.enabled = true
				var accuracy_target: Vector3 = ai.global_position - ai.global_transform.basis.z * 10.0
				if ai.has_method("FireAccuracy"):
					accuracy_target = ai.FireAccuracy()
				ai.fire.look_at(accuracy_target, Vector3.UP, true)
				ai.fire.force_raycast_update()
				if ai.fire.is_colliding():
					var hitCollider = ai.fire.get_collider()
					if hitCollider and not hitCollider.is_in_group("Player"):
						var hitPoint = ai.fire.get_collision_point()
						var hitNormal = ai.fire.get_collision_normal()
						var hitSurface = hitCollider.get("surface")
						if ai.has_method("BulletDecal"):
							ai.BulletDecal(hitCollider, hitPoint, hitNormal, hitSurface)
				ai.fire.enabled = was_enabled
		AI_SOUND_TAIL: ai.PlayTail()
		AI_SOUND_IDLE: ai.PlayIdle()
		AI_SOUND_COMBAT: ai.PlayCombat()
		AI_SOUND_DAMAGE:
			ai.PlayDamage()
			# [RTVCoop] 클라이언트 사이드 피격 모션(Spine Impulse) 시뮬레이션 복원
			if "impact" in ai and "spineData" in ai and ai.spineData:
				ai.impact = true
				ai.impulseTime = ai.spineData.impulse
				ai.impulseTimer = 0.0
				ai.recoveryTime = ai.spineData.impulse
				ai.recoveryTimer = 0.0
				
				var spine_target = ai.spineTarget if "spineTarget" in ai else Vector3.ZERO
				var impact_val = ai.spineData.impact
				var impulseX = randf_range(spine_target.x - impact_val / 2, spine_target.x - impact_val)
				var impulseY = randf_range(spine_target.y - impact_val, spine_target.y + impact_val)
				var impulseZ = randf_range(spine_target.z - impact_val, spine_target.z + impact_val)
				ai.impulseTarget = Vector3(impulseX, impulseY, impulseZ)
		AI_SOUND_DEATH: ai.PlayDeath()
		
	ai.set_meta("_coop_force_local_play", false)
	
	# 생성된 오디오 노드의 process_mode를 ALWAYS로 설정하여 클라이언트 사이드 재생 보장
	for child in ai.get_children():
		if not child in old_root_children:
			child.process_mode = Node.PROCESS_MODE_ALWAYS
	if eyes:
		for child in eyes.get_children():
			if not child in old_eyes_children:
				child.process_mode = Node.PROCESS_MODE_ALWAYS


@rpc("authority", "reliable", "call_remote")
func BroadcastAIDeath(uuid: int, pos: Vector3, rot: Vector3, direction: Vector3, force: float, container_loot: Array = [], weapon_dict: Dictionary = {}, backpack_dict: Dictionary = {}, secondary_dict: Dictionary = {}, corpse_cid: int = -1) -> void:
	var players := _players()
	_prune_pending_uuid(uuid)
	var ai := _live_ai(uuid)
	if ai == null:
		var entry := _make_spawn_entry(uuid, pos, rot, {}, "", false)
		if _try_spawn_agent(entry):
			ai = _live_ai(uuid)
		else:
			players.world_ai.erase(uuid)
			players.ai_targets.erase(uuid)
			return
	var ss := _slot_serializer()
	var lc := _get_ai_loot_container(ai)
	if ss:
		if container_loot.size() > 0 and lc:
			lc.loot.clear()
			for dict in container_loot:
				var slot = ss.DeserializeSlotData(dict)
				if slot:
					lc.loot.append(slot)
		if weapon_dict.size() > 0 and ai.weapon and ai.weapon.slotData:
			ss.ApplySlotDictToPickup(ai.weapon, weapon_dict)
		if backpack_dict.size() > 0 and ai.backpack and ai.backpack.slotData:
			ss.ApplySlotDictToPickup(ai.backpack, backpack_dict)
		if secondary_dict.size() > 0 and ai.secondary and ai.secondary.slotData:
			ss.ApplySlotDictToPickup(ai.secondary, secondary_dict)
	_log("BroadcastAIDeath applying: uuid=%d dir=%s force=%.1f loot=%d lc=%s" % [uuid, str(direction), force, container_loot.size(), str(lc)])
	ai.set_meta("_coop_death_from_broadcast", true)
	for child in ai.find_children("*", "AnimationMixer", true, false):
		child.active = false
		child.process_mode = Node.PROCESS_MODE_DISABLED
	if ai.skeleton:
		ai.skeleton.process_mode = Node.PROCESS_MODE_INHERIT # 부모의 비활성을 따르도록 복구
		ai.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE
		# 모든 SkeletonIK3D 및 SkeletonModifier3D 노드를 정지 및 비활성화
		for ik in ai.find_children("*", "SkeletonIK3D", true, false):
			ik.stop()
		for mod in ai.find_children("*", "SkeletonModifier3D", true, false):
			mod.active = false
	ai.Death(direction, force)
	if ai.skeleton and "simulationTime" in ai.skeleton:
		ai.skeleton.simulationTime = 999.0
		
	players.world_ai.erase(uuid)
	_ai_queues.erase(uuid)

	if ai.weapon:
		var w_uuid: int = uuid * 10 + 1
		ai.weapon.set_meta("network_uuid", w_uuid)
		players.worldItems[w_uuid] = ai.weapon
		if w_uuid >= players.nextUuid:
			players.nextUuid = w_uuid + 1
	if ai.backpack:
		var b_uuid: int = uuid * 10 + 2
		ai.backpack.set_meta("network_uuid", b_uuid)
		players.worldItems[b_uuid] = ai.backpack
		if b_uuid >= players.nextUuid:
			players.nextUuid = b_uuid + 1
	if ai.secondary:
		var s_uuid: int = uuid * 10 + 3
		ai.secondary.set_meta("network_uuid", s_uuid)
		players.worldItems[s_uuid] = ai.secondary
		if s_uuid >= players.nextUuid:
			players.nextUuid = s_uuid + 1

	if lc:
		if not lc.is_in_group("CoopLootContainer"):
			lc.add_to_group("CoopLootContainer")
		lc.set_meta("coop_container_id", corpse_cid)


@rpc("authority", "reliable", "call_remote")
func BroadcastAIRemove(uuids: PackedInt32Array) -> void:
	var players := _players()
	for uuid in uuids:
		var key: int = int(uuid)
		_prune_pending_uuid(key)
		var ai: Node = players.world_ai.get(key)
		if is_instance_valid(ai) and not ai.dead:
			ai.queue_free()
		players.world_ai.erase(key)
		players.ai_targets.erase(key)
		_ai_queues.erase(key)


@rpc("any_peer", "reliable", "call_remote")
func RequestAIManifest() -> void:
	if not multiplayer.is_server():
		return
	var players := _players()
	var sender: int = multiplayer.get_remote_sender_id()
	var uuids := PackedInt32Array()
	for uuid in players.world_ai:
		if _live_ai(uuid) != null:
			uuids.append(int(uuid))
	DeliverAIManifest.rpc_id(sender, uuids)


@rpc("authority", "reliable", "call_remote")
func DeliverAIManifest(host_uuids: PackedInt32Array) -> void:
	var players := _players()
	var host_set: Dictionary = {}
	for u in host_uuids:
		host_set[int(u)] = true
	var client_set: Dictionary = {}
	for u in players.world_ai:
		client_set[int(u)] = true

	var missing_on_client: Array = []
	var extra_on_client: Array = []
	for u in host_set:
		if not client_set.has(u):
			missing_on_client.append(u)
	for u in client_set:
		if not host_set.has(u):
			extra_on_client.append(u)

	if missing_on_client.is_empty() and extra_on_client.is_empty():
		return

	for u in extra_on_client:
		var ai: Node = players.world_ai.get(u)
		if is_instance_valid(ai) and not ai.dead:
			ai.queue_free()
		players.world_ai.erase(u)
		players.ai_targets.erase(u)
		_ai_queues.erase(u)

	if not missing_on_client.is_empty():
		RequestAISync.rpc_id(1, PackedInt32Array(missing_on_client))


@rpc("any_peer", "reliable", "call_remote")
func RequestAIDamage(uuid: int, hitbox: String, damage: float) -> void:
	if not multiplayer.is_server():
		return
	var attacker: int = multiplayer.get_remote_sender_id()
	var players := _players()
	var ai := _live_ai(uuid)
	if ai == null:
		players.world_ai.erase(uuid)
		return
		
	# [안전장치] 데미지 적용 전에 수면 상태면 즉시 해제하여 완벽한 물리/사망 처리 보장
	if ai.get_meta("coop_ai_asleep", false):
		if has_method("SetAISleepState"):
			SetAISleepState.rpc(uuid, false)
			
	ai.WeaponDamage(hitbox, damage)
	record_threat(uuid, attacker, damage)


func process_host_ai_physics_pre(a: Node, delta: float) -> bool:
	return false


func process_host_ai_physics_post() -> void:
	pass


func on_host_ai_death(a: Node, direction, force) -> void:
	var uuid: int = BuildAndBroadcastAIDeath(a, direction, force)
	var players_ref := _players()
	if uuid >= 0 and players_ref:
		players_ref.world_ai.erase(uuid)
		players_ref.ai_targets.erase(uuid)


func process_client_ai_tick(a: Node, delta: float) -> void:
	var animator: AnimationMixer = a.animator if "animator" in a else null
	var skeleton: Skeleton3D = a.skeleton if "skeleton" in a else null
	if animator == null or skeleton == null:
		return

	var anim_player: AnimationPlayer = null
	if animator is AnimationTree and not animator.anim_player.is_empty():
		anim_player = animator.get_node_or_null(animator.anim_player) as AnimationPlayer

	if not a.get_meta("coop_client_anim_ready", false):
		# [애니메이션 및 IK 비활성 크래시 방지] 클라이언트 측 AI(a) 본체는 PROCESS_MODE_DISABLED 지만,
		# 자식인 애니메이터와 IK는 틱 연산(ALWAYS)을 하도록 유도한다.
		animator.process_mode = Node.PROCESS_MODE_ALWAYS
		skeleton.process_mode = Node.PROCESS_MODE_ALWAYS
		if anim_player != null:
			anim_player.process_mode = Node.PROCESS_MODE_ALWAYS
			
		# [RTVCoop] 클라이언트 틱에서 수동 advance를 위해 MANUAL로 셋업
		animator.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
		
		a.set_meta("coop_client_anim_ready", true)

	var speed: float = a.speed if "speed" in a else 0.0
	var movement_speed: float = a.movementSpeed if "movementSpeed" in a else 0.0
	movement_speed = move_toward(movement_speed, speed, delta * 5.0)
	if "movementSpeed" in a:
		a.movementSpeed = movement_speed
	animator["parameters/Rifle/Movement/blend_position"] = movement_speed
	animator["parameters/Pistol/Movement/blend_position"] = movement_speed

	# v0.6-kr: Combat/Hunt 애니메이션용 blend_position (strafeDirection) 업데이트 추가
	var strafe_dir: float = a.strafeDirection if "strafeDirection" in a else 0.0
	animator["parameters/Rifle/Combat/blend_position"] = strafe_dir
	animator["parameters/Rifle/Hunt/blend_position"] = strafe_dir
	animator["parameters/Pistol/Combat/blend_position"] = strafe_dir
	animator["parameters/Pistol/Hunt/blend_position"] = strafe_dir

	# [RTVCoop] 클라이언트 사이드 조준(Spine) 애니메이션 동기화 및 하늘 조준 버그 픽스
	if a.has_method("Spine"):
		if a.get("playerVisible") == true:
			var nearest_cam = GetNearestPlayerCamera(a.global_position)
			if nearest_cam != Vector3.ZERO:
				a.LKL = nearest_cam
			else:
				a.LKL = a.global_position - a.global_transform.basis.z * 10.0
		else:
			# 비감지 상태 시 전방 정면 10m 앞을 바라보도록 LKL 보정
			a.LKL = a.global_position - a.global_transform.basis.z * 10.0
		a.Spine(delta)
		
	# [RTVCoop] 클라이언트 측 캐릭터가 굳는 현상 방지를 위 수동 advance 밀어주기
	if animator.has_method("advance"):
		animator.advance(delta)
	if skeleton.has_method("advance"):
		skeleton.advance(delta)


func _proactive_disable_module_hub() -> void:
	if not CoopAuthority.is_active() or CoopAuthority.is_host():
		return
	var root = get_tree().root if get_tree() else null
	if root:
		_find_and_disable_module_hub(root)


func _find_and_disable_module_hub(root: Node) -> void:
	if root == null:
		return
	if root.name == "ModuleHub" or (root.get_script() and root.get_script().resource_path.ends_with("ModuleHub.gd")):
		root.process_mode = Node.PROCESS_MODE_DISABLED
		print("[AISync] Client proactively disabled ModuleHub node: %s" % root.get_path())
	for child in root.get_children():
		_find_and_disable_module_hub(child)
