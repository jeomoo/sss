extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

func _setup_hooks() -> void:
	CoopHook.register(self, "btr-_ready-post", _on_btr_ready_post)
	CoopHook.register_replace_or_post(self, "btr-_physics_process", _replace_btr_physics, _post_btr_physics)
	CoopHook.register(self, "btr-muzzle-post", _on_btr_muzzle_post)

	CoopHook.register(self, "casa-_ready-post", _on_casa_ready_post)
	CoopHook.register_replace_or_post(self, "casa-_physics_process", _replace_casa_physics, _noop)
	CoopHook.register(self, "casa-_physics_process-post", _post_casa_physics)
	CoopHook.register_replace_or_post(self, "casa-collided", _replace_casa_collided, _noop)
	CoopHook.register(self, "casa-collided-post", _post_casa_collided)

	CoopHook.register(self, "helicopter-_ready-post", _on_helicopter_ready_post)
	CoopHook.register_replace_or_post(self, "helicopter-_physics_process", _replace_helicopter_physics, _post_helicopter_physics)
	CoopHook.register_replace_or_post(self, "helicopter-firerockets", _replace_helicopter_fire, _noop)
	CoopHook.register(self, "helicopter-firerockets-post", _post_helicopter_fire)
	CoopHook.register_replace_or_post(self, "helicopter-spotted", _replace_helicopter_spotted, _noop)
	CoopHook.register(self, "helicopter-spotted-post", _post_helicopter_spotted)
	CoopHook.register_replace_or_post(self, "helicopter-sensor", _replace_helicopter_sensor, _post_helicopter_sensor)

	CoopHook.register(self, "police-_ready-post", _on_police_ready_post)
	CoopHook.register_replace_or_post(self, "police-_physics_process", _replace_police_physics, _post_police_physics)

	CoopHook.register(self, "rocketgrad-executelaunch-post", _on_rocketgrad_launch_post)
	CoopHook.register_replace_or_post(self, "rocketgrad-_process", _replace_rocketgrad_process, _noop)
	CoopHook.register(self, "rocketgrad-_process-post", _post_rocketgrad_process)

	CoopHook.register(self, "rockethelicopter-_ready-post", _on_rockethelicopter_ready_post)
	CoopHook.register_replace_or_post(self, "rockethelicopter-_physics_process", _replace_rockethelicopter_physics, _post_rockethelicopter_physics)

	CoopHook.register_replace_or_post(self, "missilespawner-executelaunchmissiles", _replace_missile_launch, _post_missile_launch)


func _noop() -> void:
	pass

func _on_btr_ready_post() -> void:
	var btr := CoopHook.caller()
	if btr == null or not CoopAuthority.is_active():
		return
	if CoopAuthority.is_host():
		if world:
			world.register_vehicle(btr)
	else:
		btr.freeze = true


func _replace_btr_physics(delta: float) -> void:
	var btr := CoopHook.caller()
	if btr == null:
		return
	if CoopAuthority.is_active() and not CoopAuthority.is_host():
		btr.Tires(delta)
		btr.Suspension(delta)
		CoopHook.skip_super()


func _post_btr_physics(_delta: float) -> void:
	pass


func _on_btr_muzzle_post() -> void:
	var btr := CoopHook.caller()
	if btr == null:
		return
	if btr.has_meta("_coop_remote_fire"):
		btr.remove_meta("_coop_remote_fire")
		return
	if CoopAuthority.is_host() and CoopAuthority.is_active() and event:
		event.BroadcastBTRFire.rpc(btr.name, btr.fullAuto)


func _on_casa_ready_post() -> void:
	var casa := CoopHook.caller()
	if casa == null or not CoopAuthority.is_active():
		return
	if CoopAuthority.is_host():
		if world:
			world.register_vehicle(casa)
	else:
		if casa.get("airdrop"):
			casa.airdrop.freeze = true
			casa.airdrop.sleeping = true


func _replace_casa_physics(delta: float) -> void:
	var casa := CoopHook.caller()
	if casa == null:
		return
	if CoopAuthority.is_active() and not CoopAuthority.is_host():
		casa.leftPropeller.rotation.z += delta * 20.0
		casa.rightPropeller.rotation.z += delta * 20.0
		casa.Parachute(delta)
		CoopHook.skip_super()


func _post_casa_physics(_delta: float) -> void:
	var casa := CoopHook.caller()
	if casa == null or not CoopAuthority.is_host() or not CoopAuthority.is_active():
		return
	if not casa.dropped or not casa.airdrop or not is_instance_valid(casa.airdrop) or not casa.airdrop.is_inside_tree():
		return
	if event:
		event.BroadcastAirdropPose.rpc(casa.name, casa.airdrop.global_position, casa.airdrop.global_rotation, casa.released)


func _replace_casa_collided(_body: Node3D) -> void:
	if CoopAuthority.is_active() and not CoopAuthority.is_host():
		CoopHook.skip_super()


func _post_casa_collided(_body: Node3D) -> void:
	var casa := CoopHook.caller()
	if casa == null or not CoopAuthority.is_host() or not CoopAuthority.is_active():
		return
	if event and casa.airdrop:
		event.BroadcastAirdropLanding.rpc(casa.airdrop.global_position, casa.airdrop.global_rotation)


func _on_helicopter_ready_post() -> void:
	var heli := CoopHook.caller()
	if heli == null or not CoopAuthority.is_active() or not CoopAuthority.is_host():
		return
	if world:
		world.register_vehicle(heli)


func _replace_helicopter_physics(delta: float) -> void:
	var heli := CoopHook.caller()
	if heli == null:
		return
	if CoopAuthority.is_active() and not CoopAuthority.is_host():
		heli.RotorBlades(delta)
		CoopHook.skip_super()


func _post_helicopter_physics(_delta: float) -> void:
	pass


func _replace_helicopter_fire() -> void:
	var heli := CoopHook.caller()
	if heli == null:
		return
	if CoopAuthority.is_active() and not CoopAuthority.is_host() and not heli.has_meta("_coop_remote_fire"):
		CoopHook.skip_super()


func _post_helicopter_fire() -> void:
	var heli := CoopHook.caller()
	if heli == null:
		return
	if heli.has_meta("_coop_remote_fire"):
		heli.remove_meta("_coop_remote_fire")
		return
	if CoopAuthority.is_host() and CoopAuthority.is_active() and event:
		event.BroadcastHelicopterRockets.rpc(heli.name, heli.global_position, heli.global_rotation)


func _replace_helicopter_spotted() -> void:
	if CoopAuthority.is_active() and not CoopAuthority.is_host():
		CoopHook.skip_super()


func _post_helicopter_spotted() -> void:
	if CoopAuthority.is_host() and CoopAuthority.is_active() and event:
		event.BroadcastHelicopterSpotted.rpc()


func _replace_helicopter_sensor(_delta: float) -> void:
	if CoopAuthority.is_active() and not CoopAuthority.is_host():
		CoopHook.skip_super()


func _post_helicopter_sensor(_delta: float) -> void:
	pass


func _on_police_ready_post() -> void:
	var police := CoopHook.caller()
	if police == null or not CoopAuthority.is_active():
		return
	if CoopAuthority.is_host():
		if world:
			world.register_vehicle(police)
	else:
		police.freeze = true
		police.set_meta("_coop_client_prev_pos", police.global_position)


func _replace_police_physics(delta: float) -> void:
	var police := CoopHook.caller()
	if police == null:
		return
	if CoopAuthority.is_active() and not CoopAuthority.is_host():
		var prev: Vector3 = police.get_meta("_coop_client_prev_pos", police.global_position)
		var vel: Vector3 = (police.global_position - prev) / max(delta, 0.001)
		police.set_meta("_coop_client_prev_pos", police.global_position)
		var fwd: float = vel.dot(police.global_transform.basis.z)
		police.Tire_FL.rotation.y = lerp_angle(police.Tire_FL.rotation.y, 0.0, delta * police.steerSmoothness)
		police.Tire_FR.rotation.y = lerp_angle(police.Tire_FR.rotation.y, 0.0, delta * police.steerSmoothness)
		police.Tire_FL.rotation.x += fwd * delta
		police.Tire_FR.rotation.x += fwd * delta
		police.Tire_RL.rotation.x += fwd * delta
		police.Tire_RR.rotation.x += fwd * delta
		police.Suspension(delta)
		police.Wobble(delta)
		police.Audio(delta)
		if "currentState" in police and police.currentState == police.State.Boss:
			police.police.rotation.y += delta * 20.0
		CoopHook.skip_super()


func _post_police_physics(_delta: float) -> void:
	pass


func _on_rocketgrad_launch_post(_value: bool = true) -> void:
	var rocket := CoopHook.caller()
	if rocket == null:
		return
	rocket.add_to_group("CoopRocket")
	if CoopAuthority.is_host() and CoopAuthority.is_active() and world:
		world.register_rocket(rocket)


func _replace_rocketgrad_process(_delta: float) -> void:
	if CoopAuthority.is_active() and not CoopAuthority.is_host():
		CoopHook.skip_super()


func _post_rocketgrad_process(_delta: float) -> void:
	var rocket := CoopHook.caller()
	if rocket == null or rocket.has_meta("_coop_cleared") or not rocket.launched:
		return
	const GRAD_CLEANUP_OVERSHOOT := 100.0
	if rocket.global_position.z > abs(rocket.tracking) + GRAD_CLEANUP_OVERSHOOT:
		rocket.set_meta("_coop_cleared", true)
		if CoopAuthority.is_host() and CoopAuthority.is_active() and event:
			event.BroadcastRocketCleanup.rpc(rocket.global_position)


func _on_rockethelicopter_ready_post() -> void:
	var rocket := CoopHook.caller()
	if rocket == null:
		return
	rocket.add_to_group("CoopRocket")
	if CoopAuthority.is_host() and CoopAuthority.is_active() and world:
		world.register_rocket(rocket)


func _replace_rockethelicopter_physics(_delta: float) -> void:
	if CoopAuthority.is_active() and not CoopAuthority.is_host():
		CoopHook.skip_super()


func _post_rockethelicopter_physics(_delta: float) -> void:
	pass


func _replace_missile_launch(value: bool) -> void:
	var spawner := CoopHook.caller()
	if spawner == null:
		return
	if Engine.is_editor_hint() or not CoopAuthority.is_active():
		return
	if not CoopAuthority.is_host():
		spawner.launchMissiles = false
		CoopHook.skip_super()
		return
	CoopHook.skip_super()
	_coop_host_missile_launch(spawner)


func _post_missile_launch(_value: bool) -> void:
	pass


func _coop_host_missile_launch(spawner: Node) -> void:
	var pool: Array = spawner.get_children().filter(func(n): return n.has_method("ExecuteLaunch"))
	var needs_prepare: bool = pool.is_empty()
	if needs_prepare:
		spawner.ExecutePrepareMissiles(true)
		pool = spawner.get_children().filter(func(n): return n.has_method("ExecuteLaunch"))

	if world and needs_prepare:
		world.BroadcastMissilePrepare.rpc(spawner.get_path())

	pool.shuffle()
	spawner.launched = true
	var total: int = pool.size()
	var fired: int = 0
	for element in pool:
		var tree = get_tree()
		if tree == null:
			break
		await tree.create_timer(randf_range(0.0, spawner.launchDelay)).timeout
		if get_tree() == null:
			break
		if not is_instance_valid(element):
			continue
		element.visible = true
		element.ExecuteLaunch(true)
		if world:
			world.BroadcastMissileLaunch.rpc(spawner.get_path(), element.get_index())
		fired += 1
		if fired == total:
			spawner.launched = false
	spawner.launchMissiles = false
