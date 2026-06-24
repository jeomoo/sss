extends "res://Scripts/Explosion.gd"


const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")


func CheckOverlap() -> void:
	if CoopAuthority.is_active() and not CoopAuthority.is_host():
		return
	if CoopAuthority.is_active() and area:
		var _bodies = area.get_overlapping_bodies()
		var _info = []
		for _b in _bodies:
			_info.append("%s%s" % [str(_b.name), str(_b.get_groups())])
		print("[CoopExpl] CheckOverlap @%s bodies=%d %s" % [str(global_position.round()), _bodies.size(), str(_info)])
	super()


func CheckLOS(target) -> void:
	var head_pos: Vector3 = target.global_position + Vector3(0, 1.5, 0)
	if target.get("head") and target.head:
		head_pos = target.head.global_position

	LOS.look_at(head_pos, Vector3.UP, true)
	LOS.force_raycast_update()

	if LOS.is_colliding():
		var _col = LOS.get_collider()
		if _col.is_in_group("AI"):
			print("[CoopExpl]  LOS→AI %s damage" % str(target.name))
			target.ExplosionDamage(LOS.global_basis.z)
		if _col.is_in_group("Player"):
			print("[CoopExpl]  LOS→Player target=%s child0=%s" % [str(target.name), (str(target.get_child(0).name) if target.get_child_count() > 0 else "?")])
			target.get_child(0).ExplosionDamage()
	else:
		print("[CoopExpl]  LOS no-collide target=%s (head LOS blocked?)" % str(target.name))


func CheckAlert() -> void:
	if CoopAuthority.is_active() and not CoopAuthority.is_host():
		return
	super()
