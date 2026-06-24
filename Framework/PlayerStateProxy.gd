extends Node


var sync_position: Vector3 = Vector3.ZERO
var sync_rotation: Vector3 = Vector3.ZERO
var sync_anim_condition: String = "Guard"
var sync_anim_blend: float = 0.0
var sync_weapon_type: String = "rifle"
var sync_weapon_file: String = ""
var sync_has_weapon: bool = false
var sync_is_firing: bool = false
var sync_fire_mode: int = 1
var sync_flashlight: bool = false
var sync_suppressed: bool = false
var sync_pitch: float = 0.0
var sync_attachments: String = ""
var sync_backpack_file: String = ""

var shot_accumulator: int = 0


func write_state(state: Dictionary) -> void:
	sync_position = state.get("pos", sync_position)
	sync_rotation = state.get("rot", sync_rotation)
	sync_anim_condition = state.get("animCondition", sync_anim_condition)
	sync_anim_blend = state.get("animBlend", sync_anim_blend)
	sync_weapon_type = state.get("weapon", sync_weapon_type)
	sync_weapon_file = state.get("weaponFile", sync_weapon_file)
	sync_has_weapon = state.get("hasWeapon", sync_has_weapon)
	sync_is_firing = state.get("isFiring", sync_is_firing)
	sync_fire_mode = state.get("fireMode", sync_fire_mode)
	sync_flashlight = state.get("flashlight", sync_flashlight)
	sync_suppressed = state.get("suppressed", sync_suppressed)
	sync_pitch = state.get("pitch", sync_pitch)
	shot_accumulator += state.get("shots", 0)
	var att: Array = state.get("attachments", [])
	sync_attachments = ",".join(att)
	sync_backpack_file = state.get("backpackFile", sync_backpack_file)
	_push_state()


func read_state() -> Dictionary:
	var att_array: Array = []
	if sync_attachments != "":
		att_array = Array(sync_attachments.split(",", false))
	return {
		"pos": sync_position,
		"rot": sync_rotation,
		"animCondition": sync_anim_condition,
		"animBlend": sync_anim_blend,
		"weapon": sync_weapon_type,
		"weaponFile": sync_weapon_file,
		"hasWeapon": sync_has_weapon,
		"isFiring": sync_is_firing,
		"shots": 0,
		"fireMode": sync_fire_mode,
		"flashlight": sync_flashlight,
		"suppressed": sync_suppressed,
		"pitch": sync_pitch,
		"attachments": att_array,
		"backpackFile": sync_backpack_file,
	}


func _push_state() -> void:
	if multiplayer == null or multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	var payload := _pack()
	if multiplayer.is_server():
		_apply_broadcast.rpc(payload, sync_anim_condition, sync_weapon_type, sync_weapon_file, sync_attachments, sync_backpack_file)
	else:
		_submit_to_host.rpc_id(1, payload, sync_anim_condition, sync_weapon_type, sync_weapon_file, sync_attachments, sync_backpack_file)


func _pack() -> PackedFloat32Array:
	var p := PackedFloat32Array()
	p.resize(20)
	p[0] = sync_position.x; p[1] = sync_position.y; p[2] = sync_position.z
	p[3] = sync_rotation.x; p[4] = sync_rotation.y; p[5] = sync_rotation.z
	p[6] = sync_anim_blend
	p[7] = 1.0 if sync_has_weapon else 0.0
	p[8] = 1.0 if sync_is_firing else 0.0
	p[9] = float(sync_fire_mode)
	p[10] = 1.0 if sync_flashlight else 0.0
	p[11] = 1.0 if sync_suppressed else 0.0
	p[12] = sync_pitch
	p[13] = float(shot_accumulator)
	return p


func _unpack(p: PackedFloat32Array) -> void:
	if p.size() < 14:
		return
	sync_position = Vector3(p[0], p[1], p[2])
	sync_rotation = Vector3(p[3], p[4], p[5])
	sync_anim_blend = p[6]
	sync_has_weapon = p[7] > 0.5
	sync_is_firing = p[8] > 0.5
	sync_fire_mode = int(p[9])
	sync_flashlight = p[10] > 0.5
	sync_suppressed = p[11] > 0.5
	sync_pitch = p[12]
	shot_accumulator = int(p[13])


@rpc("any_peer", "unreliable", "call_remote")
func _submit_to_host(payload: PackedFloat32Array, anim_cond: String = "",
		weapon_type: String = "", weapon_file: String = "", attachments: String = "", backpack_file: String = "") -> void:
	if not multiplayer.is_server():
		return
	_unpack(payload)
	sync_anim_condition = anim_cond
	sync_weapon_type = weapon_type
	sync_weapon_file = weapon_file
	sync_attachments = attachments
	sync_backpack_file = backpack_file
	_apply_broadcast.rpc(payload, anim_cond, weapon_type, weapon_file, attachments, backpack_file)


@rpc("any_peer", "unreliable", "call_remote")
func _apply_broadcast(payload: PackedFloat32Array, anim_cond: String = "",
		weapon_type: String = "", weapon_file: String = "", attachments: String = "", backpack_file: String = "") -> void:
	_unpack(payload)
	if anim_cond != "":
		sync_anim_condition = anim_cond
	if weapon_type != "":
		sync_weapon_type = weapon_type
	if weapon_file != "":
		sync_weapon_file = weapon_file
	if attachments != "":
		sync_attachments = attachments
	sync_backpack_file = backpack_file
