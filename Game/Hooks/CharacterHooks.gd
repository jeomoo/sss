extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")
const FastStateProxy = preload("res://mods/RTVCoop/Framework/FastStateProxy.gd")

# v0.3: Antigravity 패턴 통합 — 호스트/클라 self character의 state를 매 frame proxy에 write.
# vanilla _physics_process frame timing 이용 (가벼운 write only, RPC 없음).
# 송신은 SyncTickService 20Hz tick이 dirty proxy만 처리 (LocalStateSync._on_sync_tick).
var _state_proxy: FastStateProxy = null

var _drain_prev: Dictionary = {}
var _downed_char_node: Node = null
var _host_char_sanitized: bool = false
var _cached_controller: Node = null

# --- fix9 diagnostics ---
var _diag_char_process_called: bool = false
var _diag_moving_before: bool = false
var _diag_moving_after: bool = false
var _diag_velocity: Vector3 = Vector3.ZERO


func _setup_hooks() -> void:
	CoopHook.register(self, "character-_physics_process-pre", _on_character_physics_pre)
	CoopHook.register(self, "character-_physics_process-post", _on_character_physics_post)
	CoopHook.register_replace_or_post(self, "character-death", _replace_character_death, _post_character_death)
	if downed:
		downed.local_revived.connect(_on_local_revived)
		downed.local_bled_out.connect(_on_local_bled_out)
		downed.local_downed.connect(_on_local_downed)
	# fix9: expose this instance for DebugOverlay diagnostics
	Engine.set_meta("_coop_char_hooks_diag", self)


func _on_character_physics_pre(_delta: float = 0.0) -> void:
	if not CoopAuthority.is_active():
		return

	var char_node: Node = CoopHook.caller()
	if char_node:
		# Controller 캐싱: 매번 get_parent 대신 캐시 사용
		if _cached_controller == null or not is_instance_valid(_cached_controller):
			_cached_controller = char_node.get_parent()
		var controller: Node = _cached_controller
		if controller:
			# --- fix9 diagnostics: capture state BEFORE Character._physics_process ---
			_diag_char_process_called = true
			_diag_moving_before = _game_data().isMoving if _game_data() else false
			# v0.13.72: 매프레임 str(get_path())/process_mode 진단 캡처 제거 (프레임 비용). F5는 velocity/isMoving만 씀.
			if "velocity" in controller:
				_diag_velocity = controller.velocity
			else:
				_diag_velocity = Vector3.ZERO

			if not _host_char_sanitized:
				_sanitize_host_character(controller)
				_host_char_sanitized = true
			# Phase1: 매 10틱 재귀순회 제거 — PROCESS_MODE_ALWAYS로 한번에 해결

	if settings == null:
		return
	var mult: float = settings.Get("stats_drain_multiplier", 1.0)
	if mult == 1.0:
		return
	var gd: Resource = _game_data()
	if gd == null:
		return
	_drain_prev = {
		"energy": gd.energy,
		"hydration": gd.hydration,
		"mental": gd.mental,
	}


func _on_character_physics_post(_delta: float = 0.0) -> void:
	# --- v0.3/v0.5: FastStateProxy write (Antigravity 패턴) ---
	# v0.5: Core/Character 외에 RemotePlayer puppet character도 포함 → self vs puppet 구분은
	# is_multiplayer_authority()로. 또 path check 실패 시 1회 진단 로그.
	var caller_v03 := CoopHook.caller()
	if caller_v03 and CoopAuthority.is_active():
		var caller_path: String = str(caller_v03.get_path())
		# self character만: Core/Character path. RemotePlayer puppet은 자체 character이지만 path 다름.
		# v0.13.61: 진단 로그 제거 — is_self_char 가드(`/Core/Character`)가 항상 false라(실제 경로는
		# `/Core/Controller/Character`) `not _state_proxy`가 매 프레임 참 → "first post" 로그가 매 물리프레임
		# 폭주(로그 97.5%, 매프레임 print+파일기록 = 프레임드랍 주범). 진단은 목적 달성했으니 삭제.
		# (참고: 같은 경로버그로 FastStateProxy는 dead 상태 — 일반 LocalStateSync로 sync는 정상 동작 중.
		#  프록시 재활성화는 별도 최적화로 추후 검토)
		var is_self_char: bool = caller_path.find("/Core/Controller/Character") >= 0
		if is_self_char:
			if _state_proxy == null:
				_state_proxy = FastStateProxy.new()
				Engine.set_meta("LocalCharacterProxy", _state_proxy)
				var l_set = Engine.get_meta("CoopLogger", null)
				if l_set: l_set.log_msg("CharHook", "v0.5 LocalCharacterProxy SET (path=%s)" % caller_path)
			var ctrl_v03: Node = caller_v03.get_parent()
			if ctrl_v03:
				var gd_v03: Resource = _game_data()
				var anim_state: String = ""
				if gd_v03:
					if gd_v03.isRunning: anim_state = "Running"
					elif gd_v03.isWalking: anim_state = "Walking"
					elif gd_v03.isCrouching: anim_state = "Crouching"
					elif gd_v03.isAiming: anim_state = "Aiming"
					else: anim_state = "Idle"
				_state_proxy.update_state(
					ctrl_v03.global_position,
					ctrl_v03.global_rotation,
					anim_state,
					gd_v03.isFiring if gd_v03 else false
				)

	# --- fix9 diagnostics: capture state AFTER Character._physics_process ---
	var gd_diag: Resource = _game_data()
	if gd_diag:
		_diag_moving_after = gd_diag.isMoving
		# v0.13.72: GHOST DETECTED 로그 제거(프레임 비용↓). isMoving desync 자체는 별도 트랙 #2.
		# F5 오버레이는 _diag_moving_before/after/velocity 로 계속 확인 가능.

	if _drain_prev.is_empty() or not CoopAuthority.is_active() or settings == null:
		_drain_prev.clear()
		return
	var mult: float = settings.Get("stats_drain_multiplier", 1.0)
	var gd: Resource = _game_data()
	if gd == null:
		_drain_prev.clear()
		return
	for key in ["energy", "hydration", "mental"]:
		var before: float = _drain_prev[key]
		var after: float = gd.get(key)
		var drain: float = before - after
		if drain > 0:
			gd.set(key, before - drain * mult)
	_drain_prev.clear()


func _game_data() -> Resource:
	var caller := CoopHook.caller()
	if caller and "gameData" in caller:
		return caller.gameData
	return load("res://Resources/GameData.tres")


func _replace_character_death() -> void:
	if not CoopAuthority.is_active():
		return
	var char_node := CoopHook.caller()
	if char_node == null:
		return
	CoopHook.skip_super()
	_coop_enter_downed(char_node)


func _post_character_death() -> void:
	pass


func _coop_enter_downed(char_node: Node) -> void:
	if players == null:
		return
	var gd: Resource = _game_data()
	if gd == null:
		return

	_downed_char_node = char_node

	if char_node.has_method("PlayDeathAudio"):
		char_node.PlayDeathAudio()
	if char_node.get("audio"):
		if char_node.audio.get("breathing"):
			char_node.audio.breathing.stop()
		if char_node.audio.get("heartbeat"):
			char_node.audio.heartbeat.stop()

	gd.health = 0
	gd.isDead = true
	gd.freeze = true

	if downed:
		downed.enter_downed(multiplayer.get_unique_id())


func _on_local_downed() -> void:
	var gd: Resource = _game_data()
	if gd == null:
		return
	if gd.permadeath:
		Loader.Message("쓰러졌습니다 — 팀원을 기다리세요!", Color.RED)
	else:
		_show_bleedout_countdown()


func _on_local_revived() -> void:
	var gd: Resource = _game_data()
	if gd == null:
		return

	gd.health = 25.0
	gd.isDead = false
	gd.freeze = false
	gd.damage = false
	gd.impact = false
	gd.bleeding = false
	gd.fracture = false
	gd.burn = false
	gd.rupture = false
	gd.headshot = false
	gd.poisoning = false

	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	Loader.FadeOut()
	Loader.Message("회복되었습니다!", Color.GREEN)
	players.NotifyPlayerRespawn(multiplayer.get_unique_id())
	_downed_char_node = null


func _on_local_bled_out() -> void:
	if _downed_char_node and is_instance_valid(_downed_char_node):
		_coop_respawn(_downed_char_node)
	_downed_char_node = null


const GIVEUP_KEY := KEY_G       # v0.13.53 버티기 포기 키 (물리 키 — vanilla 바인딩 없음)
const GIVEUP_HOLD := 1.5        # 실수 방지: 이 시간만큼 연속으로 눌러야 포기
const _COUNTDOWN_TICK := 0.1


func _show_bleedout_countdown() -> void:
	# v0.13.21: 매 초 Loader.Message → UI에 메시지 stacking spam. 5초 간격 + 마지막 3·2·1초만 표시.
	# v0.13.53: tick을 0.1초로 줄여 give-up(G 길게 누르기) 입력 감지. 아무도 못 구할 때 버티기 포기하고
	# 즉시 리스폰 (블리드아웃 경로 재사용 — 루팅은 death container로 드롭됨).
	var remaining: float = downed.BLEEDOUT_TIMER if downed else 30.0
	var shown: Dictionary = {}
	var giveup_held: float = 0.0
	while remaining > 0 and _downed_char_node != null:
		if Input.is_key_pressed(GIVEUP_KEY):
			giveup_held += _COUNTDOWN_TICK
			if giveup_held >= GIVEUP_HOLD:
				Loader.Message("버티기 포기 — 리스폰합니다", Color.ORANGE)
				if downed:
					downed.request_give_up()
				return
		else:
			giveup_held = 0.0
		var sec: int = int(ceil(remaining))
		var should_show: bool = (sec % 5 == 0 or sec <= 3) and sec > 0
		if should_show and not shown.has(sec):
			shown[sec] = true
			Loader.Message("쓰러짐 — %d초 후 출혈사  (G 길게: 즉시 리스폰)" % sec, Color.RED)
		var tree = get_tree()
		if tree == null:
			break
		await tree.create_timer(_COUNTDOWN_TICK).timeout
		if get_tree() == null:
			break
		remaining -= _COUNTDOWN_TICK


func _coop_respawn(char_node: Node) -> void:
	if players == null:
		return
	var gd: Resource = _game_data()
	if gd == null:
		return

	players.NotifyPlayerDeath(multiplayer.get_unique_id())

	# v0.7: death container ground 정렬. controller.global_position은 capsule 중심 (~ground + 0.9m).
	# 그 위치에 container 두면 공중에 떠있음. ground raycast로 정확한 ground 위치 계산.
	var ctrl_node: Node = char_node.get_parent()
	var death_pos: Vector3 = ctrl_node.global_position
	if ctrl_node is Node3D:
		var space_state = ctrl_node.get_world_3d().direct_space_state
		var ray_from: Vector3 = death_pos + Vector3(0, 0.5, 0)
		var ray_to: Vector3 = death_pos + Vector3(0, -5.0, 0)
		var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to, 0xFFFFFFFF, [ctrl_node.get_rid()])
		var hit = space_state.intersect_ray(query)
		if hit and hit.has("position"):
			death_pos = hit["position"] + Vector3(0, 0.05, 0)  # ground 위 살짝
	if not gd.isDead and char_node.has_method("PlayDeathAudio"):
		char_node.PlayDeathAudio()
	if not gd.isDead and char_node.get("audio"):
		if char_node.audio.get("breathing"):
			char_node.audio.breathing.stop()
		if char_node.audio.get("heartbeat"):
			char_node.audio.heartbeat.stop()
	gd.health = 0
	gd.isDead = true
	gd.freeze = true

	var iface: Node = players.GetLocalInterface()
	var death_items: Array = []
	if iface and slot:
		for item in iface.inventoryGrid.get_children():
			death_items.append(slot.SerializeSlotData(item.slotData))
		for item in iface.inventoryGrid.get_children():
			iface.inventoryGrid.Pick(item)
			item.queue_free()
		for equipment_slot in iface.equipment.get_children():
			if equipment_slot is Slot and equipment_slot.get_child_count() != 0:
				var slot_item = equipment_slot.get_child(0)
				death_items.append(slot.SerializeSlotData(slot_item.slotData))
				slot_item.queue_free()
				equipment_slot.hint.show()
		for item in iface.catalogGrid.get_children():
			death_items.append(slot.SerializeSlotData(item.slotData))
		for item in iface.catalogGrid.get_children():
			iface.catalogGrid.Pick(item)
			item.queue_free()
		iface.UpdateStats(false)
		if iface.activeProgress and is_instance_valid(iface.activeProgress):
			iface.activeProgress.queue_free()
		iface.activeProgress = null
		iface.isCrafting = false

	if char_node.get("rigManager") and char_node.rigManager.has_method("ClearRig"):
		char_node.rigManager.ClearRig()

	if death_items.size() > 0 and pickup:
		if CoopAuthority.is_host():
			var stash_cid: int = players.nextContainerId if players else 0
			if players:
				players.nextContainerId += 1
			pickup.SpawnDeathContainer.rpc(death_pos, death_items, stash_cid)
		else:
			pickup.SubmitDeathContainer.rpc_id(1, death_pos, death_items)

	Loader.FadeIn()
	var tree = get_tree()
	if tree == null:
		return
	await tree.create_timer(5.0).timeout
	if not is_instance_valid(self) or get_tree() == null:
		return

	var controller: Node = char_node.get_parent()
	var respawn_pos: Vector3 = controller.global_position + Vector3(0, 1, 0)

	var best_transition: Node = null
	var best_dist: float = INF
	for transition in get_tree().get_nodes_in_group("Transition"):
		if transition.owner == null or not transition.owner.get("spawn"):
			continue
		var d: float = controller.global_position.distance_squared_to(transition.owner.global_position)
		if d < best_dist:
			best_dist = d
			best_transition = transition.owner
	if best_transition and best_transition.spawn:
		respawn_pos = best_transition.spawn.global_position + Vector3(0, 0.5, 0)

	controller.global_position = respawn_pos
	if "velocity" in controller:
		controller.velocity = Vector3.ZERO

	gd.health = 100
	gd.bodyStamina = 100
	gd.armStamina = 100
	gd.oxygen = 100
	gd.energy = clampf(gd.energy, 25.0, 100.0)
	gd.hydration = clampf(gd.hydration, 25.0, 100.0)
	gd.mental = clampf(gd.mental, 25.0, 100.0)
	gd.temperature = clampf(gd.temperature, 25.0, 100.0)
	gd.bleeding = false
	gd.fracture = false
	gd.burn = false
	gd.frostbite = false
	gd.insanity = false
	gd.rupture = false
	gd.headshot = false
	gd.starvation = false
	gd.dehydration = false
	gd.overweight = false
	gd.poisoning = false
	gd.isDead = false
	gd.freeze = false
	gd.damage = false
	gd.impact = false
	gd.isOccupied = false
	gd.isPlacing = false
	gd.isInserting = false
	gd.isInspecting = false
	gd.isReloading = false
	gd.isChecking = false
	gd.isClearing = false
	gd.isDrawing = false
	gd.isFiring = false
	gd.isAiming = false
	gd.isScoped = false
	gd.isTransitioning = false
	gd.isCaching = false
	gd.isSleeping = false
	gd.isCrafting = false
	gd.jammed = false
	gd.interaction = false
	gd.transition = false

	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	Loader.FadeOut()
	players.NotifyPlayerRespawn(multiplayer.get_unique_id())


# --- Phase1 + fix9: Host Character sanitisation helpers ---

## One-time deep clean of the host's own Character controller tree.
## 1. Removes VisibleOnScreenEnabler3D/Notifier3D nodes that disable processing
##    when the host body exits the 1st-person camera frustum
## 2. Sets critical nodes to PROCESS_MODE_ALWAYS so they can NEVER be disabled
##    by any parent node or engine mechanism — this is the root cause fix for
##    the ghost/footstep bug. ALWAYS mode is immune to parent DISABLED propagation.
## 3. Forces extra_cull_margin on geometry so meshes are never culled.
func _sanitize_host_character(root: Node) -> void:
	var l = Engine.get_meta("CoopLogger", null)
	if l:
		l.log_msg("CharHooks", "Phase1: sanitizing host Character tree '%s'" % str(root.get_path()))
	# Step 1: Remove all VisibleOnScreenEnabler3D/Notifier3D + bloat cull margins
	_remove_enablers_recursive(root)
	# Step 2: Set Controller to PROCESS_MODE_ALWAYS — the KEY fix.
	# Unlike INHERIT, ALWAYS is immune to parent process_mode changes.
	# This prevents any future DISABLED propagation from breaking the game loop.
	root.process_mode = Node.PROCESS_MODE_ALWAYS
	# Also protect the Character (stat manager) node
	for child in root.get_children():
		if child.name == "Character":
			child.process_mode = Node.PROCESS_MODE_ALWAYS
			if l:
				l.log_msg("CharHooks", "Phase1: Character node set to ALWAYS")
	if l:
		l.log_msg("CharHooks", "Phase1: Controller set to PROCESS_MODE_ALWAYS")
	# Step 3: Sanitize the Core tree (Audio, Camera etc.)
	var scene: Node = get_tree().current_scene
	if scene:
		var core: Node = scene.get_node_or_null("Core")
		if core:
			if l:
				l.log_msg("CharHooks", "Phase1: sanitizing Core tree")
			_remove_enablers_recursive(core)
			# Core also ALWAYS — protects Camera, Audio, WeaponRig Manager
			core.process_mode = Node.PROCESS_MODE_ALWAYS


func _remove_enablers_recursive(node: Node) -> void:
	for child in node.get_children():
		if child is VisibleOnScreenEnabler3D or child is VisibleOnScreenNotifier3D:
			# Bloat AABB so it never triggers, then remove
			child.aabb = AABB(Vector3(-10000, -10000, -10000), Vector3(20000, 20000, 20000))
			child.queue_free()
		if child is GeometryInstance3D:
			child.extra_cull_margin = 16384.0
		_remove_enablers_recursive(child)
