extends "res://mods/RTVCoop/Game/Sync/BaseSync.gd"




const TRADERS := ["Generalist", "Doctor", "Gunsmith", "Grandma"]


var coop_trader_state: Dictionary = {}
var state_received: Dictionary = {}
var _loaded_from_disk: bool = false


func _sync_key() -> String:
	return "quest"


func _ready() -> void:
	call_deferred("_init_from_disk_if_host")


func _init_from_disk_if_host() -> void:
	if not CoopAuthority.is_host():
		return
	if _loaded_from_disk:
		return
	if not FileAccess.file_exists("user://Traders.tres"):
		_ensure_defaults()
		_loaded_from_disk = true
		return
	var traders := load("user://Traders.tres")
	if traders == null:
		_ensure_defaults()
		_loaded_from_disk = true
		return
	coop_trader_state["Generalist"] = traders.generalist.duplicate() if traders.generalist else []
	coop_trader_state["Doctor"] = traders.doctor.duplicate() if traders.doctor else []
	coop_trader_state["Gunsmith"] = traders.gunsmith.duplicate() if traders.gunsmith else []
	coop_trader_state["Grandma"] = traders.grandma.duplicate() if traders.grandma else []
	_loaded_from_disk = true


func _ensure_defaults() -> void:
	for t_name in TRADERS:
		if not coop_trader_state.has(t_name):
			coop_trader_state[t_name] = []


func get_completed(trader_name: String) -> Array:
	if not coop_trader_state.has(trader_name):
		coop_trader_state[trader_name] = []
	return coop_trader_state[trader_name]


func apply_completion_local(trader_name: String, task_name: String) -> void:
	var completed := get_completed(trader_name)
	if not completed.has(task_name):
		completed.append(task_name)
	var trader := _find_active_trader(trader_name)
	if trader and not trader.tasksCompleted.has(task_name):
		trader.tasksCompleted.append(task_name)


func _find_active_trader(trader_name: String) -> Node:
	var coop := RTVCoop.get_instance()
	var interface_node: Node = coop.scene.interface() if coop and coop.scene else null
	if interface_node and interface_node.get("trader") != null:
		var t = interface_node.trader
		if is_instance_valid(t) and t.traderData and t.traderData.name == trader_name:
			return t
	for node in get_tree().get_nodes_in_group("Trader"):
		if is_instance_valid(node) and node.traderData and node.traderData.name == trader_name:
			return node
	return null


func _persist_host() -> void:
	if not CoopAuthority.is_host():
		return
	var traders = null
	if FileAccess.file_exists("user://Traders.tres"):
		traders = load("user://Traders.tres")
	if traders == null:
		var trader_save_script := load("res://Scripts/TraderSave.gd")
		if trader_save_script == null:
			return
		traders = trader_save_script.new()
	traders.generalist = get_completed("Generalist").duplicate()
	traders.doctor = get_completed("Doctor").duplicate()
	traders.gunsmith = get_completed("Gunsmith").duplicate()
	traders.grandma = get_completed("Grandma").duplicate()
	ResourceSaver.save(traders, "user://Traders.tres")


@rpc("any_peer", "reliable", "call_remote")
func RequestTraderState(trader_name: String) -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	DeliverTraderState.rpc_id(sender, trader_name, get_completed(trader_name))


@rpc("authority", "reliable", "call_remote")
func DeliverTraderState(trader_name: String, completed: Array) -> void:
	coop_trader_state[trader_name] = completed.duplicate()
	state_received[trader_name] = true
	var trader := _find_active_trader(trader_name)
	if trader:
		trader.tasksCompleted.clear()
		for task_name in completed:
			trader.tasksCompleted.append(task_name)


func has_state_for(trader_name: String) -> bool:
	if CoopAuthority.is_host():
		return true
	return state_received.get(trader_name, false)


func push_full_state_to(peer_id: int) -> void:
	if not CoopAuthority.is_host():
		return
	for t_name in TRADERS:
		DeliverTraderState.rpc_id(peer_id, t_name, get_completed(t_name))


@rpc("any_peer", "reliable", "call_remote")
func SubmitTaskCompletion(trader_name: String, task_name: String) -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	print("[QuestSync/HOST] SubmitTaskCompletion received from=%d trader=%s task=%s" % [sender, trader_name, task_name])
	var completed := get_completed(trader_name)
	if completed.has(task_name):
		print("[QuestSync/HOST] task already completed, skipping")
		return
	completed.append(task_name)
	# fix4: mirror host-side effects from InterfaceHooks._replace_interface_complete (host path).
	# Without these, a client-completed task is just appended to a list — the trader animation
	# never plays on the host, the save isn't flushed, and Loader.UpdateProgression() never
	# fires, leaving follow-up dialog / unlock state frozen.
	var trader := _find_active_trader(trader_name)
	if trader and trader.has_method("PlayTraderTask"):
		if not trader.tasksCompleted.has(task_name):
			trader.tasksCompleted.append(task_name)
		trader.PlayTraderTask()
	var gd: Resource = load("res://Resources/GameData.tres")
	var in_tutorial: bool = gd != null and gd.tutorial
	if not in_tutorial:
		Loader.SaveTrader(trader_name)
		Loader.UpdateProgression()
	_persist_host()
	BroadcastTaskCompletion.rpc(trader_name, task_name)


@rpc("authority", "reliable", "call_local")
func BroadcastTaskCompletion(trader_name: String, task_name: String) -> void:
	print("[QuestSync/PEER] BroadcastTaskCompletion received trader=%s task=%s" % [trader_name, task_name])
	apply_completion_local(trader_name, task_name)
	# v0.11: chat 알림
	var chat = Engine.get_meta("ChatOverlay", null)
	if chat and chat.has_method("add_message"):
		chat.add_message("[System] 임무 완료: [b]%s[/b] (%s)" % [task_name, trader_name], "#7fd0ff")


# v0.9: SaveTaskNotes (받기) 양방향 sync. 노트북은 user://Traders.tres taskNotes에 저장됨.
# 호스트/클라 각자 디스크에 동일 노트북 유지 — RPC 받으면 자기 측 디스크 ResourceSaver.save.
@rpc("any_peer", "reliable", "call_remote")
func SubmitNoteChange(task_resource_path: String, add: bool) -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	print("[QuestSync/HOST] SubmitNoteChange received from=%d path=%s add=%s" % [sender, task_resource_path, str(add)])
	_apply_note_local(task_resource_path, add)
	BroadcastNoteChange.rpc(task_resource_path, add)


@rpc("authority", "reliable", "call_remote")
func BroadcastNoteChange(task_resource_path: String, add: bool) -> void:
	print("[QuestSync/PEER] BroadcastNoteChange received path=%s add=%s" % [task_resource_path, str(add)])
	_apply_note_local(task_resource_path, add)


func _apply_note_local(task_resource_path: String, add: bool) -> void:
	if task_resource_path == "":
		return
	var task = load(task_resource_path)
	if task == null:
		push_warning("[QuestSync] _apply_note_local: failed to load TaskData at %s" % task_resource_path)
		return
	if not FileAccess.file_exists("user://Traders.tres"):
		return
	var traders = load("user://Traders.tres") as TraderSave
	if traders == null:
		return
	if add:
		if not traders.taskNotes.has(task):
			traders.taskNotes.append(task)
	else:
		if traders.taskNotes.has(task):
			traders.taskNotes.erase(task)
	ResourceSaver.save(traders, "user://Traders.tres")
