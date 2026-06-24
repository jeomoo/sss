extends "res://mods/RTVCoop/Game/Sync/BaseSync.gd"




const VEHICLE_BROADCAST_RATE: float = 20.0
const ROCKET_BROADCAST_RATE: float = 15.0
const VEHICLE_LERP_SPEED: float = 12.0
const ROCKET_LERP_SPEED: float = 20.0


var _vehicle_accum: float = 0.0
var _rocket_accum: float = 0.0
var _vehicles: Array = []
var _rockets: Array = []

var _vehicle_targets: Dictionary = {}
var _rocket_targets: Dictionary = {}
var _remote_instrument_audio: Dictionary = {}


func _sync_key() -> String:
	return "world"


func _physics_process(delta: float) -> void:
	if not CoopAuthority.is_active():
		return

	if CoopAuthority.is_host():
		_vehicle_accum += delta
		if _vehicle_accum >= 1.0 / VEHICLE_BROADCAST_RATE:
			_vehicle_accum = 0.0
			_broadcast_vehicles()

		_rocket_accum += delta
		if _rocket_accum >= 1.0 / ROCKET_BROADCAST_RATE:
			_rocket_accum = 0.0
			_broadcast_rockets()
	else:
		_lerp_targets(_vehicle_targets, VEHICLE_LERP_SPEED, delta)
		_lerp_targets(_rocket_targets, ROCKET_LERP_SPEED, delta)


func _lerp_targets(targets: Dictionary, speed: float, delta: float) -> void:
	if targets.is_empty():
		return
	var t: float = clampf(speed * delta, 0.0, 1.0)
	var stale: Array = []
	for path in targets:
		var node: Node = get_node_or_null(path)
		if node == null or not is_instance_valid(node):
			stale.append(path)
			continue
		var target: Dictionary = targets[path]
		node.global_position = node.global_position.lerp(target.pos, t)
		node.global_rotation.x = lerp_angle(node.global_rotation.x, target.rot.x, t)
		node.global_rotation.y = lerp_angle(node.global_rotation.y, target.rot.y, t)
		node.global_rotation.z = lerp_angle(node.global_rotation.z, target.rot.z, t)
	for p in stale:
		targets.erase(p)


func register_vehicle(node: Node3D) -> void:
	if not _vehicles.has(node):
		_vehicles.append(node)


func _broadcast_vehicles() -> void:
	var alive: Array = []
	for v in _vehicles:
		if not is_instance_valid(v) or not v.is_inside_tree():
			continue
		alive.append(v)
		BroadcastVehiclePose.rpc(v.get_path(), v.global_position, v.global_rotation)
	_vehicles = alive


@rpc("authority", "unreliable", "call_remote")
func BroadcastVehiclePose(path: NodePath, pos: Vector3, rot: Vector3) -> void:
	_vehicle_targets[path] = {"pos": pos, "rot": rot}


func register_rocket(node: Node3D) -> void:
	if not _rockets.has(node):
		_rockets.append(node)


func _broadcast_rockets() -> void:
	var alive: Array = []
	for r in _rockets:
		if not is_instance_valid(r) or not r.is_inside_tree():
			continue
		alive.append(r)
		BroadcastRocketPose.rpc(r.get_path(), r.global_position, r.global_rotation)
	_rockets = alive


@rpc("authority", "unreliable", "call_remote")
func BroadcastRocketPose(path: NodePath, pos: Vector3, rot: Vector3) -> void:
	_rocket_targets[path] = {"pos": pos, "rot": rot}


func CoopRouteInteractToggle(path: NodePath) -> bool:
	if not CoopAuthority.is_active():
		return false
	if CoopAuthority.is_host():
		BroadcastInteractToggle.rpc(path)
	else:
		RequestInteractToggle.rpc_id(1, path)
	return true


@rpc("any_peer", "reliable", "call_remote")
func RequestInteractToggle(path: NodePath) -> void:
	if not multiplayer.is_server():
		return
	BroadcastInteractToggle.rpc(path)


@rpc("authority", "reliable", "call_local")
func BroadcastInteractToggle(path: NodePath) -> void:
	var node: Node = get_node_or_null(path)
	if node == null or not node.has_method("Interact"):
		return
	# fix6.5: inline what Radio_Extend / Television_Extend _coop_remote_interact did —
	# set the in-remote-interact meta so WorldHooks' radio/TV Interact hook skips its
	# local broadcast path, run vanilla Interact, then clear the flag. Avoids requiring
	# the script_extend (which would clobber [hooks] rewrites).
	if node.has_method("_coop_remote_interact"):
		node._coop_remote_interact()
		return
	node.set_meta("_coop_in_remote_interact", true)
	node.Interact()
	node.remove_meta("_coop_in_remote_interact")


@rpc("any_peer", "reliable", "call_remote")
func RequestInstrumentPlay(clip_path: String) -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	BroadcastInstrumentPlay.rpc(sender, clip_path)


@rpc("any_peer", "reliable", "call_remote")
func RequestInstrumentStop() -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	BroadcastInstrumentStop.rpc(sender)


@rpc("authority", "reliable", "call_local")
func BroadcastInstrumentPlay(peer_id: int, clip_path: String) -> void:
	if peer_id == multiplayer.get_unique_id():
		return
	_play_remote_instrument(peer_id, clip_path)


@rpc("authority", "reliable", "call_local")
func BroadcastInstrumentStop(peer_id: int) -> void:
	if peer_id == multiplayer.get_unique_id():
		return
	_stop_remote_instrument(peer_id)


func _play_remote_instrument(peer_id: int, clip_path: String) -> void:
	_stop_remote_instrument(peer_id)
	if clip_path == "":
		return
	var coop := RTVCoop.get_instance()
	if coop == null or coop.players == null:
		return
	var puppet: Node = coop.players.GetPuppet(peer_id)
	if puppet == null:
		return
	var clip := load(clip_path)
	if clip == null:
		return
	var audio := AudioStreamPlayer3D.new()
	audio.stream = clip
	audio.max_distance = 50.0
	audio.unit_size = 6.0
	audio.bus = "Master"
	puppet.add_child(audio)
	audio.play()
	audio.finished.connect(func(): _on_remote_instrument_finished(peer_id, audio))
	_remote_instrument_audio[peer_id] = audio


func _stop_remote_instrument(peer_id: int) -> void:
	if not _remote_instrument_audio.has(peer_id):
		return
	var audio: Node = _remote_instrument_audio[peer_id]
	_remote_instrument_audio.erase(peer_id)
	if is_instance_valid(audio):
		audio.stop()
		audio.queue_free()


func _on_remote_instrument_finished(peer_id: int, audio: AudioStreamPlayer3D) -> void:
	if _remote_instrument_audio.get(peer_id) == audio:
		_remote_instrument_audio.erase(peer_id)
	if is_instance_valid(audio):
		audio.queue_free()


@rpc("authority", "reliable", "call_remote")
func BroadcastMissilePrepare(spawner_path: NodePath) -> void:
	var spawner: Node = get_node_or_null(spawner_path)
	if spawner == null or not spawner.has_method("ExecutePrepareMissiles"):
		return
	var existing: Array = spawner.get_children().filter(func(n): return n.has_method("ExecuteLaunch"))
	if existing.is_empty():
		spawner.ExecutePrepareMissiles(true)


@rpc("authority", "reliable", "call_remote")
func BroadcastMissileLaunch(spawner_path: NodePath, child_index: int) -> void:
	var spawner: Node = get_node_or_null(spawner_path)
	if spawner == null:
		return
	if child_index < 0 or child_index >= spawner.get_child_count():
		return
	var child: Node = spawner.get_child(child_index)
	if child == null or not child.has_method("ExecuteLaunch"):
		return
	spawner.launched = true
	child.visible = true
	child.ExecuteLaunch(true)


@rpc("any_peer", "reliable", "call_remote")
func RequestCatState(cat_found: bool, cat_dead: bool, cat_hydration: float) -> void:
	if not multiplayer.is_server():
		return
	BroadcastCatState.rpc(cat_found, cat_dead, cat_hydration)


@rpc("authority", "reliable", "call_local")
func BroadcastCatState(cat_found: bool, cat_dead: bool, cat_hydration: float) -> void:
	var gd := load("res://Resources/GameData.tres")
	if gd == null:
		return
	if cat_found:
		gd.catFound = true
	if cat_dead:
		gd.catDead = true
	gd.cat = cat_hydration
