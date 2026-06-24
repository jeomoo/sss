extends "res://Scripts/Mine.gd"


const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")
const RTVCoop = preload("res://mods/RTVCoop/Game/Coop.gd")


func _ready() -> void:
	super()
	add_to_group("CoopMine")


func _log(msg: String) -> void:
	var l = Engine.get_meta("CoopLogger", null)
	if l: l.log_msg("Mine", msg)

func Detonate() -> void:
	if isDetonated:
		return
	var coop_inst = RTVCoop.get_instance()
	var mid: int = coop_inst.players.CoopPosHash(global_position) if coop_inst and coop_inst.players else -1
	_log("Detonate pos=%s mine_id=%d is_host=%s" % [str(global_position), mid, str(CoopAuthority.is_host())])
	super()
	if get_meta("_coop_detonate_suppressed", false):
		return
	if not CoopAuthority.is_active():
		return
	var coop := RTVCoop.get_instance()
	if coop == null or coop.players == null:
		return
	var sync_node: Node = coop.get_sync("interactable")
	if sync_node == null:
		return
	var mine_id: int = coop.players.CoopPosHash(global_position)
	if CoopAuthority.is_host():
		sync_node.BroadcastMineDetonate.rpc(mine_id)
	else:
		sync_node.SubmitMineDetonate.rpc_id(1, mine_id)


func InstantDetonate() -> void:
	if isDetonated or is_queued_for_deletion():
		return
	super()
	if get_meta("_coop_detonate_suppressed", false):
		return
	if not CoopAuthority.is_active():
		return
	var coop := RTVCoop.get_instance()
	if coop == null or coop.players == null:
		return
	var sync_node: Node = coop.get_sync("interactable")
	if sync_node == null:
		return
	var mine_id: int = coop.players.CoopPosHash(global_position)
	if CoopAuthority.is_host():
		sync_node.BroadcastMineInstantDetonate.rpc(mine_id)
	else:
		sync_node.SubmitMineInstantDetonate.rpc_id(1, mine_id)
