extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

const SYNC_INTERVAL := 1.0 / 20.0
const SETTLING_DURATION := 2.0
const SETTLING_REST_LINEAR := 0.1
const SETTLING_REST_ANGULAR := 0.1


var _state: Dictionary = {}


func _setup_hooks() -> void:
	CoopHook.register(self, "placer-_physics_process-pre", _on_placer_physics_pre)
	CoopHook.register(self, "placer-_physics_process-post", _on_placer_physics_post)
	CoopHook.register(self, "placer-_input-pre", _on_placer_input_pre)
	CoopHook.register(self, "placer-contextplace-post", _on_placer_context_place_post)

	if events:
		events.furniture_lock_denied.connect(_on_furniture_lock_denied)


func _state_for(placer: Node) -> Dictionary:
	var pid: int = placer.get_instance_id()
	if not _state.has(pid):
		_state[pid] = {
			"was_placing_furniture": false,
			"last_fid": -1,
			"last_placable_uuid": -1,
			"sync_accum": 0.0,
			"settling_uuid": -1,
			"settling_time_remaining": 0.0,
			"settling_accum": 0.0,
		}
	return _state[pid]


func _game_data() -> Resource:
	return load("res://Resources/GameData.tres")


func _on_placer_physics_pre(_delta: float) -> void:
	var placer := CoopHook.caller()
	if placer == null:
		return
	var gd: Resource = _game_data()
	if gd == null:
		return
	var state := _state_for(placer)
	state["was_placing_furniture"] = gd.isPlacing and placer.furniture != null

	if gd.isPlacing and (placer.placable == null or not is_instance_valid(placer.placable)):
		if state["last_fid"] >= 0:
			_release_furniture_lock(state["last_fid"])
		placer.placable = null
		placer.furniture = null
		placer.initialWait = false
		gd.isPlacing = false
		state["last_fid"] = -1


func _on_placer_physics_post(delta: float) -> void:
	var placer := CoopHook.caller()
	if placer == null:
		return
	var gd: Resource = _game_data()
	if gd == null:
		return
	var state := _state_for(placer)

	if not state["was_placing_furniture"] and gd.isPlacing and placer.placable and placer.furniture \
			and placer.placable.has_meta("coop_furniture_id") \
			and CoopAuthority.is_active():
		_handle_furniture_grab(placer, state)

	if CoopAuthority.is_active():
		_tick_sync(placer, state, delta)


func _handle_furniture_grab(placer: Node, state: Dictionary) -> void:
	if furniture == null:
		return
	var fid: int = int(placer.placable.get_meta("coop_furniture_id"))
	var my_id: int = multiplayer.get_unique_id()
	if furniture.IsFurnitureLocked(fid) and furniture.GetFurnitureLockOwner(fid) != my_id:
		var locker_name: String = players.GetPlayerName(furniture.GetFurnitureLockOwner(fid)) if players else str(furniture.GetFurnitureLockOwner(fid))
		Loader.Message("사용 중: " + locker_name, Color.ORANGE)
		if placer.furniture and placer.furniture.has_method("ResetMove"):
			placer.furniture.ResetMove()
		placer.placable = null
		placer.furniture = null
		var gd: Resource = _game_data()
		if gd:
			gd.isPlacing = false
		return
	state["last_fid"] = fid
	if CoopAuthority.is_host():
		furniture.HostStartPlacement(fid)
	else:
		furniture.RequestStartPlacement.rpc_id(1, fid)


func _tick_sync(placer: Node, state: Dictionary, delta: float) -> void:
	var gd: Resource = _game_data()
	if gd == null:
		return
	if gd.isPlacing and placer.placable and is_instance_valid(placer.placable):
		if placer.placable.has_meta("network_uuid"):
			_tick_pickup_sync(placer, state, delta)
			return
		elif placer.placable.has_meta("coop_furniture_id"):
			state["sync_accum"] += delta
			if state["sync_accum"] < SYNC_INTERVAL:
				return
			state["sync_accum"] = 0.0
			var fid: int = int(placer.placable.get_meta("coop_furniture_id"))
			if furniture == null:
				return
			if CoopAuthority.is_host():
				furniture.BroadcastFurnitureMove.rpc(fid, placer.placable.global_position, placer.placable.global_rotation, placer.placable.scale)
			else:
				furniture.SubmitFurnitureMove.rpc_id(1, fid, placer.placable.global_position, placer.placable.global_rotation, placer.placable.scale)
			return

	if state["last_placable_uuid"] >= 0:
		state["settling_uuid"] = state["last_placable_uuid"]
		state["settling_time_remaining"] = SETTLING_DURATION
		state["settling_accum"] = 0.0
		state["last_placable_uuid"] = -1
		state["sync_accum"] = 0.0

	if state["settling_uuid"] >= 0:
		_tick_settling(state, delta)

	if state["last_fid"] >= 0 and not gd.isPlacing:
		_finalize_furniture_sync(state["last_fid"])
		state["last_fid"] = -1
		state["sync_accum"] = 0.0


func _tick_pickup_sync(placer: Node, state: Dictionary, delta: float) -> void:
	state["last_placable_uuid"] = int(placer.placable.get_meta("network_uuid"))
	state["sync_accum"] += delta
	if state["sync_accum"] < SYNC_INTERVAL:
		return
	state["sync_accum"] = 0.0
	if pickup == null:
		return
	if CoopAuthority.is_host():
		pickup.BroadcastPickupMove.rpc(state["last_placable_uuid"], placer.placable.global_position, placer.placable.global_rotation, true)
	else:
		pickup.SubmitPickupMove.rpc_id(1, state["last_placable_uuid"], placer.placable.global_position, placer.placable.global_rotation, true)


func _tick_settling(state: Dictionary, delta: float) -> void:
	if players == null or not players.worldItems.has(state["settling_uuid"]):
		state["settling_uuid"] = -1
		return
	var p: Node = players.worldItems[state["settling_uuid"]]
	if not is_instance_valid(p):
		state["settling_uuid"] = -1
		return
	if p.freeze_mode == RigidBody3D.FREEZE_MODE_KINEMATIC:
		state["settling_uuid"] = -1
		return
	state["settling_time_remaining"] -= delta
	state["settling_accum"] += delta
	var at_rest: bool = p.linear_velocity.length() < SETTLING_REST_LINEAR \
		and p.angular_velocity.length() < SETTLING_REST_ANGULAR
	if state["settling_time_remaining"] <= 0.0 or at_rest:
		p.linear_velocity = Vector3.ZERO
		p.angular_velocity = Vector3.ZERO
		if p.has_method("Freeze"):
			p.Freeze()
		else:
			p.freeze = true
		_settle_broadcast(state["settling_uuid"], p)
		state["settling_uuid"] = -1
		state["settling_accum"] = 0.0
		return
	if state["settling_accum"] < SYNC_INTERVAL:
		return
	state["settling_accum"] = 0.0
	_settle_broadcast(state["settling_uuid"], p)


func _settle_broadcast(uuid: int, p: Node) -> void:
	if pickup == null:
		return
	if CoopAuthority.is_host():
		pickup.BroadcastPickupMove.rpc(uuid, p.global_position, p.global_rotation, true)
	else:
		pickup.SubmitPickupMove.rpc_id(1, uuid, p.global_position, p.global_rotation, true)


func _finalize_furniture_sync(fid: int) -> void:
	if players == null or furniture == null:
		return
	var root: Node = players._find_furniture_by_id(fid)
	if root == null:
		return
	if CoopAuthority.is_host():
		furniture.HostEndPlacement(fid, root.global_position, root.global_rotation, root.scale)
	else:
		furniture.RequestEndPlacement.rpc_id(1, fid, root.global_position, root.global_rotation, root.scale)


func _release_furniture_lock(fid: int) -> void:
	if fid < 0 or furniture == null:
		return
	if CoopAuthority.is_host():
		furniture.HostUnlockFurniture(fid)
	else:
		furniture.RequestFurnitureUnlock.rpc_id(1, fid)


func _on_placer_input_pre(event_arg: InputEvent) -> void:
	var placer := CoopHook.caller()
	if placer == null:
		return
	var gd: Resource = _game_data()
	if gd == null:
		return
	if not (CoopAuthority.is_active() and gd.isPlacing and gd.decor \
			and placer.placable and is_instance_valid(placer.placable) and placer.furniture):
		return
	if not (event_arg is InputEventKey and event_arg.is_action_pressed("interact")):
		return
	var fid: int = -1
	if placer.placable.has_meta("coop_furniture_id"):
		fid = int(placer.placable.get_meta("coop_furniture_id"))
	if fid < 0 or furniture == null:
		return
	_release_furniture_lock(fid)
	if CoopAuthority.is_host():
		furniture.BroadcastFurnitureRemove.rpc(fid)
	else:
		furniture.SubmitFurnitureRemove.rpc_id(1, fid)
	var state := _state_for(placer)
	state["last_fid"] = -1
	state["sync_accum"] = 0.0


func _on_placer_context_place_post(target: Node3D) -> void:
	if not CoopAuthority.is_active():
		return
	if target == null or not is_instance_valid(target):
		return
	if not target.has_meta("coop_furniture_id"):
		return
	var placer := CoopHook.caller()
	if placer == null or furniture == null:
		return
	var fid: int = int(target.get_meta("coop_furniture_id"))
	var state := _state_for(placer)
	state["last_fid"] = fid
	state["sync_accum"] = 0.0
	if CoopAuthority.is_host():
		furniture.HostStartPlacement(fid)
	else:
		furniture.RequestStartPlacement.rpc_id(1, fid)


func _on_furniture_lock_denied(fid: int) -> void:
	var gd: Resource = _game_data()
	if gd == null or not gd.isPlacing:
		return
	for placer_id in _state:
		var state: Dictionary = _state[placer_id]
		if state["last_fid"] != fid:
			continue
		var placer: Object = instance_from_id(placer_id)
		if placer == null or not is_instance_valid(placer):
			continue
		if placer.placable == null or not is_instance_valid(placer.placable):
			continue
		if not placer.placable.has_meta("coop_furniture_id"):
			continue
		if int(placer.placable.get_meta("coop_furniture_id")) != fid:
			continue
		Loader.Message("다른 플레이어가 사용 중", Color.ORANGE)
		if placer.furniture and placer.furniture.has_method("ResetMove"):
			placer.furniture.ResetMove()
		placer.placable = null
		placer.furniture = null
		gd.isPlacing = false
		state["last_fid"] = -1
