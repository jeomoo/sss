class_name CoopLobby extends Node



const RTVCoop = preload("res://mods/RTVCoop/Game/Coop.gd")

# fix6.4: Road to Vostok ships under two App IDs:
#   - 1963610 = Early Access (released 2026-04-07, paid)
#   - 2141300 = Public Demo (free)
# Whichever the user owns, steamInitEx must be called with the right one or auth fails.
# Strategy: read steam_appid.txt if present (Steam itself writes this when launched via
# the library), otherwise try EA first then fall back to demo.
const APP_ID_EA := 1963610
const APP_ID_DEMO := 2141300
var APP_ID: int = APP_ID_EA   # picked at runtime in _resolve_app_id()


func _resolve_app_id() -> int:
	# 1) steam_appid.txt next to the executable — most reliable
	var f := FileAccess.open("res://steam_appid.txt", FileAccess.READ)
	if f == null:
		# In exported games res:// can't see files outside the pck; try the OS path
		var exe_dir: String = OS.get_executable_path().get_base_dir()
		var path: String = exe_dir + "/steam_appid.txt"
		if FileAccess.file_exists(path):
			f = FileAccess.open(path, FileAccess.READ)
	if f:
		var txt: String = f.get_as_text().strip_edges()
		f.close()
		var parsed: int = txt.to_int()
		if parsed == APP_ID_EA or parsed == APP_ID_DEMO:
			print("[CoopLobby] steam_appid.txt -> %d" % parsed)
			return parsed
	# 2) Probe Steam: try EA, then demo. First one that returns status 0 wins.
	for candidate in [APP_ID_EA, APP_ID_DEMO]:
		OS.set_environment("SteamAppId", str(candidate))
		var probe: Variant = steam.steamInitEx(false, candidate)
		var status: int = -1
		if probe is Dictionary and probe.has("status"):
			status = int(probe["status"])
		print("[CoopLobby] probe app_id=%d -> %s" % [candidate, str(probe)])
		if status == 0:
			return candidate
		# steamShutdown so we can re-init cleanly with the other ID
		if steam.has_method("steamShutdown"):
			steam.steamShutdown()
	# 3) Default to EA — users who own the paid build are more likely to be hosting
	push_warning("[CoopLobby] Could not auto-detect Steam App ID; defaulting to EA (%d)" % APP_ID_EA)
	return APP_ID_EA

const LOBBY_TYPE_PRIVATE := 0
const LOBBY_TYPE_FRIENDS_ONLY := 1
const LOBBY_TYPE_PUBLIC := 2
const LOBBY_TYPE_INVISIBLE := 3


var available: bool = false
var steam = null
var lobby_id: int = 0
var host_steam_id: int = 0


signal lobby_created_ok(id: int)
signal lobby_create_failed(reason: String)
signal lobby_joined_ok(id: int, host_id: int)
signal lobby_join_failed(reason: String)
signal lobby_left


func _enter_tree() -> void:
	var coop := RTVCoop.get_instance()
	if coop:
		coop.lobby = self


func _exit_tree() -> void:
	var coop := RTVCoop.get_instance()
	if coop and coop.lobby == self:
		coop.lobby = null


func _ready() -> void:
	# fix4: cross-check both ClassDB entries AND the singleton. If GodotSteam half-loaded
	# (e.g. runtime load returned NEEDS_RESTART and only registered some symbols), proceeding
	# would crash on the first steam.* call when the user clicks Host.
	if not ClassDB.class_exists("Steam") or not ClassDB.class_exists("SteamMultiplayerPeer"):
		print("[CoopLobby] Steam classes not registered — disabled (install addons/godotsteam at game root and restart)")
		return
	steam = Engine.get_singleton("Steam")
	if steam == null:
		print("[CoopLobby] Steam singleton missing — disabled")
		return
	if not steam.has_method("steamInitEx") or not steam.has_method("isSteamRunning"):
		print("[CoopLobby] Steam singleton missing expected methods — disabled (GodotSteam version mismatch?)")
		steam = null
		return

	# fix6.4: pick EA (1963610) or demo (2141300) automatically based on what's installed.
	APP_ID = _resolve_app_id()
	OS.set_environment("SteamAppId", str(APP_ID))
	OS.set_environment("SteamGameId", str(APP_ID))

	var init_result: Variant = steam.steamInitEx(false, APP_ID)
	print("[CoopLobby] steamInitEx (app_id=%d): %s" % [APP_ID, str(init_result)])

	if not steam.isSteamRunning():
		print("[CoopLobby] Steam client not running — disabled")
		steam = null
		return

	available = true
	steam.lobby_created.connect(_on_lobby_created)
	steam.lobby_joined.connect(_on_lobby_joined)
	steam.join_requested.connect(_on_join_requested)
	steam.lobby_chat_update.connect(_on_lobby_chat_update)

	print("[CoopLobby] Ready — %s (%d)" % [steam.getPersonaName(), steam.getSteamID()])
	_check_cold_start_join()


func _check_cold_start_join() -> void:
	var args := OS.get_cmdline_args()
	for i in args.size():
		if args[i] == "+connect_lobby" and i + 1 < args.size():
			var target_id: int = args[i + 1].to_int()
			if target_id > 0:
				print("[CoopLobby] Cold-start +connect_lobby: %d" % target_id)
				JoinLobby(target_id)
			return


func _process(_delta: float) -> void:
	if available and steam:
		steam.run_callbacks()


func MyId() -> int:
	return steam.getSteamID() if available else 0


func MyName() -> String:
	return steam.getPersonaName() if available else ""


func InLobby() -> bool:
	return lobby_id != 0


func CreateLobby(max_members: int = 4) -> void:
	if not available:
		lobby_create_failed.emit("Steam not available")
		return
	print("[CoopLobby] Creating FRIENDS_ONLY lobby (max=%d)" % max_members)
	steam.createLobby(LOBBY_TYPE_FRIENDS_ONLY, max_members)


func JoinLobby(target_lobby_id: int) -> void:
	if not available:
		lobby_join_failed.emit("Steam not available")
		return
	print("[CoopLobby] Joining lobby %d" % target_lobby_id)
	steam.joinLobby(target_lobby_id)


func LeaveLobby() -> void:
	if not available or lobby_id == 0:
		return
	print("[CoopLobby] Leaving lobby %d" % lobby_id)
	steam.leaveLobby(lobby_id)
	lobby_id = 0
	host_steam_id = 0
	_clear_rich_presence()
	lobby_left.emit()
	var coop := RTVCoop.get_instance()
	if coop and coop.events:
		coop.events.lobby_left.emit()


func OpenInviteOverlay() -> void:
	if not available or lobby_id == 0:
		return
	steam.activateGameOverlayInviteDialog(lobby_id)


func _set_rich_presence_for_lobby() -> void:
	if not available or lobby_id == 0:
		return
	steam.setRichPresence("status", "In a coop session")
	steam.setRichPresence("connect", "+connect_lobby " + str(lobby_id))


func _clear_rich_presence() -> void:
	if available:
		steam.clearRichPresence()


func _on_lobby_created(connect_status: int, new_lobby_id: int) -> void:
	print("[CoopLobby] lobby_created: status=%d id=%d" % [connect_status, new_lobby_id])
	if connect_status != 1:
		lobby_create_failed.emit("createLobby status=%d" % connect_status)
		return
	lobby_id = new_lobby_id
	host_steam_id = steam.getSteamID()
	steam.setLobbyData(lobby_id, "host_steam_id", str(host_steam_id))
	steam.setLobbyData(lobby_id, "mod", "rtv-coop")
	steam.setLobbyJoinable(lobby_id, true)
	_set_rich_presence_for_lobby()
	lobby_created_ok.emit(lobby_id)
	var coop := RTVCoop.get_instance()
	if coop and coop.events:
		coop.events.lobby_joined.emit(lobby_id)


func _on_lobby_joined(joined_lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	print("[CoopLobby] lobby_joined: id=%d response=%d" % [joined_lobby_id, response])
	if response != 1:
		lobby_join_failed.emit("response=%d" % response)
		return
	lobby_id = joined_lobby_id
	var owner_id: int = steam.getLobbyOwner(joined_lobby_id)
	host_steam_id = owner_id
	_set_rich_presence_for_lobby()
	var coop := RTVCoop.get_instance()
	if coop and coop.events:
		coop.events.lobby_joined.emit(joined_lobby_id)
	if owner_id == steam.getSteamID():
		return
	lobby_joined_ok.emit(joined_lobby_id, owner_id)


func _on_join_requested(target_lobby_id: int, friend_id: int) -> void:
	print("[CoopLobby] join_requested from friend %d" % friend_id)
	JoinLobby(target_lobby_id)


const LOBBY_STATE_ENTERED := 0x01
const LOBBY_STATE_LEFT := 0x02
const LOBBY_STATE_DISCONNECTED := 0x04
const LOBBY_STATE_KICKED := 0x08
const LOBBY_STATE_BANNED := 0x10


func _on_lobby_chat_update(_lobby: int, changed: int, _maker: int, state: int) -> void:
	var tag: String = ""
	if state & LOBBY_STATE_ENTERED:
		tag = "entered"
	elif state & LOBBY_STATE_LEFT:
		tag = "left"
	elif state & LOBBY_STATE_DISCONNECTED:
		tag = "disconnected"
	elif state & LOBBY_STATE_KICKED:
		tag = "kicked"
	elif state & LOBBY_STATE_BANNED:
		tag = "banned"
	else:
		tag = "state=%d" % state
	print("[CoopLobby] member %d %s" % [changed, tag])
	var coop := RTVCoop.get_instance()
	if coop and coop.events:
		coop.events.lobby_state_changed.emit(state)
		coop.events.lobby_member_changed.emit(changed, state)
