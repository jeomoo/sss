class_name CoopCharacterBuffer extends Node



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")
const RTVCoop = preload("res://mods/RTVCoop/Game/Coop.gd")
const SlotSerializer = preload("res://mods/RTVCoop/Game/Sync/SlotSerializer.gd")

const COOP_SAVE_INTERVAL := 60.0


var _players: Node
var _loading: bool = false
var _save_timer: float = 0.0


func _enter_tree() -> void:
	_players = get_parent()


func _physics_process(delta: float) -> void:
	if not CoopAuthority.is_active():
		return
	if multiplayer.is_server() or _players == null or not _players.scene_ready:
		return
	_save_timer += delta
	if _save_timer >= COOP_SAVE_INTERVAL:
		_save_timer = 0.0
		if not _players.gameData.isDead and not _players.gameData.isCaching:
			Save()


func IsLoading() -> bool:
	return _loading


func Clear() -> void:
	var path: String = _save_path(multiplayer.get_unique_id())
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func Save() -> void:
	if _players == null or multiplayer.is_server() or _loading or not _players.scene_ready:
		return
	var iface: Node = _players.GetLocalInterface()
	if iface == null:
		return
	var gd: Resource = _players.gameData
	var character = CharacterSave.new()
	character.initialSpawn = false
	character.startingKit = null
	_copy_stats_to(character, gd)

	character.inventory.clear()
	character.equipment.clear()
	character.catalog.clear()

	for item in iface.inventoryGrid.get_children():
		var new_slot = SlotData.new()
		new_slot.Update(item.slotData)
		new_slot.GridSave(item.position, item.rotated)
		character.inventory.append(new_slot)

	for equipment_slot in iface.equipment.get_children():
		if equipment_slot is Slot and equipment_slot.get_child_count() != 0:
			var slot_item = equipment_slot.get_child(0)
			var new_slot = SlotData.new()
			new_slot.Update(slot_item.slotData)
			new_slot.slot = equipment_slot.name
			character.equipment.append(new_slot)

	for item in iface.catalogGrid.get_children():
		var new_slot = SlotData.new()
		new_slot.Update(item.slotData)
		new_slot.GridSave(item.position, item.rotated)
		if item.slotData.storage.size() != 0:
			new_slot.storage = item.slotData.storage
		character.catalog.append(new_slot)

	_players.coopCharacterBuffer = character
	SubmitClientCharacterData.rpc_id(1, Serialize(character))


func Load() -> void:
	if _players == null or multiplayer.is_server() or _players.coopCharacterBuffer == null:
		return
	_loading = true
	var tree = get_tree()
	if tree == null:
		_loading = false
		return
	await tree.create_timer(0.1).timeout
	if not is_instance_valid(self) or get_tree() == null:
		_loading = false
		return
	var iface: Node = _players.GetLocalInterface()
	if iface == null:
		_loading = false
		return
	var scene: Node = get_tree().current_scene
	var rig_manager: Node = scene.get_node_or_null("Core/Camera/Manager") if scene else null
	var flashlight: Node = scene.get_node_or_null("Core/Camera/Flashlight") if scene else null
	var nvg: Node = scene.get_node_or_null("Core/UI/NVG") if scene else null
	if rig_manager == null:
		_loading = false
		return
	var character = _players.coopCharacterBuffer

	for child in iface.inventoryGrid.get_children():
		iface.inventoryGrid.remove_child(child)
		child.queue_free()
	for child in iface.catalogGrid.get_children():
		iface.catalogGrid.remove_child(child)
		child.queue_free()
	for equipment_slot in iface.equipment.get_children():
		if equipment_slot is Slot:
			for child in equipment_slot.get_children():
				equipment_slot.remove_child(child)
				child.queue_free()
	rig_manager.ClearRig()
	tree = get_tree()
	if tree == null:
		_loading = false
		return
	await tree.process_frame
	if not is_instance_valid(self) or get_tree() == null:
		_loading = false
		return

	for slot_data in character.inventory:
		if slot_data and slot_data.itemData:
			iface.LoadGridItem(slot_data, iface.inventoryGrid, slot_data.gridPosition)
	for slot_data in character.equipment:
		if slot_data and slot_data.itemData:
			iface.LoadSlotItem(slot_data, slot_data.slot)
	for slot_data in character.catalog:
		if slot_data and slot_data.itemData:
			iface.LoadGridItem(slot_data, iface.catalogGrid, slot_data.gridPosition)
	iface.UpdateStats(false)

	var gd: Resource = _players.gameData
	_copy_stats_from(gd, character)

	if gd.primary:
		rig_manager.LoadPrimary()
		gd.weaponPosition = character.weaponPosition
	elif gd.secondary:
		rig_manager.LoadSecondary()
		gd.weaponPosition = character.weaponPosition
	elif gd.knife:
		rig_manager.LoadKnife()
	elif gd.grenade1:
		rig_manager.LoadGrenade1()
	elif gd.grenade2:
		rig_manager.LoadGrenade2()

	if gd.flashlight and flashlight:
		flashlight.Load()
	if gd.NVG and nvg:
		nvg.Load()
	_loading = false


func GiveStarterKit() -> void:
	if multiplayer.is_server() or _players == null:
		return
	var tree = get_tree()
	if tree == null:
		return
	await tree.create_timer(0.1).timeout
	if not is_instance_valid(self) or get_tree() == null:
		return
	var iface: Node = _players.GetLocalInterface()
	if iface == null or not Loader or Loader.startingKits.size() == 0:
		return
	var kit = Loader.startingKits.pick_random()
	if kit == null or kit.items.size() == 0:
		return
	for item in kit.items:
		var new_slot = SlotData.new()
		new_slot.itemData = item
		if new_slot.itemData.stackable:
			new_slot.amount = new_slot.itemData.defaultAmount
		iface.Create(new_slot, iface.inventoryGrid, false)
	iface.UpdateStats(false)


func Serialize(character) -> Dictionary:
	var ss: SlotSerializer = _slot_serializer()
	var data: Dictionary = {
		"health": character.health, "energy": character.energy,
		"hydration": character.hydration, "mental": character.mental,
		"temperature": character.temperature, "bodyStamina": character.bodyStamina,
		"armStamina": character.armStamina, "overweight": character.overweight,
		"starvation": character.starvation, "dehydration": character.dehydration,
		"bleeding": character.bleeding, "fracture": character.fracture,
		"burn": character.burn, "frostbite": character.frostbite,
		"insanity": character.insanity, "rupture": character.rupture,
		"headshot": character.headshot, "cat": character.cat,
		"catFound": character.catFound, "catDead": character.catDead,
		"primary": character.primary, "secondary": character.secondary,
		"knife": character.knife, "grenade1": character.grenade1,
		"grenade2": character.grenade2, "flashlight": character.flashlight,
		"NVG": character.NVG, "weaponPosition": character.weaponPosition,
	}
	data["inventory"] = []
	data["equipment"] = []
	data["catalog"] = []
	if ss:
		for slot in character.inventory:
			var d = ss.SerializeSlotData(slot)
			d["gridPosition"] = slot.gridPosition
			d["gridRotated"] = slot.gridRotated
			data["inventory"].append(d)
		for slot in character.equipment:
			var d = ss.SerializeSlotData(slot)
			d["slotName"] = slot.slot
			data["equipment"].append(d)
		for slot in character.catalog:
			var d = ss.SerializeSlotData(slot)
			d["gridPosition"] = slot.gridPosition
			d["gridRotated"] = slot.gridRotated
			data["catalog"].append(d)
	return data


func Deserialize(data: Dictionary):
	var ss: SlotSerializer = _slot_serializer()
	var character = CharacterSave.new()
	character.initialSpawn = false
	character.startingKit = null
	character.health = data.get("health", 100.0)
	character.energy = data.get("energy", 100.0)
	character.hydration = data.get("hydration", 100.0)
	character.mental = data.get("mental", 100.0)
	character.temperature = data.get("temperature", 100.0)
	character.bodyStamina = data.get("bodyStamina", 100.0)
	character.armStamina = data.get("armStamina", 100.0)
	character.overweight = data.get("overweight", false)
	character.starvation = data.get("starvation", false)
	character.dehydration = data.get("dehydration", false)
	character.bleeding = data.get("bleeding", false)
	character.fracture = data.get("fracture", false)
	character.burn = data.get("burn", false)
	character.frostbite = data.get("frostbite", false)
	character.insanity = data.get("insanity", false)
	character.rupture = data.get("rupture", false)
	character.headshot = data.get("headshot", false)
	character.cat = data.get("cat", 100.0)
	character.catFound = data.get("catFound", false)
	character.catDead = data.get("catDead", false)
	character.primary = data.get("primary", false)
	character.secondary = data.get("secondary", false)
	character.knife = data.get("knife", false)
	character.grenade1 = data.get("grenade1", false)
	character.grenade2 = data.get("grenade2", false)
	character.flashlight = data.get("flashlight", false)
	character.NVG = data.get("NVG", false)
	character.weaponPosition = data.get("weaponPosition", 1)
	character.inventory.clear()
	character.equipment.clear()
	character.catalog.clear()
	if ss:
		for d in data.get("inventory", []):
			var slot = ss.DeserializeSlotData(d)
			if slot:
				slot.gridPosition = d.get("gridPosition", Vector2.ZERO)
				slot.gridRotated = d.get("gridRotated", false)
				character.inventory.append(slot)
		for d in data.get("equipment", []):
			var slot = ss.DeserializeSlotData(d)
			if slot:
				slot.slot = d.get("slotName", "")
				character.equipment.append(slot)
		for d in data.get("catalog", []):
			var slot = ss.DeserializeSlotData(d)
			if slot:
				slot.gridPosition = d.get("gridPosition", Vector2.ZERO)
				slot.gridRotated = d.get("gridRotated", false)
				character.catalog.append(slot)
	return character


func TryDeliverTo(peer_id: int) -> void:
	var path: String = _save_path(peer_id)
	if not FileAccess.file_exists(path):
		GrantStarterKit.rpc_id(peer_id)
		return
	var character = load(path)
	if character == null:
		GrantStarterKit.rpc_id(peer_id)
		return
	DeliverCoopSave.rpc_id(peer_id, Serialize(character))


func BroadcastNewGame() -> void:
	if not multiplayer.is_server():
		return
	# 새 게임 시 접속 중인 클라들의 in-memory 버퍼만 비움.
	# 디스크 세이브는 vanilla FormatSave(루트 .tres 삭제) + MSS wipe_slot이 처리.
	# (코옵 세이브가 user:// 루트라 슬롯별 관리·새게임 삭제에 자동 포함됨 — v0.13.67)
	for peer_id in multiplayer.get_peers():
		ClearCoopSaveBuffer.rpc_id(peer_id)


func SetLoading(value: bool) -> void:
	_loading = value


@rpc("any_peer", "reliable", "call_remote")
func SubmitClientCharacterData(data: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	var character = Deserialize(data)
	ResourceSaver.save(character, _save_path(sender))


@rpc("authority", "reliable", "call_remote")
func DeliverCoopSave(data: Dictionary) -> void:
	if _players:
		_players.coopCharacterBuffer = Deserialize(data)


@rpc("authority", "reliable", "call_remote")
func GrantStarterKit() -> void:
	GiveStarterKit()


@rpc("authority", "reliable", "call_remote")
func ClearCoopSaveBuffer() -> void:
	if _players:
		_players.coopCharacterBuffer = null


# v0.13.67: 코옵 세이브를 user:// 루트에 uid로 키잉 (user://coop_<uid>.tres).
#   - 루트 .tres라 MSS가 슬롯별 sync_in/out으로 관리 → 슬롯 자동 분리
#   - vanilla FormatSave(새 게임)가 루트 .tres 삭제 → 새 게임 = 깨끗하게 시작
#   - uid 파일명이라 이름 바꿔도 진행 유지
# (v0.13.57의 user://coop/players/<uid>.tres 하위폴더는 MSS 관리 밖이라 모든
#  슬롯이 한 파일 공유 + 새 게임에도 안 지워지는 회귀였음 → 루트로 복귀.)
const LEGACY_SUBDIR := "user://coop/players"  # v0.13.57~66 하위폴더 (마이그레이션 소스)


func _uid_for(peer_id: int) -> String:
	if _players and "peer_uids" in _players and _players.peer_uids.has(peer_id):
		return str(_players.peer_uids[peer_id])
	return ""


func _legacy_name_path(peer_id: int) -> String:
	var name_key: String = ""
	if _players and "peer_names" in _players and _players.peer_names.has(peer_id):
		name_key = _players.peer_names[peer_id]
	if name_key == "":
		name_key = str(peer_id)
	name_key = name_key.replace(" ", "_").replace("/", "_").replace("\\", "_").replace(":", "_")
	return "user://coop_%s.tres" % name_key


func _save_path(peer_id: int) -> String:
	var uid: String = _uid_for(peer_id)
	if uid == "":
		return _legacy_name_path(peer_id)
	var p: String = "user://coop_%s.tres" % uid
	# 1회 마이그레이션: 루트 uid 파일 없으면 (a) v0.13.57~66 하위폴더 또는
	# (b) 레거시 이름 기반 파일에서 복사해 기존 진행 보존.
	if not FileAccess.file_exists(p):
		var subdir: String = "%s/%s.tres" % [LEGACY_SUBDIR, uid]
		var legacy_name: String = _legacy_name_path(peer_id)
		if FileAccess.file_exists(subdir):
			DirAccess.copy_absolute(subdir, p)
			print("[CoopCharBuf] migrated subdir save -> '%s'" % p)
		elif legacy_name != p and FileAccess.file_exists(legacy_name):
			DirAccess.copy_absolute(legacy_name, p)
			print("[CoopCharBuf] migrated legacy-name save -> '%s'" % p)
	return p


func _slot_serializer() -> SlotSerializer:
	var coop := RTVCoop.get_instance()
	return coop.get_sync("slot_serializer") as SlotSerializer if coop else null


func _copy_stats_to(character, gd: Resource) -> void:
	character.health = gd.health
	character.energy = gd.energy
	character.hydration = gd.hydration
	character.mental = gd.mental
	character.temperature = gd.temperature
	character.bodyStamina = gd.bodyStamina
	character.armStamina = gd.armStamina
	character.overweight = gd.overweight
	character.starvation = gd.starvation
	character.dehydration = gd.dehydration
	character.bleeding = gd.bleeding
	character.fracture = gd.fracture
	character.burn = gd.burn
	character.frostbite = gd.frostbite
	character.insanity = gd.insanity
	character.rupture = gd.rupture
	character.headshot = gd.headshot
	character.cat = gd.cat
	character.catFound = gd.catFound
	character.catDead = gd.catDead
	character.primary = gd.primary
	character.secondary = gd.secondary
	character.knife = gd.knife
	character.grenade1 = gd.grenade1
	character.grenade2 = gd.grenade2
	character.flashlight = gd.flashlight
	character.NVG = gd.NVG
	character.weaponPosition = gd.weaponPosition


func _copy_stats_from(gd: Resource, character) -> void:
	gd.health = character.health
	gd.energy = character.energy
	gd.hydration = character.hydration
	gd.mental = character.mental
	gd.temperature = character.temperature
	gd.bodyStamina = character.bodyStamina
	gd.armStamina = character.armStamina
	gd.overweight = character.overweight
	gd.starvation = character.starvation
	gd.dehydration = character.dehydration
	gd.bleeding = character.bleeding
	gd.fracture = character.fracture
	gd.burn = character.burn
	gd.frostbite = character.frostbite
	gd.insanity = character.insanity
	gd.rupture = character.rupture
	gd.headshot = character.headshot
	gd.cat = character.cat
	gd.catFound = character.catFound
	gd.catDead = character.catDead
	gd.primary = character.primary
	gd.secondary = character.secondary
	gd.knife = character.knife
	gd.grenade1 = character.grenade1
	gd.grenade2 = character.grenade2
	gd.flashlight = character.flashlight
	gd.NVG = character.NVG
