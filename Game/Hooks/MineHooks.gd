extends "res://mods/RTVCoop/HookKit/BaseHook.gd"


const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

func _log(msg: String) -> void:
    var l = Engine.get_meta("CoopLogger", null)
    if l: l.log_msg("MineHooks", msg)

func _setup_hooks() -> void:
    # v0.5 fix: 원래 의도(_ready 시 모든 지뢰를 CoopMine 그룹에 등록)인데 "mine-detonate-pre"에
    # 잘못 등록돼 있었음 → 지뢰가 *자기가 터질 때만* 그룹에 들어가서, 리모트 peer의 BroadcastMineDetonate가
    # 아직 안 터진 지뢰를 _find_mine_by_id로 못 찾음 → 클라 지뢰 detonate 안 됨(소리 안 남). _ready로 이동.
    CoopHook.register(self, "mine-_ready-pre", _on_mine_ready_pre)
    CoopHook.register_replace_or_post(self, "mine-detonate", _replace_mine_detonate, _post_mine_detonate)
    CoopHook.register_replace_or_post(self, "mine-instantdetonate", _replace_mine_instant_detonate, _post_mine_instant_detonate)


func _on_mine_ready_pre() -> void:
    var mine := CoopHook.caller()
    if mine:
        mine.add_to_group("CoopMine")


func _mine_id(mine: Node) -> int:
    if players and players.has_method("CoopPosHash"):
        return players.CoopPosHash(mine.global_position)
    return abs(hash(str(mine.global_position)))


func _replace_mine_detonate() -> void:
    var mine := CoopHook.caller()
    if mine == null or not CoopAuthority.is_active():
        return
    if mine.isDetonated:
        CoopHook.skip_super()
        return
    if mine.get_meta("_coop_detonate_suppressed", false):
        return
    var mid: int = _mine_id(mine)
    _log("Detonate mine_id=%d pos=%s is_host=%s" % [mid, str(mine.global_position), str(CoopAuthority.is_host())])
    if CoopAuthority.is_host():
        interactable.BroadcastMineDetonate.rpc(mid, mine.global_position)
    else:
        interactable.SubmitMineDetonate.rpc_id(1, mid, mine.global_position)


func _post_mine_detonate() -> void:
    pass


func _replace_mine_instant_detonate() -> void:
    var mine := CoopHook.caller()
    if mine == null or not CoopAuthority.is_active():
        return
    if mine.isDetonated or mine.is_queued_for_deletion():
        CoopHook.skip_super()
        return
    if mine.get_meta("_coop_detonate_suppressed", false):
        return
    var mid: int = _mine_id(mine)
    _log("InstantDetonate mine_id=%d pos=%s is_host=%s" % [mid, str(mine.global_position), str(CoopAuthority.is_host())])
    if CoopAuthority.is_host():
        interactable.BroadcastMineInstantDetonate.rpc(mid, mine.global_position)
    else:
        interactable.SubmitMineInstantDetonate.rpc_id(1, mid, mine.global_position)


func _post_mine_instant_detonate() -> void:
    pass
