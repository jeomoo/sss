class_name CoopSettings extends Node



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")
const RTVCoop = preload("res://mods/RTVCoop/Game/Coop.gd")

const DEFAULTS := {
	"loot_multiplier": 1.0,
	"stats_drain_multiplier": 1.0,
	"ai_multiplier": 1.0,
	"day_rate_multiplier": 1.0,
	"night_rate_multiplier": 1.0,
}


var _values: Dictionary = {}


func _enter_tree() -> void:
	_values = DEFAULTS.duplicate()
	var coop := RTVCoop.get_instance()
	if coop:
		coop.settings = self


func _exit_tree() -> void:
	var coop := RTVCoop.get_instance()
	if coop and coop.settings == self:
		coop.settings = null


func _ready() -> void:
	var coop := RTVCoop.get_instance()
	if coop and coop.net:
		coop.net.disconnected.connect(_reset_to_defaults)
		coop.net.peer_joined.connect(_on_peer_joined)


func Get(key: String, fallback: float = 1.0) -> float:
	return float(_values.get(key, fallback))


func Set(key: String, value: float) -> void:
	_values[key] = value
	_notify_changed(key, value)
	if CoopAuthority.is_host() and CoopAuthority.is_active():
		Broadcast.rpc(_values)


func GetAll() -> Dictionary:
	return _values.duplicate()


func _reset_to_defaults() -> void:
	_values = DEFAULTS.duplicate()
	for key in _values:
		_notify_changed(key, _values[key])


func _on_peer_joined(peer_id: int) -> void:
	if multiplayer.is_server():
		Broadcast.rpc_id(peer_id, _values)


@rpc("authority", "call_remote", "reliable")
func Broadcast(values: Dictionary) -> void:
	_values = values.duplicate()
	for key in _values:
		_notify_changed(key, _values[key])


func _notify_changed(key: String, value: Variant) -> void:
	var coop := RTVCoop.get_instance()
	if coop and coop.events:
		coop.events.setting_changed.emit(key, value)
