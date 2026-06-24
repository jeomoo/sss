extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

var _pending_placement_token: int = -1
var _pending_furniture_token: int = -1
var _pending_furniture_storage: Array = []


func _setup_hooks() -> void:
	CoopHook.register_replace_or_post(self, "interface-complete", _replace_interface_complete, _post_interface_complete)
	CoopHook.register(self, "interface-close-pre", _on_interface_close_pre)
	CoopHook.register(self, "interface-close-post", _on_interface_close_post)
	CoopHook.register_replace_or_post(self, "interface-drop", _replace_interface_drop, _post_interface_drop)
	CoopHook.register_replace_or_post(self, "interface-contextplace", _replace_interface_context_place, _post_interface_context_place)


func _replace_interface_complete(data) -> void:
	var iface := CoopHook.caller()
	if iface == null or not CoopAuthority.is_active() or quest == null:
		return
	if not (data is TaskData) or iface.trader == null:
		return
	var trader_name: String = iface.trader.traderData.name

	if CoopAuthority.is_host():
		print("[QuestSync/HOST] interface-complete fired trader=%s task=%s" % [trader_name, data.name])
		if not iface.trader.tasksCompleted.has(data.name):
			iface.trader.tasksCompleted.append(data.name)
		iface.trader.PlayTraderTask()
		Loader.Message("임무 완료: " + data.name, Color.GREEN)
		if not iface.gameData.tutorial:
			Loader.SaveTrader(trader_name)
			Loader.UpdateProgression()
		quest.coop_trader_state[trader_name] = iface.trader.tasksCompleted.duplicate()
		quest._persist_host()
		quest.BroadcastTaskCompletion.rpc(trader_name, data.name)
	else:
		print("[QuestSync/CLIENT] interface-complete fired trader=%s task=%s" % [trader_name, data.name])
		if not quest.has_state_for(trader_name):
			print("[QuestSync/CLIENT] BLOCKED — no state for trader=%s (push_full_state_to never arrived?)" % trader_name)
			Loader.Message("상인 상태 동기화 중… 잠시 후 다시 시도하세요.", Color.ORANGE)
			CoopHook.skip_super()
			return
		if quest.get_completed(trader_name).has(data.name):
			Loader.Message("이미 완료된 임무입니다.", Color.ORANGE)
			CoopHook.skip_super()
			return
		if not iface.trader.tasksCompleted.has(data.name):
			iface.trader.tasksCompleted.append(data.name)
		iface.trader.PlayTraderTask()
		Loader.Message("임무 완료: " + data.name, Color.GREEN)
		print("[QuestSync/CLIENT] sending SubmitTaskCompletion to host trader=%s task=%s" % [trader_name, data.name])
		quest.SubmitTaskCompletion.rpc_id(1, trader_name, data.name)

	iface.UpdateTraderInfo()
	iface.DestroyInputItems(data)
	iface.GetOutputItems()
	iface.ResetInput()
	CoopHook.skip_super()


func _post_interface_complete(_data) -> void:
	pass


func _on_interface_close_pre() -> void:
	var iface := CoopHook.caller()
	if iface == null or not CoopAuthority.is_active() or players == null:
		return
	if "container" in iface and iface.container:
		if iface.has_method("StorageContainerGrid"):
			iface.StorageContainerGrid()
		players.SyncContainerStorage(iface.container)
		players.ReleaseContainerLock(iface.container)
		if "containerName" in iface.container and iface.container.containerName == "Death Stash":
			var is_empty: bool = iface.container.storage.size() == 0 if iface.container.storaged else iface.container.loot.size() == 0
			if is_empty:
				var cid: int = int(iface.container.get_meta("coop_container_id", 0))
				if cid == 0 and container:
					cid = container._node_id(iface.container)
				if pickup:
					if CoopAuthority.is_host():
						pickup.BroadcastDeathStashRemove.rpc(cid)
					else:
						pickup.SubmitDeathStashRemove.rpc_id(1, cid)


func _on_interface_close_post() -> void:
	if CoopAuthority.is_active() and CoopAuthority.is_client() and players:
		players.SaveClientCharacterBuffer()


func _replace_interface_drop(target) -> void:
	var iface := CoopHook.caller()
	if iface == null or not CoopAuthority.is_active() or target == null:
		return
	var file_scene = Database.get(target.slotData.itemData.file)
	if file_scene == null:
		target.queue_free()
		if iface.has_method("PlayDrop"):
			iface.PlayDrop()
		CoopHook.skip_super()
		return

	var drop_direction: Vector3
	var drop_position: Vector3
	var drop_rotation: Vector3
	var drop_force: float = 2.5

	if iface.trader:
		if iface.hoverGrid == null:
			drop_direction = iface.trader.global_transform.basis.z
			drop_position = (iface.trader.global_position + Vector3(0, 1.0, 0)) + drop_direction / 2
			drop_rotation = Vector3(-25, iface.trader.rotation_degrees.y + 180 + randf_range(-45, 45), 45)
	else:
		if iface.hoverGrid == null or iface.hoverGrid.get_parent().name == "Inventory":
			drop_direction = -iface.camera.global_transform.basis.z
			drop_position = (iface.camera.global_position + Vector3(0, -0.25, 0)) + drop_direction / 2
			drop_rotation = Vector3(-25, iface.camera.rotation_degrees.y + 180 + randf_range(-45, 45), 45)
		elif iface.hoverGrid.get_parent().name == "Container":
			drop_direction = iface.container.global_transform.basis.z
			drop_position = (iface.container.global_position + Vector3(0, 0.5, 0)) + drop_direction / 2
			drop_rotation = Vector3(-25, iface.container.rotation_degrees.y + 180 + randf_range(-45, 45), 45)

	if target.slotData.itemData.stackable:
		var box_size: int = target.slotData.itemData.defaultAmount
		var boxes_needed: int = ceil(float(target.slotData.amount) / float(box_size))
		var amount_left: int = target.slotData.amount
		for _box in boxes_needed:
			var amount_for_box: int
			if amount_left > box_size:
				amount_left -= box_size
				amount_for_box = box_size
			else:
				amount_for_box = amount_left
			var slot_dict := {
				"file": target.slotData.itemData.file,
				"amount": amount_for_box,
				"condition": target.slotData.condition,
				"state": target.slotData.state,
			}
			if pickup:
				pickup.RequestPickupSpawn(slot_dict, drop_position, drop_rotation, drop_direction * drop_force)
	else:
		if slot and pickup:
			var slot_dict: Dictionary = slot.SerializeSlotData(target.slotData)
			pickup.RequestPickupSpawn(slot_dict, drop_position, drop_rotation, drop_direction * drop_force)

	target.reparent(iface)
	target.queue_free()
	if iface.has_method("PlayDrop"):
		iface.PlayDrop()
	iface.UpdateStats(true)
	CoopHook.skip_super()


func _post_interface_drop(_target) -> void:
	pass


func _replace_interface_context_place() -> void:
	var iface := CoopHook.caller()
	if iface == null or not CoopAuthority.is_active():
		return
	if iface.gameData.decor:
		CoopHook.skip_super()
		_coop_context_place_furniture(iface)
		return
	if not CoopAuthority.is_host():
		CoopHook.skip_super()
		_coop_client_context_place(iface)
		return

	var file_scene = Database.get(iface.contextItem.slotData.itemData.file)
	if file_scene == null or players == null or pickup == null or slot == null:
		return
	var uuid: int = players.GenerateUuid()
	var slot_dict: Dictionary = slot.SerializeSlotData(iface.contextItem.slotData)
	var initial_pos: Vector3 = iface.camera.global_position + (-iface.camera.global_transform.basis.z * 1.0)
	pickup.BroadcastPickupSpawn.rpc(uuid, slot_dict, initial_pos, Vector3.ZERO, Vector3.ZERO)

	if not players.worldItems.has(uuid):
		return
	var p: Node = players.worldItems[uuid]
	iface.placer.ContextPlace(p)
	_finish_context_place(iface)
	CoopHook.skip_super()


func _post_interface_context_place() -> void:
	pass


func _coop_context_place_furniture(iface: Node) -> void:
	if players == null or furniture == null:
		return
	var filename: String = iface.contextItem.slotData.itemData.file
	var scene = Database.get(filename)
	if scene == null:
		return
	var initial_pos: Vector3 = iface.camera.global_position + (-iface.camera.global_transform.basis.z * 2.0)

	if CoopAuthority.is_host():
		var fid: int = players.GenerateFurnitureId()
		furniture.BroadcastFurnitureSpawn.rpc(fid, filename, initial_pos, Vector3.ZERO, Vector3.ONE)
		var root: Node = players._find_furniture_by_id(fid)
		if root == null:
			return
		if root is LootContainer and iface.contextItem.slotData.storage.size() != 0:
			root.storage = iface.contextItem.slotData.storage
			root.storaged = true
			players.SyncContainerStorage(root)
		iface.placer.ContextPlace(root)
	else:
		if _pending_furniture_token != -1 and furniture.furniture_token_received.is_connected(_on_furniture_token_received):
			furniture.furniture_token_received.disconnect(_on_furniture_token_received)
		_pending_furniture_token = furniture.NextFurnitureToken()
		_pending_furniture_storage = iface.contextItem.slotData.storage.duplicate() if iface.contextItem.slotData.storage.size() > 0 else []
		furniture.furniture_token_received.connect(_on_furniture_token_received.bind(iface))
		furniture.RequestFurnitureSpawn.rpc_id(1, _pending_furniture_token, filename, initial_pos, Vector3.ZERO, Vector3.ONE)
	_finish_context_place(iface)


func _on_furniture_token_received(token: int, fid: int, iface: Node = null) -> void:
	if token != _pending_furniture_token:
		return
	_pending_furniture_token = -1
	if furniture and furniture.furniture_token_received.is_connected(_on_furniture_token_received):
		furniture.furniture_token_received.disconnect(_on_furniture_token_received)
	if players == null:
		_pending_furniture_storage = []
		return
	var root: Node = players._find_furniture_by_id(fid)
	if root == null:
		_pending_furniture_storage = []
		return
	if root is LootContainer and _pending_furniture_storage.size() > 0:
		root.storage = _pending_furniture_storage
		root.storaged = true
		players.SyncContainerStorage(root)
	_pending_furniture_storage = []
	if iface and is_instance_valid(iface) and iface.placer:
		iface.placer.ContextPlace(root)


func _coop_client_context_place(iface: Node) -> void:
	if players == null or pickup == null or slot == null:
		return
	var slot_dict: Dictionary = slot.SerializeSlotData(iface.contextItem.slotData)
	var initial_pos: Vector3 = iface.camera.global_position + (-iface.camera.global_transform.basis.z * 1.0)

	if _pending_placement_token != -1 and pickup.placement_token_received.is_connected(_on_placement_token_received):
		pickup.placement_token_received.disconnect(_on_placement_token_received)
	_pending_placement_token = pickup.NextPlacementToken()
	pickup.placement_token_received.connect(_on_placement_token_received.bind(iface))
	pickup.RequestPlacementSpawn.rpc_id(1, _pending_placement_token, slot_dict, initial_pos)
	_finish_context_place(iface)


func _on_placement_token_received(token: int, uuid: int, iface: Node = null) -> void:
	if token != _pending_placement_token:
		return
	_pending_placement_token = -1
	if pickup and pickup.placement_token_received.is_connected(_on_placement_token_received):
		pickup.placement_token_received.disconnect(_on_placement_token_received)
	if players == null or not players.worldItems.has(uuid):
		return
	var p: Node = players.worldItems[uuid]
	if not is_instance_valid(p):
		return
	if iface and is_instance_valid(iface) and iface.placer:
		iface.placer.ContextPlace(p)


func _finish_context_place(iface: Node) -> void:
	if iface.contextGrid:
		iface.contextGrid.Pick(iface.contextItem)
	iface.contextItem.reparent(iface)
	iface.contextItem.queue_free()
	if iface.contextSlot:
		iface.rigManager.UpdateRig(false)
		iface.contextSlot.hint.show()
	iface.Reset()
	iface.HideContext()
	iface.PlayClick()
	var scene: Node = get_tree().current_scene
	var ui_mgr: Node = scene.get_node_or_null("Core/UI") if scene else null
	if ui_mgr and ui_mgr.has_method("ToggleInterface"):
		ui_mgr.ToggleInterface()
