extends "res://mods/RTVCoop/HookKit/BaseHook.gd"


const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

# GameData backup variables for host-side target injection/restoration
var _gd_injected: bool = false
var _sv_gd_pp: Vector3 = Vector3.ZERO
var _sv_gd_cp: Vector3 = Vector3.ZERO
var _sv_gd_ir: bool = false
var _sv_gd_iw: bool = false
var _sv_gd_if: bool = false
var _sv_gd_pv: Vector3 = Vector3.ZERO
var _sv_gd_id: bool = false
var _sv_gd_it: bool = false

func _setup_hooks() -> void:
	var coop_instance = RTVCoop.get_instance()
	if coop_instance:
		coop_instance.set_meta("AIHooks", self)

	# 1. Vanilla AI hooks
	CoopHook.register_replace_or_post(self,
		"ai-_physics_process",
		_replace_ai_physics_process,
		_post_ai_physics_process)
	CoopHook.register(self, "ai-_physics_process-post", _post_ai_physics_process)
	CoopHook.register_replace_or_post(self,
		"ai-death",
		_replace_ai_death,
		_post_ai_death)
	CoopHook.register_replace_or_post(self,
		"ai-initialize",
		_replace_ai_initialize,
		_post_ai_initialize)
	CoopHook.register(self, "ai-initialize-post", _post_ai_initialize)
	CoopHook.register_replace_or_post(self, "ai-playfire", _replace_sound_fire, _post_sound)
	CoopHook.register_replace_or_post(self, "ai-playtail", _replace_sound_tail, _post_sound)
	CoopHook.register_replace_or_post(self, "ai-playidle", _replace_sound_idle, _post_sound)
	CoopHook.register_replace_or_post(self, "ai-playcombat", _replace_sound_combat, _post_sound)
	CoopHook.register_replace_or_post(self, "ai-playdamage", _replace_sound_damage, _post_sound)
	CoopHook.register_replace_or_post(self, "ai-playdeath", _replace_sound_death, _post_sound)

	CoopHook.register_replace_or_post(self, "ai-raycast", _replace_ai_raycast, _post_ai_raycast)
	CoopHook.register_replace_or_post(self, "ai-Sensor", _replace_ai_sensor, _post_noop)
	CoopHook.register_replace_or_post(self, "ai-Hearing", _replace_ai_hearing, _post_noop)
	CoopHook.register_replace_or_post(self, "ai-FireDetection", _replace_ai_fire_detection, _post_noop)
	CoopHook.register_replace_or_post(self, "ai-LOSCheck", _replace_ai_los_check, _post_noop)

func _replace_ai_physics_process(delta: float) -> void:
	var a := CoopHook.caller()
	if a == null:
		return
	if a.has_meta("coop_trader_guard"):
		return  # skip_super 호출 안 함 → vanilla AI 본문 실행
	if not CoopAuthority.is_active():
		return
	if a.get_meta("coop_puppet_mode", false):
		CoopHook.skip_super()
		return
	if not CoopAuthority.is_host():
		# 클라이언트: 로컬 FSM 차단, 애니메이션 틱만 실행
		if ai and ai.has_method("process_client_ai_tick"):
			ai.process_client_ai_tick(a, delta)
		CoopHook.skip_super()
		return

	# 호스트: 네이티브 _physics_process 실행 허용 (skip_super 호출 안 함)
	# AICoopManager에 등록 (Proximity Sleep 추적용)
	var coop := RTVCoop.get_instance()
	var manager = coop.get_sync("coop_manager") if coop else null
	if manager and manager.has_method("register_ai"):
		manager.register_ai(a)

	# 절전 상태면 네이티브 틱도 차단
	if a.get_meta("coop_ai_asleep", false):
		CoopHook.skip_super()
		return

	# [멀티 타겟 GameData 주입]
	# AI의 네이티브 코드는 전역 gameData에서 플레이어 위치를 읽는데,
	# gameData에는 호스트 로컬 플레이어만 있으므로 클라이언트 인식 불가.
	# → 최적 타겟(호스트 or 클라이언트) 데이터를 GameData에 주입한 뒤
	#   네이티브 틱을 돌리고, _post에서 복원.
	var ai_sync = coop.get_sync("ai") if coop else null
	if ai_sync == null:
		return  # ai_sync 없으면 기본 GameData로 네이티브 실행

	var target_state = ai_sync.GetBestTargetState(a.global_position, a)
	if target_state.is_empty():
		return  # 유효 타겟 없으면 기본대로 실행

	# 전역 GameData 교체 (Sensor/Hearing/LOSCheck 등이 이걸 읽음)
	var gd = a.get("gameData") if "gameData" in a else null
	if gd:
		if not _gd_injected:
			_gd_injected = true
			_sv_gd_pp = gd.playerPosition
			_sv_gd_cp = gd.cameraPosition
			_sv_gd_ir = gd.isRunning
			_sv_gd_iw = gd.isWalking
			_sv_gd_if = gd.isFiring
			_sv_gd_pv = gd.playerVector
			_sv_gd_id = gd.isDead
			_sv_gd_it = gd.isTrading

		gd.playerPosition = target_state["pos"]
		gd.cameraPosition = target_state["cam"]
		gd.isRunning = target_state.get("is_running", false)
		gd.isWalking = target_state.get("is_walking", false)
		gd.isFiring = target_state.get("is_firing", false)
		gd.playerVector = target_state.get("player_vector", Vector3.ZERO)
		gd.isDead = target_state.get("is_dead", false)
		gd.isTrading = target_state.get("is_trading", false)
	# skip_super 호출 안 함 → 네이티브 _physics_process 실행


func _post_ai_physics_process(_delta: float) -> void:
	# 호스트: 네이티브 틱 완료 후 GameData 복원
	if _gd_injected:
		_gd_injected = false
		var a := CoopHook.caller()
		if a != null:
			var gd = a.get("gameData") if "gameData" in a else null
			if gd:
				gd.playerPosition = _sv_gd_pp
				gd.cameraPosition = _sv_gd_cp
				gd.isRunning = _sv_gd_ir
				gd.isWalking = _sv_gd_iw
				gd.isFiring = _sv_gd_if
				gd.playerVector = _sv_gd_pv
				gd.isDead = _sv_gd_id
				gd.isTrading = _sv_gd_it


func _replace_ai_death(direction, force) -> void:
	var a := CoopHook.caller()
	if a == null or not CoopAuthority.is_active():
		return
	if a.get_meta("coop_puppet_mode", false):
		return

	# 호스트/클라이언트 공통: 사망 시 IK 및 애니메이션 콜백을 IDLE로 설정하여 ragdoll 엉킴(치즈 현상) 방지
	if a.animator:
		a.animator.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	if a.skeleton:
		a.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE

	if a.get_meta("_coop_death_from_broadcast", false):
		a.remove_meta("_coop_death_from_broadcast")
		return
	if a.dead:
		CoopHook.skip_super()
		return
	if not CoopAuthority.is_host():
		CoopHook.skip_super()
		return
	if not a.has_meta("network_uuid"):
		return
	
	if ai and ai.has_method("on_host_ai_death"):
		ai.on_host_ai_death(a, direction, force)


func _post_ai_death(direction, force) -> void:
	pass


func _replace_ai_initialize() -> void:
	var a := CoopHook.caller()
	if a == null or not CoopAuthority.is_active():
		return
	if a.get_meta("coop_puppet_mode", false):
		CoopHook.skip_super()
		return
	if not CoopAuthority.is_host():
		if a.has_meta("coop_trader_guard"):
			return
		CoopHook.skip_super()


func _post_ai_initialize() -> void:
	var a := CoopHook.caller()
	if a == null or not is_instance_valid(a) or not CoopAuthority.is_active():
		return
	if not CoopAuthority.is_host():
		return
	if a.get_meta("coop_puppet_mode", false):
		return

	# [PROXIMITY SLEEP REDESIGN]
	# Auto-register every host-initialized AI in AISync (if not done already)
	# and register it in AICoopManager for proximity sleep/wake tracking.
	if not a.has_meta("network_uuid"):
		var uuid: int = ai.GenerateAiUuid()
		a.set_meta("network_uuid", uuid)
		a.set_meta("is_vanilla_ai", true)
		
		players.world_ai[uuid] = a
		
		var spawn_type := "Wanderer"
		if a.get("boss") == true:
			spawn_type = "Boss"
		
		var script = a.get_script()
		print("[AIHooks] Auto-registered host spawn: uuid=%d, script=%s" % [uuid, script.resource_path if script else "unknown"])
		
		# 바닐라 AI: 즉시 장비 읽기 후 클라이언트에 브로드캐스트
		var variant: Dictionary = _read_actual_equipment(a)
		a.set_meta("coop_spawn_variant", variant)
		ai.BroadcastAISpawn.rpc(uuid, spawn_type, a.global_position, a.global_rotation, variant)
		
	var coop2 := RTVCoop.get_instance()
	var manager = coop2.get_sync("coop_manager") if coop2 else null
	if manager and manager.has_method("register_ai"):
		manager.register_ai(a)



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


func _coop_sound(a: Node, sound_type: int, extra_bool: bool = false) -> bool:
	if a.get_meta("_coop_force_local_play", false):
		return true
	if not CoopAuthority.is_active():
		return true
	if not CoopAuthority.is_host():
		return false
	if a.has_meta("network_uuid") and ai:
		ai.BroadcastAISound.rpc(int(a.get_meta("network_uuid")), sound_type, extra_bool)
	return true


func _replace_sound_fire() -> void:
	var a := CoopHook.caller()
	if a == null or a.get_meta("coop_puppet_mode", false):
		return
	if not _coop_sound(a, 0, a.fullAuto if "fullAuto" in a else false):
		CoopHook.skip_super()

func _replace_sound_tail() -> void:
	var a := CoopHook.caller()
	if a == null or a.get_meta("coop_puppet_mode", false):
		return
	if not _coop_sound(a, 1):
		CoopHook.skip_super()

func _replace_sound_idle() -> void:
	var a := CoopHook.caller()
	if a == null or a.get_meta("coop_puppet_mode", false):
		return
	if not _coop_sound(a, 2):
		CoopHook.skip_super()

func _replace_sound_combat() -> void:
	var a := CoopHook.caller()
	if a == null or a.get_meta("coop_puppet_mode", false):
		return
	if not _coop_sound(a, 3):
		CoopHook.skip_super()

func _replace_sound_damage() -> void:
	var a := CoopHook.caller()
	if a == null or a.get_meta("coop_puppet_mode", false):
		return
	if not _coop_sound(a, 4):
		CoopHook.skip_super()

func _replace_sound_death() -> void:
	var a := CoopHook.caller()
	if a == null or a.get_meta("coop_puppet_mode", false):
		return
	if not _coop_sound(a, 5):
		CoopHook.skip_super()

func _post_sound() -> void:
	pass


func _replace_ai_raycast() -> void:
	var a := CoopHook.caller()
	if a == null:
		return
	if not CoopAuthority.is_active():
		return
	if a.get_meta("coop_puppet_mode", false):
		CoopHook.skip_super()
		return
	if not CoopAuthority.is_host():
		CoopHook.skip_super()
		return

	CoopHook.skip_super()
	if a.fire == null:
		return

	var accuracy_target: Vector3 = a.global_position - a.global_transform.basis.z * 10.0
	if a.has_method("FireAccuracy"):
		accuracy_target = a.FireAccuracy()

	a.fire.look_at(accuracy_target, Vector3.UP, true)
	a.fire.force_raycast_update()

	if a.fire.is_colliding():
		var hitCollider = a.fire.get_collider()
		if hitCollider != null:
			if hitCollider.is_in_group("Player"):
				var damage: float = a.weaponData.damage if "weaponData" in a and a.weaponData != null else 10.0
				var penetration: float = a.weaponData.penetration if "weaponData" in a and a.weaponData != null else 0.0
				if "boss" in a and a.boss:
					damage *= 2.0

				# hitCollider가 Puppet인 경우 자체 함수 호출, 바닐라인 경우 자식 노드 호출
				if hitCollider.has_method("WeaponDamage"):
					hitCollider.WeaponDamage("Body", damage)
				elif hitCollider.get_child_count() > 0 and hitCollider.get_child(0).has_method("WeaponDamage"):
					hitCollider.get_child(0).WeaponDamage(damage, penetration)
				else:
					push_warning("[RTVCoop] hitCollider %s has no WeaponDamage method!" % hitCollider.name)
			else:
				var hitPoint = a.fire.get_collision_point()
				var hitNormal = a.fire.get_collision_normal()
				var hitSurface = hitCollider.get("surface")
				if a.has_method("BulletDecal"):
					a.BulletDecal(hitCollider, hitPoint, hitNormal, hitSurface)
	else:
		var dist: float = a.playerDistance3D if "playerDistance3D" in a else 0.0
		if dist > 50.0:
			_play_flyby_deferred(a)

func _post_ai_raycast() -> void:
	pass

func _play_flyby_deferred(a: Node) -> void:
	if a == null or not is_instance_valid(a):
		return
	await a.get_tree().create_timer(0.1, false).timeout
	if is_instance_valid(a) and a.has_method("PlayFlyby"):
		a.PlayFlyby()


func _replace_ai_sensor(delta: float) -> void:
	var a := CoopHook.caller()
	if a == null or not CoopAuthority.is_active():
		return
	if not CoopAuthority.is_host():
		CoopHook.skip_super()
		return
	# 호스트: 네이티브 Sensor 실행 허용 (GameData는 _replace_ai_physics_process에서 이미 주입됨)


func _replace_ai_hearing() -> void:
	var a := CoopHook.caller()
	if a == null or not CoopAuthority.is_active():
		return
	if not CoopAuthority.is_host():
		CoopHook.skip_super()
		return
	# 호스트: 네이티브 Hearing 실행 허용


func _replace_ai_fire_detection(delta: float) -> void:
	var a := CoopHook.caller()
	if a == null or not CoopAuthority.is_active():
		return
	if not CoopAuthority.is_host():
		CoopHook.skip_super()
		return
	# 호스트: 네이티브 FireDetection 실행 허용


func _replace_ai_los_check(_target: Vector3) -> void:
	var a := CoopHook.caller()
	if a == null or not CoopAuthority.is_active():
		return
	if not CoopAuthority.is_host():
		CoopHook.skip_super()
		return
	# 호스트: 네이티브 LOSCheck 실행 허용


func _post_noop() -> void:
	pass


