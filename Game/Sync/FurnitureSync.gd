extends "res://mods/RTVCoop/Game/Sync/BaseSync.gd"




const FURNITURE_LERP_SPEED := 18.0
const FURNITURE_LERP_EPSILON := 0.01
const SPAWN_DEDUP_RADIUS := 0.35


signal furniture_token_received(token: int, fid: int)
signal furniture_lock_denied(fid: int)


var _next_furniture_token: int = 0
var _move_targets: Dictionary = {}
var _editing_locks: Dictionary = {}


func _sync_key() -> String:
	return "furniture"


func _players() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.players if coop else null


func _map() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.scene.get_map() if coop and coop.scene else null


func IsFurnitureLocked(fid: int) -> bool:
	return _editing_locks.has(fid)


func GetFurnitureLockOwner(fid: int) -> int:
	return int(_editing_locks.get(fid, 0))


func NextFurnitureToken() -> int:
	_next_furniture_token += 1
	return _next_furniture_token


func push_state_to(peer_id: int) -> void:
	var players := _players()
	if players == null:
		return
	BroadcastClearShelterFurniture.rpc_id(peer_id)
	for fid in players.worldFurniture:
		var root: Node = players.worldFurniture[fid]
		if not is_instance_valid(root) or not root.is_inside_tree():
			continue
		var component = _find_component(root)
		if component == null or not component.itemData:
			continue
		BroadcastFurnitureSpawn.rpc_id(peer_id, fid, component.itemData.file, root.global_position, root.global_rotation, root.scale)


func _find_furniture_by_id(fid: int) -> Node3D:
	var players := _players()
	if players == null:
		return null
	var wf: Dictionary = players.worldFurniture
	if wf.has(fid):
		var cached: Node = wf[fid]
		if is_instance_valid(cached):
			return cached
		wf.erase(fid)
	for root in _iter_furniture_roots():
		if root.has_meta("coop_furniture_id") and int(root.get_meta("coop_furniture_id")) == fid:
			wf[fid] = root
			return root
	return null


func _iter_furniture_roots() -> Array:
	var roots: Array = []
	var seen: Dictionary = {}
	for node in get_tree().get_nodes_in_group("Furniture"):
		var root: Node = node.owner
		if root == null or not is_instance_valid(root) or seen.has(root):
			continue
		seen[root] = true
		roots.append(root)
	return roots


func _find_component(root: Node):
	for child in root.get_children():
		if child is Furniture:
			return child
	return null


func _physics_process(delta: float) -> void:
	if _move_targets.is_empty():
		return
	var t: float = clampf(FURNITURE_LERP_SPEED * delta, 0.0, 1.0)
	var stale: Array = []
	for fid in _move_targets:
		var root := _find_furniture_by_id(fid)
		if root == null:
			stale.append(fid)
			continue
		var target: Dictionary = _move_targets[fid]
		if root.global_position.distance_to(target.pos) < FURNITURE_LERP_EPSILON:
			root.global_position = target.pos
			root.global_rotation = target.rot
			root.scale = target.scl
			stale.append(fid)
			continue
		root.global_position = root.global_position.lerp(target.pos, t)
		root.global_rotation.x = lerp_angle(root.global_rotation.x, target.rot.x, t)
		root.global_rotation.y = lerp_angle(root.global_rotation.y, target.rot.y, t)
		root.global_rotation.z = lerp_angle(root.global_rotation.z, target.rot.z, t)
		root.scale = root.scale.lerp(target.scl, t)
	for f in stale:
		_move_targets.erase(f)


@rpc("any_peer", "reliable", "call_remote")
func RequestFurnitureLock(fid: int) -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if _editing_locks.has(fid):
		DenyFurnitureLock.rpc_id(sender, fid)
		return
	_editing_locks[fid] = sender
	BroadcastFurnitureLock.rpc(fid, sender)


func HostLockFurniture(fid: int) -> void:
	if _editing_locks.has(fid):
		return
	_editing_locks[fid] = 1
	BroadcastFurnitureLock.rpc(fid, 1)


@rpc("authority", "reliable", "call_local")
func BroadcastFurnitureLock(fid: int, peer_id: int) -> void:
	_editing_locks[fid] = peer_id


@rpc("authority", "reliable", "call_remote")
func DenyFurnitureLock(fid: int) -> void:
	furniture_lock_denied.emit(fid)
	var coop := RTVCoop.get_instance()
	if coop and coop.events and coop.events.has_signal("furniture_lock_denied"):
		coop.events.emit_signal("furniture_lock_denied", fid)


@rpc("any_peer", "reliable", "call_remote")
func RequestStartPlacement(fid: int) -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if _editing_locks.has(fid) and int(_editing_locks[fid]) != sender:
		DenyFurnitureLock.rpc_id(sender, fid)
		return
	_editing_locks[fid] = sender
	BroadcastFurniturePlacementStart.rpc(fid, sender)


func HostStartPlacement(fid: int) -> void:
	if _editing_locks.has(fid) and int(_editing_locks[fid]) != 1:
		return
	_editing_locks[fid] = 1
	BroadcastFurniturePlacementStart.rpc(fid, 1)


@rpc("any_peer", "reliable", "call_remote")
func RequestEndPlacement(fid: int, pos: Vector3, rot: Vector3, scl: Vector3) -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if int(_editing_locks.get(fid, -1)) != sender:
		return
	_editing_locks.erase(fid)
	BroadcastFurniturePlacementEnd.rpc(fid, sender, pos, rot, scl)


func HostEndPlacement(fid: int, pos: Vector3, rot: Vector3, scl: Vector3) -> void:
	_editing_locks.erase(fid)
	BroadcastFurniturePlacementEnd.rpc(fid, 1, pos, rot, scl)


@rpc("authority", "reliable", "call_local")
func BroadcastFurniturePlacementStart(fid: int, peer_id: int) -> void:
	_editing_locks[fid] = peer_id
	if peer_id == multiplayer.get_unique_id():
		return
	var root := _find_furniture_by_id(fid)
	if root == null:
		return
	var component = _find_component(root)
	if component:
		_visual_start_placement(component)


@rpc("authority", "reliable", "call_local")
func BroadcastFurniturePlacementEnd(fid: int, peer_id: int, pos: Vector3, rot: Vector3, scl: Vector3) -> void:
	_editing_locks.erase(fid)
	_move_targets.erase(fid)
	if peer_id == multiplayer.get_unique_id():
		return
	var root := _find_furniture_by_id(fid)
	if root == null:
		return
	var component = _find_component(root)
	if component:
		_visual_end_placement(component, root, pos, rot, scl)


func _visual_start_placement(component) -> void:
	component.isMoving = true
	if component.indicator:
		component.indicator.hide()
	if component.hint:
		component.hint.hide()
	if component.mesh:
		for mat_idx in component.mesh.get_surface_override_material_count():
			component.mesh.set_surface_override_material(mat_idx, Furniture.furnitureMaterial)


func _visual_end_placement(component, root: Node3D, pos: Vector3, rot: Vector3, scl: Vector3) -> void:
	component.isMoving = false
	if component.indicator:
		component.indicator.show()
	if component.hint:
		component.hint.hide()
	if component.mesh:
		for mat_idx in component.mesh.get_surface_override_material_count():
			if mat_idx < component.sourceMaterials.size():
				component.mesh.set_surface_override_material(mat_idx, component.sourceMaterials[mat_idx])
	root.global_position = pos
	root.global_rotation = rot
	root.scale = scl


@rpc("any_peer", "reliable", "call_remote")
func RequestFurnitureUnlock(fid: int) -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if _editing_locks.get(fid, -1) == sender:
		_editing_locks.erase(fid)
		BroadcastFurnitureUnlock.rpc(fid)


func HostUnlockFurniture(fid: int) -> void:
	_editing_locks.erase(fid)
	BroadcastFurnitureUnlock.rpc(fid)


@rpc("authority", "reliable", "call_local")
func BroadcastFurnitureUnlock(fid: int) -> void:
	_editing_locks.erase(fid)


func ReleaseLockForPeer(peer_id: int) -> void:
	var to_release: Array = []
	for fid in _editing_locks:
		if int(_editing_locks[fid]) == peer_id:
			to_release.append(fid)
	for fid in to_release:
		_editing_locks.erase(fid)
		BroadcastFurnitureUnlock.rpc(fid)


@rpc("any_peer", "reliable", "call_remote")
func RequestFurnitureSpawn(token: int, file: String, pos: Vector3, rot: Vector3, scl: Vector3) -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	var players := _players()
	var fid: int = players.GenerateFurnitureId() if players and players.has_method("GenerateFurnitureId") else 0
	BroadcastFurnitureSpawn.rpc(fid, file, pos, rot, scl)
	DeliverFurnitureToken.rpc_id(sender, token, fid)


@rpc("authority", "reliable", "call_remote")
func DeliverFurnitureToken(token: int, fid: int) -> void:
	furniture_token_received.emit(token, fid)


@rpc("authority", "reliable", "call_local")
func BroadcastFurnitureSpawn(fid: int, file: String, pos: Vector3, rot: Vector3, scl: Vector3) -> void:
	var map := _map()
	if map == null:
		return
	var players := _players()
	if players == null:
		return
	if players.worldFurniture.has(fid):
		var existing: Node = players.worldFurniture[fid]
		if is_instance_valid(existing):
			existing.global_position = pos
			existing.global_rotation = rot
			existing.scale = scl
			return
		players.worldFurniture.erase(fid)
	var claimed := _claim_existing_at(file, pos, fid)
	if claimed:
		claimed.global_position = pos
		claimed.global_rotation = rot
		claimed.scale = scl
		if fid >= players.nextFurnitureId:
			players.nextFurnitureId = fid + 1
		return
	var scene = Database.get(file)
	if scene == null:
		return
	var root: Node = scene.instantiate()
	map.add_child(root)
	root.global_position = pos
	root.global_rotation = rot
	root.scale = scl
	root.set_meta("coop_furniture_id", fid)
	players.worldFurniture[fid] = root
	if fid >= players.nextFurnitureId:
		players.nextFurnitureId = fid + 1
	if root is LootContainer:
		root.set_meta("coop_container_id", fid)
		if not root.is_in_group("CoopLootContainer"):
			root.add_to_group("CoopLootContainer")


func _claim_existing_at(file: String, pos: Vector3, fid: int) -> Node3D:
	var players := _players()
	if players == null:
		return null
	for node in get_tree().get_nodes_in_group("Furniture"):
		var root: Node = node.owner
		if root == null or not is_instance_valid(root):
			continue
		if root.has_meta("coop_furniture_id"):
			continue
		if root.global_position.distance_to(pos) > SPAWN_DEDUP_RADIUS:
			continue
		var component = _find_component(root)
		if component == null or not component.itemData or component.itemData.file != file:
			continue
		root.set_meta("coop_furniture_id", fid)
		players.worldFurniture[fid] = root
		if root is LootContainer:
			root.set_meta("coop_container_id", fid)
			if not root.is_in_group("CoopLootContainer"):
				root.add_to_group("CoopLootContainer")
		return root
	return null


@rpc("any_peer", "unreliable_ordered", "call_remote")
func SubmitFurnitureMove(fid: int, pos: Vector3, rot: Vector3, scl: Vector3) -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	_move_targets[fid] = {"pos": pos, "rot": rot, "scl": scl}
	var players := _players()
	if players == null:
		return
	for peer_id in players.peer_names.keys():
		if peer_id == sender or peer_id == 1:
			continue
		BroadcastFurnitureMove.rpc_id(peer_id, fid, pos, rot, scl)


@rpc("authority", "unreliable_ordered", "call_remote")
func BroadcastFurnitureMove(fid: int, pos: Vector3, rot: Vector3, scl: Vector3) -> void:
	_move_targets[fid] = {"pos": pos, "rot": rot, "scl": scl}


@rpc("any_peer", "reliable", "call_remote")
func SubmitFurnitureRemove(fid: int) -> void:
	if not multiplayer.is_server():
		return
	BroadcastFurnitureRemove.rpc(fid)


# v0.9: 클라가 가구 catalog 회수 시 호출. 호스트가 worldFurniture에 fid 있는지 검증 후
# 모든 peer에 노드 free broadcast. 같은 fid 두 번째 요청은 reject — 시리얼 복제 방지.
@rpc("any_peer", "reliable", "call_remote")
func SubmitFurnitureClaim(fid: int) -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	var players_ref := _players()
	print("[FurnitureSync/HOST] SubmitFurnitureClaim from=%d fid=%d" % [sender, fid])
	if players_ref == null:
		return
	if not players_ref.worldFurniture.has(fid):
		print("[FurnitureSync/HOST] SubmitFurnitureClaim REJECTED — fid not tracked (already claimed?)")
		return
	# BroadcastFurnitureRemove는 call_local — 호스트 자체 + 다른 모든 peer 노드 free
	# claimer 측은 이미 vanilla로 free됐으므로 idempotent (root invalid → 무해)
	BroadcastFurnitureRemove.rpc(fid)


@rpc("authority", "reliable", "call_local")
func BroadcastFurnitureRemove(fid: int) -> void:
	var root := _find_furniture_by_id(fid)
	if root:
		root.queue_free()
	var players := _players()
	if players:
		players.worldFurniture.erase(fid)


@rpc("authority", "reliable", "call_remote")
func BroadcastClearShelterFurniture() -> void:
	var furnitures: Array = get_tree().get_nodes_in_group("Furniture")
	for furn_node in furnitures:
		if not is_instance_valid(furn_node):
			continue
		if furn_node.owner and is_instance_valid(furn_node.owner):
			furn_node.owner.global_position.y = -100.0
			furn_node.queue_free()
