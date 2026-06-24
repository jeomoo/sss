extends "res://mods/RTVCoop/Game/Sync/BaseSync.gd"


# Phase1: 20Hz broadcast 유지, Dirty Flag + deferred 방식 전환
const BROADCAST_RATE := 20.0


var gameData: Resource = preload("res://Resources/GameData.tres")
var _broadcast_accum: float = 0.0
var _local_shot_count: int = 0
var _was_firing_local: bool = false
var _prev_shot_accum: Dictionary = {}
var _bp_logged: bool = false
# fix9.10: 보정 throttle accumulator (20Hz 발화)
var _repair_accum: float = 0.0

# --- Phase1: 캐싱 ---
var _cached_controller: Node = null
var _cached_rig_manager: Node = null
var _cached_scene: Node = null
var _cache_valid: bool = false

# --- Phase1: Dirty Flag ---
var _last_sent_state: Dictionary = {}
var _force_send_countdown: int = 0  # 매 N틱마다 강제 전송 (heartbeat)
const FORCE_SEND_INTERVAL: int = 20  # 1초에 한번은 강제 전송 (20Hz * 1s)

# --- Phase1: position delta tracking ---
var _prev_local_pos: Vector3 = Vector3.ZERO
var _prev_local_time: float = 0.0

# v0.13.26: sprint hysteresis for broadcast. vanilla isRunning이 sprint 도중 짧은 frame에 false로
# 떨어지거나 velocity가 4.5 미만 dip하는 케이스 → puppet animation/sound walk로 깜빡임.
# v0.13.28: 사용자 관찰 — 클라 puppet이 호스트 시야 밖일 때 fix9.7 skel.advance skip으로
# 호스트 process load 변동 → vanilla MovementStates timing dip 빈도 증가. 보정 범위 더 넓힘.
const SPRINT_GRACE_DURATION: float = 1.0   # 0.4 → 1.0
const SPRINT_KEEP_SPEED: float = 1.5       # 2.5 → 1.5
const SPRINT_ENTER_SPEED: float = 4.0      # 4.5 → 4.0 (dip 더 일찍 catch)
var _sprint_active_until: float = 0.0


func _sync_key() -> String:
	return "local_state"


func _players() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.players if coop else null


## Phase1: 씬 노드 레퍼런스를 캐시. null이면 한번만 재탐색.
func _ensure_cache() -> void:
	if _cache_valid and is_instance_valid(_cached_controller):
		return
	_cache_valid = false
	var players := _players()
	if players == null:
		return
	_cached_controller = players.GetLocalController() if players.has_method("GetLocalController") else null
	if _cached_controller == null:
		return
	_cached_scene = get_tree().current_scene
	_cached_rig_manager = _cached_scene.get_node_or_null("Core/Camera/Manager") if _cached_scene else null
	_cache_valid = true


## Phase1: 캐시 무효화 (씬 전환 시 호출)
func _invalidate_cache() -> void:
	_cached_controller = null
	_cached_rig_manager = null
	_cached_scene = null
	_cache_valid = false
	_last_sent_state.clear()


var _tick_service_hooked: bool = false


func _physics_process(delta: float) -> void:
	# v0.2: fix9.2 보정 *복원*. v0.1에서 server 처리 분리만으로 vanilla MovementStates
	# 자동 정상화 안 됨 확인됨 → 보정 없으면 호스트 발소리/모션 사라짐.
	# 진짜 원인 (vanilla Controller._physics_process 흐름 깨는 코드)은 별도 트랙으로 추적.
	if not CoopAuthority.is_active():
		return
	if not _tick_service_hooked:
		_tick_service_hooked = true
		var tick = Engine.get_meta("SyncTickService", null)
		if tick:
			tick.on_sync_tick.connect(_on_sync_tick)

	# v0.13.29: vanilla MovementStates 완전 격리됨 (ControllerHooks._replace_controller_movementstates).
	# 이전 fix9.2/v0.13.27 보정은 vanilla 본문이 dip할 때 사후 패치였는데, 이제 vanilla 안 거치니
	# 보정 자체 불필요. 안전망 차원에서 isMoving 가드만 유지.
	if gameData.isMoving and not gameData.isCrouching and not gameData.isRunning and not gameData.isWalking:
		gameData.isWalking = true

	# v0.13.1: rising edge 감지는 *fallback only*. WeaponRigHooks._on_weaponrig_fireevent_post가
	# 매 발사마다 _local_shot_count 증가 (auto fire 누락 fix). rising edge는 hook fail 시 backup.
	if gameData.isFiring and not _was_firing_local:
		# auto fire의 첫 발은 WeaponRig hook이 잡지만 timing에 따라 누락 가능. 안전 가드.
		pass
	_was_firing_local = gameData.isFiring


# v0.1/v0.3: SyncTickService의 20Hz tick. character _physics_process frame과 격리.
# v0.3: 추가로 FastStateProxy(LocalCharacterProxy)가 dirty이면 빠른 RPC 송신 (Antigravity 패턴).
func _on_sync_tick() -> void:
	if not CoopAuthority.is_active():
		return
	if multiplayer.get_peers().size() == 0:
		return

	# v0.3: FastStateProxy dirty check + 빠른 RPC (4필드).
	# v0.5: has_meta로 안전 check (Godot 4 get_meta가 default 있어도 ERROR 출력하는 케이스 대응)
	if Engine.has_meta("LocalCharacterProxy"):
		var fast_proxy = Engine.get_meta("LocalCharacterProxy")
		if fast_proxy and fast_proxy.is_dirty:
			var packet: Dictionary = fast_proxy.collect_and_clean()
			_broadcast_fast_state.rpc(packet)

	call_deferred("_deferred_sync_tick")


# v0.13.4: 일반화된 무기 audio sync — audio_key 기반 dispatch
# WeaponRigHooks가 vanilla audio 함수 hook 시 audio_key 넘기면 broadcast로 모든 peer puppet에 재생
func _broadcast_weapon_audio(audio_key: String) -> void:
	if multiplayer.is_server():
		BroadcastWeaponAudio.rpc(multiplayer.get_unique_id(), audio_key)
	else:
		SubmitWeaponAudio.rpc_id(1, audio_key)


@rpc("any_peer", "reliable", "call_remote")
func SubmitWeaponAudio(audio_key: String) -> void:
	if not multiplayer.is_server():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	BroadcastWeaponAudio.rpc(sender_id, audio_key)


@rpc("authority", "reliable", "call_local")
func BroadcastWeaponAudio(shooter_id: int, audio_key: String) -> void:
	# v0.13.38 진단: RPC 수신 확인
	print("[LocalStateSync] BroadcastWeaponAudio recv shooter=%d key=%s me=%d" % [shooter_id, audio_key, multiplayer.get_unique_id()])
	if shooter_id == multiplayer.get_unique_id():
		return  # 자기 측 vanilla 자동 재생
	var players_ref: Node = _players()
	if players_ref == null:
		return
	var puppet: Node = players_ref.remote_players.get(shooter_id, null) if "remote_players" in players_ref else null
	if puppet:
		var pm: Node = puppet.get_node_or_null("PlayerModel")
		if pm and pm.has_method("PlayPuppetWeaponAudio"):
			pm.PlayPuppetWeaponAudio(audio_key)
		else:
			print("[LocalStateSync] reload audio FAIL — pm=%s" % str(pm))
	else:
		print("[LocalStateSync] reload audio FAIL — no puppet for shooter=%d" % shooter_id)


# v0.11.12: 별도 reliable fire RPC — unreliable shot_accumulator delta가 packet loss로 일부 누락되는
# 케이스 보완. 발신자→호스트 Submit → 호스트→모든 peer Broadcast.
# v0.13.0: shots_count 추가 — 연발 시 한 tick에 N발 묶이면 N번 fire 재생 (이전엔 1번만 = 10/8 누락)
@rpc("any_peer", "reliable", "call_remote")
func SubmitShot(suppressed: bool, fire_mode: int, shots_count: int = 1) -> void:
	if not multiplayer.is_server():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	BroadcastShot.rpc(sender_id, suppressed, fire_mode, shots_count)


@rpc("authority", "reliable", "call_local")
func BroadcastShot(shooter_id: int, suppressed: bool, fire_mode: int, shots_count: int = 1) -> void:
	if shooter_id == multiplayer.get_unique_id():
		return  # 자기 측 발사음은 vanilla 자동 재생
	var players_ref: Node = _players()
	if players_ref == null:
		return
	var puppet: Node = players_ref.remote_players.get(shooter_id, null) if "remote_players" in players_ref else null
	if puppet:
		var pm: Node = puppet.get_node_or_null("PlayerModel")
		if pm and pm.has_method("PlayPuppetFireEffect"):
			# v0.13.0: shots_count 만큼 반복 fire (연발 audio 일관)
			for i in shots_count:
				pm.PlayPuppetFireEffect(suppressed, fire_mode)


# v0.3: Antigravity 패턴 fast state broadcast. 모든 peer가 받음.
@rpc("any_peer", "unreliable_ordered", "call_remote")
func _broadcast_fast_state(packet: Dictionary) -> void:
	# 수신: 자기 클라가 보는 *송신자의 RemotePlayer puppet*에 push_state 적용
	var sender_id: int = multiplayer.get_remote_sender_id()
	var players := _players()
	if players == null:
		return
	var puppet: Node = players.remote_players.get(sender_id, null)
	if puppet and is_instance_valid(puppet) and puppet.has_method("push_state"):
		puppet.push_state(packet)


## Phase1: 바닐라 _physics_process 완료 후 실행되는 deferred sync
func _deferred_sync_tick() -> void:
	_ensure_cache()
	if not _cache_valid or _cached_controller == null:
		return
	var coop := RTVCoop.get_instance()
	if coop == null:
		return
	var proxy: Node = coop.get_player_proxy(CoopAuthority.local_peer_id())
	if proxy == null:
		return

	var state: Dictionary = _gather_state_cached()

	# Phase1: Dirty Flag — 상태 변화 없으면 RPC 생략
	_force_send_countdown -= 1
	if _is_state_dirty(state) or _force_send_countdown <= 0:
		_last_sent_state = state.duplicate()
		_force_send_countdown = FORCE_SEND_INTERVAL
		proxy.write_state(state)

	# 원격 퍼펫 상태 읽기 (이것은 항상 실행 — 수신 데이터 적용)
	_read_remote_proxies()


## Phase1: Dirty Flag 판정 — 주요 필드의 변화량 체크
func _is_state_dirty(state: Dictionary) -> bool:
	if _last_sent_state.is_empty():
		return true
	# Position 변화
	var pos: Vector3 = state.get("pos", Vector3.ZERO)
	var last_pos: Vector3 = _last_sent_state.get("pos", Vector3.ZERO)
	if pos.distance_squared_to(last_pos) > 0.0001:  # ~0.01 unit
		return true
	# Rotation 변화
	var rot: Vector3 = state.get("rot", Vector3.ZERO)
	var last_rot: Vector3 = _last_sent_state.get("rot", Vector3.ZERO)
	if rot.distance_squared_to(last_rot) > 0.0001:
		return true
	# Animation 변화
	if state.get("animCondition", "") != _last_sent_state.get("animCondition", ""):
		return true
	if absf(state.get("animBlend", 0.0) - _last_sent_state.get("animBlend", 0.0)) > 0.05:
		return true
	# Boolean 필드 변화
	for key in ["hasWeapon", "isFiring", "flashlight", "suppressed"]:
		if state.get(key, false) != _last_sent_state.get(key, false):
			return true
	# Weapon 변화
	if state.get("weaponFile", "") != _last_sent_state.get("weaponFile", ""):
		return true
	# Shot 변화
	if state.get("shots", 0) > 0:
		return true
	# Pitch 변화
	if absf(state.get("pitch", 0.0) - _last_sent_state.get("pitch", 0.0)) > 0.01:
		return true
	return false


func _read_remote_proxies() -> void:
	var players := _players()
	if players == null:
		return
	var coop := RTVCoop.get_instance()
	if coop == null:
		return
	var my_id: int = CoopAuthority.local_peer_id()
	for peer_id in players.remote_players:
		if peer_id == my_id:
			continue
		var puppet: Node = players.remote_players[peer_id]
		if not is_instance_valid(puppet) or not puppet.is_inside_tree():
			continue
		var proxy: Node = coop.get_player_proxy(peer_id)
		if proxy == null:
			continue
		var state: Dictionary = proxy.read_state()
		var shot_delta: int = proxy.shot_accumulator - _prev_shot_accum.get(peer_id, 0)
		_prev_shot_accum[peer_id] = proxy.shot_accumulator
		if shot_delta > 0:
			state["shots"] = shot_delta
		if puppet.has_method("SetTarget"):
			puppet.SetTarget(state.get("pos", puppet.global_position), state.get("rot", puppet.global_rotation))
		if puppet.has_method("ApplyAnimState"):
			puppet.ApplyAnimState(state)


## Phase1: 캐시된 노드를 사용하는 경량 상태 수집
## 기존 GatherLocalAnimState와 동일한 로직이지만 get_node_or_null 호출을 최소화
func _gather_state_cached() -> Dictionary:
	var controller: Node3D = _cached_controller
	var state: Dictionary = {
		"pos": controller.global_position,
		"rot": controller.global_rotation,
		"animCondition": "Guard",
		"animBlend": 0.0,
		"weapon": "rifle",
		"hasWeapon": false,
		"weaponFile": "",
	}

	var is_moving: bool = gameData.isMoving
	var is_running: bool = gameData.isRunning
	var _now_for_sprint: float = float(Time.get_ticks_msec()) / 1000.0

	if controller and "velocity" in controller:
		var horizontal_vel = Vector3(controller.velocity.x, 0, controller.velocity.z)
		var speed = horizontal_vel.length()
		if speed > 0.1:
			is_moving = true
		# v0.13.26/28: sprint hysteresis. 진입 threshold + grace + keep speed 모두 상수화.
		if speed > SPRINT_ENTER_SPEED:
			is_running = true
			_sprint_active_until = _now_for_sprint + SPRINT_GRACE_DURATION
		elif _now_for_sprint < _sprint_active_until and speed > SPRINT_KEEP_SPEED:
			is_running = true

	# 지형 버그 등으로 속도가 0으로 찍히는 유령 현상 방지
	var current_time: float = float(Time.get_ticks_msec()) / 1000.0
	var time_diff: float = current_time - _prev_local_time
	if time_diff > 0.0 and _prev_local_pos != Vector3.ZERO:
		var horiz_dist = Vector2(controller.global_position.x - _prev_local_pos.x, controller.global_position.z - _prev_local_pos.z).length()
		var real_speed = horiz_dist / time_diff
		if real_speed > 0.2:
			is_moving = true
		# v0.13.26/28: 동일 sprint hysteresis 적용 (real_speed 측정 fallback에도). threshold 상수화.
		if real_speed > SPRINT_ENTER_SPEED:
			is_running = true
			_sprint_active_until = current_time + SPRINT_GRACE_DURATION
		elif current_time < _sprint_active_until and real_speed > SPRINT_KEEP_SPEED:
			is_running = true

	_prev_local_pos = controller.global_position
	_prev_local_time = current_time

	if gameData.isCrouching:
		state["animCondition"] = "Hunt"
		state["animBlend"] = 1.0 if is_moving else 0.0
	elif gameData.isAiming and is_moving:
		state["animCondition"] = "Combat"
		state["animBlend"] = 1.0
	elif gameData.isAiming:
		state["animCondition"] = "Defend"
		state["animBlend"] = 0.0
	elif is_moving and gameData.weaponPosition == 1:
		state["animCondition"] = "MovementLow"
		state["animBlend"] = 2.0 if is_running else 1.0
	elif is_moving:
		state["animCondition"] = "Movement"
		if is_running:
			state["animBlend"] = 5.0
		else:
			state["animBlend"] = 1.0
	elif gameData.weaponPosition == 2:
		state["animCondition"] = "Defend"
		state["animBlend"] = 0.0
	else:
		state["animCondition"] = "Group"
		state["animBlend"] = 1.0

	# Phase1: 캐시된 rig_manager 사용
	var rig_manager: Node = _cached_rig_manager
	var weapon_slot = null

	if rig_manager:
		if gameData.primary and rig_manager.primarySlot and rig_manager.primarySlot.get_child_count() > 0:
			weapon_slot = rig_manager.primarySlot.get_child(0)
		elif gameData.secondary and rig_manager.secondarySlot and rig_manager.secondarySlot.get_child_count() > 0:
			weapon_slot = rig_manager.secondarySlot.get_child(0)

		# v0.13.65: mod-무관 robust fallback. vanilla primary/secondary 슬롯에서 무기를 못 찾았는데
		# 무기 드로우 상태면, 실제로 손에 든 활성 rig(RigManager의 마지막 자식 = WeaponRig)에서 직접 읽음.
		# WeaponRig._ready가 드로우 시점의 슬롯에서 slotData를 캡처하므로 — 어느 모드가 무기 슬롯을
		# 재배치하든(VRCETS 권총 슬롯 등) 모든 총기류(권총·라이플·샷건…)에 동작. WeaponRig.slotData는
		# 슬롯 item과 동일 인터페이스(.slotData.itemData/.mode)라 아래 블록·fireMode 그대로 처리됨.
		if weapon_slot == null and (gameData.primary or gameData.secondary) and rig_manager and rig_manager.get_child_count() > 0:
			var _rig = rig_manager.get_child(rig_manager.get_child_count() - 1)
			if _rig is WeaponRig and _rig.slotData and _rig.slotData.itemData:
				weapon_slot = _rig

		if weapon_slot and weapon_slot.slotData and weapon_slot.slotData.itemData:
			state["weaponFile"] = weapon_slot.slotData.itemData.file
			state["hasWeapon"] = true
			state["weapon"] = "pistol" if weapon_slot.slotData.itemData.weaponType == "Pistol" else "rifle"
		elif gameData.knife and rig_manager.knifeSlot and rig_manager.knifeSlot.get_child_count() > 0:
			var knife_item = rig_manager.knifeSlot.get_child(0)
			if knife_item.slotData and knife_item.slotData.itemData:
				state["weaponFile"] = knife_item.slotData.itemData.file

	state["isFiring"] = gameData.isFiring
	# v0.11.12: shot delta가 있으면 별도 reliable RPC로 broadcast (audio 누락 방지)
	if _local_shot_count > 0:
		var sup: bool = false  # 아래에서 suppressed 계산 후 다시 호출
		var fmode: int = 1
		# 호출은 함수 끝 (suppressed/fireMode 결정 후)에 별도 처리
		pass
	state["shots"] = _local_shot_count
	var _shot_delta_for_rpc: int = _local_shot_count
	_local_shot_count = 0
	state["fireMode"] = 1
	if weapon_slot and weapon_slot.slotData:
		state["fireMode"] = weapon_slot.slotData.mode
	state["flashlight"] = gameData.flashlight
	state["nvg"] = gameData.NVG

	var scene: Node = _cached_scene
	var iface: Node = scene.get_node_or_null("Core/UI/Interface") if scene else null
	if iface:
		var bp_slot: Node = iface.get_node_or_null("Equipment/Backpack")
		var bp_cc: int = bp_slot.get_child_count() if bp_slot else -1
		if bp_slot and bp_cc > 0:
			var bp_item = bp_slot.get_child(0)
			if "slotData" in bp_item and bp_item.slotData and bp_item.slotData.itemData:
				state["backpackFile"] = bp_item.slotData.itemData.file
		# v0.5: 리그(조끼)를 backpackFile로 흘려보내던 fallback 제거. 퍼펫엔 가슴/리그 슬롯이 없어
		# _apply_puppet_backpack이 리그를 *백팩 본(등)* 에 붙여서 "조끼가 가방처럼 등에 붙는" 버그였음.
		# 등 슬롯이 아니므로 표시 안 함(잘못 붙는 것보다 나음). 제대로 가슴 렌더는 별도(chest 본 + 오프셋 튜닝).

	var attachment_files: Array = []
	if weapon_slot and weapon_slot.slotData:
		for nested in weapon_slot.slotData.nested:
			if nested and nested.file:
				attachment_files.append(nested.file)
	state["attachments"] = attachment_files

	var is_suppressed: bool = false
	if rig_manager and rig_manager.get_child_count() > 0:
		var rig: Node = rig_manager.get_child(rig_manager.get_child_count() - 1)
		if rig.get("activeMuzzle") != null and rig.activeMuzzle != null:
			is_suppressed = true
	state["suppressed"] = is_suppressed

	var camera: Node = scene.get_node_or_null("Core/Camera") if scene else null
	state["pitch"] = camera.rotation.x if camera else 0.0

	# v0.13.0: shot 발생 시 별도 reliable RPC + shots_count로 연발 일관.
	# 20Hz tick에서 한 tick에 여러 발 가능 (auto fire). delta 그대로 전달 → puppet 측에서 N번 fire.
	if _shot_delta_for_rpc > 0:
		var sup_for_rpc: bool = bool(state.get("suppressed", false))
		var fm_for_rpc: int = int(state.get("fireMode", 1))
		if multiplayer.is_server():
			BroadcastShot.rpc(multiplayer.get_unique_id(), sup_for_rpc, fm_for_rpc, _shot_delta_for_rpc)
		else:
			SubmitShot.rpc_id(1, sup_for_rpc, fm_for_rpc, _shot_delta_for_rpc)

	return state
