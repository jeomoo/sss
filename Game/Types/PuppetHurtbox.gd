extends Node3D



const RTVCoop = preload("res://mods/RTVCoop/Game/Coop.gd")

func WeaponDamage(damage: float, penetration: float) -> void:
	var puppet := owner
	if puppet == null or not ("peer_id" in puppet):
		return
	var coop := RTVCoop.get_instance()
	if coop == null or coop.players == null:
		return
	var iac: Node = coop.get_sync("interactable")
	if iac and iac.has_method("RequestPlayerDamage"):
		iac.RequestPlayerDamage(puppet.peer_id, damage, penetration)


func ExplosionDamage() -> void:
	var puppet := owner
	if puppet == null or not ("peer_id" in puppet):
		return
	var coop := RTVCoop.get_instance()
	if coop == null:
		return
	var iac: Node = coop.get_sync("interactable")
	if iac and iac.has_method("RequestPlayerExplosionDamage"):
		iac.RequestPlayerExplosionDamage(puppet.peer_id)
