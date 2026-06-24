extends "res://mods/RTVCoop/Game/Sync/BaseSync.gd"



const BaseSync = preload("res://mods/RTVCoop/Game/Sync/BaseSync.gd")

func _sync_key() -> String:
	return "interactable"


func _ready() -> void:
	get_tree().get_root().child_entered_tree.connect(_on_root_child_added)


func _on_root_child_added(node: Node) -> void:
	if not (node is Grenade):
		return
	if node.has_meta("_coop_remote"):
		return
	if not CoopAuthority.is_active():
		return
	_broadcast_grenade_spawn(node)


func _broadcast_grenade_spawn(grenade: Node) -> void:
	var tree = get_tree()
	if tree == null:
		return
	await tree.physics_frame
	if get_tree() == null:
		return
	if not is_instance_valid(grenade) or not grenade.is_inside_tree():
		return

	var throw_path: String = grenade.scene_file_path
	var handle_path: String = ""
	if grenade.get("handle") and is_instance_valid(grenade.handle):
		handle_path = grenade.handle.scene_file_path

	if CoopAuthority.is_host():
		BroadcastGrenadeThrow.rpc(
			multiplayer.get_unique_id(),
			throw_path, handle_path,
			grenade.global_position, grenade.rotation_degrees,
			grenade.linear_velocity, grenade.angular_velocity
		)
	else:
		SubmitGrenadeThrow.rpc_id(1,
			throw_path, handle_path,
			grenade.global_position, grenade.rotation_degrees,
			grenade.linear_velocity, grenade.angular_velocity
		)


func _find_mine_by_id(mine_id: int, fallback_pos: Vector3 = Vector3.ZERO) -> Node3D:
	for mine in get_tree().get_nodes_in_group("CoopMine"):
		if not is_instance_valid(mine):
			continue
		if _coop_id(mine) == mine_id:
			return mine
	for node in get_tree().get_nodes_in_group("Interactable"):
		if not is_instance_valid(node):
			continue
		var root: Node = node.owner
		if root and root is Mine and _coop_id(root) == mine_id:
			if not root.is_in_group("CoopMine"):
				root.add_to_group("CoopMine")
			return root

	# 해시 불일치 시 물리적 거리 기반 Fallback (0.2m 이내)
	if fallback_pos != Vector3.ZERO:
		var best_mine: Node3D = null
		var best_dist: float = 0.2 * 0.2  # 0.04
		for mine in get_tree().get_nodes_in_group("CoopMine"):
			if not is_instance_valid(mine):
				continue
			var dist: float = mine.global_position.distance_squared_to(fallback_pos)
			if dist < best_dist:
				best_dist = dist
				best_mine = mine
		if best_mine:
			return best_mine
			
		for node in get_tree().get_nodes_in_group("Interactable"):
			if not is_instance_valid(node):
				continue
			var root: Node = node.owner
			if root and root is Mine:
				var dist: float = root.global_position.distance_squared_to(fallback_pos)
				if dist < best_dist:
					best_dist = dist
					best_mine = root
		if best_mine:
			if not best_mine.is_in_group("CoopMine"):
				best_mine.add_to_group("CoopMine")
			return best_mine
	return null


func _coop_id(node: Node) -> int:
	var coop := RTVCoop.get_instance()
	if coop and coop.players and coop.players.has_method("CoopPosHash"):
		return coop.players.CoopPosHash(node.global_position)
	return abs(hash(str(node.global_position)))


@rpc("any_peer", "reliable", "call_remote")
func RequestDoorSync() -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	var doors: Array = []
	var scene := get_tree().current_scene
	if scene:
		BaseSync.coop_walk(scene, func(node):
			if node is Door:
				doors.append({
					"path": node.get_path(),
					"isOpen": bool(node.isOpen),
					"locked": bool(node.locked),
				})
			return false
		)
	print("[InteractableSync] door manifest to peer %d: %d doors" % [sender, doors.size()])
	ApplyDoorManifest.rpc_id(sender, doors)


@rpc("authority", "reliable", "call_remote")
func ApplyDoorManifest(doors: Array) -> void:
	print("[InteractableSync] door manifest received: %d doors" % doors.size())
	for entry in doors:
		var door: Node = get_node_or_null(entry.get("path", NodePath()))
		if door == null or not (door is Door):
			continue
		var desired_open: bool = bool(entry.get("isOpen", false))
		var desired_locked: bool = bool(entry.get("locked", false))
		if not desired_locked and door.locked:
			door.locked = false
			if door.get("linked"):
				door.linked.locked = false
		
		# isOpen 분기를 타지 않고, 맵 로드 시점에 무조건 문 상태를 일치시킴 (비주얼 desync 차단)
		door.isOpen = desired_open
		if desired_open:
			door.position = door.openOffset + door.defaultPosition
			door.rotation_degrees = door.openAngle + door.defaultRotation
		else:
			door.position = door.defaultPosition
			door.rotation_degrees = door.defaultRotation
		door.animationTime = 0.0
		door.handleMoving = false
		door.isOccupied = false
		door.occupiedTimer = 0.0


@rpc("any_peer", "reliable", "call_remote")
func RequestDoorToggle(door_path: NodePath) -> void:
	_log("RequestDoorToggle path=%s" % str(door_path))
	if not multiplayer.is_server():
		return
	var door: Node = get_node_or_null(door_path)
	_log("  → found=%s is_door=%s locked=%s" % [str(door != null), str(door is Door if door else false), str(door.locked if door and "locked" in door else "?")])
	if door == null or not (door is Door):
		return
	if door.locked:
		return
	door.isOccupied = false
	door.occupiedTimer = 0.0
	var new_open: bool = not door.isOpen
	if door.has_method("ApplyDoorState"):
		door.ApplyDoorState(new_open)
	else:
		_apply_door_state_inline(door, new_open)
	BroadcastDoorState.rpc(door_path, new_open)


@rpc("authority", "reliable", "call_remote")
func BroadcastDoorState(door_path: NodePath, new_open: bool) -> void:
	var door: Node = get_node_or_null(door_path)
	if door == null or not (door is Door):
		return
	if door.has_method("ApplyDoorState"):
		door.ApplyDoorState(new_open)
	else:
		_apply_door_state_inline(door, new_open)


func _apply_door_state_inline(door: Node, new_open: bool) -> void:
	door.isOpen = new_open
	door.animationTime = 4.0
	door.handleMoving = true
	if door.openAngle.y > 0.0:
		door.handleTarget = Vector3(0, 0, -45)
	else:
		door.handleTarget = Vector3(0, 0, 45)
	if door.has_method("PlayDoor"):
		door.PlayDoor()
	door.isOccupied = true
	door.occupiedTimer = 0.0


@rpc("any_peer", "reliable", "call_remote")
func RequestDoorUnlock(door_path: NodePath) -> void:
	if not multiplayer.is_server():
		return
	var door: Node = get_node_or_null(door_path)
	if door == null or not (door is Door):
		return
	if door.has_method("ApplyDoorUnlock"):
		door.ApplyDoorUnlock()
	else:
		_apply_door_unlock_inline(door)
	BroadcastDoorUnlock.rpc(door_path)


@rpc("authority", "reliable", "call_remote")
func BroadcastDoorUnlock(door_path: NodePath) -> void:
	var door: Node = get_node_or_null(door_path)
	if door == null or not (door is Door):
		return
	if door.has_method("ApplyDoorUnlock"):
		door.ApplyDoorUnlock()
	else:
		_apply_door_unlock_inline(door)


func _apply_door_unlock_inline(door: Node) -> void:
	door.locked = false
	if door.get("linked") and door.linked:
		door.linked.locked = false
	if door.has_method("PlayUnlock"):
		door.PlayUnlock()


@rpc("any_peer", "reliable", "call_remote")
func RequestSwitchToggle(switch_path: NodePath) -> void:
	if not multiplayer.is_server():
		return
	var sw: Node = get_node_or_null(switch_path)
	if sw == null:
		return
	var new_active: bool = not sw.active
	# fix6.5: drop the ApplySwitchState script_extend dependency, mirror what Door already does.
	if sw.has_method("ApplySwitchState"):
		sw.ApplySwitchState(new_active)
	else:
		_apply_switch_state_inline(sw, new_active)
	BroadcastSwitchState.rpc(switch_path, new_active)


@rpc("authority", "reliable", "call_remote")
func BroadcastSwitchState(switch_path: NodePath, new_active: bool) -> void:
	var sw: Node = get_node_or_null(switch_path)
	if sw == null:
		return
	if sw.has_method("ApplySwitchState"):
		sw.ApplySwitchState(new_active)
	else:
		_apply_switch_state_inline(sw, new_active)


# fix6.5: inline body of the removed Switch_Extend.ApplySwitchState. Toggles the active
# field, plays the appropriate Activate/Deactivate transition, and triggers the audio.
func _apply_switch_state_inline(sw: Node, new_active: bool) -> void:
	sw.active = new_active
	if new_active:
		if sw.has_method("Activate"):
			sw.Activate()
	else:
		if sw.has_method("Deactivate"):
			sw.Deactivate()
	if sw.has_method("PlaySwitch"):
		sw.PlaySwitch()


func _log(msg: String) -> void:
	var l = Engine.get_meta("CoopLogger", null)
	if l: l.log_msg("InteractableSync", msg)


@rpc("any_peer", "reliable", "call_remote")
func SubmitMineDetonate(mine_id: int, fallback_pos: Vector3 = Vector3.ZERO) -> void:
	_log("SubmitMineDetonate RECEIVED mine_id=%d" % mine_id)
	if not multiplayer.is_server():
		return
	var mine := _find_mine_by_id(mine_id, fallback_pos)
	_log("  → found mine: %s" % str(mine))
	if mine == null or mine.isDetonated:
		return
	mine.Detonate()


@rpc("authority", "reliable", "call_remote")
func BroadcastMineDetonate(mine_id: int, fallback_pos: Vector3 = Vector3.ZERO) -> void:
	_log("BroadcastMineDetonate RECEIVED mine_id=%d" % mine_id)
	var mine := _find_mine_by_id(mine_id, fallback_pos)
	_log("  → found mine: %s" % str(mine))
	if mine == null or mine.isDetonated:
		return
	mine.set_meta("_coop_detonate_suppressed", true)
	mine.Detonate()
	mine.set_meta("_coop_detonate_suppressed", false)


@rpc("any_peer", "reliable", "call_remote")
func SubmitMineInstantDetonate(mine_id: int, fallback_pos: Vector3 = Vector3.ZERO) -> void:
	if not multiplayer.is_server():
		return
	var mine := _find_mine_by_id(mine_id, fallback_pos)
	if mine == null or mine.isDetonated or mine.is_queued_for_deletion():
		return
	mine.InstantDetonate()


@rpc("authority", "reliable", "call_remote")
func BroadcastMineInstantDetonate(mine_id: int, fallback_pos: Vector3 = Vector3.ZERO) -> void:
	var mine := _find_mine_by_id(mine_id, fallback_pos)
	if mine == null or mine.isDetonated or mine.is_queued_for_deletion():
		return
	mine.set_meta("_coop_detonate_suppressed", true)
	mine.InstantDetonate()
	mine.set_meta("_coop_detonate_suppressed", false)


func RequestGrenadeThrow(throw_path: String, handle_path: String, pos: Vector3, rot_deg: Vector3, vel: Vector3, ang_vel: Vector3) -> void:
	if not CoopAuthority.is_active():
		return
	var origin_id: int = multiplayer.get_unique_id()
	if CoopAuthority.is_host():
		BroadcastGrenadeThrow.rpc(origin_id, throw_path, handle_path, pos, rot_deg, vel, ang_vel)
	else:
		SubmitGrenadeThrow.rpc_id(1, throw_path, handle_path, pos, rot_deg, vel, ang_vel)


@rpc("any_peer", "reliable", "call_remote")
func SubmitGrenadeThrow(throw_path: String, handle_path: String, pos: Vector3, rot_deg: Vector3, vel: Vector3, ang_vel: Vector3) -> void:
	if not multiplayer.is_server():
		return
	var origin_id: int = multiplayer.get_remote_sender_id()
	_spawn_grenade_locally(throw_path, handle_path, pos, rot_deg, vel, ang_vel)
	BroadcastGrenadeThrow.rpc(origin_id, throw_path, handle_path, pos, rot_deg, vel, ang_vel)


@rpc("authority", "reliable", "call_remote")
func BroadcastGrenadeThrow(origin_id: int, throw_path: String, handle_path: String, pos: Vector3, rot_deg: Vector3, vel: Vector3, ang_vel: Vector3) -> void:
	if multiplayer.get_unique_id() == origin_id:
		return
	_spawn_grenade_locally(throw_path, handle_path, pos, rot_deg, vel, ang_vel)


func _spawn_grenade_locally(throw_path: String, handle_path: String, pos: Vector3, rot_deg: Vector3, vel: Vector3, ang_vel: Vector3) -> void:
	var throw_scene := load(throw_path)
	if throw_scene == null:
		push_warning("[InteractableSync] failed to load grenade scene: " + throw_path)
		return
	var throw_grenade: Node = throw_scene.instantiate()
	throw_grenade.set_meta("_coop_remote", true)
	get_tree().get_root().add_child(throw_grenade)
	throw_grenade.position = pos
	throw_grenade.rotation_degrees = rot_deg
	throw_grenade.linear_velocity = vel
	throw_grenade.angular_velocity = ang_vel
	if handle_path != "":
		var handle_scene := load(handle_path)
		if handle_scene:
			var throw_handle: Node = handle_scene.instantiate()
			get_tree().get_root().add_child(throw_handle)
			throw_grenade.handle = throw_handle
			throw_handle.position = pos
			throw_handle.rotation_degrees = rot_deg
			throw_handle.linear_velocity = vel / 2.0
			throw_handle.angular_velocity = -ang_vel


@rpc("authority", "reliable", "call_remote")
func BroadcastTransitionDrain(energy: float, hydration: float) -> void:
	var gd := load("res://Resources/GameData.tres")
	if gd == null:
		return
	gd.energy -= energy
	gd.hydration -= hydration


func RequestPlayerDamage(target_peer_id: int, damage: int, penetration: int = 0) -> void:
	if not CoopAuthority.is_active():
		return
	if CoopAuthority.is_host():
		ApplyPlayerDamage.rpc(target_peer_id, damage, penetration)
	else:
		SubmitPlayerDamage.rpc_id(1, target_peer_id, damage, penetration)


@rpc("any_peer", "reliable", "call_remote")
func SubmitPlayerDamage(target_peer_id: int, damage: int, penetration: int) -> void:
	if not multiplayer.is_server():
		return
	ApplyPlayerDamage.rpc(target_peer_id, damage, penetration)


@rpc("authority", "reliable", "call_local")
func ApplyPlayerDamage(target_peer_id: int, damage: int, penetration: int) -> void:
	if target_peer_id != multiplayer.get_unique_id():
		return
	var coop := RTVCoop.get_instance()
	if coop == null or coop.players == null:
		return
	var character: Node = coop.players.GetLocalCharacter() if coop.players.has_method("GetLocalCharacter") else null
	if character and character.has_method("WeaponDamage"):
		character.WeaponDamage(damage, penetration)


func RequestPlayerExplosionDamage(target_peer_id: int) -> void:
	if not CoopAuthority.is_active():
		return
	ApplyPlayerExplosionDamage.rpc(target_peer_id)


@rpc("authority", "reliable", "call_local")
func ApplyPlayerExplosionDamage(target_peer_id: int) -> void:
	if target_peer_id != multiplayer.get_unique_id():
		return
	var coop := RTVCoop.get_instance()
	if coop == null or coop.players == null:
		return
	var character: Node = coop.players.GetLocalCharacter() if coop.players.has_method("GetLocalCharacter") else null
	if character and character.has_method("ExplosionDamage"):
		character.ExplosionDamage()
