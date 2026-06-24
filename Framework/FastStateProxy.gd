class_name FastStateProxy
extends RefCounted

# Antigravity 작품 기반. PlayerStateProxy(기존)와 이름 충돌 회피 → FastStateProxy.
# 무거운 Node 상속 없이 메모리 light. dirty flag로 변경점만 RPC 송신 (대역폭 절약).

var position: Vector3 = Vector3.ZERO
var rotation: Vector3 = Vector3.ZERO
var anim_condition: String = ""
var is_firing: bool = false

# SyncService tick이 collect할지 결정하는 플래그
var is_dirty: bool = false


func update_state(new_pos: Vector3, new_rot: Vector3, new_anim: String, new_firing: bool) -> void:
	# 변경 없으면 dirty 안 세움
	if position.distance_squared_to(new_pos) < 0.001 and \
	   rotation.distance_squared_to(new_rot) < 0.001 and \
	   anim_condition == new_anim and \
	   is_firing == new_firing:
		return

	position = new_pos
	rotation = new_rot
	anim_condition = new_anim
	is_firing = new_firing
	is_dirty = true


func collect_and_clean() -> Dictionary:
	is_dirty = false
	return {
		"p": position,
		"r": rotation,
		"a": anim_condition,
		"f": is_firing
	}
