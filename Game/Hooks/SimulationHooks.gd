extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

var _sim_broadcast_accum: float = 0.0
const SIM_BROADCAST_RATE: float = 1.0

func _setup_hooks() -> void:
	CoopHook.register_replace_or_post(self, "simulation-_process", _replace_simulation_process, _post_simulation_process)


func _replace_simulation_process(delta: float) -> void:
	var sim := CoopHook.caller()
	if sim == null or not CoopAuthority.is_active():
		return
	if CoopAuthority.is_client():
		if sim.simulate:
			CoopHook.skip_super()
		return

	if not sim.simulate:
		return

	if settings:
		var is_day: bool = sim.time >= 600.0 and sim.time < 1800.0
		var key: String = "day_rate_multiplier" if is_day else "night_rate_multiplier"
		var mult: float = settings.Get(key, 1.0)
		if mult != 1.0:
			sim.time += delta * (mult - 1.0)

	_sim_broadcast_accum += delta
	if _sim_broadcast_accum >= 1.0 / SIM_BROADCAST_RATE:
		_sim_broadcast_accum = 0.0
		if event:
			event.BroadcastSimulationState.rpc(sim.time, sim.day, sim.weather, sim.weatherTime, sim.season)


func _post_simulation_process(_delta: float) -> void:
	pass
