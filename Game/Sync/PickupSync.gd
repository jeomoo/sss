extends "res://mods/RTVCoop/Game/Sync/BaseSync.gd"




const PICKUP_LERP_SPEED := 18.0
const PICKUP_LERP_EPSILON := 0.01


signal placement_token_received(token: int, uuid: int)


var _pickup_targets: Dictionary = {}
var _next_placement_token: int = 0


func _sync_key() -> String:
	return "pickup"


func _players() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.players if coop else null


func _map() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.scene.get_map() if coop and coop.scene else null


func _slot_serializer() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.get_sync("slot_serializer") if coop else null


func _container_sync() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.get_sync("container") if coop else null


func _physics_process(delta: float) -> void:
	_lerp_pickup_targets(delta)


func _lerp_pickup_targets(delta: float) -> void:
	if _pickup_targets.is_empty():
		return
	var players := _players()
	if players == null:
		return
	var t: float = clampf(PICKUP_LERP_SPEED * delta, 0.0, 1.0)
	var stale: Array = []
	for uuid in _pickup_targets:
		if not players.worldItems.has(uuid):
			stale.append(uuid)
			continue
		var pickup: Node = players.worldItems[uuid]
		if not is_instance_valid(pickup):
			stale.append(uuid)
			continue
		var target: Dictionary = _pickup_targets[uuid]
		if target.frozen and pickup.global_position.distance_to(target.pos) < PICKUP_LERP_EPSILON:
			pickup.global_position = target.pos
			pickup.global_rotation = target.rot
			pickup.freeze = true
			stale.append(uuid)
			continue
		pickup.global_position = pickup.global_position.lerp(target.pos, t)
		pickup.global_rotation.x = lerp_angle(pickup.global_rotation.x, target.rot.x, t)
		pickup.global_rotation.y = lerp_angle(pickup.global_rotation.y, target.rot.y, t)
		pickup.global_rotation.z = lerp_angle(pickup.global_rotation.z, target.rot.z, t)
		if target.frozen:
			pickup.freeze = true
		else:
			if pickup.has_method("Unfreeze"):
				pickup.Unfreeze()
			else:
				pickup.freeze = false
	for u in stale:
		_pickup_targets.erase(u)


func NextPlacementToken() -> int:
	_next_placement_token += 1
	return _next_placement_token


func RequestPickup(uuid: int) -> void:
	if not CoopAuthority.is_active():
		return
	var players := _players()
	if players == null or not players.worldItems.has(uuid):
		return
	var pickup: Node = players.worldItems[uuid]
	if not is_instance_valid(pickup):
		players.worldItems.erase(uuid)
		return
	var iface: Node = players.GetLocalInterface()
	if iface == null:
		return

	var added: bool = false
	if iface.AutoStack(pickup.slotData, iface.inventoryGrid):
		added = true
	elif iface.Create(pickup.slotData, iface.inventoryGrid, false):
		added = true

	if not added:
		if iface.has_method("PlayError"):
			iface.PlayError()
		return

	iface.UpdateStats(false)
	if pickup.has_method("PlayPickup"):
		pickup.PlayPickup()

	players.worldItems.erase(uuid)
	pickup.queue_free()

	if CoopAuthority.is_host():
		BroadcastPickupRemove.rpc(uuid)
	else:
		SubmitPickupRemove.rpc_id(1, uuid)


@rpc("any_peer", "reliable", "call_remote")
func SubmitPickupRemove(uuid: int) -> void:
	if not multiplayer.is_server():
		return
	BroadcastPickupRemove.rpc(uuid)


@rpc("authority", "reliable", "call_local")
func BroadcastPickupRemove(uuid: int) -> void:
	var players := _players()
	if players == null or not players.worldItems.has(uuid):
		return
	var pickup: Node = players.worldItems[uuid]
	if is_instance_valid(pickup):
		pickup.queue_free()
	players.worldItems.erase(uuid)


func RequestPickupSpawn(slot_dict: Dictionary, pos: Vector3, rot_deg: Vector3, vel: Vector3) -> void:
	if not CoopAuthority.is_active():
		return
	var players := _players()
	if players == null:
		return
	if CoopAuthority.is_host():
		var uuid: int = players.GenerateUuid()
		BroadcastPickupSpawn.rpc(uuid, slot_dict, pos, rot_deg, vel)
	else:
		SubmitPickupSpawn.rpc_id(1, slot_dict, pos, rot_deg, vel)


@rpc("any_peer", "reliable", "call_remote")
func SubmitPickupSpawn(slot_dict: Dictionary, pos: Vector3, rot_deg: Vector3, vel: Vector3) -> void:
	if not multiplayer.is_server():
		return
	var players := _players()
	if players == null:
		return
	var uuid: int = players.GenerateUuid()
	BroadcastPickupSpawn.rpc(uuid, slot_dict, pos, rot_deg, vel)


@rpc("authority", "reliable", "call_local")
func BroadcastPickupSpawn(uuid: int, slot_dict: Dictionary, pos: Vector3, rot_deg: Vector3, vel: Vector3) -> void:
	var file: String = slot_dict.get("file", "")
	if file == "":
		return
	var scene = Database.get(file)
	if scene == null:
		push_warning("[PickupSync] Pickup not in Database: %s" % file)
		return
	var map := _map()
	if map == null:
		return
	var players := _players()
	if players == null:
		return

	var pickup: Node = scene.instantiate()
	map.add_child(pickup)
	pickup.position = pos
	pickup.rotation_degrees = rot_deg
	pickup.linear_velocity = vel
	if pickup.has_method("Unfreeze"):
		pickup.Unfreeze()

	var ss := _slot_serializer()
	if ss:
		ss.ApplySlotDictToPickup(pickup, slot_dict)

	pickup.set_meta("network_uuid", uuid)
	players.worldItems[uuid] = pickup

	if uuid >= players.nextUuid:
		players.nextUuid = uuid + 1


@rpc("authority", "reliable", "call_remote")
func BroadcastPickupMove(uuid: int, pos: Vector3, rot: Vector3, frozen: bool = true) -> void:
	_pickup_targets[uuid] = {"pos": pos, "rot": rot, "frozen": frozen}


@rpc("any_peer", "reliable", "call_remote")
func SubmitPickupMove(uuid: int, pos: Vector3, rot: Vector3, frozen: bool = true) -> void:
	if not multiplayer.is_server():
		return
	_pickup_targets[uuid] = {"pos": pos, "rot": rot, "frozen": frozen}
	BroadcastPickupMove.rpc(uuid, pos, rot, frozen)


@rpc("any_peer", "reliable", "call_remote")
func RequestPlacementSpawn(token: int, slot_dict: Dictionary, initial_pos: Vector3) -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	var players := _players()
	if players == null:
		return
	var uuid: int = players.GenerateUuid()
	BroadcastPickupSpawn.rpc(uuid, slot_dict, initial_pos, Vector3.ZERO, Vector3.ZERO)
	DeliverPlacementToken.rpc_id(sender, token, uuid)


@rpc("authority", "reliable", "call_remote")
func DeliverPlacementToken(token: int, uuid: int) -> void:
	placement_token_received.emit(token, uuid)
	var players := _players()
	if players:
		players.placement_token_received.emit(token, uuid)


@rpc("any_peer", "reliable", "call_remote")
func SubmitDeathContainer(pos: Vector3, items: Array) -> void:
	if not multiplayer.is_server():
		return
	var players := _players()
	var stash_cid: int = players.nextContainerId if players else 0
	if players:
		players.nextContainerId += 1
	SpawnDeathContainer.rpc(pos, items, stash_cid)


@rpc("authority", "reliable", "call_local")
func SpawnDeathContainer(pos: Vector3, items: Array, stash_cid: int = -1) -> void:
	var map := _map()
	if map == null:
		return
	var scene = Database.get("Crate_Military")
	if scene == null:
		return
	var ss := _slot_serializer()
	var container: Node = scene.instantiate()
	map.add_child(container)
	# v0.7.1: +0.5m 오프셋 제거. CharacterHooks가 이미 ground raycast로 ground+0.05m 보냄.
	# 여기서 또 +0.5 더하면 총 0.55m 공중에 떠있게 됨 (사진 증상).
	container.global_position = pos

	container.containerSize = Vector2(16, 16)
	container.loot.clear()
	container.storage.clear()
	if ss:
		for dict in items:
			var slot = ss.DeserializeSlotData(dict)
			if slot and slot.itemData:
				container.loot.append(slot)
	container.storaged = false
	container.containerName = "Death Stash"

	var mesh: Node = container.get_node_or_null("Mesh")
	if mesh:
		mesh.hide()

	var backpack_scene = Database.get("Duffel_Retro")
	if backpack_scene:
		var visual: Node = backpack_scene.instantiate()
		visual.collision_layer = 0
		visual.collision_mask = 0
		if "freeze" in visual:
			visual.freeze = true
		if visual.is_in_group("Item"):
			visual.remove_from_group("Item")
		container.add_child(visual)

	if not container.is_in_group("CoopLootContainer"):
		container.add_to_group("CoopLootContainer")
	if stash_cid >= 0:
		container.set_meta("coop_container_id", stash_cid)


@rpc("any_peer", "reliable", "call_remote")
func SubmitDeathStashRemove(cid: int) -> void:
	if not multiplayer.is_server():
		return
	BroadcastDeathStashRemove.rpc(cid)


@rpc("authority", "reliable", "call_local")
func BroadcastDeathStashRemove(cid: int) -> void:
	var cs := _container_sync()
	if cs == null:
		return
	var container: Node = cs._find_container_by_id(cid)
	if container and container.containerName == "Death Stash":
		container.queue_free()


func NotifyPlayerDeath(peer_id: int) -> void:
	if not CoopAuthority.is_active():
		return
	if CoopAuthority.is_host():
		BroadcastPlayerDeath.rpc(peer_id)
	else:
		SubmitPlayerDeath.rpc_id(1, peer_id)


@rpc("any_peer", "reliable", "call_remote")
func SubmitPlayerDeath(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	BroadcastPlayerDeath.rpc(peer_id)


@rpc("authority", "reliable", "call_local")
func BroadcastPlayerDeath(peer_id: int) -> void:
	if peer_id == multiplayer.get_unique_id():
		return
	var players := _players()
	if players == null or not players.remote_players.has(peer_id):
		return
	var puppet: Node = players.remote_players[peer_id]
	if is_instance_valid(puppet) and puppet.has_method("OnDeath"):
		puppet.OnDeath()


func NotifyPlayerRespawn(peer_id: int) -> void:
	if not CoopAuthority.is_active():
		return
	if CoopAuthority.is_host():
		BroadcastPlayerRespawn.rpc(peer_id)
	else:
		SubmitPlayerRespawn.rpc_id(1, peer_id)


@rpc("any_peer", "reliable", "call_remote")
func SubmitPlayerRespawn(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	BroadcastPlayerRespawn.rpc(peer_id)


@rpc("authority", "reliable", "call_local")
func BroadcastPlayerRespawn(peer_id: int) -> void:
	if peer_id == multiplayer.get_unique_id():
		return
	var players := _players()
	if players == null or not players.remote_players.has(peer_id):
		return
	var puppet: Node = players.remote_players[peer_id]
	if is_instance_valid(puppet) and puppet.has_method("OnRespawn"):
		puppet.OnRespawn()
