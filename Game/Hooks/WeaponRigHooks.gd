extends "res://mods/RTVCoop/HookKit/BaseHook.gd"


const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

# Phase1: puppet 판별 결과를 캐시하여 매 프레임 트리 순회 방지
# key = weapon node instance_id, value = is_puppet bool
var _puppet_cache: Dictionary = {}
var _prev_states: Dictionary = {}
var _recent_broadcasts: Dictionary = {}


func _setup_hooks() -> void:
	CoopHook.register(self, "weaponrig-_ready-pre", _on_weaponrig_ready_pre)
	CoopHook.register(self, "weaponrig-_input-pre", _on_weaponrig_input_pre)
	CoopHook.register(self, "weaponrig-_physics_process-pre", _on_weaponrig_physics_pre)
	CoopHook.register(self, "weaponrig-_process-pre", _on_weaponrig_process_pre)
	# v0.13.1: FireEvent hook — 매 발사마다 fire (자동 발사도 매 발 count).
	# 이전엔 rising edge 1번만 count되어 auto fire 시 9/10 누락.
	CoopHook.register(self, "weaponrig-fireevent-post", _on_weaponrig_fireevent_post)
	# v0.13.9: audio hook 재장전(2종)만 유지 — 9종 중 7종은 mod.txt 비활성 (crash 의심 격리)
	# v0.13.38: PlayReload(볼트액션 Manual 무기) 추가 — 이전엔 reloadEmpty/Tactical만 hook
	CoopHook.register(self, "weaponrig-playreloadempty-post", _on_playreloadempty_post)
	CoopHook.register(self, "weaponrig-playreloadtactical-post", _on_playreloadtactical_post)
	CoopHook.register(self, "weaponrig-playreload-post", _on_playreload_post)
	# v0.13.41: 나머지 무기 audio 7종 재활성화 (v0.13.9 crash 의심 격리 해제 — 진짜 원인은 AFK 폴더였음)
	CoopHook.register(self, "weaponrig-playcharge-post", _on_playcharge_post)
	CoopHook.register(self, "weaponrig-playmagazineattachempty-post", _on_playmagazineattachempty_post)
	CoopHook.register(self, "weaponrig-playmagazineattachtactical-post", _on_playmagazineattachtactical_post)
	CoopHook.register(self, "weaponrig-playmagazinedetach-post", _on_playmagazinedetach_post)
	CoopHook.register(self, "weaponrig-playammocheck-post", _on_playammocheck_post)
	CoopHook.register(self, "weaponrig-playinsertstart-post", _on_playinsertstart_post)
	CoopHook.register(self, "weaponrig-playinsertend-post", _on_playinsertend_post)
	CoopHook.register(self, "weaponrig-playinsert-post", _on_playinsert_post)
	print("[WeaponRigHooks] Phase1: Hook setups complete + 무기 audio 10종 sync")



func _on_weaponrig_fireevent_post() -> void:
	var weapon := CoopHook.caller()
	if _is_puppet_weapon(weapon):
		return  # puppet weapon은 본인이 트리거한 fire 아님 — skip
	# 호스트/클라 자기 측 fire 시점. LocalStateSync._local_shot_count 증가.
	if local_state and "_local_shot_count" in local_state:
		local_state._local_shot_count += 1


# v0.13.3/v0.13.4: 무기 audio sync — vanilla 함수 hook + 일반화 broadcast
# audio_key = ItemData의 audio reference 필드명 (reloadEmpty, charge, magazineAttachEmpty 등)
func _broadcast_weapon_audio_safe(audio_key: String) -> void:
	var weapon := CoopHook.caller()
	if _is_puppet_weapon(weapon):
		return
	
	# v0.6.8: 중복 발송 디바운스 처리 (150ms 이내 동일 키 발송 차단)
	var now: float = Time.get_ticks_msec()
	var prev_time: float = _recent_broadcasts.get(audio_key, 0.0)
	if now - prev_time < 150.0:
		return
	_recent_broadcasts[audio_key] = now

	# v0.13.38 진단: 재장전 audio broadcast 경로 추적
	if local_state and local_state.has_method("_broadcast_weapon_audio"):
		print("[WeaponRigHooks] reload audio broadcast: %s" % audio_key)
		local_state._broadcast_weapon_audio(audio_key)
	else:
		print("[WeaponRigHooks] reload audio FAIL — local_state=%s" % str(local_state))


func _on_playreloadempty_post() -> void: _broadcast_weapon_audio_safe("reloadEmpty")
func _on_playreloadtactical_post() -> void: _broadcast_weapon_audio_safe("reloadTactical")
func _on_playreload_post() -> void: _broadcast_weapon_audio_safe("reload")
func _on_playcharge_post() -> void: _broadcast_weapon_audio_safe("charge")
func _on_playmagazineattachempty_post() -> void: _broadcast_weapon_audio_safe("magazineAttachEmpty")
func _on_playmagazineattachtactical_post() -> void: _broadcast_weapon_audio_safe("magazineAttachTactical")
func _on_playmagazinedetach_post() -> void: _broadcast_weapon_audio_safe("magazineDetach")
func _on_playammocheck_post() -> void: _broadcast_weapon_audio_safe("ammoCheck")
func _on_playinsertstart_post() -> void: _broadcast_weapon_audio_safe("insertStart")
func _on_playinsertend_post() -> void: _broadcast_weapon_audio_safe("insertEnd")
func _on_playinsert_post() -> void: _broadcast_weapon_audio_safe("insert")


## Phase1: 캐시된 puppet 판별 — O(1) 딕셔너리 조회
## 첫 호출(보통 _ready)에서만 조상 노드를 실제 탐색하고 결과를 캐시
func _is_puppet_weapon(weapon: Node) -> bool:
	if weapon == null:
		return false
	var wid: int = weapon.get_instance_id()
	if _puppet_cache.has(wid):
		return _puppet_cache[wid]
	# 첫 조회: 실제 조상 탐색 후 캐시
	var result: bool = _walk_ancestors_for_puppet(weapon)
	_puppet_cache[wid] = result
	return result


## 실제 조상 노드 탐색 — _is_puppet_weapon에서 캐시 miss일 때만 호출
func _walk_ancestors_for_puppet(weapon: Node) -> bool:
	var parent: Node = weapon.get_parent()
	while parent:
		if parent.get_meta("coop_puppet_mode", false):
			return true
		parent = parent.get_parent()
	return false


func _on_weaponrig_ready_pre() -> void:
	var weapon := CoopHook.caller()
	var is_puppet := _is_puppet_weapon(weapon)
	var l = Engine.get_meta("CoopLogger", null)
	if l:
		l.log_msg("WeaponRigHooks", "_ready: weapon=%s, is_puppet=%s" % [str(weapon.get_path()) if weapon else "null", str(is_puppet)])
	if is_puppet:
		CoopHook.skip_super()


func _on_weaponrig_input_pre(_event: InputEvent) -> void:
	var weapon := CoopHook.caller()
	if _is_puppet_weapon(weapon):
		CoopHook.skip_super()


func _on_weaponrig_physics_pre(_delta: float = 0.0) -> void:
	var weapon := CoopHook.caller()
	if weapon == null:
		return
	var is_puppet := _is_puppet_weapon(weapon)
	if is_puppet:
		CoopHook.skip_super()
		return

	# --- v0.6.8: 애니메이션 상태 전이 감지 Fallback (권총/레버액션 오디오 트랙 우회 대응) ---
	if weapon.get("animator") and is_instance_valid(weapon.animator) and weapon.animator.active:
		var playback = weapon.animator.get("parameters/playback")
		if playback:
			var current_state: String = str(playback.get_current_node())
			var wid := weapon.get_instance_id()
			var prev_state: String = _prev_states.get(wid, "")
			if current_state != prev_state:
				_prev_states[wid] = current_state
				_on_weapon_state_changed(weapon, prev_state, current_state)


func _on_weaponrig_process_pre(_delta: float = 0.0) -> void:
	var weapon := CoopHook.caller()
	if _is_puppet_weapon(weapon):
		CoopHook.skip_super()


# --- v0.6.8: 애니메이션 상태 전이 시 오디오 강제 싱크 매핑 함수 ---
func _on_weapon_state_changed(weapon: Node, prev: String, current: String) -> void:
	# 1. 탄창 장착 (Glock 권총 등 애니메이션 트랙 우회 대응)
	if current == "Magazine_Attach_Empty" and prev != "Magazine_Attach_Empty":
		_broadcast_weapon_audio_safe("magazineAttachEmpty")
	elif current == "Magazine_Attach_Tactical" and prev != "Magazine_Attach_Tactical":
		_broadcast_weapon_audio_safe("magazineAttachTactical")
	elif current == "Reload_Empty" and prev != "Reload_Empty":
		_broadcast_weapon_audio_safe("reloadEmpty")
	elif current == "Reload_Tactical" and prev != "Reload_Tactical":
		_broadcast_weapon_audio_safe("reloadTactical")
	
	# 2. 레버액션 탄환 삽입 (Winchester 1873 등 애니메이션 트랙 우회 대응)
	elif current == "Insert" and prev != "Insert":
		_broadcast_weapon_audio_safe("insert")
	elif current == "Insert_Start" and prev != "Insert_Start":
		_broadcast_weapon_audio_safe("insertStart")
	elif current == "Insert_End" and prev != "Insert_End":
		_broadcast_weapon_audio_safe("insertEnd")

