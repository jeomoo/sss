extends Node



const CoopFrameworksReady = preload("res://mods/RTVCoop/HookKit/CoopFrameworksReady.gd")
const CoopLobby = preload("res://mods/RTVCoop/Game/CoopLobby.gd")
const CoopNet = preload("res://mods/RTVCoop/Framework/CoopNet.gd")
const CoopPlayers = preload("res://mods/RTVCoop/Game/CoopPlayers.gd")
const CoopSettings = preload("res://mods/RTVCoop/Game/CoopSettings.gd")
const CoopMCM = preload("res://mods/RTVCoop/Game/CoopMCM.gd")
const RTVCoop = preload("res://mods/RTVCoop/Game/Coop.gd")

const _COOP_PRELOADS = preload("res://mods/RTVCoop/_preloads.gd")


const STEAM_EXTENSION_PATH := "res://addons/godotsteam/godotsteam.gdextension"

const HOOK_SCRIPTS := [
	"res://mods/RTVCoop/Game/Hooks/LoaderHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/AIHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/CharacterHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/ControllerHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/HandlingHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/InteractHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/WorldHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/VehicleHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/InstrumentHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/TransitionHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/FireHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/BedHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/SimulationHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/HitboxHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/AISpawnerHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/LootHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/TraderHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/EventSystemHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/CompilerHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/PlacerHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/FurnitureHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/InteractorHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/InterfaceHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/CatFeederHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/MineHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/LayoutHooks.gd",
	"res://mods/RTVCoop/Game/Hooks/WeaponRigHooks.gd",
]

const SYNC_SCRIPTS := [
	"res://mods/RTVCoop/Game/Sync/SlotSerializer.gd",
	"res://mods/RTVCoop/Game/Sync/InteractableSync.gd",
	"res://mods/RTVCoop/Game/Sync/WorldSync.gd",
	"res://mods/RTVCoop/Game/Sync/EventSync.gd",
	"res://mods/RTVCoop/Game/Sync/AISync.gd",
	"res://mods/RTVCoop/Game/Sync/AICoopSpawner.gd",
	"res://mods/RTVCoop/Game/Sync/AICoopManager.gd",
	"res://mods/RTVCoop/Game/Sync/ContainerSync.gd",
	"res://mods/RTVCoop/Game/Sync/DownedSync.gd",
	"res://mods/RTVCoop/Game/Sync/QuestSync.gd",
	"res://mods/RTVCoop/Game/Sync/FurnitureSync.gd",
	"res://mods/RTVCoop/Game/Sync/GuardSync.gd",
	"res://mods/RTVCoop/Game/Sync/PickupSync.gd",
	"res://mods/RTVCoop/Game/Sync/VoiceSync.gd",
	"res://mods/RTVCoop/Game/Sync/LocalStateSync.gd",
	"res://mods/RTVCoop/Game/Sync/ModBridge.gd",
]

const UI_SCRIPTS := [
	"res://mods/RTVCoop/UI/DebugOverlay.gd",
	"res://mods/RTVCoop/UI/LobbyUI.gd",
	"res://mods/RTVCoop/UI/SleepOverlay.gd",
	"res://mods/RTVCoop/UI/VoiceUI.gd",
	"res://mods/RTVCoop/UI/ChatOverlay.gd",
]


var _coop: RTVCoop


var logger: Node = null

const BUILD_STAMP := "2026-06-07 v0.1 KR (Antigravity sync)"

const SyncTickService = preload("res://mods/RTVCoop/Framework/SyncTickService.gd")

const EMBEDDED_MSS_PATH := "res://mods/RTVCoop/Vendor/MultiSaveSlots/Main.gd"


func _ready() -> void:
	print("[RTVCoop] Main.gd _ready (build %s)" % BUILD_STAMP)
	_try_load_steam_extension()
	_spawn_embedded_mss()
	_coop = RTVCoop.new()
	get_tree().root.add_child(_coop)
	_coop.boot()
	logger = load("res://mods/RTVCoop/Game/CoopLogger.gd").new()
	logger.name = "CoopLogger"
	_coop.add_child(logger)
	Engine.set_meta("CoopLogger", logger)
	logger.log_msg("Main", "BUILD: %s" % BUILD_STAMP)
	# v0.1: SyncTickService autoload — 20Hz tick manager. _process timing이라
	# vanilla character _physics_process frame 부담과 격리됨.
	var tick_service := SyncTickService.new()
	tick_service.name = "SyncTickService"
	_coop.add_child(tick_service)
	Engine.set_meta("SyncTickService", tick_service)
	logger.log_msg("Main", "SyncTickService spawned (20Hz tick decoupling)")
	_spawn_services()
	_spawn_sync()
	_spawn_hooks()
	_spawn_ui()
	await CoopFrameworksReady.wait_async()
	if CoopFrameworksReady.is_available():
		logger.log_msg("Main", "frameworks_ready confirmed (modloader v%s)" % CoopFrameworksReady.lib().version())
	else:
		logger.log_msg("Main", "RTVModLib not present; running without hooks")

	# v0.13.34: AFK 호스트 모드 폐기 (v0.12.x 시도 후 v0.13.9에서 abandon).
	# 폐기 이유: vanilla focus pause + AISpawner 의존 + Steam 우회 launch 실패 (메모리 참고).


func _spawn_embedded_mss() -> void:
	# v0.13.68: Multi Save Slots 흡수 — standalone MSS 모드 없이도 코옵 슬롯 세이브가
	# 작동하도록 벤더본(res://mods/RTVCoop/Vendor/MultiSaveSlots/Main.gd)을 직접
	# 인스턴스화. standalone MSS가 이미 있으면(autoload MultiSaveSlotsMain) 양보 = 이중 실행 방지.
	# 같은 이름(MultiSaveSlotsMain)으로 띄워서 LobbyUI의 기존 조회가 그대로 동작.
	var root := get_tree().root
	if root.get_node_or_null("MultiSaveSlotsMain") != null:
		print("[RTVCoop] standalone Multi Save Slots present — skipping embedded copy")
		return
	var script: GDScript = load(EMBEDDED_MSS_PATH)
	if script == null:
		push_warning("[RTVCoop] embedded MSS load failed (%s) — coop 지연 save는 단일 슬롯에만 국한될 수 있음")
		return
	var mss: Node = script.new()
	mss.name = "MultiSaveSlotsMain"
	root.add_child(mss)
	print("[RTVCoop] embedded Multi Save Slots spawned (standalone not found)")


func _spawn_services() -> void:
	_add_child_node(CoopNet.new(), "Net")
	_add_child_node(CoopLobby.new(), "Lobby")
	_add_child_node(CoopSettings.new(), "Settings")
	_add_child_node(CoopPlayers.new(), "Players")
	_add_child_node(CoopMCM.new(), "MCM")


func _spawn_sync() -> void:
	for path in SYNC_SCRIPTS:
		var script: GDScript = load(path)
		if script == null:
			push_error("[RTVCoop] failed to load " + path)
			continue
		var node: Node = script.new()
		_add_child_node(node, "Sync_" + path.get_file().get_basename().replace("Sync", ""))


func _spawn_hooks() -> void:
	for path in HOOK_SCRIPTS:
		var script: GDScript = load(path)
		if script == null:
			push_error("[RTVCoop] failed to load " + path)
			continue
		var node: Node = script.new()
		_add_child_node(node, path.get_file().get_basename())


func _spawn_ui() -> void:
	for path in UI_SCRIPTS:
		var script: GDScript = load(path)
		if script == null:
			push_error("[RTVCoop] failed to load " + path)
			continue
		var node: Node = script.new()
		_add_child_node(node, path.get_file().get_basename())


func _add_child_node(node: Node, node_name: String) -> void:
	node.name = node_name
	_coop.add_child(node)


func _try_load_steam_extension() -> void:
	# fix6.1: revert fix4 over-cautious behaviour. Earlier fix4 *removed* the runtime load
	# call entirely, assuming Godot would always return NEEDS_RESTART. That's wrong for
	# Godot 4.4+ — the first runtime load of a class-registering extension can actually
	# return LOAD_STATUS_OK. Restore ovrrde's original load attempt with clearer logging
	# so we can see what the engine actually says.
	if ClassDB.class_exists("Steam") and ClassDB.class_exists("SteamMultiplayerPeer"):
		print("[RTVCoop] GodotSteam classes already registered at boot — Steam transport available")
		Engine.set_meta("coop_steam_status", "loaded")
		return
	if not FileAccess.file_exists(STEAM_EXTENSION_PATH):
		push_warning("[RTVCoop] GodotSteam extension not found at %s" % STEAM_EXTENSION_PATH)
		push_warning("[RTVCoop] Steam features disabled. Drop addons/godotsteam/ next to the game executable, then restart.")
		Engine.set_meta("coop_steam_status", "missing")
		return
	if GDExtensionManager.is_extension_loaded(STEAM_EXTENSION_PATH):
		print("[RTVCoop] GodotSteam reported as already loaded by GDExtensionManager")
		Engine.set_meta("coop_steam_status", "loaded")
		return
	print("[RTVCoop] Attempting runtime GDExtension load: %s" % STEAM_EXTENSION_PATH)
	var status: int = GDExtensionManager.load_extension(STEAM_EXTENSION_PATH)
	match status:
		GDExtensionManager.LOAD_STATUS_OK:
			print("[RTVCoop] GodotSteam extension loaded OK")
			Engine.set_meta("coop_steam_status", "loaded")
		GDExtensionManager.LOAD_STATUS_ALREADY_LOADED:
			print("[RTVCoop] GodotSteam extension reported ALREADY_LOADED")
			Engine.set_meta("coop_steam_status", "loaded")
		GDExtensionManager.LOAD_STATUS_NEEDS_RESTART:
			push_warning("[RTVCoop] GodotSteam load returned NEEDS_RESTART — Steam features unavailable this session.")
			push_warning("[RTVCoop] Restart the game. If still NEEDS_RESTART after restart, your Godot build forbids runtime class registration for this extension.")
			push_warning("[RTVCoop] In that case use the direct ENet UI ('직접 호스트') with Tailscale / LAN instead.")
			Engine.set_meta("coop_steam_status", "needs_restart")
		GDExtensionManager.LOAD_STATUS_FAILED:
			push_error("[RTVCoop] GodotSteam load returned FAILED — likely DLL signature mismatch or missing dependency (steam_api64.dll?).")
			Engine.set_meta("coop_steam_status", "failed")
		GDExtensionManager.LOAD_STATUS_NOT_LOADED:
			push_error("[RTVCoop] GodotSteam load returned NOT_LOADED — extension file present but engine refused to load it.")
			Engine.set_meta("coop_steam_status", "failed")
		_:
			push_warning("[RTVCoop] GodotSteam load returned unknown status %d" % status)
			Engine.set_meta("coop_steam_status", "unknown")
	# Final verification: did the classes actually register?
	var verified: bool = ClassDB.class_exists("Steam") and ClassDB.class_exists("SteamMultiplayerPeer")
	print("[RTVCoop] Post-load class check: Steam=%s SteamMultiplayerPeer=%s" % [
		ClassDB.class_exists("Steam"), ClassDB.class_exists("SteamMultiplayerPeer")
	])
	if not verified:
		push_warning("[RTVCoop] Despite load attempt, Steam classes are still not in ClassDB. Steam features will not work this session.")
