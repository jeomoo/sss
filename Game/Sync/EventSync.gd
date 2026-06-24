extends "res://mods/RTVCoop/Game/Sync/BaseSync.gd"



const BaseSync = preload("res://mods/RTVCoop/Game/Sync/BaseSync.gd")

const HELI_ROCKET_MATCH_RADIUS: float = 500.0
const ROCKET_EXPLODE_MATCH_RADIUS: float = 10.0
const ROCKET_CLEANUP_MATCH_RADIUS: float = 50.0
const ROCKET_EXPLOSION_SIZE: float = 20.0
const BTR_CRACK_DISTANCE_THRESHOLD: float = 50.0
const BTR_CRACK_DELAY_S: float = 0.1
const SLEEP_ENERGY_DRAIN: float = 20.0
const SLEEP_HYDRATION_DRAIN: float = 20.0
const SLEEP_MENTAL_REGEN: float = 20.0
const SLEEP_HOUR_TO_SIM_TIME: float = 100.0
const DAY_DURATION: float = 2400.0


var gameData: Resource = preload("res://Resources/GameData.tres")


var _pending_events: Array = []
var _sleep_ready: Dictionary = {}
var _sleep_in_progress: bool = false


func _sync_key() -> String:
	return "event"


func _players() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.players if coop else null


func _map() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.scene.get_map() if coop and coop.scene else null


func _physics_process(_delta: float) -> void:
	if _pending_events.is_empty():
		return
	var event_system := _find_event_system()
	if event_system == null:
		return
	var to_process := _pending_events.duplicate()
	_pending_events.clear()
	for event in to_process:
		_apply_event(event["name"], event["params"], event_system)


func _find_event_system() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	for g in ["EventSystem", "Events"]:
		for n in tree.get_nodes_in_group(g):
			if is_instance_valid(n):
				return n
	var roots: Array = []
	if tree.current_scene:
		roots.append(tree.current_scene)
	var map := tree.root.get_node_or_null("Map")
	if map and not roots.has(map):
		roots.append(map)
	for r in tree.root.get_children():
		if not roots.has(r):
			roots.append(r)
	for r in roots:
		var direct: Node = r.get_node_or_null("EventSystem")
		if direct:
			return direct
		var deep: Node = r.find_child("EventSystem", true, false)
		if deep:
			return deep
		var by_script := _scan_for_es(r)
		if by_script:
			return by_script
	return null


func _scan_for_es(n: Node) -> Node:
	if not is_instance_valid(n):
		return null
	var s := n.get_script()
	if s and str(s.resource_path).find("EventSystem") != -1:
		return n
	if n.has_method("FighterJet") and n.has_method("Airdrop") and n.has_method("Helicopter"):
		return n
	for c in n.get_children():
		var hit := _scan_for_es(c)
		if hit:
			return hit
	return null


@rpc("authority", "reliable", "call_remote")
func BroadcastEvent(event_name: String, params: Dictionary) -> void:
	var players := _players()
	var scene_ready: bool = players.scene_ready if players and "scene_ready" in players else false
	if not scene_ready:
		_pending_events.append({"name": event_name, "params": params})
		return
	var event_system := _find_event_system()
	if event_system == null:
		_pending_events.append({"name": event_name, "params": params})
		return
	_apply_event(event_name, params, event_system)


func _apply_event(event_name: String, params: Dictionary, event_system: Node) -> void:
	var cname: String = params.get("_cname", "")
	var start_cid: int = int(params.get("_startCid", 0))
	if start_cid > 0:
		var coop := RTVCoop.get_instance()
		if coop and coop.players:
			coop.players.nextContainerId = start_cid
	match event_name:
		"FighterJet":
			var ev = load("res://Assets/Fighter_Jet/Fighter_Jet.tscn").instantiate()
			if cname != "": ev.name = cname
			event_system.add_child(ev)
			ev.global_position = params.get("pos", ev.global_position)
			ev.global_rotation = params.get("rot", ev.global_rotation)
		"Airdrop":
			var ev = load("res://Assets/CASA/CASA.tscn").instantiate()
			if cname != "": ev.name = cname
			event_system.add_child(ev)
			ev.global_position = params.get("pos", ev.global_position)
			ev.global_rotation = params.get("rot", ev.global_rotation)
			if params.has("dropThreshold"):
				ev.dropThreshold = params["dropThreshold"]
			_register_crash_containers(ev)
		"Helicopter":
			var ev = load("res://Assets/Helicopter/Helicopter.tscn").instantiate()
			if cname != "": ev.name = cname
			event_system.add_child(ev)
			ev.global_position = params.get("pos", ev.global_position)
			ev.global_rotation = params.get("rot", ev.global_rotation)
		"Police":
			var paths_node: Node = event_system.get_node_or_null("Paths")
			if paths_node == null: return
			var path_index: int = int(params.get("pathIndex", 0))
			if path_index >= paths_node.get_child_count(): return
			var selected_path: Node = paths_node.get_child(path_index)
			var inverse: bool = params.get("inverse", false)
			var waypoint: Node = selected_path.get_child(selected_path.get_child_count() - 1) if inverse else selected_path.get_child(0)
			var ev = load("res://Assets/Police/Police.tscn").instantiate()
			if cname != "": ev.name = cname
			event_system.add_child(ev)
			ev.selectedPath = selected_path
			ev.inversePath = inverse
			ev.global_transform = waypoint.global_transform
		"BTR":
			var paths_node: Node = event_system.get_node_or_null("Paths")
			if paths_node == null: return
			var path_index: int = int(params.get("pathIndex", 0))
			if path_index >= paths_node.get_child_count(): return
			var selected_path: Node = paths_node.get_child(path_index)
			var inverse: bool = params.get("inverse", false)
			var waypoint: Node = selected_path.get_child(selected_path.get_child_count() - 1) if inverse else selected_path.get_child(0)
			var ev = load("res://Assets/BTR/BTR.tscn").instantiate()
			if cname != "": ev.name = cname
			event_system.add_child(ev)
			ev.selectedPath = selected_path
			ev.inversePath = inverse
			ev.global_transform = waypoint.global_transform
		"CrashSite":
			var crashes_node: Node = event_system.get_node_or_null("Crashes")
			if crashes_node == null: return
			var crash_index: int = int(params.get("crashIndex", 0))
			if crash_index >= crashes_node.get_child_count(): return
			var random_crash: Node = crashes_node.get_child(crash_index)
			var ev = load("res://Assets/Helicopter/Helicopter_Crash.tscn").instantiate()
			random_crash.add_child(ev)
			ev.global_transform = random_crash.global_transform
			_register_crash_containers(ev)
		"Cat":
			if gameData.catFound or gameData.catDead: return
			var wells := get_tree().get_nodes_in_group("Well")
			if wells.size() == 0: return
			var well_index: int = int(params.get("wellIndex", 0))
			if well_index >= wells.size(): return
			var random_well: Node3D = wells[well_index]
			var well_bottom: Node = random_well.get_node_or_null("Bottom")
			if well_bottom == null: return
			var cat_scene := load("res://Items/Lore/Cat/Cat.tscn")
			var rescue_scene := load("res://Items/Lore/Cat/Rescue.tscn")
			var cat_instance = cat_scene.instantiate()
			well_bottom.add_child(cat_instance)
			cat_instance.global_transform = well_bottom.global_transform
			var cat_system: Node = cat_instance.get_child(0)
			cat_system.currentState = cat_system.State.Rescue
			var rescue_instance = rescue_scene.instantiate()
			well_bottom.add_child(rescue_instance)
			rescue_instance.global_transform = well_bottom.global_transform
			rescue_instance.cat = cat_instance
			rescue_instance.position.y = 3.0
		"Transmission":
			for radio in get_tree().get_nodes_in_group("Radio"):
				radio.Transmission()


func _register_crash_containers(crash_root: Node) -> void:
	var coop := RTVCoop.get_instance()
	if coop == null or coop.players == null:
		return
	var players = coop.players
	BaseSync.coop_walk(crash_root, func(node):
		if node is LootContainer:
			if not node.is_in_group("CoopLootContainer"):
				node.add_to_group("CoopLootContainer")
			if not node.has_meta("coop_container_id"):
				node.set_meta("coop_container_id", players.nextContainerId)
				players.nextContainerId += 1
		return false
	)


@rpc("authority", "reliable", "call_remote")
func BroadcastHelicopterRockets(heli_path: String, heli_pos: Vector3, heli_rot: Vector3) -> void:
	var es := _find_event_system()
	if es == null: return
	var heli: Node = es.get_node_or_null(heli_path)
	if heli == null:
		for child in es.get_children():
			if child.has_method("FireRockets") and child.global_position.distance_to(heli_pos) < HELI_ROCKET_MATCH_RADIUS:
				heli = child
				break
	if heli and heli.has_method("FireRockets"):
		heli.global_position = heli_pos
		heli.global_rotation = heli_rot
		heli.set_meta("_coop_remote_fire", true)
		heli.FireRockets()


@rpc("authority", "unreliable", "call_remote")
func BroadcastAirdropPose(casa_name: String, airdrop_pos: Vector3, airdrop_rot: Vector3, is_released: bool) -> void:
	var es := _find_event_system()
	if es == null: return
	var casa_node: Node = es.get_node_or_null(casa_name)
	if casa_node == null: return
	var ad: Node = casa_node.get_node_or_null("Airdrop")
	if ad == null:
		var map := _map()
		if map:
			for child in map.get_children():
				if child.name.begins_with("Airdrop") and child is RigidBody3D:
					ad = child
					break
	if ad == null: return
	ad.global_position = airdrop_pos
	ad.global_rotation = airdrop_rot
	if casa_node:
		if not casa_node.dropped:
			casa_node.dropped = true
			ad.show()
		if is_released and not casa_node.released:
			casa_node.released = true
	if is_released and ad.get_parent() != null and ad.get_parent() != _map():
		var map := _map()
		if map:
			ad.reparent(map)
			ad.show()
			ad.freeze = true


@rpc("authority", "reliable", "call_local")
func BroadcastAirdropLanding(pos: Vector3, rot: Vector3) -> void:
	var ad := _find_airdrop()
	if ad == null: return
	ad.global_position = pos
	ad.global_rotation = rot
	if ad is RigidBody3D:
		ad.freeze = true
		ad.linear_velocity = Vector3.ZERO
		ad.angular_velocity = Vector3.ZERO
	_reseed_airdrop_loot(ad, pos)


func _find_airdrop() -> Node:
	var map := _map()
	if map:
		for child in map.get_children():
			if child.name.begins_with("Airdrop") and child is RigidBody3D:
				return child
	var es := _find_event_system()
	if es:
		for casa in es.get_children():
			var ad: Node = casa.get_node_or_null("Airdrop")
			if ad:
				return ad
	return null


func _reseed_airdrop_loot(container: Node, landing_pos: Vector3) -> void:
	if not container.has_method("GenerateLoot"):
		return
	if container.get("loot") != null:
		container.loot.clear()
	if container.get("storage") != null:
		container.storage.clear()
	if container.get("storaged") != null:
		container.storaged = false
	for c in container.get_children():
		if c.is_in_group("Item"):
			c.queue_free()
	var players := _players()
	var pos_hash: int = players.CoopPosHash(landing_pos) if players and players.has_method("CoopPosHash") else hash(str(landing_pos))
	var session_seed: int = players._ensure_session_seed() if players and players.has_method("_ensure_session_seed") else 0
	seed(pos_hash ^ session_seed)
	if not container.custom.is_empty() and container.get("force"):
		container.table = container.custom.pick_random()
		for index in container.table.items.size():
			container.CreateLoot(container.table.items[index])
	elif not container.custom.is_empty():
		container.table = container.custom.pick_random()
		container.ClearBuckets()
		if container.has_method("FillBucketsCustom"):
			container.FillBucketsCustom()
		else:
			container.FillBuckets()
		container.GenerateLoot()
	else:
		container.ClearBuckets()
		container.FillBuckets()
		container.GenerateLoot()
	randomize()


@rpc("authority", "reliable", "call_remote")
func BroadcastBTRFire(btr_name: String, full_auto: bool) -> void:
	var es := _find_event_system()
	if es == null: return
	var btr: Node = es.get_node_or_null(btr_name)
	if btr == null: return
	btr.fullAuto = full_auto
	btr.playerDistance = btr.global_position.distance_to(gameData.playerPosition)
	btr.set_meta("_coop_remote_fire", true)
	btr.Muzzle()
	btr.PlayFire()
	btr.PlayTail()
	if btr.playerDistance > BTR_CRACK_DISTANCE_THRESHOLD:
		var tree = get_tree()
		if tree == null:
			return
		await tree.create_timer(BTR_CRACK_DELAY_S, false).timeout
		if get_tree() == null:
			return
		if is_instance_valid(btr):
			btr.PlayCrack()


@rpc("authority", "reliable", "call_remote")
func BroadcastRocketExplode(pos: Vector3) -> void:
	var best: Node = null
	var best_dist: float = ROCKET_EXPLODE_MATCH_RADIUS
	for rocket in get_tree().get_nodes_in_group("CoopRocket"):
		if not is_instance_valid(rocket):
			continue
		var d: float = rocket.global_position.distance_to(pos)
		if d < best_dist:
			best_dist = d
			best = rocket
	if best:
		best.queue_free()
	var explosion_scene := load("res://Effects/Explosion.tscn")
	if explosion_scene:
		var instance = explosion_scene.instantiate()
		get_tree().get_root().add_child(instance)
		instance.global_position = pos
		instance.size = ROCKET_EXPLOSION_SIZE
		if instance.has_method("Explode"):
			instance.Explode()


@rpc("authority", "reliable", "call_remote")
func BroadcastRocketCleanup(pos: Vector3) -> void:
	var best: Node = null
	var best_dist: float = ROCKET_CLEANUP_MATCH_RADIUS
	for rocket in get_tree().get_nodes_in_group("CoopRocket"):
		if not is_instance_valid(rocket):
			continue
		var d: float = rocket.global_position.distance_to(pos)
		if d < best_dist:
			best_dist = d
			best = rocket
	if best:
		best.queue_free()


@rpc("authority", "reliable", "call_remote")
func BroadcastHelicopterSpotted() -> void:
	Loader.Message("발각되었습니다!", Color.RED)


@rpc("any_peer", "reliable", "call_remote")
func RequestSleepReady(hours: int) -> void:
	if not multiplayer.is_server():
		return
	HostToggleSleepReady(multiplayer.get_remote_sender_id(), hours)


func HostToggleSleepReady(peer_id: int, hours: int) -> void:
	if not multiplayer.is_server() or _sleep_in_progress:
		return
	if _sleep_ready.has(peer_id):
		_sleep_ready.erase(peer_id)
	else:
		_sleep_ready[peer_id] = hours
	var coop := RTVCoop.get_instance()
	var total: int = 1 + (coop.net.GetPeerIds().size() if coop and coop.net else 0)
	var ready_ids: Array = _sleep_ready.keys()
	BroadcastSleepStatus.rpc(ready_ids, total)
	if _sleep_ready.size() >= total:
		var max_hours: int = 0
		for id in _sleep_ready:
			if int(_sleep_ready[id]) > max_hours:
				max_hours = int(_sleep_ready[id])
		_sleep_in_progress = true
		_sleep_ready.clear()
		BroadcastSleepStatus.rpc([], total)
		BroadcastSleep.rpc(max_hours)


@rpc("authority", "reliable", "call_local")
func BroadcastSleepStatus(ready_ids: Array, total: int) -> void:
	var players := _players()
	if players:
		players.set_meta("coop_sleep_ready_ids", ready_ids)
		players.set_meta("coop_sleep_total", total)
	# v0.13.54: 수면 준비 카운트를 채팅으로 통합 (상단 SleepOverlay 표시 폐지 — transition vote와 동일 패턴)
	if total > 1 and ready_ids.size() > 0:
		var chat = Engine.get_meta("ChatOverlay", null)
		if chat and chat.has_method("add_message"):
			chat.add_message("수면 준비 [%d/%d]" % [ready_ids.size(), total], "#b8a0ff")


@rpc("authority", "reliable", "call_local")
func BroadcastSleep(sleep_hours: int) -> void:
	gameData.isSleeping = true
	gameData.freeze = true
	Simulation.simulate = false

	var sleep_time: float = sleep_hours * SLEEP_HOUR_TO_SIM_TIME
	var current_time: float = Simulation.time
	var combined_time: float = current_time + sleep_time
	if combined_time >= DAY_DURATION:
		Simulation.day += 1
		Simulation.time = combined_time - DAY_DURATION
		Simulation.weatherTime -= sleep_time
	else:
		Simulation.time = combined_time
		Simulation.weatherTime -= sleep_time

	gameData.energy -= SLEEP_ENERGY_DRAIN
	gameData.hydration -= SLEEP_HYDRATION_DRAIN
	gameData.mental += SLEEP_MENTAL_REGEN

	Loader.Message("%d시간 잤습니다" % sleep_hours, Color.GREEN)

	var tree = get_tree()
	if tree == null:
		return
	await tree.create_timer(float(sleep_hours), false).timeout

	if not is_instance_valid(self) or get_tree() == null:
		return

	Simulation.simulate = true
	gameData.isSleeping = false
	gameData.freeze = false
	_sleep_in_progress = false

	for collider in get_tree().get_nodes_in_group("Interactable"):
		var node: Node = collider
		while node:
			if node.get("canSleep") != null:
				node.canSleep = false
				break
			node = node.get_parent()


@rpc("any_peer", "reliable", "call_remote")
func RequestFireSync() -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	var fires: Array = []
	for fire in _all_fires():
		fires.append({"path": fire.get_path(), "active": bool(fire.active)})
	ApplyFireManifest.rpc_id(sender, fires)


@rpc("authority", "reliable", "call_remote")
func ApplyFireManifest(fires: Array) -> void:
	for entry in fires:
		var fire: Node = get_node_or_null(entry.get("path", NodePath()))
		if fire == null or not fire.has_method("Activate"):
			continue
		var desired: bool = bool(entry.get("active", false))
		if fire.active == desired:
			continue
		fire.active = desired
		if desired:
			fire.Activate()
		else:
			fire.Deactivate()


func _all_fires() -> Array:
	var out: Array = []
	var scene := get_tree().current_scene
	if scene == null:
		return out
	BaseSync.coop_walk(scene, func(node):
		if node.has_method("Activate") and node.has_method("Deactivate") and node.get("active") != null and node.get("force") != null:
			var s = node.get_script()
			if s and str(s.resource_path).find("Fire") != -1:
				out.append(node)
		return false
	)
	return out


@rpc("any_peer", "reliable", "call_remote")
func RequestFireToggle(fire_path: NodePath) -> void:
	if not multiplayer.is_server():
		return
	var fire: Node = get_node_or_null(fire_path)
	if fire == null or not fire.has_method("Activate"):
		return
	if not fire.active:
		fire.active = true
		fire.Activate()
		fire.IgniteAudio()
	else:
		fire.active = false
		fire.Deactivate()
		fire.ExtinguishAudio()
	BroadcastFireState.rpc(fire_path, fire.active)


@rpc("authority", "reliable", "call_remote")
func BroadcastFireState(fire_path: NodePath, is_active: bool) -> void:
	var fire: Node = get_node_or_null(fire_path)
	if fire == null or not fire.has_method("Activate"):
		return
	fire.active = is_active
	if is_active:
		fire.Activate()
		fire.IgniteAudio()
	else:
		fire.Deactivate()
		fire.ExtinguishAudio()


@rpc("authority", "unreliable", "call_remote")
func BroadcastSimulationState(time: float, day: int, weather: String, weather_time: float, season: int) -> void:
	Simulation.time = time
	Simulation.day = day
	Simulation.weather = weather
	Simulation.weatherTime = weather_time
	Simulation.season = season
