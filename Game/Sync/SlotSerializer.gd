extends "res://mods/RTVCoop/Game/Sync/BaseSync.gd"


var itemDataCache: Dictionary = {}


func _sync_key() -> String:
	return "slot_serializer"


func SerializeSlotData(slot) -> Dictionary:
	if slot == null or slot.itemData == null:
		return {}
	var nested_files: Array = []
	for item in slot.nested:
		if item:
			nested_files.append(item.file)
	var dict = {
		"file": slot.itemData.file,
		"amount": slot.amount,
		"condition": slot.condition,
		"state": slot.state,
		"rotated": slot.gridRotated,
		"gridPosition": slot.gridPosition,
		"position": slot.position,
		"mode": slot.mode,
		"zoom": slot.zoom,
		"chamber": slot.chamber,
		"casing": slot.casing,
		"nested": nested_files,
	}
	if slot.storage.size() > 0:
		var storage_arr: Array = []
		for s in slot.storage:
			storage_arr.append(SerializeSlotData(s))
		dict["storage_data"] = storage_arr
	return dict


func DeserializeSlotData(dict: Dictionary):
	var slot = SlotData.new()
	var file: String = dict.get("file", "")
	if file == "":
		return null
	slot.itemData = LookupItemData(file)
	if slot.itemData == null:
		return null
	slot.amount = dict.get("amount", 0)
	slot.condition = dict.get("condition", 100)
	slot.state = dict.get("state", "")
	slot.gridRotated = dict.get("rotated", false)
	slot.gridPosition = dict.get("gridPosition", Vector2.ZERO)
	slot.position = dict.get("position", 0)
	slot.mode = dict.get("mode", 1)
	slot.zoom = dict.get("zoom", 1)
	slot.chamber = dict.get("chamber", false)
	slot.casing = dict.get("casing", false)
	for nested_file in dict.get("nested", []):
		var nested_data = LookupItemData(nested_file)
		if nested_data:
			slot.nested.append(nested_data)
	for sd in dict.get("storage_data", []):
		var stored = DeserializeSlotData(sd)
		if stored:
			slot.storage.append(stored)
	return slot


var _mod_item_index: Dictionary = {}
var _mod_item_indexed: bool = false

func _build_mod_item_index() -> void:
	if _mod_item_indexed: return
	_mod_item_indexed = true
	var queue = ["res://mods/"]
	while queue.size() > 0:
		var current = queue.pop_front()
		var dir = DirAccess.open(current)
		if dir:
			dir.list_dir_begin()
			var file_name = dir.get_next()
			while file_name != "":
				if file_name != "." and file_name != "..":
					if dir.current_is_dir():
						queue.append(current + file_name + "/")
					elif file_name.ends_with(".tscn"):
						var short_name = file_name.get_basename()
						_mod_item_index[short_name] = current + file_name
				file_name = dir.get_next()


func LookupItemData(file: String):
	if file == "":
		return null
	if itemDataCache.has(file):
		return itemDataCache[file]
	var scene = Database.get(file)
	if scene == null and ResourceLoader.exists(file):
		scene = load(file)
	if scene == null:
		_build_mod_item_index()
		if _mod_item_index.has(file):
			scene = load(_mod_item_index[file])
	if scene == null:
		push_warning("[SlotSerializer] Unknown item file: %s" % file)
		return null
	var temp = scene.instantiate()
	var data = null
	if "slotData" in temp and temp.slotData and temp.slotData.itemData:
		data = temp.slotData.itemData
	temp.queue_free()
	if data:
		itemDataCache[file] = data
	return data


func ApplySlotDictToPickup(pickup, slot_dict: Dictionary) -> void:
	if pickup == null or pickup.slotData == null:
		return
	pickup.slotData.amount = slot_dict.get("amount", pickup.slotData.amount)
	pickup.slotData.condition = slot_dict.get("condition", pickup.slotData.condition)
	pickup.slotData.state = slot_dict.get("state", pickup.slotData.state)
	pickup.slotData.chamber = slot_dict.get("chamber", pickup.slotData.chamber)
	pickup.slotData.casing = slot_dict.get("casing", pickup.slotData.casing)
	pickup.slotData.mode = slot_dict.get("mode", pickup.slotData.mode)
	pickup.slotData.zoom = slot_dict.get("zoom", pickup.slotData.zoom)
	pickup.slotData.position = slot_dict.get("position", pickup.slotData.position)
	pickup.slotData.nested.clear()
	for nested_file in slot_dict.get("nested", []):
		var nested_data = LookupItemData(nested_file)
		if nested_data:
			pickup.slotData.nested.append(nested_data)
	if pickup.has_method("UpdateAttachments"):
		pickup.UpdateAttachments()
