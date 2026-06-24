extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

const REVIVE_DURATION := 5.0
const REVIVE_MAX_RANGE := 4.0
var _gd: Resource = preload("res://Resources/GameData.tres")  # v0.13.62 매프레임 load() 제거(캐싱)

var _reviving: bool = false
var _diag_cooldown: float = 0.0
var _vote_sent_frame: int = -1  # v0.13.14 replace+post 둘 다 fire되어 vote 두 번 발사되는 toggle 사고 방지


func _send_transition_vote(tr_name: String) -> void:
	# v0.13.14: replace hook과 post hook 양쪽에서 호출 가능 — 한 frame당 1회만 발사.
	# (메모리 미해결 #1이 일부 케이스에서 fire되는 것으로 보임 → 둘 다 vote 보내면 toggle로 1/2 → 0/2)
	var f: int = Engine.get_physics_frames()
	if _vote_sent_frame == f:
		return
	_vote_sent_frame = f
	var coop_ref = RTVCoop.get_instance()
	var sf: Node = null
	if coop_ref and coop_ref.players and "_scene_flow" in coop_ref.players:
		sf = coop_ref.players._scene_flow
	if sf == null:
		return
	if CoopAuthority.is_host():
		sf._add_transition_vote(tr_name, multiplayer.get_unique_id())
	else:
		sf.RequestTransitionVote.rpc_id(1, tr_name)
	_log("transition vote: %s (frame=%d)" % [tr_name, f])

func _log(msg: String) -> void:
	var l = Engine.get_meta("CoopLogger", null)
	if l: l.log_msg("InteractorHooks", msg)

func _setup_hooks() -> void:
	_log("_setup_hooks called")
	var id1 = CoopHook.register(self, "interactor-_physics_process-post", _on_interactor_physics_post)
	_log("  interactor-_physics_process-post → id=%d" % id1)
	var id2 = CoopHook.register_replace_or_post(self, "interactor-interact", _replace_interactor_interact, _post_interactor_interact)
	_log("  interactor-interact → id=%d" % id2)


func _on_interactor_physics_post(delta: float) -> void:
	var interactor := CoopHook.caller()
	if interactor == null or not CoopAuthority.is_active():
		return
	var gd: Resource = _gd
	if gd == null:
		return

	_diag_cooldown -= delta
	if downed and downed.is_any_peer_downed() and _diag_cooldown <= 0.0:
		_diag_cooldown = 2.0
		var tgt_info: String = "null"
		if interactor.target:
			var groups: String = str(interactor.target.get_groups())
			var owner_str: String = str(interactor.target.owner) if interactor.target.owner else "null"
			var layer: int = interactor.target.collision_layer if "collision_layer" in interactor.target else -1
			tgt_info = "groups=%s owner=%s layer=%d" % [groups, owner_str, layer]
		_log("DIAG target=%s interaction=%s freeze=%s decor=%s" % [tgt_info, str(gd.interaction), str(gd.freeze), str(gd.decor)])

	if interactor.target and interactor.target.is_in_group("Interactable") and not gd.decor:
		if interactor.target.owner and interactor.target.owner.get("isDowned") == true:
			if Input.is_action_just_pressed("interact") and not _reviving:
				_log("revive: interact pressed on downed puppet (post hook)")
				_start_revive(interactor.target.owner)
			return

	if not interactor.target:
		return
	if interactor.target.is_in_group("Transition") and not gd.decor:
		if downed and downed.is_any_peer_downed():
			gd.tooltip = "팀원이 쓰러진 상태에서는 떠날 수 없습니다"
			gd.interaction = false
			gd.transition = false
			return
		# v0.13.14: chat 안내 메시지 제거 (vanilla HUD prompt 살아있음 + vote_status broadcast가 카운트 표시).
		# NodePath/get_path/get_meta 매 frame 호출도 같이 제거 — frame drop 원인 추정.
		if CoopAuthority.is_client():
			# 메모리 미해결 #1 우회 — post에서 input 잡아 vote RPC. 단 replace도 fire되는 케이스 발견 →
			# _send_transition_vote가 frame 단위 가드. 한 frame에 두 hook이 fire되어도 vote 1회.
			if Input.is_action_just_pressed("interact"):
				var tr_owner: Node = interactor.target.owner
				if tr_owner and tr_owner.name:
					_send_transition_vote(str(tr_owner.name))
		return
	if interactor.target.is_in_group("Interactable") and not gd.decor:
		if interactor.target.owner and interactor.target.owner.get("canSleep") != null:
			_coop_bed_tooltip(interactor.target.owner, gd)
		elif interactor.target.owner and interactor.target.owner is LootContainer:
			_coop_container_tooltip(interactor.target.owner, gd)

	# v0.10.2: 도둑질 감지 — interactor-_physics_process-post는 클라/호스트 양쪽 fire됨
	# (메모리 미해결 #1는 interactor-interact 한정). just_pressed + trader display target → guard aggro.
	if Input.is_action_just_pressed("interact") and interactor.target and interactor.target.is_in_group("Item"):
		if players and players._is_trader_display_item(interactor.target):
			var perp_id: int = multiplayer.get_unique_id()
			_log("THEFT detected by peer=%d target=%s" % [perp_id, str(interactor.target.name)])
			if guard != null:
				if CoopAuthority.is_host():
					guard._activate_aggro()
					guard.BroadcastTheftAggro.rpc()
				else:
					guard.SubmitTheft.rpc_id(1, perp_id)


func _replace_interactor_interact() -> void:
	var interactor := CoopHook.caller()
	if interactor == null or not CoopAuthority.is_active():
		_log("_replace_interactor_interact: early return (caller=%s active=%s)" % [str(interactor != null), str(CoopAuthority.is_active())])
		return
	if _reviving:
		CoopHook.skip_super()
		return
	if not Input.is_action_just_pressed("interact"):
		return
	var gd: Resource = _gd
	if gd == null or interactor.target == null:
		_log("_replace_interactor_interact: no gameData or no target")
		return

	if not gd.decor and interactor.target.is_in_group("Interactable"):
		if interactor.target.owner and interactor.target.owner.get("isDowned") == true:
			_start_revive(interactor.target.owner)
			CoopHook.skip_super()
			return
		if interactor.target.owner and interactor.target.owner.get("canSleep") != null:
			_log("  → bed interact")
			_coop_bed_interact(interactor.target.owner)
			CoopHook.skip_super()
			return
		_log("  → general Interactable, calling owner.Interact() (has_method=%s)" % str(interactor.target.owner.has_method("Interact") if interactor.target.owner else false))
		if interactor.target.owner and interactor.target.owner.has_method("Interact"):
			interactor.target.owner.Interact()
		CoopHook.skip_super()
		return

	if not gd.decor and interactor.target.is_in_group("Transition"):
		if downed and downed.is_any_peer_downed():
			Loader.Message("팀원이 쓰러진 상태에서는 떠날 수 없습니다", Color.ORANGE)
			CoopHook.skip_super()
			return
		# v0.12.5 vote 기반 transition. v0.13.14 헬퍼로 통일 (frame 단위 가드로 post와 중복 발사 방지).
		var tr_owner: Node = interactor.target.owner
		if tr_owner and tr_owner.name:
			_send_transition_vote(str(tr_owner.name))
		CoopHook.skip_super()
		return

	if not gd.decor and interactor.target.is_in_group("Item"):
		gd.interaction = true
		if interactor.target.has_meta("network_uuid"):
			var uuid: int = int(interactor.target.get_meta("network_uuid"))
			if players and players.has_method("RequestPickup"):
				players.RequestPickup(uuid)
			CoopHook.skip_super()
			return
		# v0.11.10: trader display item interact → 도둑질 감지 (호스트 fire 시점, target 유효)
		if players and players._is_trader_display_item(interactor.target):
			var perp_id: int = multiplayer.get_unique_id()
			_log("THEFT detected (replace_interactor_interact) peer=%d" % perp_id)
			if guard != null:
				if CoopAuthority.is_host():
					guard._activate_aggro()
					guard.BroadcastTheftAggro.rpc()
				else:
					guard.SubmitTheft.rpc_id(1, perp_id)
			# vanilla 통과 (skip_super 안 호출) — picking 진행

	if gd.decor and interactor.target.is_in_group("Furniture"):
		var coop_fid: int = -1
		var root: Node = interactor.target.owner
		if root and root.has_meta("coop_furniture_id"):
			coop_fid = int(root.get_meta("coop_furniture_id"))
			if furniture and furniture.IsFurnitureLocked(coop_fid):
				var locker_id: int = furniture.GetFurnitureLockOwner(coop_fid)
				var locker_name: String = players.GetPlayerName(locker_id) if players else str(locker_id)
				Loader.Message("사용 중: " + locker_name, Color.ORANGE)
				CoopHook.skip_super()
				return
		for child in interactor.target.owner.get_children():
			if child is Furniture:
				child.Catalog()
		# v0.9: BroadcastFurnitureRemove/SubmitFurnitureRemove 호출은 furniture-catalog hook으로 일원화.
		# child.Catalog()가 우리 hook을 fire시키고, 그 안에서 호스트=Broadcast / 클라=SubmitClaim 처리.
		# (참고: 이 InteractorHooks 자체는 클라에서 fire 안 되는 케이스 있음 — 메모리 미해결 #1)
		CoopHook.skip_super()


func _post_interactor_interact() -> void:
	pass


func _coop_bed_interact(bed: Node) -> void:
	if not bed.canSleep or event == null:
		return
	if CoopAuthority.is_host():
		event.HostToggleSleepReady(multiplayer.get_unique_id(), bed.randomSleep)
	else:
		event.RequestSleepReady.rpc_id(1, bed.randomSleep)


func _coop_container_tooltip(lc: Node, gd: Resource) -> void:
	if container == null:
		return
	var cid: int = container._node_id(lc)
	if not container._container_holders.has(cid):
		return
	var holder_id: int = int(container._container_holders[cid])
	if holder_id == multiplayer.get_unique_id():
		return
	var holder_name: String = players.GetPlayerName(holder_id) if players else str(holder_id)
	gd.tooltip = lc.containerName + " [" + holder_name + " 사용 중]"


func _coop_bed_tooltip(bed: Node, gd: Resource) -> void:
	if not bed.canSleep:
		gd.tooltip = ""
		return
	var my_id: int = multiplayer.get_unique_id()
	if event and event._sleep_ready.has(my_id):
		gd.tooltip = "취침 [취소]"
	else:
		gd.tooltip = "취침 (랜덤: 6-12시간) [준비]"


func _start_revive(puppet: Node) -> void:
	if _reviving or downed == null:
		return
	_reviving = true
	var puppet_peer_id: int = puppet.peer_id
	var player_name: String = players.GetPlayerName(puppet_peer_id) if players else str(puppet_peer_id)
	_log("revive: STARTED for peer=%d name=%s" % [puppet_peer_id, player_name])

	var elapsed: float = 0.0
	while elapsed < REVIVE_DURATION:
		if not is_instance_valid(puppet) or not puppet.isDowned:
			Loader.Message("회복 취소됨", Color.RED)
			_log("revive: cancelled (puppet invalid or no longer downed)")
			_reviving = false
			return
		var controller = players.GetLocalController() if players else null
		if controller and controller.global_position.distance_to(puppet.global_position) > REVIVE_MAX_RANGE:
			Loader.Message("너무 멉니다 — 회복 취소됨", Color.RED)
			_log("revive: cancelled (too far)")
			_reviving = false
			return
		var pct: int = int((elapsed / REVIVE_DURATION) * 100.0)
		Loader.Message("%s 회복 중... %d%%" % [player_name, pct], Color.YELLOW)
		var tree = get_tree()
		if tree == null:
			break
		await tree.create_timer(0.5).timeout
		if get_tree() == null:
			break
		elapsed += 0.5

	if not is_instance_valid(puppet) or not puppet.isDowned:
		Loader.Message("Revive cancelled", Color.RED)
		_reviving = false
		return

	downed.request_revive(puppet_peer_id)
	Loader.Message("%s 회복 완료!" % player_name, Color.GREEN)
	_log("revive: COMPLETED for peer=%d" % puppet_peer_id)
	_reviving = false
