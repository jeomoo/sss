class_name RTVCoop extends Node



const CoopEvents = preload("res://mods/RTVCoop/Framework/CoopEvents.gd")
const CoopScene = preload("res://mods/RTVCoop/Game/CoopScene.gd")
const _SyncService = preload("res://mods/RTVCoop/Framework/SyncService.gd")
const _PlayerStateProxy = preload("res://mods/RTVCoop/Framework/PlayerStateProxy.gd")

signal boot_complete


var events: CoopEvents
var scene: CoopScene
var sync_service: Node
var player_states: Node = null
var net: Node = null
var lobby: Node = null
var players: Node = null
var settings: Node = null

var _booted: bool = false


static func get_instance() -> RTVCoop:
	return Engine.get_meta("Coop", null) as RTVCoop


static func has_instance() -> bool:
	return Engine.has_meta("Coop")


func _enter_tree() -> void:
	name = "RTVCoop"
	if Engine.has_meta("Coop") and Engine.get_meta("Coop") != self:
		push_warning("[RTVCoop] Coop meta already set; overwriting (hot reload?)")
	Engine.set_meta("Coop", self)
	set_meta("coop_active", false)


func _exit_tree() -> void:
	if Engine.get_meta("Coop", null) == self:
		Engine.remove_meta("Coop")


func boot() -> void:
	if _booted:
		return

	sync_service = _SyncService.new()
	sync_service.name = "SyncService"
	add_child(sync_service)

	events = CoopEvents.new()
	events.name = "Events"
	add_child(events)

	scene = CoopScene.new()
	scene.name = "Scene"
	add_child(scene)

	player_states = Node.new()
	player_states.name = "PlayerStates"
	add_child(player_states)

	_booted = true
	boot_complete.emit()
	print("[RTVCoop] service locator booted (sync_service + events + scene ready)")


func register_sync(key: String, module: Node) -> void:
	sync_service.register(key, module)


func get_sync(key: String) -> Node:
	return sync_service.get_module(key) if sync_service else null


func ensure_player_proxy(peer_id: int) -> Node:
	if player_states == null:
		return null
	var proxy_name := "State_%d" % peer_id
	var existing := player_states.get_node_or_null(proxy_name)
	if existing:
		return existing
	var proxy: Node = _PlayerStateProxy.new()
	proxy.name = proxy_name
	player_states.add_child(proxy)
	return proxy


func remove_player_proxy(peer_id: int) -> void:
	if player_states == null:
		return
	var proxy := player_states.get_node_or_null("State_%d" % peer_id)
	if proxy:
		proxy.queue_free()


func get_player_proxy(peer_id: int) -> Node:
	if player_states == null:
		return null
	return player_states.get_node_or_null("State_%d" % peer_id)


func clear_player_proxies() -> void:
	if player_states == null:
		return
	for child in player_states.get_children():
		child.queue_free()
