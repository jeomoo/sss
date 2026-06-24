extends Control

# ---------------------------------------------------------------------------
# SlotPanel
#
# Modal save-slot picker built entirely in code so we don't need to ship a
# .tscn (avoids relative path issues inside the .vmz). Modes:
#   - "load": choosing a slot syncs its files into user:// and triggers the
#             vanilla Continue flow.
#   - "new":  choosing a slot wipes it (with overwrite confirmation if
#             occupied), sets it active, and triggers the vanilla New Game
#             flow.
# ---------------------------------------------------------------------------

const SLOT_COUNT := 5

var _mode: String        = "load"
var _controller          = null
var _confirm_dialog      = null
var _name_dialog         = null
var _row_buttons: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0
	offset_top = 0
	offset_right = 0
	offset_bottom = 0
	z_index = 4096


func open(mode: String, controller) -> void:
	_mode = mode
	_controller = controller
	_build_ui()


func _build_ui() -> void:
	for c in get_children():
		c.queue_free()

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.75)
	bg.anchor_left = 0.0
	bg.anchor_top = 0.0
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	var center := CenterContainer.new()
	center.anchor_left = 0.0
	center.anchor_top = 0.0
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(840, 580)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	vbox.add_child(margin)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 10)
	margin.add_child(inner)

	var title := Label.new()
	title.text = "Select Save Slot"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	inner.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Load Game" if _mode == "load" else "New Game"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 16)
	subtitle.modulate = Color(0.8, 0.8, 0.8)
	inner.add_child(subtitle)

	var sep := HSeparator.new()
	inner.add_child(sep)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 6)
	inner.add_child(rows)

	for n in range(1, SLOT_COUNT + 1):
		rows.add_child(_build_slot_row(n))

	var sep2 := HSeparator.new()
	inner.add_child(sep2)

	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_END
	inner.add_child(footer)

	var back_btn := Button.new()
	back_btn.text = "Back"
	back_btn.custom_minimum_size = Vector2(120, 36)
	back_btn.pressed.connect(_on_back_pressed)
	footer.add_child(back_btn)


func _build_slot_row(n: int) -> Control:
	var meta: Dictionary = _controller.slot_metadata(n) if _controller != null else {
		"occupied": false, "display_name": "", "last_map": "", "last_play_iso": "", "dead": false
	}
	var occupied: bool        = bool(meta.get("occupied", false))
	var dead: bool            = bool(meta.get("dead", false))
	var display_name: String  = String(meta.get("display_name", ""))

	var row_panel := PanelContainer.new()
	row_panel.custom_minimum_size = Vector2(0, 64)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	row_panel.add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	margin.add_child(hbox)

	var slot_label := Label.new()
	var slot_text := "Slot %d" % n
	if display_name != "":
		slot_text = "%s  (#%d)" % [display_name, n]
	slot_label.text = slot_text
	slot_label.custom_minimum_size = Vector2(180, 0)
	slot_label.add_theme_font_size_override("font_size", 18)
	hbox.add_child(slot_label)

	var info := Label.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if occupied:
		var map_str: String = String(meta.get("last_map", ""))
		var date_str: String = String(meta.get("last_play_iso", ""))
		var info_text := "Map: %s" % (map_str if map_str != "" else "?")
		if date_str != "":
			info_text += "   |   %s" % date_str
		if dead:
			info_text += "   [DEAD]"
			info.modulate = Color(1, 0.4, 0.4)
		info.text = info_text
	else:
		info.text = "Empty"
		info.modulate = Color(0.6, 0.6, 0.6)
	hbox.add_child(info)

	var action_btn := Button.new()
	action_btn.custom_minimum_size = Vector2(110, 36)
	if _mode == "load":
		action_btn.text = "Continue"
		action_btn.disabled = not occupied
		action_btn.pressed.connect(_on_load_pressed.bind(n))
	else:
		action_btn.text = "New"
		action_btn.pressed.connect(_on_new_pressed.bind(n))
	hbox.add_child(action_btn)

	var rename_btn := Button.new()
	rename_btn.text = "Rename"
	rename_btn.custom_minimum_size = Vector2(90, 36)
	rename_btn.disabled = not occupied
	rename_btn.pressed.connect(_on_rename_pressed.bind(n, display_name))
	hbox.add_child(rename_btn)

	var del_btn := Button.new()
	del_btn.text = "Delete"
	del_btn.custom_minimum_size = Vector2(90, 36)
	del_btn.disabled = not occupied
	del_btn.pressed.connect(_on_delete_pressed.bind(n))
	hbox.add_child(del_btn)

	_row_buttons[n] = {"action": action_btn, "rename": rename_btn, "delete": del_btn}
	return row_panel


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

func _on_back_pressed() -> void:
	if _mode == "new" and _controller != null and _controller.has_method("cancel_pending_new_flow"):
		_controller.cancel_pending_new_flow()
	_close()


func _on_load_pressed(n: int) -> void:
	if _controller == null:
		_close()
		return
	if not _controller.is_slot_occupied(n):
		return
	_controller.queue_load_slot(n)
	_close()


func _on_new_pressed(n: int) -> void:
	if _controller == null:
		_close()
		return
	if _controller.is_slot_occupied(n):
		_show_confirm("Overwrite slot %d? The existing save will be lost." % n,
			func(): _prompt_name_for_new(n))
	else:
		_prompt_name_for_new(n)


func _prompt_name_for_new(n: int) -> void:
	# Pre-fill with existing name (when overwriting) or blank for fresh slots.
	var default_name := ""
	if _controller != null:
		default_name = String(_controller.slot_metadata(n).get("display_name", ""))
	_show_name_dialog(
		"Name this save (Slot %d)" % n,
		default_name,
		"Start",
		func(name: String): _confirm_new(n, name)
	)


func _confirm_new(n: int, display_name: String) -> void:
	if _controller == null:
		_close()
		return
	_controller.queue_new_slot(n, display_name)
	_close()


func _on_rename_pressed(n: int, current_name: String) -> void:
	if _controller == null:
		return
	if not _controller.is_slot_occupied(n):
		return
	_show_name_dialog(
		"Rename Slot %d" % n,
		current_name,
		"Save",
		func(name: String): _confirm_rename(n, name)
	)


func _confirm_rename(n: int, display_name: String) -> void:
	if _controller == null:
		return
	_controller.set_slot_display_name(n, display_name)
	_build_ui()


func _on_delete_pressed(n: int) -> void:
	if _controller == null:
		return
	if not _controller.is_slot_occupied(n):
		return
	_show_confirm("Delete slot %d? This cannot be undone." % n,
		func(): _confirm_delete(n))


func _confirm_delete(n: int) -> void:
	if _controller == null:
		return
	_controller.wipe_slot(n)
	# Re-evaluate the main menu's Load Game button: if all slots are now empty
	# we want it disabled, otherwise keep it enabled.
	if _controller.has_method("refresh_load_button_state_external"):
		_controller.refresh_load_button_state_external()
	# Refresh row in place by rebuilding the UI with the same mode.
	_build_ui()


func _show_name_dialog(title: String, default_text: String, ok_label: String, on_ok: Callable) -> void:
	if _name_dialog != null and is_instance_valid(_name_dialog):
		_name_dialog.queue_free()
	var dlg := AcceptDialog.new()
	dlg.title = title
	dlg.ok_button_text = ok_label
	dlg.add_cancel_button("Cancel")
	dlg.min_size = Vector2(420, 0)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	dlg.add_child(vbox)

	var prompt := Label.new()
	prompt.text = "Enter a name (leave blank for default):"
	vbox.add_child(prompt)

	var line := LineEdit.new()
	line.text = default_text
	line.placeholder_text = "My save"
	line.max_length = 40
	line.custom_minimum_size = Vector2(380, 0)
	vbox.add_child(line)

	dlg.confirmed.connect(func():
		on_ok.call(line.text.strip_edges())
		dlg.queue_free()
	)
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.close_requested.connect(func(): dlg.queue_free())

	add_child(dlg)
	_name_dialog = dlg
	dlg.popup_centered()
	# Focus the input and select all so the user can immediately overwrite.
	line.call_deferred("grab_focus")
	if default_text != "":
		line.call_deferred("select_all")


func _show_confirm(text: String, on_yes: Callable) -> void:
	if _confirm_dialog != null and is_instance_valid(_confirm_dialog):
		_confirm_dialog.queue_free()
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = text
	dlg.title = "Confirm"
	dlg.confirmed.connect(func():
		on_yes.call()
		dlg.queue_free()
	)
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.close_requested.connect(func(): dlg.queue_free())
	add_child(dlg)
	_confirm_dialog = dlg
	dlg.popup_centered()


func _close() -> void:
	queue_free()
