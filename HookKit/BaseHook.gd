class_name BaseHook extends Node



const AISync = preload("res://mods/RTVCoop/Game/Sync/AISync.gd")
const ContainerSync = preload("res://mods/RTVCoop/Game/Sync/ContainerSync.gd")
const CoopEvents = preload("res://mods/RTVCoop/Framework/CoopEvents.gd")
const CoopFrameworksReady = preload("res://mods/RTVCoop/HookKit/CoopFrameworksReady.gd")
const CoopHook = preload("res://mods/RTVCoop/HookKit/CoopHook.gd")
const CoopLobby = preload("res://mods/RTVCoop/Game/CoopLobby.gd")
const CoopNet = preload("res://mods/RTVCoop/Framework/CoopNet.gd")
const CoopPlayers = preload("res://mods/RTVCoop/Game/CoopPlayers.gd")
const CoopSettings = preload("res://mods/RTVCoop/Game/CoopSettings.gd")
const DownedSync = preload("res://mods/RTVCoop/Game/Sync/DownedSync.gd")
const EventSync = preload("res://mods/RTVCoop/Game/Sync/EventSync.gd")
const FurnitureSync = preload("res://mods/RTVCoop/Game/Sync/FurnitureSync.gd")
const GuardSync = preload("res://mods/RTVCoop/Game/Sync/GuardSync.gd")
const InteractableSync = preload("res://mods/RTVCoop/Game/Sync/InteractableSync.gd")
const LocalStateSync = preload("res://mods/RTVCoop/Game/Sync/LocalStateSync.gd")
const PickupSync = preload("res://mods/RTVCoop/Game/Sync/PickupSync.gd")
const QuestSync = preload("res://mods/RTVCoop/Game/Sync/QuestSync.gd")
const RTVCoop = preload("res://mods/RTVCoop/Game/Coop.gd")
const SlotSerializer = preload("res://mods/RTVCoop/Game/Sync/SlotSerializer.gd")
const VoiceSync = preload("res://mods/RTVCoop/Game/Sync/VoiceSync.gd")
const WorldSync = preload("res://mods/RTVCoop/Game/Sync/WorldSync.gd")

var coop: RTVCoop
var events: CoopEvents
var players: CoopPlayers
var net: CoopNet
var lobby: CoopLobby
var settings: CoopSettings
var interactable: InteractableSync
var world: WorldSync
var event: EventSync
var ai: AISync
var container: ContainerSync
var downed: DownedSync
var furniture: FurnitureSync
var guard: GuardSync
var quest: QuestSync
var pickup: PickupSync
var voice: VoiceSync
var slot: SlotSerializer
var local_state: LocalStateSync


func _ready() -> void:
	await CoopFrameworksReady.wait_async()
	coop = RTVCoop.get_instance()
	if coop:
		events = coop.events
		players = coop.players as CoopPlayers
		net = coop.net as CoopNet
		lobby = coop.lobby as CoopLobby
		settings = coop.settings as CoopSettings
		interactable = coop.get_sync("interactable") as InteractableSync
		world = coop.get_sync("world") as WorldSync
		event = coop.get_sync("event") as EventSync
		ai = coop.get_sync("ai") as AISync
		container = coop.get_sync("container") as ContainerSync
		downed = coop.get_sync("downed") as DownedSync
		furniture = coop.get_sync("furniture") as FurnitureSync
		guard = coop.get_sync("guard") as GuardSync
		quest = coop.get_sync("quest") as QuestSync
		pickup = coop.get_sync("pickup") as PickupSync
		voice = coop.get_sync("voice") as VoiceSync
		slot = coop.get_sync("slot_serializer") as SlotSerializer
		local_state = coop.get_sync("local_state") as LocalStateSync

	if not CoopFrameworksReady.is_available():
		push_warning("[%s] RTVModLib missing; hooks not registered" % _tag())
		return
	_setup_hooks()
	print("[%s] registered" % _tag())


func _exit_tree() -> void:
	CoopHook.unhook_all(self)


func _setup_hooks() -> void:
	pass


func _tag() -> String:
	return get_script().resource_path.get_file().get_basename()
