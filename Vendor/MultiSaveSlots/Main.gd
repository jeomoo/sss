extends Node

# ---------------------------------------------------------------------------
# Multi Save Slots
#
# Adds 5 save slots to the main menu:
#   - "New Game" opens a slot picker so you choose where to create the run
#     (the previous save in other slots is preserved).
#   - "Continue" is renamed to "Load Game" and opens a slot picker to load
#     any of the existing slot saves.
#
# Permadeath wipes only the active slot. All work is done from a single
# autoload at runtime; no vanilla scripts are overridden, which keeps this
# mod compatible with 00ModConfigurationMenu, SuspendSaveSystem and others.
# ---------------------------------------------------------------------------

const MOD_NAME         := "Multi Save Slots"
const MOD_ID           := "multi-save-slots"
const MOD_VERSION      := "1.1.16"

const SLOT_COUNT       := 5
const ROOT_DIR         := "user://MultiSaveSlots"
const STATE_PATH       := ROOT_DIR + "/state.cfg"
const FILE_RULES_PATH  := ROOT_DIR + "/file_rules.cfg"

const CONFIG_DIR       := "user://MCM/MultiSaveSlots"
const CONFIG_PATH      := CONFIG_DIR + "/config.ini"
const FALLBACK_CFG     := ROOT_DIR + "/fallback.cfg"
const MCM_HELPERS_PATH := "res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres"

# ---------------------------------------------------------------------------
# Default file-rules.
#
# These are the values the mod ships with. The actual rules used at runtime
# live in the variables below (_tracked_file_extensions, _never_touch_files,
# etc) and are populated from user://MultiSaveSlots/file_rules.cfg, which is
# auto-created from these defaults on first launch and is fully editable by
# the user. See _load_or_init_file_rules() for details.
#
# DO NOT edit these constants if you're a user customising your own setup --
# edit the cfg file instead. These constants only matter on a fresh install
# (no cfg yet) or after deleting the cfg to reset to defaults.
# ---------------------------------------------------------------------------

const DEFAULT_TRACKED_FILE_EXTENSIONS := ["tres", "json", "save", "jpg"]

const DEFAULT_NEVER_TOUCH_FILES := [
	"modloader.gd",
	"mod_config.cfg",
	"mod_profiles.cfg",
	"modloader_conflicts.txt",
	"override.cfg",
	"Validator.tres",
	"Preferences.tres",
	"simplehud_preferences.json",
]

const DEFAULT_NEVER_TOUCH_EXTENSIONS := ["gd", "txt", "cfg", "ini"]

const DEFAULT_FORCE_TRACKED_FILES := [
	"XPData.cfg",
	"XPPrestige.cfg",
	"XPSkillsBookCache.cfg",
]

const DEFAULT_FORCE_TRACKED_PREFIXES := [
	"XPData_",
]

const DEFAULT_NEVER_TOUCH_SUFFIXES := [
	"_preferences.json",
	"_settings.json",
	"_config.json",
	"_prefs.json",
]

# Live rules, populated by _load_or_init_file_rules(). Initialised to the
# defaults so they're safe to use even if the loader isn't called yet (eg.
# during static init of helpers).
var _tracked_file_extensions: Array  = DEFAULT_TRACKED_FILE_EXTENSIONS.duplicate()
var _never_touch_files: Array        = DEFAULT_NEVER_TOUCH_FILES.duplicate()
var _never_touch_extensions: Array   = DEFAULT_NEVER_TOUCH_EXTENSIONS.duplicate()
var _force_tracked_files: Array      = DEFAULT_FORCE_TRACKED_FILES.duplicate()
var _force_tracked_prefixes: Array   = DEFAULT_FORCE_TRACKED_PREFIXES.duplicate()
var _never_touch_suffixes: Array     = DEFAULT_NEVER_TOUCH_SUFFIXES.duplicate()

# A slot is considered "occupied" when this file exists inside its dir.
const OCCUPANCY_MARKER := "Character.tres"

var gameData = preload("res://Resources/GameData.tres")
var _mcm_helpers = null

# -- Configuration ----------------------------------------------------------
var _enabled: bool                   = true
var _verbose_logs: bool              = false
var _autodelete_on_permadeath: bool  = true

# -- Runtime state ----------------------------------------------------------
var _active_slot: int                = 1
var _was_dead: bool                  = false
var _pending_permadeath_wipe: bool   = false
# Slot to wipe captured at the moment of death so a later set_active_slot()
# (e.g. user starts a new game on a different slot before the wipe runs)
# cannot redirect the wipe to the wrong slot.
var _permadeath_target_slot: int     = 0
var _permadeath_target_map: String   = ""
var _last_scene_was_menu: bool       = true
var _menu_hooks_installed_for: Node  = null
# Reference to the Load Game / Continue button in the current Menu so we can
# re-evaluate its disabled state after slot operations (Delete, permadeath
# wipe) without waiting for the menu node to be recreated.
var _load_button: Button             = null

# In-game pause-menu Quit / Exit-Menu hooking. Vanilla's Loader.Quit() doesn't
# wait for our tree_exiting handler to flush slot files reliably (file copy
# during shutdown is racy: SAVE messages appear but DirAccess.copy may not
# finish). We pre-empt the click: when the player presses Quit Game / Exit
# Menu, we sync to the slot FIRST, then invoke the original handler.
#
# _pause_button_kinds maps each hooked button to its kind ("quit" or "exit"):
# quit triggers full save+sync+quit_done flag, exit only forces a vanilla
# save before the scene change so the post-transition sync_out (in
# _check_scene_transition_for_sync_out) sees fresh user://Character.tres.
# Without this, vanilla's Exit-to-Menu path (without SuspendSaveSystem) does
# NOT call SaveCharacter/SaveShelter, so the slot ends up empty until the
# next launch when crash-recovery sync picks up the stale state.
var _pause_button_hooks: Dictionary  = {} # Button -> Array[Callable]
var _pause_button_kinds: Dictionary  = {} # Button -> String ("quit"|"exit")

# Map-change watcher: vanilla writes Character/World/<map>.tres BEFORE
# updating gameData.currentMap during a transition. We poll the variable
# in-memory each frame (zero I/O) and trigger sync_out the moment it changes
# so the active slot mirrors vanilla's checkpoints without polling disk.
var _last_known_map: String          = ""

# Stored callables of the original New / Continue buttons, so we can re-fire
# the vanilla logic after the user picks a slot.
var _orig_new_callables: Array       = []
var _orig_continue_callables: Array  = []

# Reference to the SlotPanel script (loaded lazily).
var _slot_panel_script = null

# Pending action queued by the SlotPanel so we can run the vanilla flow on
# the next frame after sync_in / wipe_slot completed.
var _pending_action := {} # {"kind": "load", "slot": int}

# State for the New Game -> Difficulty -> Slot flow.
# 1) The user clicks "New Game" -> we snapshot all visible buttons in the
#    menu and invoke the vanilla handler (which reveals the difficulty
#    submenu).
# 2) We watch for newly-visible buttons and re-bind them so that pressing one
#    opens our slot panel.
# 3) When the user picks a slot, we invoke the captured difficulty handler so
#    the vanilla flow proceeds with that difficulty.
var _difficulty_handlers: Dictionary  = {} # Button -> Array[Callable]
var _pending_difficulty_btn: Button   = null
var _await_difficulty_after: float    = -1.0
var _pre_new_visible: Dictionary      = {} # Button -> bool


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	process_priority = 1000
	_was_dead = bool(gameData.isDead) if "isDead" in gameData else false
	_ensure_dir(ROOT_DIR)
	for n in range(1, SLOT_COUNT + 1):
		_ensure_dir(slot_dir(n))
	_load_state()
	# Load per-user file rules (or write defaults on first launch). MUST run
	# before _restore_blacklisted_globals / _check_crash_recovery_sync so
	# every blacklist/whitelist decision uses the user's customised lists.
	_load_or_init_file_rules()
	_mcm_helpers = _try_load_mcm()
	if _mcm_helpers != null:
		_init_mcm_config()
	else:
		_load_fallback_config()
	# Idempotent cleanup: undo damage from older MSS versions that may have
	# moved global mod-config JSONs (SimpleHUD etc) into per-slot folders
	# before they were blacklisted. Runs every startup, no-op once clean.
	_restore_blacklisted_globals()
	_check_crash_recovery_sync()
	_first_run_migration()
	_refresh_map_baseline()
	# Catch any quit path: window X button (NOTIFICATION_WM_CLOSE_REQUEST) and
	# in-game "Quit Game" button which calls Loader.Quit() -> get_tree().quit()
	# (only emits tree_exiting, NOT WM_CLOSE_REQUEST).
	get_tree().tree_exiting.connect(_on_tree_exiting)
	# Event-driven hooking for in-game pause-menu buttons. Subscribing once
	# to SceneTree.node_added avoids polling find_children() on /root/Map
	# every N seconds. The handler does an O(1) type check and ignores
	# anything that isn't a Button, so the cost per non-button add is a
	# single `is` test.
	get_tree().node_added.connect(_on_scene_node_added)
	print("[%s] Ready (v%s) active_slot=%d" % [MOD_NAME, MOD_VERSION, _active_slot])


func _process(delta: float) -> void:
	if not _enabled:
		return

	_check_menu_scene_and_install_hooks()
	# Run permadeath wipe BEFORE sync_out so a dying slot doesn't get briefly
	# repopulated with the death state (vanilla may write Character.tres on
	# the way to the menu). After the wipe, sync_out_active sees an empty
	# user:// and aborts via the H11 guard.
	_run_permadeath_watcher()
	_check_scene_transition_for_sync_out()
	_run_pending_action()
	_poll_difficulty_buttons(delta)
	_watch_map_change()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_log("Window close requested, force saving + syncing out active slot")
		_save_and_sync_on_quit()


func _on_tree_exiting() -> void:
	_log("SceneTree exiting (Quit Game), force saving + syncing out active slot")
	_save_and_sync_on_quit()


# Idempotent guard so we don't run the save+sync twice if both the window
# close notification AND tree_exiting fire on the same shutdown.
var _quit_sync_done: bool = false


func _save_and_sync_on_quit() -> void:
	if _quit_sync_done:
		return
	_quit_sync_done = true
	# If we're still in a Map at close, force vanilla saves first so the
	# slot captures the last in-game state.
	if _get_menu_node() == null:
		_force_vanilla_save()
	sync_out_active()


# ---------------------------------------------------------------------------
# Public API (used by SlotPanel)
# ---------------------------------------------------------------------------

func get_active_slot() -> int:
	return _active_slot


func set_active_slot(n: int) -> void:
	n = clampi(n, 1, SLOT_COUNT)
	_active_slot = n
	_save_state()
	_log("Active slot set to %d" % n)


func slot_dir(n: int) -> String:
	return "%s/slot%d" % [ROOT_DIR, n]


func is_slot_occupied(n: int) -> bool:
	return FileAccess.file_exists(slot_dir(n) + "/" + OCCUPANCY_MARKER)


# Returns true if at least one slot has a save. Used to keep the Load Game
# button enabled even when user:// has no Character.tres (e.g. right after a
# permadeath wipe), so the player can still load a different surviving slot.
func any_slot_occupied() -> bool:
	for n in range(1, SLOT_COUNT + 1):
		if is_slot_occupied(n):
			return true
	return false


func slot_metadata(n: int) -> Dictionary:
	var meta := {
		"occupied": is_slot_occupied(n),
		"display_name": "",
		"last_map": "",
		"last_play_iso": "",
		"dead": false,
	}
	var meta_path := slot_dir(n) + "/_meta.cfg"
	if FileAccess.file_exists(meta_path):
		var cfg := ConfigFile.new()
		if cfg.load(meta_path) == OK:
			meta.display_name  = String(cfg.get_value("meta", "display_name", ""))
			meta.last_map      = cfg.get_value("meta", "last_map",      "")
			meta.last_play_iso = cfg.get_value("meta", "last_play_iso", "")
			meta.dead          = bool(cfg.get_value("meta", "dead",     false))
	return meta


# Update only the display_name field of a slot's metadata; preserves other
# fields if the meta file already exists.
func set_slot_display_name(n: int, display_name: String) -> void:
	if n < 1 or n > SLOT_COUNT:
		return
	_ensure_dir(slot_dir(n))
	var meta_path := slot_dir(n) + "/_meta.cfg"
	var cfg := ConfigFile.new()
	if FileAccess.file_exists(meta_path):
		cfg.load(meta_path)
	cfg.set_value("meta", "display_name", display_name.strip_edges())
	cfg.save(meta_path)
	_log("Set display name for slot %d: '%s'" % [n, display_name])


func wipe_slot(n: int) -> void:
	var dir_path := slot_dir(n)
	var dir = DirAccess.open(dir_path)
	if dir == null:
		_ensure_dir(dir_path)
		return
	for f in dir.get_files():
		dir.remove(f)
	_log("Wiped slot %d" % n)


func wipe_active_slot() -> void:
	wipe_slot(_active_slot)


# Copy slotN/* into user:// root, replacing tracked files.
func sync_in(n: int) -> void:
	if n < 1 or n > SLOT_COUNT:
		return
	_clear_user_root_tracked()
	var src := slot_dir(n)
	var dir = DirAccess.open(src)
	if dir == null:
		return
	for f in dir.get_files():
		if f.begins_with("_"):
			continue
		# Defense in depth: even if a slot folder has a stale modloader.gd
		# (left over from buggy older mod versions), refuse to copy it back
		# to user:// where it would clobber the live Metro Mod Loader.
		if not _is_safe_to_touch(f):
			_log("Refused to copy protected file '%s' from slot %d into user://" % [f, n])
			continue
		var src_path := src + "/" + f
		var dst_path := "user://" + f
		var err := dir.copy(src_path, dst_path)
		if err != OK:
			_log("sync_in copy fail %s -> %s err=%d" % [src_path, dst_path, err])
	_log("sync_in slot %d" % n)
	_refresh_map_baseline()


# Copy tracked files from user:// root into the active slot folder, refreshing
# its metadata. Safe to call multiple times.
func sync_out_active() -> void:
	# Never wipe a slot when user:// has no actual save data. Vanilla only
	# writes Character.tres on map transitions / sleep / shelter exit; if it's
	# missing here, the player exited without triggering any save and we'd
	# destroy the slot's existing data.
	if not FileAccess.file_exists("user://" + OCCUPANCY_MARKER):
		_log("sync_out aborted: no Character.tres in user:// (would wipe slot)")
		return
	if _active_slot < 1 or _active_slot > SLOT_COUNT:
		return
	var dst := slot_dir(_active_slot)
	_ensure_dir(dst)
	var dir = DirAccess.open(dst)
	if dir == null:
		return
	for f in dir.get_files():
		if f.begins_with("_"):
			continue
		dir.remove(f)

	var root = DirAccess.open("user://")
	if root == null:
		return
	for f in root.get_files():
		if not _is_trackable_file(f):
			continue
		# Defense in depth: never copy modloader/configs into the slot folder
		# even if the whitelist is widened by mistake. Prevents poisoning a
		# slot with files that would clobber Metro Mod Loader on sync_in.
		if not _is_safe_to_touch(f):
			_log("Refused to copy protected file '%s' into slot %d" % [f, _active_slot])
			continue
		var err := root.copy("user://" + f, dst + "/" + f)
		if err != OK:
			_log("sync_out copy fail %s err=%d" % [f, err])
	_write_slot_meta(_active_slot)
	_log("sync_out slot %d" % _active_slot)
	_refresh_map_baseline()


func clear_user_root_tracked_external() -> void:
	_clear_user_root_tracked()


# Called by SlotPanel after the user picks a slot in the desired mode.
func queue_load_slot(n: int) -> void:
	set_active_slot(n)
	sync_in(n)
	# After sync_in user:// has whatever the slot had. If a SuspendSave.save
	# was captured (from SuspendSaveSystem), resume directly to that map
	# instead of vanilla's Continue (which always lands in Cabin). Falls
	# back to vanilla Continue if SuspendSave.save is missing or unparsable,
	# or if the user doesn't have SSS installed (no SuspendSave.save will
	# ever exist in their slots, so vanilla Continue runs as-is and
	# exploration-mode runs without SSS will fail to load -- matching the
	# vanilla limitation; we don't synthesize a resume MSS-side because that
	# would add functionality that vanilla itself does not have).
	if FileAccess.file_exists("user://SuspendSave.save"):
		if _try_resume_via_suspend_save():
			return
	_pending_action = {"kind": "load", "slot": n}


func queue_new_slot(n: int, display_name: String = "") -> void:
	wipe_slot(n)
	_clear_user_root_tracked()
	set_active_slot(n)
	# Persist the user-chosen display name so it shows up immediately in the
	# slot panel and survives the next sync_out (which preserves display_name
	# in _write_slot_meta).
	if display_name.strip_edges() != "":
		set_slot_display_name(n, display_name)
	# Vanilla's difficulty button handler ("Enter the Road") calls
	# Loader.NewGame() which writes fresh save defaults to user://. We don't
	# need to reset anything ourselves; just clear the slot + user:// tracked
	# files so vanilla starts from a clean state.
	_pending_action = {"kind": "new", "slot": n}


# Called by SlotPanel when the user cancels the slot picker. If we were in the
# middle of the New Game -> difficulty flow, drop the pending difficulty so the
# user can pick again.
func cancel_pending_new_flow() -> void:
	_pending_difficulty_btn = null


# ---------------------------------------------------------------------------
# Pending action runner
# ---------------------------------------------------------------------------

func _run_pending_action() -> void:
	if _pending_action.is_empty():
		return
	var kind: String = _pending_action.get("kind", "")
	_pending_action = {}
	match kind:
		"new":
			_invoke_pending_difficulty_handler()
		"load":
			_invoke_original_continue()


func _invoke_pending_difficulty_handler() -> void:
	var btn: Button = _pending_difficulty_btn
	_pending_difficulty_btn = null
	if btn == null or not is_instance_valid(btn):
		_log("No pending difficulty button captured, falling back to direct game start")
		_fallback_start_new_game()
		return
	var callables: Array = _difficulty_handlers.get(btn, [])
	if callables.is_empty():
		_log("Difficulty button had no captured handlers, falling back")
		_fallback_start_new_game()
		return
	for c in callables:
		if c.is_valid():
			c.call()


# Per-slot SuspendSaveSystem resume support. Reads user://SuspendSave.save
# (which sync_in just restored from the active slot's folder) and jumps
# straight to the suspended outdoor map, mimicking the SuspendSaveButton
# logic so each slot can have its own independent suspended exploration.
# Returns true if it actually resumed; false to let the caller fall back
# to vanilla Continue (Cabin).
func _try_resume_via_suspend_save() -> bool:
	var file = FileAccess.open("user://SuspendSave.save", FileAccess.READ)
	if file == null:
		return false
	var current_map := ""
	var previous_map := ""
	while file.get_position() < file.get_length():
		var line := file.get_line()
		if line.is_empty():
			continue
		var json := JSON.new()
		if json.parse(line) != OK:
			continue
		var data = json.data
		if typeof(data) != TYPE_DICTIONARY:
			continue
		if data.has("currentMap") and String(data["currentMap"]) != "":
			current_map = String(data["currentMap"])
		if data.has("previousMap"):
			previous_map = String(data["previousMap"])
	file.close()
	if current_map == "" or current_map == "Menu":
		return false
	if not _do_resume_to_map(current_map, previous_map, "SuspendSave"):
		return false
	# Consume the SuspendSave: delete from both user:// and the slot folder
	# so it's a one-shot resume just like SSS standalone behaviour. Use a
	# tiny delay so the deletion runs after LoadScene has read everything.
	var slot_n := _active_slot
	get_tree().create_timer(0.05).timeout.connect(func():
		if FileAccess.file_exists("user://SuspendSave.save"):
			DirAccess.remove_absolute("user://SuspendSave.save")
		var slot_save := slot_dir(slot_n) + "/SuspendSave.save"
		if FileAccess.file_exists(slot_save):
			DirAccess.remove_absolute(slot_save)
	)
	return true


# Common LoadScene + UI cleanup used by the SuspendSave resume path. Kept as
# a separate helper in case future per-mod resume mechanisms (still external
# to vanilla) want to reuse it. We deliberately do NOT expose a vanilla-only
# auto-resume: vanilla Continue can't resume mid-exploration, and MSS
# mirrors that limitation rather than synthesizing a feature SSS provides.
func _do_resume_to_map(current_map: String, previous_map: String, source: String) -> bool:
	var loader = get_node_or_null("/root/Loader")
	if loader == null or not loader.has_method("LoadScene"):
		return false
	if "gameData" in loader and loader.gameData != null:
		if "currentMap" in loader.gameData:
			loader.gameData.currentMap = current_map
		if "previousMap" in loader.gameData:
			loader.gameData.previousMap = previous_map
	_log("Resume via %s: jumping to '%s' (prev='%s')" % [source, current_map, previous_map])
	loader.LoadScene(current_map)
	# Mimic SuspendSaveButton UI cleanup so the menu doesn't accept further
	# clicks during the transition.
	var menu = get_tree().root.get_node_or_null("Menu")
	if menu != null:
		if menu.has_method("PlayClick"):
			menu.PlayClick()
		if menu.has_method("DeactivateButtons"):
			menu.DeactivateButtons()
		if "blocker" in menu and menu.blocker != null:
			menu.blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	return true


func _invoke_original_continue() -> void:
	if _orig_continue_callables.is_empty():
		_log("No original Continue handler captured, falling back to direct load")
		_fallback_load_game()
		return
	for c in _orig_continue_callables:
		if c.is_valid():
			c.call()


# Fallbacks for when we couldn't capture the vanilla button handlers (e.g. the
# button name differs from what we expected). Mirrors what the menu would do.
func _fallback_start_new_game() -> void:
	var loader = get_node_or_null("/root/Loader")
	if loader == null:
		return
	if loader.has_method("ResetSave"):
		loader.ResetSave()
	if "gameData" in loader and loader.gameData != null:
		if "previousMap" in loader.gameData:
			loader.gameData.previousMap = ""
		if "currentMap" in loader.gameData:
			loader.gameData.currentMap = "Tutorial"
	if loader.has_method("LoadScene"):
		loader.LoadScene("Tutorial")


func _fallback_load_game() -> void:
	var loader = get_node_or_null("/root/Loader")
	if loader == null:
		return
	if loader.has_method("LoadTransition"):
		loader.LoadTransition()
	var target := "Cabin"
	if "gameData" in loader and loader.gameData != null and "currentMap" in loader.gameData:
		var cm := String(loader.gameData.currentMap)
		if cm != "" and cm != "Menu":
			target = cm
	if loader.has_method("LoadScene"):
		loader.LoadScene(target)


# ---------------------------------------------------------------------------
# Menu hooks
# ---------------------------------------------------------------------------

func _check_menu_scene_and_install_hooks() -> void:
	var menu := _get_menu_node()
	if menu == null:
		_menu_hooks_installed_for = null
		_load_button = null
		return
	if _menu_hooks_installed_for == menu:
		return
	_install_menu_hooks(menu)
	_menu_hooks_installed_for = menu


func _get_menu_node() -> Node:
	var root := get_tree().root
	if root == null:
		return null
	var menu := root.get_node_or_null("Menu")
	if menu == null:
		menu = root.get_node_or_null("Menu2")
	return menu


func _install_menu_hooks(menu: Node) -> void:
	var buttons_root := _find_menu_buttons_root(menu)
	if buttons_root == null:
		_log("Menu buttons root not found, skipping hooks")
		return

	var new_btn := _find_button_in(buttons_root, ["New", "NewGame", "New Game"])
	if new_btn != null:
		var new_captured := _take_over_button(new_btn, _on_new_pressed_capture)
		# Only overwrite the stored originals if we captured fresh vanilla
		# handlers. Otherwise (e.g. menu reload where the only existing
		# handler was our own) keep the previous captures.
		if not new_captured.is_empty():
			_orig_new_callables = new_captured
		_log("Hooked New button (captured %d, total stored %d)" % [
			new_captured.size(), _orig_new_callables.size()
		])
	else:
		_log("No New button found")

	var continue_btn := _find_button_in(buttons_root, [
		"Continue", "ContinueGame", "Resume", "Load", "LoadGame", "Load Game"
	])
	if continue_btn != null:
		continue_btn.text = "Load Game"
		var cont_captured := _take_over_button(continue_btn, _open_panel_in_load_mode)
		if not cont_captured.is_empty():
			_orig_continue_callables = cont_captured
		_load_button = continue_btn
		_refresh_load_button_state()
		_log("Hooked Continue button as 'Load Game' (captured %d, total stored %d)" % [
			cont_captured.size(), _orig_continue_callables.size()
		])
	else:
		_create_load_game_button(buttons_root, new_btn)


# Force-enable the Load Game button if any slot has a save, even if vanilla
# disabled it because user:// has no Character.tres (typical state after a
# permadeath wipe of the active slot). Public so SlotPanel can call it after
# Delete operations to refresh the menu button live.
func _refresh_load_button_state() -> void:
	if _load_button == null or not is_instance_valid(_load_button):
		return
	_load_button.disabled = not any_slot_occupied()


func refresh_load_button_state_external() -> void:
	_refresh_load_button_state()


func _find_menu_buttons_root(menu: Node) -> Node:
	var candidates := [
		"Main/Buttons",
		"Main/MainMenu/Buttons",
		"MainMenu/Buttons",
		"Buttons",
	]
	for path in candidates:
		var node := menu.get_node_or_null(path)
		if node != null:
			return node
	for child in menu.find_children("*Buttons*", "", true, false):
		return child
	return null


func _find_button_in(parent: Node, names: Array) -> Button:
	for n in names:
		var direct := parent.get_node_or_null(n)
		if direct is Button:
			return direct
	for child in parent.get_children():
		if child is Button:
			var label := String(child.name)
			for n in names:
				if label == n:
					return child
	for child in parent.get_children():
		if child is Button:
			var txt := String(child.text)
			for n in names:
				if txt == n:
					return child
	return null


func _take_over_button(btn: Button, new_callable: Callable) -> Array:
	# Disconnect every existing pressed handler. Capture ONLY callables that
	# don't belong to this autoload (avoid self-loops when a button gets
	# re-hooked across menu redraws: capturing our own old binding would make
	# _invoke_pending_difficulty_handler call _on_difficulty_pressed in a loop
	# instead of the real vanilla handler).
	var captured: Array = []
	for c in btn.pressed.get_connections():
		var cb: Callable = c.callable
		btn.pressed.disconnect(cb)
		if cb.get_object() == self:
			continue
		captured.append(cb)
	btn.pressed.connect(new_callable)
	return captured


func _create_load_game_button(parent: Node, sibling: Node) -> void:
	if parent.get_node_or_null("MultiSaveSlots_LoadGame") != null:
		return
	var btn := Button.new()
	btn.name = "MultiSaveSlots_LoadGame"
	btn.text = "Load Game"
	btn.custom_minimum_size = Vector2(0, 40)
	btn.pressed.connect(_open_panel_in_load_mode)
	if sibling != null and sibling.get_parent() == parent:
		sibling.add_sibling(btn, true)
		parent.move_child(btn, sibling.get_index() + 1)
	else:
		parent.add_child(btn)
	_log("Created standalone Load Game button")


# ---------------------------------------------------------------------------
# New Game -> Difficulty -> Slot flow
# ---------------------------------------------------------------------------

# Triggered when the user clicks the vanilla "New Game" button. We snapshot
# the current visible buttons in the menu, run the vanilla handler so the
# difficulty submenu appears, and then start polling for newly-visible buttons
# to re-bind.
func _on_new_pressed_capture() -> void:
	# Drop only stale entries (buttons freed since last hook). Keep valid
	# entries so the second click on "New" doesn't re-hook live buttons and
	# accidentally capture our own callable as the "original".
	var stale: Array = []
	for btn in _difficulty_handlers.keys():
		if not is_instance_valid(btn):
			stale.append(btn)
	for s in stale:
		_difficulty_handlers.erase(s)
		_pre_new_visible.erase(s)
	_pending_difficulty_btn = null
	var menu := _get_menu_node()
	if menu != null:
		for node in menu.find_children("*", "Button", true, false):
			var btn: Button = node as Button
			if btn != null and not _difficulty_handlers.has(btn):
				_pre_new_visible[btn] = btn.is_visible_in_tree()
	_log("Invoking vanilla New handler (%d captured handlers)" % _orig_new_callables.size())
	for c in _orig_new_callables:
		if c.is_valid():
			c.call()
	# Watch the menu for newly-visible buttons for ~1.5s. Long enough for any
	# fade-in animation, short enough to not capture buttons from later UI
	# changes.
	_await_difficulty_after = 1.5


func _poll_difficulty_buttons(delta: float) -> void:
	if _await_difficulty_after <= 0.0:
		return
	_await_difficulty_after -= delta
	var menu := _get_menu_node()
	if menu == null:
		_await_difficulty_after = -1.0
		return
	for node in menu.find_children("*", "Button", true, false):
		var btn: Button = node as Button
		if btn == null or not is_instance_valid(btn):
			continue
		if _difficulty_handlers.has(btn):
			continue
		var was_visible: bool = bool(_pre_new_visible.get(btn, false))
		if btn.is_visible_in_tree() and not was_visible and _is_difficulty_candidate(btn):
			_hook_difficulty_button(btn)


func _is_difficulty_candidate(btn: Button) -> bool:
	# Skip our own buttons and obvious non-difficulty controls.
	var name_lower := String(btn.name).to_lower()
	var text_lower := String(btn.text).to_lower()
	for blocked in ["multisaveslots", "back", "cancel", "return", "mcm", "settings", "quit"]:
		if name_lower.find(blocked) != -1:
			return false
		if text_lower == blocked:
			return false
	return true


func _hook_difficulty_button(btn: Button) -> void:
	# Inspect the button BEFORE rebinding. Buttons with zero pressed handlers
	# in vanilla are just toggles/selectors (e.g. picking which difficulty
	# row is highlighted) and must NOT open the slot panel. Only intercept
	# buttons that actually do something on press (the confirm action like
	# "Enter the Road").
	var connections := btn.pressed.get_connections()
	if connections.is_empty():
		# Mark as inspected so we don't keep re-checking it every frame.
		_difficulty_handlers[btn] = []
		_log("Skipping non-confirm button '%s' / '%s' (0 pressed handlers)" % [
			String(btn.name), String(btn.text)
		])
		return
	var captured := _take_over_button(btn, _on_difficulty_pressed.bind(btn))
	_difficulty_handlers[btn] = captured
	_log("Hooked difficulty button '%s' / '%s' (%d handlers)" % [
		String(btn.name), String(btn.text), captured.size()
	])


# ---------------------------------------------------------------------------
# In-game pause-menu hooks (Quit Game / Exit Menu)
#
# The shutdown path through tree_exiting / NOTIFICATION_WM_CLOSE_REQUEST is
# racy: vanilla SAVE messages print but DirAccess.copy from user:// to the
# slot folder may not finish before the engine tears down resources, leaving
# the slot empty. By hooking the Quit / Exit Menu buttons we run the sync
# while the engine is fully alive, before Loader.Quit() is invoked.
# ---------------------------------------------------------------------------

# Fires for every node added anywhere in the scene tree. Keep the body
# microscopic: anything more than a type check would multiply by the number
# of nodes the game spawns during loading.
func _on_scene_node_added(node: Node) -> void:
	if not (node is Button):
		return
	# Defer one frame so the owning scene can finish setting the button's
	# text, parent and pressed signal before we classify and rebind it.
	call_deferred("_try_hook_added_button", node)


func _try_hook_added_button(btn: Button) -> void:
	if btn == null or not is_instance_valid(btn) or not btn.is_inside_tree():
		return
	if _pause_button_hooks.has(btn):
		return
	# Only care about in-game pause-menu buttons (Map subtree). Anything
	# under /root/Menu is the main-menu and is handled by the dedicated
	# hook installer; anything else (popups, mod UI) is ignored.
	var path := String(btn.get_path())
	if not path.begins_with("/root/Map"):
		return
	var kind := _classify_pause_button(btn)
	if kind == "":
		return
	_hook_pause_button(btn, kind)
	# Auto-cleanup when the button leaves the tree (scene unload). Saves
	# us from iterating _pause_button_hooks looking for stale entries.
	if not btn.tree_exited.is_connected(_on_pause_button_freed):
		btn.tree_exited.connect(_on_pause_button_freed.bind(btn))


func _on_pause_button_freed(btn: Button) -> void:
	_pause_button_hooks.erase(btn)
	_pause_button_kinds.erase(btn)


# Returns "quit" for full-shutdown buttons, "exit" for return-to-menu buttons,
# or "" for unrelated buttons. Both kinds need a forced vanilla save before
# the captured handler runs (vanilla's Exit-to-Menu in particular doesn't
# auto-save Character.tres / Shelter outside SuspendSaveSystem).
func _classify_pause_button(btn: Button) -> String:
	var name_lower := String(btn.name).to_lower()
	var text_lower := String(btn.text).to_lower()
	for needle in ["quit"]:
		if name_lower.find(needle) != -1 or text_lower.find(needle) != -1:
			return "quit"
	# Match common "back to main menu" labels. We deliberately avoid matching
	# any standalone "menu" token because pause menus often have a "Menu"
	# parent container or settings tab named that way; require an explicit
	# exit/leave/main verb so we only catch real navigation buttons.
	for needle in ["exit", "leave", "main menu", "to menu", "return to menu"]:
		if name_lower.find(needle) != -1 or text_lower.find(needle) != -1:
			return "exit"
	return ""


func _hook_pause_button(btn: Button, kind: String) -> void:
	var connections := btn.pressed.get_connections()
	if connections.is_empty():
		# Not a real action button (decorative / placeholder).
		_pause_button_hooks[btn] = []
		_pause_button_kinds[btn] = kind
		return
	var captured := _take_over_button(btn, _on_pause_button_pressed.bind(btn))
	_pause_button_hooks[btn] = captured
	_pause_button_kinds[btn] = kind
	print("[%s] Hooked in-game pause button '%s' / '%s' kind=%s (%d original handlers)" % [
		MOD_NAME, String(btn.name), String(btn.text), kind, captured.size()
	])


func _on_pause_button_pressed(btn: Button) -> void:
	var kind: String = String(_pause_button_kinds.get(btn, "quit"))
	# Force vanilla saves BEFORE letting vanilla's original handler run.
	# Without SuspendSaveSystem, vanilla's _on_exit_menu_pressed and
	# _on_exit_quit_pressed do NOT call SaveCharacter / SaveShelter / SaveWorld
	# automatically (SSS adds those calls in its override). So the slot would
	# only see whatever map-transition saves happened earlier in the session,
	# missing all in-cabin progress (sleep, crafting) until the next startup
	# crash-recovery sync rescues it on relaunch.
	print("[%s] Pause button '%s' pressed (kind=%s) -> pre-handler save+sync" % [
		MOD_NAME, String(btn.name), kind
	])
	_force_vanilla_save()
	sync_out_active()
	var captured: Array = _pause_button_hooks.get(btn, [])
	for c in captured:
		if c.is_valid():
			c.call()
	if kind == "quit":
		# Second sync to capture anything the captured handler wrote AFTER our
		# initial sync (e.g. SuspendSaveSystem's _on_exit_quit_pressed writes
		# user://SuspendSave.save via save_last_spawn() before calling
		# Loader.Quit()). Loader.Quit() in vanilla doesn't truncate the frame
		# (SSS runs PlayClick() after it), so this post-sync has time to finish.
		sync_out_active()
		# Mark quit-sync as already done so the tree_exiting fallback doesn't
		# double-execute.
		_quit_sync_done = true
	else:
		# Exit-to-Menu: vanilla's handler triggers a Map -> Menu scene change.
		# _check_scene_transition_for_sync_out will fire on the next frame and
		# re-sync (e.g. picking up SuspendSave.save written by SSS's override
		# of _on_exit_menu_pressed). We MUST NOT set _quit_sync_done here so
		# a later Quit Game press from the main menu still flushes correctly.
		pass


func _on_difficulty_pressed(btn: Button) -> void:
	# Extra guard in case _hook_difficulty_button stored an empty handlers
	# list for this button: do nothing (not a confirm action).
	var captured: Array = _difficulty_handlers.get(btn, [])
	if captured.is_empty():
		return
	_pending_difficulty_btn = btn
	_log("Difficulty selected: '%s' / '%s' -> opening slot panel" % [
		String(btn.name), String(btn.text)
	])
	_open_slot_panel("new")


# ---------------------------------------------------------------------------
# Panel openers
# ---------------------------------------------------------------------------

func _open_panel_in_load_mode() -> void:
	_open_slot_panel("load")


func _open_slot_panel(mode: String) -> void:
	if _slot_panel_script == null:
		_slot_panel_script = load("res://mods/MultiSaveSlots/SlotPanel.gd")
	if _slot_panel_script == null:
		_log("SlotPanel script missing, aborting")
		return
	var existing := get_tree().root.get_node_or_null("MultiSaveSlots_Panel")
	if existing != null:
		existing.queue_free()
	var panel: Control = _slot_panel_script.new()
	panel.name = "MultiSaveSlots_Panel"
	panel.set_meta("mode", mode)
	panel.set_meta("controller", self)
	get_tree().root.add_child(panel)
	if panel.has_method("open"):
		panel.open(mode, self)


# ---------------------------------------------------------------------------
# Scene transition tracker (for sync_out when returning to menu)
# ---------------------------------------------------------------------------

func _check_scene_transition_for_sync_out() -> void:
	var on_menu := _get_menu_node() != null
	if on_menu and not _last_scene_was_menu:
		_log("Returned to menu, sync_out_active")
		sync_out_active()
	_last_scene_was_menu = on_menu


# ---------------------------------------------------------------------------
# Force vanilla save (used by app-close handler)
#
# Vanilla normally writes Character/World/Cabin on exit-to-menu by itself.
# This helper is a safety net for when the user closes the game window with
# the X button or alt+F4 mid-game; we attempt to flush vanilla saves before
# our sync_out runs.
# ---------------------------------------------------------------------------

func _force_vanilla_save() -> void:
	var loader = get_node_or_null("/root/Loader")
	if loader == null:
		return
	var current = get_tree().current_scene
	var map_node: Node = null
	if current != null:
		map_node = current.get_node_or_null("/root/Map")
	if loader.has_method("SaveCharacter"):
		loader.SaveCharacter()
	if loader.has_method("SaveWorld"):
		loader.SaveWorld()
	var shelter: bool = bool(gameData.shelter) if "shelter" in gameData else false
	if shelter and loader.has_method("SaveShelter") and map_node != null and "mapName" in map_node:
		loader.SaveShelter(String(map_node.mapName))
	_log("Forced vanilla save")


# ---------------------------------------------------------------------------
# Crash-recovery sync (startup) + map-change watcher (in-session)
#
# Vanilla writes save .tres files on map transitions and other internal
# events. MSS only syncs to slots on controlled events (menu return, Quit
# button, window close), so a crash mid-game would leave the active slot
# stale and the next sync_in would clobber the fresh user:// state with
# old slot data.
#
# Two layers make MSS as crash-safe as vanilla:
#
# 1) Startup recovery: on _ready, if user://Character.tres mtime is newer
#    than the active slot's, treat it as unsynced state from a previous
#    crash and copy it to the slot before the user can reload.
# 2) In-session watcher: vanilla writes saves BEFORE updating
#    gameData.currentMap during a transition. We watch that variable in
#    memory (zero I/O) and trigger sync_out the moment it changes.
# ---------------------------------------------------------------------------

func _check_crash_recovery_sync() -> void:
	var should_sync := false
	var reason := ""

	# Case 1: user://Character.tres mtime newer than the active slot's
	# (previous run crashed, dirty exit, or vanilla play without MSS).
	if FileAccess.file_exists("user://" + OCCUPANCY_MARKER):
		var slot_path := slot_dir(_active_slot) + "/" + OCCUPANCY_MARKER
		var user_mtime: int = int(FileAccess.get_modified_time("user://" + OCCUPANCY_MARKER))
		var slot_mtime: int = 0
		if FileAccess.file_exists(slot_path):
			slot_mtime = int(FileAccess.get_modified_time(slot_path))
		if user_mtime > slot_mtime:
			should_sync = true
			reason = "user://Character.tres (%d) newer than slot %d (%d)" % [
				user_mtime, _active_slot, slot_mtime
			]

	# Case 2: a tracked file exists in user:// but not in the active slot.
	# Covers MSS upgrades that broaden tracked extensions, and mods the user
	# installed AFTER MSS already ran (their save files were never synced).
	# Without this, the next sync_in would wipe those files and lose data.
	if not should_sync:
		var root = DirAccess.open("user://")
		if root != null:
			for f in root.get_files():
				if not _is_trackable_file(f):
					continue
				if not FileAccess.file_exists(slot_dir(_active_slot) + "/" + f):
					should_sync = true
					reason = "tracked file '%s' present in user:// but missing from slot %d" % [
						f, _active_slot
					]
					break

	if should_sync:
		print("[%s] Auto-sync at startup: %s" % [MOD_NAME, reason])
		sync_out_active()


func _watch_map_change() -> void:
	if _quit_sync_done:
		return
	if not "currentMap" in gameData:
		return
	var current: String = String(gameData.currentMap)
	# Only track real, in-game maps. We must NEVER overwrite _last_known_map
	# with "" or "Menu" because we use it as a fallback in _write_slot_meta
	# when vanilla has already cleared gameData.currentMap on exit-to-menu.
	if current == "" or current == "Menu":
		return
	if current == _last_known_map:
		return
	var prev := _last_known_map
	_last_known_map = current
	# Skip startup (prev empty / Menu): no in-game checkpoint to mirror yet.
	if prev == "" or prev == "Menu":
		return
	# Vanilla just wrote Character.tres / World.tres / <prev>.tres before
	# updating currentMap. Mirror that state into the active slot.
	sync_out_active()


# Reset the watcher's baseline after operations that intentionally write to
# user:// or trigger sync, so the watcher doesn't fire spuriously next frame.
# Like _watch_map_change, we never degrade the baseline to "" or "Menu" once
# it holds a real map; otherwise sync_out called on exit-to-menu would lose
# the last known map and write last_map = "" into the slot meta.
func _refresh_map_baseline() -> void:
	if not "currentMap" in gameData:
		return
	var current := String(gameData.currentMap)
	if current == "" or current == "Menu":
		return
	_last_known_map = current


# ---------------------------------------------------------------------------
# Permadeath watcher
# ---------------------------------------------------------------------------

func _run_permadeath_watcher() -> void:
	if not _autodelete_on_permadeath:
		return
	var dead_now: bool = bool(gameData.isDead) if "isDead" in gameData else false
	var perma: bool = bool(gameData.permadeath) if "permadeath" in gameData else false

	if dead_now and not _was_dead:
		_was_dead = true
		if perma:
			# Capture target slot AT the moment of death. If the user later
			# switches active slot (e.g. starts a new game elsewhere before
			# we reach the menu), we still wipe the slot that actually died.
			_pending_permadeath_wipe = true
			_permadeath_target_slot = _active_slot
			_permadeath_target_map = String(gameData.currentMap) if "currentMap" in gameData else ""
			_log("Permadeath detected on slot %d (map=%s), wipe queued" % [
				_permadeath_target_slot, _permadeath_target_map
			])
	elif not dead_now and _was_dead:
		_was_dead = false

	if _pending_permadeath_wipe and _get_menu_node() != null:
		var target := _permadeath_target_slot
		var was_active: bool = (_active_slot == target)
		if target >= 1 and target <= SLOT_COUNT:
			wipe_slot(target)
			# Only clear user:// if the dead slot is still the active one. If
			# the user already switched to another slot (which would have done
			# its own sync_in to populate user://), wiping user:// would
			# destroy that fresh slot's loaded data.
			if was_active:
				_clear_user_root_tracked()
		_log("Permadeath wipe applied to slot %d (was_active=%s)" % [
			target, str(was_active)
		])
		_pending_permadeath_wipe = false
		_permadeath_target_slot = 0
		_permadeath_target_map = ""
		# Re-evaluate Load Game button so the player can still load any
		# surviving slot even though vanilla just disabled it on this menu
		# instance.
		_refresh_load_button_state()


# ---------------------------------------------------------------------------
# Tracked files helpers
# ---------------------------------------------------------------------------

# Reads user://MultiSaveSlots/file_rules.cfg and applies it to the live
# rule variables. If the file doesn't exist yet, writes a fully-commented
# template seeded with the DEFAULT_* constants so the user has a clear
# starting point. If the file exists but a section/key is missing, that
# rule keeps its default (forwards-compatible: adding new categories in a
# future MSS version doesn't require the user to delete the cfg).
func _load_or_init_file_rules() -> void:
	_ensure_dir(ROOT_DIR)
	if not FileAccess.file_exists(FILE_RULES_PATH):
		_write_default_file_rules()
		_log("Created default %s -- edit it to customise per-slot rules" % FILE_RULES_PATH)
		# Defaults already loaded into the live vars at declaration time.
		return
	var cfg := ConfigFile.new()
	var err := cfg.load(FILE_RULES_PATH)
	if err != OK:
		_log("Failed to parse %s (err=%d) -- using defaults" % [FILE_RULES_PATH, err])
		return
	_tracked_file_extensions = _read_string_list(cfg, "file_rules", "tracked_file_extensions",
		DEFAULT_TRACKED_FILE_EXTENSIONS)
	_never_touch_files       = _read_string_list(cfg, "file_rules", "never_touch_files",
		DEFAULT_NEVER_TOUCH_FILES)
	_never_touch_extensions  = _read_string_list(cfg, "file_rules", "never_touch_extensions",
		DEFAULT_NEVER_TOUCH_EXTENSIONS)
	_force_tracked_files     = _read_string_list(cfg, "file_rules", "force_tracked_files",
		DEFAULT_FORCE_TRACKED_FILES)
	_force_tracked_prefixes  = _read_string_list(cfg, "file_rules", "force_tracked_prefixes",
		DEFAULT_FORCE_TRACKED_PREFIXES)
	_never_touch_suffixes    = _read_string_list(cfg, "file_rules", "never_touch_suffixes",
		DEFAULT_NEVER_TOUCH_SUFFIXES)
	_log("Loaded file rules from %s" % FILE_RULES_PATH)


# Helper: reads a value from ConfigFile as Array[String], coercing each
# element so users can hand-edit the cfg without worrying about types. Falls
# back to the provided default if the key is missing.
func _read_string_list(cfg: ConfigFile, section: String, key: String, default_value: Array) -> Array:
	if not cfg.has_section_key(section, key):
		return default_value.duplicate()
	var raw = cfg.get_value(section, key, default_value)
	if not (raw is Array):
		return default_value.duplicate()
	var out: Array = []
	for item in raw:
		out.append(String(item))
	return out


# Writes file_rules.cfg with the DEFAULT_* values and a long header that
# explains every category, the evaluation order, and how each list is used.
# We write the file by hand (instead of ConfigFile.save) so the comments are
# preserved between runs (ConfigFile.save would strip them).
func _write_default_file_rules() -> void:
	var f := FileAccess.open(FILE_RULES_PATH, FileAccess.WRITE)
	if f == null:
		_log("Could not create %s (err=%d)" % [FILE_RULES_PATH, FileAccess.get_open_error()])
		return
	f.store_string(_default_file_rules_content())
	f.close()


func _default_file_rules_content() -> String:
	var lines: Array = [
		"; ============================================================================",
		"; Multi Save Slots - File Rules Configuration",
		"; ============================================================================",
		";",
		"; This file controls which files in user:// (the game save folder) get",
		"; mirrored per slot, which stay global, and which the mod must never touch.",
		"; The mod auto-creates this file with safe defaults; edit it to add support",
		"; for new mods or to override what gets tracked on your machine.",
		";",
		"; Save folder location: %APPDATA%\\Godot\\app_userdata\\Road to Vostok\\",
		";",
		"; To reset to defaults: delete this file and restart the game.",
		";",
		"; ----------------------------------------------------------------------------",
		"; EVALUATION ORDER (top wins):",
		";",
		";   1. never_touch_files       (exact name)",
		";   2. force_tracked_files     (exact name)  + force_tracked_prefixes (prefix)",
		";   3. never_touch_extensions  (extension)   + never_touch_suffixes   (suffix)",
		";   4. tracked_file_extensions (extension)",
		";   5. anything else: left alone (default safe).",
		";",
		"; ----------------------------------------------------------------------------",
		"; CATEGORIES:",
		";",
		"; [never_touch_files] - Hard blacklist by exact filename. The mod will NEVER",
		";   move, copy, overwrite or delete these. Use it for global config files",
		";   the user wants shared across all slots, and for mod-loader internals",
		";   that would brick the game if touched. Wins over force_tracked_files.",
		";   Defaults protect: Metro Mod Loader (modloader.gd, mod_config.cfg, ...),",
		";   vanilla Validator.tres + Preferences.tres, and SimpleHUD UI prefs.",
		";",
		"; [force_tracked_files] - Whitelist by exact filename. Forces the file to",
		";   be mirrored per slot even if its extension is in never_touch_extensions",
		";   or its name matches a never_touch_suffix. Use this for mod save files",
		";   that store progression in a .cfg/.ini (which would otherwise be skipped",
		";   as global mod config). Defaults cover XP & Skills System.",
		";",
		"; [force_tracked_prefixes] - Same as force_tracked_files but matches by",
		";   filename prefix. Use for mods that name files per-profile, e.g.",
		";   XPData_<profile>.cfg with Patty's Profiles.",
		";",
		"; [never_touch_extensions] - Defense-in-depth blacklist by file extension.",
		";   Any file with one of these extensions in user:// root is treated as",
		";   global config and never per-slot. Catches mod_config.cfg-like files",
		";   automatically without naming each one. To exempt a specific file from",
		";   this blacklist, add it to force_tracked_files.",
		";",
		"; [never_touch_suffixes] - Pattern blacklist by filename suffix. Catches",
		";   mods that store JSON config with the convention <modid>_preferences.json",
		";   / _settings.json / _config.json. To exempt a specific file, add its",
		";   exact name to force_tracked_files.",
		";",
		"; [tracked_file_extensions] - Auto-discovery whitelist by extension. Any",
		";   file in user:// root with one of these extensions (and not blacklisted)",
		";   is mirrored per slot. .tres covers vanilla saves and most mod saves;",
		";   .json covers modern mod save files; .save is a common alternative;",
		";   .jpg covers save thumbnails.",
		";",
		"; ----------------------------------------------------------------------------",
		"; FORMAT: each value is a Godot Array of strings. Wrap the whole list in",
		"; square brackets, separate items with commas, and double-quote each name.",
		"; Whitespace and trailing commas are tolerated.",
		";",
		"; Example: never_touch_files = [\"file_a.cfg\", \"file_b.json\"]",
		"; ============================================================================",
		"",
		"[file_rules]",
		"",
		_emit_array_value("tracked_file_extensions", DEFAULT_TRACKED_FILE_EXTENSIONS),
		"",
		_emit_array_value("never_touch_files", DEFAULT_NEVER_TOUCH_FILES),
		"",
		_emit_array_value("never_touch_extensions", DEFAULT_NEVER_TOUCH_EXTENSIONS),
		"",
		_emit_array_value("never_touch_suffixes", DEFAULT_NEVER_TOUCH_SUFFIXES),
		"",
		_emit_array_value("force_tracked_files", DEFAULT_FORCE_TRACKED_FILES),
		"",
		_emit_array_value("force_tracked_prefixes", DEFAULT_FORCE_TRACKED_PREFIXES),
		"",
	]
	return "\n".join(lines) + "\n"


# Emits "key = [\"a\", \"b\", \"c\"]" on a single line, matching the format
# ConfigFile.save() produces so the file round-trips cleanly through both
# manual edits (any text editor) and any future programmatic re-save.
func _emit_array_value(key: String, values: Array) -> String:
	if values.is_empty():
		return "%s = []" % key
	var quoted: Array = []
	for raw in values:
		quoted.append("\"%s\"" % String(raw).replace("\"", "\\\""))
	return "%s = [%s]" % [key, ", ".join(quoted)]


func _is_trackable_file(file_name: String) -> bool:
	# Hard never-touch always wins (modloader internals, validator, simplehud).
	if _never_touch_files.has(file_name):
		return false
	# Per-mod save files whose extension is normally blacklisted (e.g.
	# XPData.cfg) opt in via the force-tracked override.
	if _is_force_tracked(file_name):
		return true
	if _is_blacklisted_file(file_name):
		return false
	var ext := file_name.get_extension().to_lower()
	return _tracked_file_extensions.has(ext)


# Hard safety net. Returns false for any file that this mod must never touch
# in user:// root regardless of whether it's in _tracked_file_extensions
# (defense in depth in case the whitelist is ever widened by mistake).
# Force-tracked files are always safe to touch (we explicitly opted them in).
func _is_safe_to_touch(file_name: String) -> bool:
	if _never_touch_files.has(file_name):
		return false
	if _is_force_tracked(file_name):
		return true
	return not _is_blacklisted_file(file_name)


func _is_force_tracked(file_name: String) -> bool:
	if _force_tracked_files.has(file_name):
		return true
	for raw_prefix in _force_tracked_prefixes:
		var prefix: String = String(raw_prefix)
		if file_name.begins_with(prefix):
			return true
	return false


func _is_blacklisted_file(file_name: String) -> bool:
	if _never_touch_files.has(file_name):
		return true
	var ext: String = file_name.get_extension().to_lower()
	if _never_touch_extensions.has(ext):
		return true
	var lower: String = file_name.to_lower()
	for raw_suffix in _never_touch_suffixes:
		var suffix: String = String(raw_suffix)
		if lower.ends_with(suffix):
			return true
	return false


func _clear_user_root_tracked() -> void:
	var root = DirAccess.open("user://")
	if root == null:
		return
	for f in root.get_files():
		if not _is_trackable_file(f):
			continue
		if not _is_safe_to_touch(f):
			_log("Refused to delete protected file '%s' from user:// root" % f)
			continue
		root.remove(f)


func _has_any_tracked_in_user_root() -> bool:
	var root = DirAccess.open("user://")
	if root == null:
		return false
	for f in root.get_files():
		if _is_trackable_file(f):
			return true
	return false


# ---------------------------------------------------------------------------
# State + slot metadata files
# ---------------------------------------------------------------------------

func _load_state() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(STATE_PATH) == OK:
		_active_slot = clampi(int(cfg.get_value("state", "active_slot", 1)), 1, SLOT_COUNT)
	else:
		_active_slot = 1
		_save_state()


func _save_state() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("state", "active_slot", _active_slot)
	cfg.save(STATE_PATH)


func _write_slot_meta(n: int) -> void:
	var meta_path := slot_dir(n) + "/_meta.cfg"
	var cfg := ConfigFile.new()
	# Preserve existing display_name AND last_map if any (we only refresh
	# map/timestamp). Keeping the previous last_map lets us avoid degrading
	# a known-good value to "" when sync_out runs on exit-to-menu (vanilla
	# has already cleared gameData.currentMap by that point).
	var existing_name := ""
	var existing_map := ""
	if FileAccess.file_exists(meta_path):
		var prev := ConfigFile.new()
		if prev.load(meta_path) == OK:
			existing_name = String(prev.get_value("meta", "display_name", ""))
			existing_map  = String(prev.get_value("meta", "last_map",     ""))
	var last_map := _resolve_last_map_for_slot(n)
	# Defensive: if all live-resolution paths failed, keep the previous
	# value rather than overwriting with "" (which surfaces as "Map ?" in
	# the slot panel).
	if last_map == "":
		last_map = existing_map
	cfg.set_value("meta", "display_name",  existing_name)
	cfg.set_value("meta", "last_map",      last_map)
	cfg.set_value("meta", "last_play_iso", Time.get_datetime_string_from_system(true))
	cfg.set_value("meta", "dead",          false)
	cfg.save(meta_path)


# Best-effort resolution of the current map for slot n, in priority order:
#   1. gameData.currentMap          (live, accurate while in-game)
#   2. _last_known_map              (in-memory baseline; preserved across
#                                    exit-to-menu by _watch_map_change)
#   3. user://Transition.tres       (vanilla writes this on map transitions
#                                    via Loader.SaveTransition)
#   4. slotN/Transition.tres        (whatever the previous sync mirrored)
# Empty / "Menu" values are treated as no-data and skip to the next step.
func _resolve_last_map_for_slot(n: int) -> String:
	if "currentMap" in gameData:
		var live := String(gameData.currentMap)
		if live != "" and live != "Menu":
			return live
	if _last_known_map != "" and _last_known_map != "Menu":
		return _last_known_map
	for tpath in ["user://Transition.tres", slot_dir(n) + "/Transition.tres"]:
		if ResourceLoader.exists(tpath):
			var tres = ResourceLoader.load(tpath)
			if tres != null and "currentMap" in tres:
				var m := String(tres.currentMap)
				if m != "" and m != "Menu":
					return m
	return ""


# ---------------------------------------------------------------------------
# First-run migration: if the user already has a save in user:// root and no
# slot is occupied, treat that save as slot 1 so they don't lose it.
# ---------------------------------------------------------------------------

func _first_run_migration() -> void:
	if not FileAccess.file_exists("user://" + OCCUPANCY_MARKER):
		return
	for n in range(1, SLOT_COUNT + 1):
		if is_slot_occupied(n):
			return
	_log("First run: migrating existing user:// save into slot 1")
	_active_slot = 1
	_save_state()
	sync_out_active()


# Restore any blacklisted file that previous MSS versions had wrongly
# mirrored into per-slot folders (e.g. simplehud_preferences.json before
# v1.1.13). Idempotent: runs every startup, no-op once slots are clean.
#
# Algorithm per blacklisted file name:
#   1. Find all slots that have a copy.
#   2. If user:// has no copy and at least one slot does, restore the
#      newest one (by mtime) so the user keeps their most recent config.
#   3. Delete the file from every slot so future sync_in/sync_out can't
#      reintroduce it.
func _restore_blacklisted_globals() -> void:
	for raw in _never_touch_files:
		var fname: String = String(raw)
		var ext: String = fname.get_extension().to_lower()
		# Only repair files that match our tracked extensions: anything
		# outside (e.g. modloader.gd / .cfg) was never copied by MSS in
		# the first place, so there's nothing to clean.
		if not _tracked_file_extensions.has(ext):
			continue
		_restore_global_from_slots(fname)


func _restore_global_from_slots(fname: String) -> void:
	var newest_slot := 0
	var newest_mtime := 0
	for n in range(1, SLOT_COUNT + 1):
		var src := slot_dir(n) + "/" + fname
		if not FileAccess.file_exists(src):
			continue
		var mtime := FileAccess.get_modified_time(src)
		if mtime > newest_mtime:
			newest_mtime = mtime
			newest_slot = n
	if newest_slot == 0:
		return
	var dst := "user://" + fname
	if not FileAccess.file_exists(dst):
		var src := slot_dir(newest_slot) + "/" + fname
		var err := DirAccess.copy_absolute(
			ProjectSettings.globalize_path(src),
			ProjectSettings.globalize_path(dst)
		)
		if err == OK:
			_log("Restored global '%s' from slot %d to user:// root" % [fname, newest_slot])
		else:
			_log("Failed to restore '%s' from slot %d (err=%d)" % [fname, newest_slot, err])
	for n in range(1, SLOT_COUNT + 1):
		var path := slot_dir(n) + "/" + fname
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
			_log("Cleaned blacklisted file '%s' from slot %d" % [fname, n])


# ---------------------------------------------------------------------------
# MCM configuration
# ---------------------------------------------------------------------------

func _try_load_mcm():
	if ResourceLoader.exists(MCM_HELPERS_PATH):
		return load(MCM_HELPERS_PATH)
	return null


func _build_default_config() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.set_value("Bool", "enabled", {
		"name":     "Enable Multi Save Slots",
		"tooltip":  "Master toggle. When off, the mod stops intercepting menu buttons and syncing slots.",
		"default":  true,
		"value":    true,
		"menu_pos": 1
	})
	cfg.set_value("Bool", "autodelete_on_permadeath", {
		"name":     "Auto-delete slot on Permadeath",
		"tooltip":  "When you die in a permadeath map, wipe the active slot automatically (matches vanilla wipe behaviour).",
		"default":  true,
		"value":    true,
		"menu_pos": 2
	})
	cfg.set_value("Bool", "verbose_logs", {
		"name":     "Verbose Logs",
		"tooltip":  "Print extra debug information to the console.",
		"default":  false,
		"value":    false,
		"menu_pos": 3
	})
	return cfg


func _init_mcm_config() -> void:
	_ensure_dir(CONFIG_DIR)
	var cfg: ConfigFile = _build_default_config()

	if not FileAccess.file_exists(CONFIG_PATH):
		cfg.save(CONFIG_PATH)
	else:
		_mcm_helpers.CheckConfigurationHasUpdated(MOD_ID, cfg, CONFIG_PATH)

	var loaded := ConfigFile.new()
	if loaded.load(CONFIG_PATH) == OK:
		_apply_config(loaded)

	_mcm_helpers.RegisterConfiguration(
		MOD_ID,
		MOD_NAME,
		CONFIG_DIR,
		"Adds %d save slots so 'New Game' no longer wipes your previous run. 'Load Game' lets you pick which slot to resume." % SLOT_COUNT,
		{ "config.ini": _on_mcm_save }
	)


func _on_mcm_save(cfg: ConfigFile) -> void:
	_apply_config(cfg)


func _mcm_val(cfg: ConfigFile, section: String, key: String, fallback):
	var entry = cfg.get_value(section, key, null)
	if entry == null or not (entry is Dictionary):
		return fallback
	return entry.get("value", fallback)


func _apply_config(cfg: ConfigFile) -> void:
	_enabled                  = bool(_mcm_val(cfg, "Bool", "enabled",                  _enabled))
	_autodelete_on_permadeath = bool(_mcm_val(cfg, "Bool", "autodelete_on_permadeath", _autodelete_on_permadeath))
	_verbose_logs             = bool(_mcm_val(cfg, "Bool", "verbose_logs",             _verbose_logs))


# -- Fallback config (no MCM) ----------------------------------------------

func _load_fallback_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(FALLBACK_CFG) == OK:
		_enabled                  = cfg.get_value("config", "enabled",                  _enabled)
		_autodelete_on_permadeath = cfg.get_value("config", "autodelete_on_permadeath", _autodelete_on_permadeath)
		_verbose_logs             = cfg.get_value("config", "verbose_logs",             _verbose_logs)
	else:
		_save_fallback_config()


func _save_fallback_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("config", "enabled",                  _enabled)
	cfg.set_value("config", "autodelete_on_permadeath", _autodelete_on_permadeath)
	cfg.set_value("config", "verbose_logs",             _verbose_logs)
	cfg.save(FALLBACK_CFG)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _ensure_dir(path: String) -> void:
	var dir = DirAccess.open("user://")
	if dir != null:
		dir.make_dir_recursive(path.replace("user://", ""))


func _log(msg: String) -> void:
	if _verbose_logs:
		print("[%s] %s" % [MOD_NAME, msg])
