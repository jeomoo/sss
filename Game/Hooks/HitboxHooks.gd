extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

func _setup_hooks() -> void:
	CoopHook.register_replace_or_post(self, "hitbox-applydamage", _replace_hitbox_apply_damage, _post_hitbox_apply_damage)


func _replace_hitbox_apply_damage(damage: float) -> void:
	var hitbox := CoopHook.caller()
	if hitbox == null:
		return
	if not CoopAuthority.is_active():
		return
	if CoopAuthority.is_host():
		# v0.5: 호스트 자기 샷이 AI hitbox 명중 → 위협 가중 타게팅에 기록(호스트 peer). 그 후 vanilla 데미지 진행.
		# (원격 사수는 아래 client 경로의 RequestAIDamage에서 기록 → 이 훅 = 호스트 샷으로 깔끔히 갈림)
		var ai_owner: Node = hitbox.owner
		if ai_owner != null and ai_owner.has_meta("network_uuid") and ai and ai.has_method("record_threat"):
			ai.record_threat(int(ai_owner.get_meta("network_uuid")), CoopAuthority.local_peer_id(), damage)
		return
	var owner_node: Node = hitbox.owner
	if owner_node == null or not owner_node.has_meta("network_uuid"):
		return

	var final_damage: float = 0.0
	match hitbox.type:
		"Head": final_damage = 100.0
		"Torso": final_damage = damage
		"Leg_L", "Leg_R": final_damage = damage / 2.0
		_: final_damage = damage

	if ai:
		ai.RequestAIDamage.rpc_id(1, int(owner_node.get_meta("network_uuid")), hitbox.type, final_damage)
		CoopHook.skip_super()


func _post_hitbox_apply_damage(_damage: float) -> void:
	pass
