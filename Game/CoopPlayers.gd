class_name CoopPlayers extends Node



const ContainerSync = preload("res://mods/RTVCoop/Game/Sync/ContainerSync.gd")
const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")
const CoopCharacterBuffer = preload("res://mods/RTVCoop/Game/CoopCharacterBuffer.gd")
const CoopSceneFlow = preload("res://mods/RTVCoop/Game/CoopSceneFlow.gd")
const FurnitureSync = preload("res://mods/RTVCoop/Game/Sync/FurnitureSync.gd")
const PickupSync = preload("res://mods/RTVCoop/Game/Sync/PickupSync.gd")
const RTVCoop = preload("res://mods/RTVCoop/Game/Coop.gd")

const REMOTE_PLAYER_PATH := "res://mods/RTVCoop/Scenes/RemotePlayer.tscn"


signal name_registry_synced(registry: Dictionary)
signal placement_token_received(token: int, uuid: int)


var peer_names: Dictionary = {}
var peer_uids: Dictionary = {}  # v0.13.57 peer_id→영구 uid (호스트가 캐릭터 세이브 키잉에 사용)
var remote_players: Dictionary = {}
var world_ai: Dictionary = {}
var ai_targets: Dictionary = {}
var next_ai_uuid: int = 0
var worldItems: Dictionary = {}
var worldFurniture: Dictionary = {}
var nextFurnitureId: int = 0
var nextUuid: int = 0
var nextContainerId: int = 1
var coop_session_seed: int = 0
var scene_visit_count: int = 0
var scene_ready: bool = false
var container_open_bypassed: bool = false
var coopCharacterBuffer: Resource = null
var _cached_local_character: Node = null
var _cached_local_controller: Node = null

var gameData: Resource = preload("res://Resources/GameData.tres")

var _remote_player_scene: PackedScene = null
var _buffer: CoopCharacterBuffer
var _scene_flow: CoopSceneFlow


func _enter_tree() -> void:
	var coop := RTVCoop.get_instance()
	if coop:
		coop.players = self


func _exit_tree() -> void:
	var coop := RTVCoop.get_instance()
	if coop and coop.players == self:
		coop.players = null


func _ready() -> void:
	_remote_player_scene = load(REMOTE_PLAYER_PATH)
	if _remote_player_scene == null:
		push_error("[CoopPlayers] Failed to load " + REMOTE_PLAYER_PATH)

	_buffer = CoopCharacterBuffer.new()
	_buffer.name = "CharacterBuffer"
	add_child(_buffer)

	_scene_flow = CoopSceneFlow.new()
	_scene_flow.name = "SceneFlow"
	add_child(_scene_flow)

	var coop := RTVCoop.get_instance()
	if coop == null or coop.net == null:
		push_error("[CoopPlayers] requires CoopNet; wiring aborted")
		return
	coop.net.disconnected.connect(_on_disconnected)
	coop.net.hosted.connect(_on_hosted)
	coop.net.joined.connect(_on_joined)
	coop.net.peer_joined.connect(_on_peer_joined)
	coop.net.peer_left.connect(_on_peer_left)
	if coop.events:
		coop.events.scene_ready.connect(_on_scene_ready)


# --- Roster ---

func GetMyDisplayName() -> String:
	var coop := RTVCoop.get_instance()
	if coop and coop.lobby and coop.lobby.available:
		return coop.lobby.MyName()
	return "Player %d" % CoopAuthority.local_peer_id()


const COOP_UID_PATH := "user://coop_uid.txt"
var _my_uid: String = ""

func GetMyUid() -> String:
	# v0.13.57: 설치별 영구 uid (1회 생성 후 평생 재사용). 이름 변경·LAN/Steam 무관 동일.
	# 캐릭터 세이브를 이 uid로 키잉 → 이름 바꿔도 진행 유지, 모드 리브랜딩에도 안전.
	if _my_uid != "":
		return _my_uid
	if FileAccess.file_exists(COOP_UID_PATH):
		var fr := FileAccess.open(COOP_UID_PATH, FileAccess.READ)
		if fr:
			_my_uid = fr.get_as_text().strip_edges()
			fr.close()
	if _my_uid == "":
		_my_uid = Crypto.new().generate_random_bytes(16).hex_encode()
		var fw := FileAccess.open(COOP_UID_PATH, FileAccess.WRITE)
		if fw:
			fw.store_string(_my_uid)
			fw.close()
		print("[CoopPlayers] generated new coop uid: %s" % _my_uid)
	return _my_uid


func GetPlayerName(peer_id: int) -> String:
	return peer_names.get(peer_id, "Player %d" % peer_id)


func GetPuppet(peer_id: int) -> Node:
	var puppet: Node = remote_players.get(peer_id, null)
	return puppet if is_instance_valid(puppet) else null


# --- Scene accessors ---

func GetLocalCharacter() -> Node:
	if is_instance_valid(_cached_local_character) and _cached_local_character.is_inside_tree():
		return _cached_local_character
	var coop := RTVCoop.get_instance()
	var scene: Node = coop.scene.current_map() if coop and coop.scene else null
	if scene == null:
		return null
	for node in scene.find_children("*", "", true, false):
		if node.has_method("ExplosionDamage") and not node.get_meta("coop_puppet_mode", false):
			_cached_local_character = node
			return node
	return null


func GetLocalController() -> Node:
	if is_instance_valid(_cached_local_controller) and _cached_local_controller.is_inside_tree():
		if not _cached_local_controller.is_in_group("CoopPlayer"):
			_cached_local_controller.add_to_group("CoopPlayer")
		return _cached_local_controller
	var coop := RTVCoop.get_instance()
	var scene: Node = coop.scene.current_map() if coop and coop.scene else null
	if scene == null:
		return null
	var controller: Node = scene.get_node_or_null("Character")
	if controller:
		_cached_local_controller = controller
		if not controller.is_in_group("CoopPlayer"):
			controller.add_to_group("CoopPlayer")
		return controller
	for node in scene.find_children("*", "CharacterBody3D", true, false):
		if not node.get_meta("coop_puppet_mode", false):
			_cached_local_controller = node
			if not node.is_in_group("CoopPlayer"):
				node.add_to_group("CoopPlayer")
			return node
	return null


func GetLocalInterface() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.scene.interface() if coop and coop.scene else null


# --- Session seed ---

func ResetSessionSeed() -> void:
	coop_session_seed = 0


func CoopSeedForNode(node: Node) -> int:
	if coop_session_seed == 0 or node == null:
		return 0
	var path_hash: int = hash(str(node.get_path()))
	return int(coop_session_seed ^ path_hash ^ (scene_visit_count * 7919)) & 0x7FFFFFFF


func CoopNodeId(node: Node) -> int:
	if node == null:
		return 0
	return abs(hash(str(node.get_path())))


func CoopPosHash(pos: Vector3) -> int:
	return abs(hash(Vector3i(int(pos.x * 100), int(pos.y * 100), int(pos.z * 100))))


func _make_session_seed() -> int:
	var t := Time.get_unix_time_from_system()
	var s: int = (int(t) ^ int(t * 1000.0)) & 0x7FFFFFFF
	return s if s != 0 else 1


func _ensure_session_seed() -> int:
	if coop_session_seed != 0:
		return coop_session_seed
	if not CoopAuthority.is_host():
		return 0
	coop_session_seed = _make_session_seed()
	if CoopAuthority.is_active():
		DeliverSessionSeed.rpc(coop_session_seed)
	return coop_session_seed


@rpc("authority", "call_remote", "reliable")
func DeliverSessionSeed(seed_value: int) -> void:
	coop_session_seed = seed_value


# --- Puppet lifecycle ---

func ReconcilePuppets() -> void:
	var map: Node = _scene_flow.GetMap() if _scene_flow else null
	if map == null:
		for id in remote_players.keys().duplicate():
			if not is_instance_valid(remote_players[id]):
				remote_players.erase(id)
		return

	var my_id: int = CoopAuthority.local_peer_id()
	var known: Array = peer_names.keys()

	for peer_id in known:
		if peer_id == my_id:
			continue
		if not remote_players.has(peer_id) or not is_instance_valid(remote_players[peer_id]):
			if remote_players.has(peer_id):
				remote_players.erase(peer_id)
			SpawnPuppet(peer_id)

	var to_remove: Array = []
	for peer_id in remote_players.keys():
		if not (peer_id in known):
			to_remove.append(peer_id)
	for peer_id in to_remove:
		DespawnPuppet(peer_id)


func SpawnPuppet(peer_id: int) -> void:
	var map: Node = _scene_flow.GetMap() if _scene_flow else null
	if map == null or _remote_player_scene == null:
		push_warning("[CoopPlayers] SpawnPuppet aborted peer=%d" % peer_id)
		return

	var puppet: Node = _remote_player_scene.instantiate()
	puppet.peer_id = peer_id
	puppet.name = "RemotePlayer_%d" % peer_id
	map.add_child(puppet)
	remote_players[peer_id] = puppet

	var local_ctrl: Node = map.get_node_or_null("Character")
	if local_ctrl and local_ctrl.is_inside_tree() and puppet is Node3D:
		puppet.global_position = local_ctrl.global_position
	elif map is Node3D:
		puppet.global_position = map.global_position

	# fix9.7: RemotePlayer 본체 layer=2 vanilla 유지 + collision exception 제거 →
	# 호스트 controller(mask=2147483691 bit 2)가 layer 2 봄 → user-pass 막힘.

	var coop := RTVCoop.get_instance()
	if coop and coop.events:
		coop.events.puppet_spawned.emit(peer_id, puppet)
	print("[CoopPlayers] spawned puppet for peer %d" % peer_id)


func DespawnPuppet(peer_id: int) -> void:
	if not remote_players.has(peer_id):
		return
	var puppet: Node = remote_players[peer_id]
	if is_instance_valid(puppet):
		puppet.queue_free()
	remote_players.erase(peer_id)
	var coop := RTVCoop.get_instance()
	if coop and coop.events:
		coop.events.puppet_despawned.emit(peer_id)
	print("[CoopPlayers] despawned puppet for peer %d" % peer_id)


# --- Peer events ---

func _on_hosted() -> void:
	peer_names.clear()
	peer_uids.clear()
	peer_names[1] = GetMyDisplayName()
	peer_uids[1] = GetMyUid()
	print("[CoopPlayers] Host name: %s" % peer_names[1])
	var coop := RTVCoop.get_instance()
	if coop:
		coop.ensure_player_proxy(1)
	_emit_peer_joined(1, peer_names[1])


func _on_joined() -> void:
	var my_name := GetMyDisplayName()
	print("[CoopPlayers] Reporting name to host: %s" % my_name)
	ReportPlayerName.rpc_id(1, my_name, GetMyUid())


func _on_peer_joined(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	if coop_session_seed == 0:
		coop_session_seed = _make_session_seed()
	var tree = get_tree()
	if tree == null:
		return
	await tree.create_timer(0.5, false).timeout
	if not is_instance_valid(self) or get_tree() == null or not CoopAuthority.is_active():
		return
	if not multiplayer.get_peers().has(peer_id):
		return
	SyncNameRegistry.rpc(peer_names)
	DeliverSessionSeed.rpc_id(peer_id, coop_session_seed)

	var coop := RTVCoop.get_instance()
	if coop and coop.settings and coop.settings.has_method("GetAll") and coop.settings.has_method("Broadcast"):
		coop.settings.Broadcast.rpc_id(peer_id, coop.settings.GetAll())

	var qs: Node = coop.get_sync("quest") if coop else null
	if qs and qs.has_method("push_full_state_to"):
		qs.push_full_state_to(peer_id)

	var map: Node = _scene_flow.GetMap() if _scene_flow else null
	if map:
		var map_name: String = str(map.get("mapName")) if map.get("mapName") else ""
		if map_name != "":
			var controller: Node = GetLocalController()
			var host_pos: Vector3 = controller.global_position if controller else Vector3.ZERO
			_scene_flow.HostSceneReady.rpc_id(peer_id, map_name, host_pos, coop_session_seed)

	var ds: Node = coop.get_sync("downed") if coop else null
	if ds and ds.has_method("push_state_to"):
		ds.push_state_to(peer_id)

	var fs: Node = coop.get_sync("furniture") if coop else null
	if fs and fs.has_method("push_state_to"):
		fs.push_state_to(peer_id)

	if _scene_flow and _scene_flow.has_method("PushLootStateTo"):
		_scene_flow.PushLootStateTo(peer_id)

	if _buffer:
		_buffer.TryDeliverTo(peer_id)


func _on_peer_left(peer_id: int) -> void:
	var display_name: String = peer_names.get(peer_id, "")
	if peer_names.has(peer_id):
		peer_names.erase(peer_id)
	peer_uids.erase(peer_id)
	_emit_peer_left(peer_id, display_name)
	DespawnPuppet(peer_id)
	var coop := RTVCoop.get_instance()
	if coop:
		coop.remove_player_proxy(peer_id)
	if multiplayer.is_server() and CoopAuthority.is_active():
		SyncNameRegistry.rpc(peer_names)
		var cs: Node = coop.get_sync("container") if coop else null
		if cs and cs.has_method("release_holders_for_peer"):
			cs.release_holders_for_peer(peer_id)
		var es: Node = coop.get_sync("event") if coop else null
		if es and "_sleep_ready" in es and es._sleep_ready.has(peer_id):
			es._sleep_ready.erase(peer_id)
			var total: int = 1 + (coop.net.GetPeerIds().size() if coop.net else 0)
			if es.has_method("BroadcastSleepStatus"):
				es.BroadcastSleepStatus.rpc(es._sleep_ready.keys(), total)
		var ds: Node = coop.get_sync("downed") if coop else null
		if ds and ds.has_method("on_peer_left"):
			ds.on_peer_left(peer_id)


func _on_disconnected() -> void:
	if _buffer and not CoopAuthority.is_host():
		_buffer.Clear()
	for id in remote_players.keys().duplicate():
		DespawnPuppet(id)
	var coop := RTVCoop.get_instance()
	if coop:
		coop.clear_player_proxies()
		var cs: Node = coop.get_sync("container") if coop else null
		if cs and "_container_holders" in cs:
			cs._container_holders.clear()
		var es: Node = coop.get_sync("event") if coop else null
		if es:
			if "_sleep_ready" in es:
				es._sleep_ready.clear()
			if "_sleep_in_progress" in es:
				es._sleep_in_progress = false
		var ds: Node = coop.get_sync("downed") if coop else null
		if ds and ds.has_method("clear_state"):
			ds.clear_state()
	peer_names.clear()
	remote_players.clear()
	world_ai.clear()
	ai_targets.clear()
	worldItems.clear()
	worldFurniture.clear()
	next_ai_uuid = 0
	nextFurnitureId = 0
	nextUuid = 0
	nextContainerId = 1
	scene_ready = false
	coop_session_seed = 0
	scene_visit_count = 0
	coopCharacterBuffer = null
	if _scene_flow:
		_scene_flow.Reset()
	_cached_local_character = null
	_cached_local_controller = null


func _on_scene_ready(_scene_root: Node) -> void:
	scene_ready = true
	_cached_local_character = null
	_cached_local_controller = null
	ReconcilePuppets()


@rpc("any_peer", "call_remote", "reliable")
func ReportPlayerName(display_name: String, uid: String = "") -> void:
	if not multiplayer.is_server():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	peer_names[sender_id] = display_name
	if uid != "":
		peer_uids[sender_id] = uid  # v0.13.57 세이브 키잉용 (TryDeliverTo 0.5초 await 안에 도착)
	print("[CoopPlayers] Registered peer %d = '%s' (uid=%s)" % [sender_id, display_name, uid])
	var coop := RTVCoop.get_instance()
	if coop:
		coop.ensure_player_proxy(sender_id)
	SyncNameRegistry.rpc(peer_names)
	_emit_peer_joined(sender_id, display_name)
	ReconcilePuppets()


@rpc("authority", "call_remote", "reliable")
func SyncNameRegistry(registry: Dictionary) -> void:
	peer_names = registry.duplicate()
	print("[CoopPlayers] Name registry synced (%d players)" % peer_names.size())
	_reconcile_player_proxies()
	name_registry_synced.emit(peer_names)
	for id in peer_names:
		_emit_peer_joined(id, peer_names[id])
	ReconcilePuppets()


func _reconcile_player_proxies() -> void:
	var coop := RTVCoop.get_instance()
	if coop == null:
		return
	for peer_id in peer_names:
		coop.ensure_player_proxy(peer_id)


func _emit_peer_joined(peer_id: int, display_name: String) -> void:
	var coop := RTVCoop.get_instance()
	if coop and coop.events:
		coop.events.peer_joined.emit(peer_id, display_name)


func _emit_peer_left(peer_id: int, _display_name: String) -> void:
	var coop := RTVCoop.get_instance()
	if coop and coop.events:
		coop.events.peer_left.emit(peer_id)


# --- Id helpers ---

func GenerateFurnitureId() -> int:
	var u: int = nextFurnitureId
	nextFurnitureId += 1
	return u


func GenerateUuid() -> int:
	var u: int = nextUuid
	nextUuid += 1
	return u


func NextPlacementToken() -> int:
	return GenerateUuid()


func _is_trader_display_item(target: Node) -> bool:
	if target == null:
		return false
	# 기존: parent chain check — trader scene 자식인 display item (Generalist/Gunsmith 내부)
	var node: Node = target
	while node:
		if node.is_in_group("Trader") or "traderData" in node:
			return true
		node = node.get_parent()
	# v0.9.4: parent chain에 TraderDisplay.gd script 붙은 노드 찾기 (Bunker_Trader.tscn 등의 정확한 식별)
	# vanilla scene 구조: Bunker_Trader > Trader (no group) > Display (script=TraderDisplay.gd) > SVD/M78/...
	# parent chain Trader 그룹 check는 fail하지만 Display 노드 script로 정확 식별 가능.
	node = target.get_parent()
	while node:
		var s = node.get_script()
		if s and s.resource_path.find("TraderDisplay.gd") != -1:
			return true
		node = node.get_parent()
	# v0.9.3: 거리 휴리스틱 (Trader 그룹 NPC 반경) — fallback for 다른 scene 구조
	if not (target is Node3D):
		return false
	var target_pos: Vector3 = (target as Node3D).global_position
	for trader in get_tree().get_nodes_in_group("Trader"):
		if not is_instance_valid(trader) or not (trader is Node3D):
			continue
		if (trader as Node3D).global_position.distance_squared_to(target_pos) < 6.25:  # 2.5m
			return true
	return false


# --- Sync-module passthroughs ---

func _pickup_sync() -> PickupSync:
	var coop := RTVCoop.get_instance()
	return coop.get_sync("pickup") as PickupSync if coop else null


func _container_sync() -> ContainerSync:
	var coop := RTVCoop.get_instance()
	return coop.get_sync("container") as ContainerSync if coop else null


func _furniture_sync() -> FurnitureSync:
	var coop := RTVCoop.get_instance()
	return coop.get_sync("furniture") as FurnitureSync if coop else null


func _find_furniture_by_id(fid: int) -> Node3D:
	var fs := _furniture_sync()
	return fs._find_furniture_by_id(fid) if fs else null


func TryOpenContainer(target) -> void:
	var cs := _container_sync()
	if cs:
		cs.TryOpenContainer(target)


func SyncContainerStorage(target) -> void:
	var cs := _container_sync()
	if cs:
		cs.SyncContainerStorage(target)


func ReleaseContainerLock(target) -> void:
	var cs := _container_sync()
	if cs:
		cs.ReleaseContainerLock(target)


func RequestPickup(uuid: int) -> void:
	var ps := _pickup_sync()
	if ps:
		ps.RequestPickup(uuid)


func RequestPickupSpawn(slot_dict: Dictionary, pos: Vector3, rot: Vector3, velocity: Vector3) -> void:
	var ps := _pickup_sync()
	if ps:
		ps.RequestPickupSpawn(slot_dict, pos, rot, velocity)


func RequestPlacementSpawn(token: int, slot_dict: Dictionary, pos: Vector3) -> void:
	var ps := _pickup_sync()
	if ps:
		ps.RequestPlacementSpawn.rpc_id(1, token, slot_dict, pos)


func NotifyPlayerDeath(peer_id: int) -> void:
	var ps := _pickup_sync()
	if ps:
		ps.NotifyPlayerDeath(peer_id)


func NotifyPlayerRespawn(peer_id: int) -> void:
	var ps := _pickup_sync()
	if ps:
		ps.NotifyPlayerRespawn(peer_id)


func BroadcastPickupMove(uuid: int, pos: Vector3, rot: Vector3, frozen: bool = true) -> void:
	var ps := _pickup_sync()
	if ps:
		ps.BroadcastPickupMove.rpc(uuid, pos, rot, frozen)


func SubmitPickupMove(uuid: int, pos: Vector3, rot: Vector3, frozen: bool = true) -> void:
	var ps := _pickup_sync()
	if ps:
		ps.SubmitPickupMove.rpc_id(1, uuid, pos, rot, frozen)


# --- Character buffer facade ---

func SaveClientCharacterBuffer() -> void:
	if _buffer:
		_buffer.Save()


func LoadClientCharacterBuffer() -> void:
	if _buffer:
		await _buffer.Load()


func GiveClientStarterKit() -> void:
	if _buffer:
		await _buffer.GiveStarterKit()


func BroadcastCoopNewGame() -> void:
	if _buffer:
		_buffer.BroadcastNewGame()


# --- Scene flow facade ---

func GetMap() -> Node:
	return _scene_flow.GetMap() if _scene_flow else null


func RegisterSceneItems() -> void:
	if _scene_flow:
		_scene_flow.RegisterSceneItems()


func RegisterSceneContainers() -> void:
	if _scene_flow:
		_scene_flow.RegisterSceneContainers()


func TriggerDynamicLootRescan(delay: float = 1.5) -> void:
	if _scene_flow:
		await _scene_flow.TriggerRescan(delay)
