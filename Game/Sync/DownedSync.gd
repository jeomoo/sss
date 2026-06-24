extends "res://mods/RTVCoop/Game/Sync/BaseSync.gd"


const BLEEDOUT_TIMER := 30.0
const REVIVE_DURATION := 5.0


signal local_revived
signal local_bled_out
signal local_downed


var gameData: Resource = preload("res://Resources/GameData.tres")
var _downed_peers: Dictionary = {}
var _bleedout_timers: Dictionary = {}
var _local_is_downed: bool = false


func _sync_key() -> String:
	return "downed"


func _players() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.players if coop else null


func is_peer_downed(peer_id: int) -> bool:
	return _downed_peers.has(peer_id)


func is_local_downed() -> bool:
	return _local_is_downed


func is_any_peer_downed() -> bool:
	return _downed_peers.size() > 0


func get_downed_peer_ids() -> Array:
	return _downed_peers.keys()


func _physics_process(delta: float) -> void:
	if not CoopAuthority.is_active() or not CoopAuthority.is_host():
		return
	var expired: Array = []
	for peer_id in _bleedout_timers:
		_bleedout_timers[peer_id] -= delta
		if _bleedout_timers[peer_id] <= 0.0:
			expired.append(peer_id)
	for peer_id in expired:
		_bleedout_timers.erase(peer_id)
		_on_bleedout_expired(peer_id)


func enter_downed(peer_id: int) -> void:
	if CoopAuthority.is_host():
		_host_enter_downed(peer_id)
	else:
		SubmitPlayerDowned.rpc_id(1, peer_id)


func request_revive(downed_peer_id: int) -> void:
	if CoopAuthority.is_host():
		_host_complete_revive(downed_peer_id)
	else:
		SubmitReviveComplete.rpc_id(1, downed_peer_id)


func request_give_up() -> void:
	# v0.13.53: 버티기 포기 — 본인의 블리드아웃을 즉시 트리거(= 리스폰). 다운 상태에서만.
	# 아무도 못 구하는 상황에서 30초 강제 대기 회피. 루팅은 기존 블리드아웃 경로대로 death container 드롭.
	if not _local_is_downed:
		return
	var my_id: int = multiplayer.get_unique_id()
	if CoopAuthority.is_host():
		_bleedout_timers.erase(my_id)
		_on_bleedout_expired(my_id)
	else:
		SubmitGiveUp.rpc_id(1, my_id)


func push_state_to(peer_id: int) -> void:
	for downed_id in _downed_peers:
		BroadcastPlayerDowned.rpc_id(peer_id, downed_id)


func on_peer_left(peer_id: int) -> void:
	_downed_peers.erase(peer_id)
	_bleedout_timers.erase(peer_id)
	if CoopAuthority.is_host():
		_check_all_downed()


func clear_state() -> void:
	_downed_peers.clear()
	_bleedout_timers.clear()
	_local_is_downed = false


func _host_enter_downed(peer_id: int) -> void:
	_downed_peers[peer_id] = true
	if not gameData.permadeath:
		_bleedout_timers[peer_id] = BLEEDOUT_TIMER
	BroadcastPlayerDowned.rpc(peer_id)
	_check_all_downed()


func _host_complete_revive(downed_peer_id: int) -> void:
	if not _downed_peers.has(downed_peer_id):
		return
	_downed_peers.erase(downed_peer_id)
	_bleedout_timers.erase(downed_peer_id)
	BroadcastReviveComplete.rpc(downed_peer_id)


func _on_bleedout_expired(peer_id: int) -> void:
	if not _downed_peers.has(peer_id):
		return
	_downed_peers.erase(peer_id)
	BroadcastPlayerBledOut.rpc(peer_id)


func _check_all_downed() -> void:
	if not gameData.permadeath:
		return
	var players := _players()
	if players == null:
		return
	var all_peers: Array = players.peer_names.keys()
	if all_peers.is_empty():
		return
	for pid in all_peers:
		if not _downed_peers.has(pid):
			return
	BroadcastAllDownedGameOver.rpc()


# --- RPCs ---


@rpc("any_peer", "reliable", "call_remote")
func SubmitPlayerDowned(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	_host_enter_downed(peer_id)


@rpc("authority", "reliable", "call_local")
func BroadcastPlayerDowned(peer_id: int) -> void:
	_downed_peers[peer_id] = true
	if peer_id == multiplayer.get_unique_id():
		_local_is_downed = true
		local_downed.emit()
	else:
		var players := _players()
		if players and players.remote_players.has(peer_id):
			var puppet = players.remote_players[peer_id]
			if is_instance_valid(puppet) and puppet.has_method("OnDowned"):
				puppet.OnDowned()


@rpc("any_peer", "reliable", "call_remote")
func SubmitReviveComplete(downed_peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	_host_complete_revive(downed_peer_id)


@rpc("any_peer", "reliable", "call_remote")
func SubmitGiveUp(peer_id: int) -> void:
	# v0.13.53: 클라가 버티기 포기 → 호스트가 해당 peer 블리드아웃 즉시 처리.
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != peer_id:  # 본인 요청만 허용
		return
	if not _downed_peers.has(peer_id):
		return
	_bleedout_timers.erase(peer_id)
	_on_bleedout_expired(peer_id)


@rpc("authority", "reliable", "call_local")
func BroadcastReviveComplete(peer_id: int) -> void:
	_downed_peers.erase(peer_id)
	if peer_id == multiplayer.get_unique_id():
		_local_is_downed = false
		local_revived.emit()
	else:
		var players := _players()
		if players and players.remote_players.has(peer_id):
			var puppet = players.remote_players[peer_id]
			if is_instance_valid(puppet) and puppet.has_method("OnRevived"):
				puppet.OnRevived()


@rpc("authority", "reliable", "call_local")
func BroadcastPlayerBledOut(peer_id: int) -> void:
	_downed_peers.erase(peer_id)
	if peer_id == multiplayer.get_unique_id():
		_local_is_downed = false
		local_bled_out.emit()
	else:
		var players := _players()
		if players and players.remote_players.has(peer_id):
			var puppet = players.remote_players[peer_id]
			if is_instance_valid(puppet):
				if puppet.has_method("OnDeath"):
					puppet.OnDeath()


@rpc("authority", "reliable", "call_local")
func BroadcastAllDownedGameOver() -> void:
	_downed_peers.clear()
	_bleedout_timers.clear()
	_local_is_downed = false
	var coop := RTVCoop.get_instance()
	if coop and coop.net and coop.net.has_method("Disconnect"):
		coop.net.Disconnect()
	Loader.FormatSave()
	Loader.LoadScene("Death")
