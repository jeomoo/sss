extends CanvasLayer



const RTVCoop = preload("res://mods/RTVCoop/Game/Coop.gd")

const ACCENT := Color(0.56, 0.79, 0.23, 1.0)
const MUTE := Color(0.55, 0.55, 0.55)
const STATUS_UPDATE_INTERVAL := 0.2
const FONT_SIZE := 12
const VALUE_WIDTH := 40
const SLIDER_MIN_WIDTH := 100


var _gameData: Resource = preload("res://Resources/GameData.tres")

var _settings_node: Control = null
var _settings_box: BoxContainer = null
var _coop_button: Button = null
var _coop_panel: PanelContainer = null
var _coop_open: bool = false
var _coop_category: VBoxContainer = null
var _voice_category: VBoxContainer = null

var _status_label: RichTextLabel = null
var _steam_label: RichTextLabel = null
var _invite_button: Button = null

var _ptt_bind_button: Button = null
var _open_mic_button: Button = null
var _vad_row_label: Label = null
var _vad_row_control: Control = null
var _vad_slider: HSlider = null
var _vad_value: Label = null
var _mic_gain_slider: HSlider = null
var _mic_gain_value: Label = null
var _master_slider: HSlider = null
var _master_value: Label = null
var _range_slider: HSlider = null
var _range_value: Label = null
var _proximity_row_label: Label = null
var _proximity_row_control: Control = null
var _proximity_slider: HSlider = null
var _proximity_value: Label = null

var _peer_toggle_button: Button = null
var _peer_container: VBoxContainer = null
var _peer_rows: Dictionary = {}
var _peers_expanded: bool = false

var _voice_signal_hooked: bool = false
var _status_accum: float = 0.0


func _net() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.net if coop else null


func _players() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.players if coop else null


func _voice() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.get_sync("voice") if coop else null


func _lobby() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.lobby if coop else null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	print("[VoiceUI] ready")


func _process(delta: float) -> void:
	if not _is_pause_open():
		_apply_visibility(false)
		return
	if not _is_coop_active():
		_apply_visibility(false)
		return
	if not _ensure_injected():
		return
	_apply_visibility(true)
	_hook_voice_signal_once()
	_status_accum += delta
	if _status_accum < STATUS_UPDATE_INTERVAL:
		return
	_status_accum = 0.0
	_update_runtime_state()


func _is_pause_open() -> bool:
	return bool(_gameData.get("settings"))


func _is_coop_active() -> bool:
	var n := _net()
	return n != null and n.IsActive()


func _ensure_injected() -> bool:
	if is_instance_valid(_coop_button) and is_instance_valid(_coop_panel):
		return true
	var settings := _find_settings_node()
	if settings == null:
		return false
	_settings_box = settings.get_node_or_null("Settings") as BoxContainer
	if _settings_box == null:
		return false

	_coop_button = _build_coop_button()
	settings.add_child(_coop_button)
	_coop_panel = _build_coop_panel()
	settings.add_child(_coop_panel)
	_coop_panel.visible = false
	_sync_from_voice()
	return true


func _find_settings_node() -> Control:
	if is_instance_valid(_settings_node):
		return _settings_node
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var node: Node = scene.get_node_or_null("Core/UI/Settings")
	if node == null:
		node = scene.find_child("Settings", true, false)
	if node is Control:
		_settings_node = node
	return _settings_node


func _build_coop_button() -> Button:
	var b := Button.new()
	b.name = "CoopSettingsButton"
	b.text = "코옵 설정"
	b.add_theme_font_size_override("font_size", FONT_SIZE + 2)
	b.anchor_left = 0.5
	b.anchor_right = 0.5
	b.anchor_top = 0.0
	b.anchor_bottom = 0.0
	b.offset_left = -90.0
	b.offset_right = 90.0
	b.offset_top = 100.0
	b.offset_bottom = 130.0
	b.pressed.connect(_toggle_coop_panel)
	return b


func _toggle_coop_panel() -> void:
	_coop_open = not _coop_open
	_apply_panel_state()


func _apply_panel_state() -> void:
	if is_instance_valid(_settings_box):
		_settings_box.visible = not _coop_open
	if is_instance_valid(_coop_panel):
		_coop_panel.visible = _coop_open
	if is_instance_valid(_coop_button):
		_coop_button.text = "코옵 설정 닫기" if _coop_open else "코옵 설정"


func _apply_visibility(coop_on: bool) -> void:
	if is_instance_valid(_coop_button):
		_coop_button.visible = coop_on
	if not coop_on:
		if _coop_open:
			_coop_open = false
		if is_instance_valid(_coop_panel):
			_coop_panel.visible = false
		if is_instance_valid(_settings_box):
			_settings_box.visible = true
	else:
		_apply_panel_state()


func _build_coop_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "CoopPanel"
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -320.0
	panel.offset_top = -260.0
	panel.offset_right = 320.0
	panel.offset_bottom = 320.0

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	_coop_category = _build_coop_category()
	vbox.add_child(_coop_category)
	vbox.add_child(HSeparator.new())
	_voice_category = _build_voice_category()
	vbox.add_child(_voice_category)

	return panel


func _build_coop_category() -> VBoxContainer:
	var cat := VBoxContainer.new()
	cat.name = "Coop"
	cat.add_theme_constant_override("separation", 3)
	cat.add_child(_title_label("코옵 설정"))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 2)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cat.add_child(grid)

	grid.add_child(_kv_label("상태"))
	_status_label = RichTextLabel.new()
	_status_label.bbcode_enabled = true
	_status_label.fit_content = true
	_status_label.scroll_active = false
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.add_theme_font_size_override("normal_font_size", FONT_SIZE)
	_status_label.text = "[color=gray]...[/color]"
	grid.add_child(_status_label)

	grid.add_child(_kv_label(""))
	_invite_button = Button.new()
	_invite_button.text = "친구 초대"
	_invite_button.add_theme_font_size_override("font_size", FONT_SIZE)
	_invite_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_invite_button.pressed.connect(_on_invite_pressed)
	grid.add_child(_invite_button)
	return cat


func _build_voice_category() -> VBoxContainer:
	var cat := VBoxContainer.new()
	cat.name = "VoiceChat"
	cat.add_theme_constant_override("separation", 3)
	cat.add_child(_title_label("보이스챗 설정"))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 2)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cat.add_child(grid)

	grid.add_child(_kv_label("푸시투토크"))
	_ptt_bind_button = Button.new()
	_ptt_bind_button.text = "V"
	_ptt_bind_button.add_theme_font_size_override("font_size", FONT_SIZE)
	_ptt_bind_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ptt_bind_button.pressed.connect(_on_ptt_bind_pressed)
	grid.add_child(_ptt_bind_button)

	grid.add_child(_kv_label("오픈 마이크 (VAD)"))
	_open_mic_button = Button.new()
	_open_mic_button.text = "꺼짐"
	_open_mic_button.toggle_mode = true
	_open_mic_button.add_theme_font_size_override("font_size", FONT_SIZE)
	_open_mic_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_open_mic_button.toggled.connect(_on_open_mic_toggled)
	grid.add_child(_open_mic_button)

	_vad_row_label = _kv_label("마이크 감도")
	grid.add_child(_vad_row_label)
	var vad_row := _slider_value_row()
	_vad_row_control = vad_row
	_vad_slider = vad_row.get_child(0) as HSlider
	_vad_slider.min_value = 0.0
	_vad_slider.max_value = 0.25
	_vad_slider.step = 0.005
	_vad_slider.value = 0.03
	_vad_value = vad_row.get_child(1) as Label
	_vad_slider.value_changed.connect(_on_vad_changed)
	grid.add_child(vad_row)

	grid.add_child(_kv_label("마이크 게인"))
	var mic_row := _slider_value_row()
	_mic_gain_slider = mic_row.get_child(0) as HSlider
	_mic_gain_slider.min_value = 0.0
	_mic_gain_slider.max_value = 2.0
	_mic_gain_slider.step = 0.05
	_mic_gain_slider.value = 1.0
	_mic_gain_value = mic_row.get_child(1) as Label
	_mic_gain_slider.value_changed.connect(_on_mic_gain_changed)
	grid.add_child(mic_row)

	grid.add_child(_kv_label("음성 볼륨"))
	var master_row := _slider_value_row()
	_master_slider = master_row.get_child(0) as HSlider
	_master_slider.min_value = 0.0
	_master_slider.max_value = 2.0
	_master_slider.step = 0.05
	_master_slider.value = 1.0
	_master_value = master_row.get_child(1) as Label
	_master_slider.value_changed.connect(_on_master_changed)
	grid.add_child(master_row)

	grid.add_child(_kv_label("청취 범위"))
	var range_row := _slider_value_row()
	_range_slider = range_row.get_child(0) as HSlider
	_range_slider.min_value = 5.0
	_range_slider.max_value = 80.0
	_range_slider.step = 1.0
	_range_slider.value = 30.0
	_range_value = range_row.get_child(1) as Label
	_range_slider.value_changed.connect(_on_range_changed)
	grid.add_child(range_row)

	_proximity_row_label = _kv_label("근접 필터")
	grid.add_child(_proximity_row_label)
	var prox_row := _slider_value_row()
	_proximity_row_control = prox_row
	_proximity_slider = prox_row.get_child(0) as HSlider
	_proximity_slider.min_value = 0.0
	_proximity_slider.max_value = 200.0
	_proximity_slider.step = 5.0
	_proximity_slider.value = 0.0
	_proximity_value = prox_row.get_child(1) as Label
	_proximity_slider.value_changed.connect(_on_proximity_changed)
	grid.add_child(prox_row)

	_peer_toggle_button = Button.new()
	_peer_toggle_button.text = "참가자 ▸"
	_peer_toggle_button.flat = true
	_peer_toggle_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_peer_toggle_button.add_theme_font_size_override("font_size", FONT_SIZE)
	_peer_toggle_button.pressed.connect(_on_peer_toggle)
	cat.add_child(_peer_toggle_button)

	_peer_container = VBoxContainer.new()
	_peer_container.add_theme_constant_override("separation", 2)
	_peer_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_peer_container.visible = false
	cat.add_child(_peer_container)

	return cat


func _on_peer_toggle() -> void:
	_peers_expanded = not _peers_expanded
	if is_instance_valid(_peer_container):
		_peer_container.visible = _peers_expanded
	if is_instance_valid(_peer_toggle_button):
		_peer_toggle_button.text = ("참가자 ▾  " if _peers_expanded else "참가자 ▸  ") + str(_peer_rows.size())


func _title_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _kv_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", FONT_SIZE)
	return l


func _slider_value_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var slider := HSlider.new()
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(SLIDER_MIN_WIDTH, 0)
	row.add_child(slider)
	var value := Label.new()
	value.add_theme_font_size_override("font_size", FONT_SIZE)
	value.add_theme_color_override("font_color", ACCENT)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.custom_minimum_size = Vector2(VALUE_WIDTH, 0)
	row.add_child(value)
	return row


func _hook_voice_signal_once() -> void:
	if _voice_signal_hooked:
		return
	var voice := _voice()
	if voice == null:
		return
	if not voice.settings_loaded.is_connected(_sync_from_voice):
		voice.settings_loaded.connect(_sync_from_voice)
	_voice_signal_hooked = true
	_sync_from_voice()


func _sync_from_voice() -> void:
	var v := _voice()
	if v == null or not is_instance_valid(_master_slider):
		return
	_master_slider.set_value_no_signal(v.master_volume_linear)
	_write_percent(_master_value, v.master_volume_linear)
	_mic_gain_slider.set_value_no_signal(v.mic_gain_linear)
	_write_percent(_mic_gain_value, v.mic_gain_linear)
	_vad_slider.set_value_no_signal(v.vad_threshold)
	_vad_value.text = String.num(v.vad_threshold, 2)
	_range_slider.set_value_no_signal(v.max_hearing_distance)
	_range_value.text = str(int(round(v.max_hearing_distance))) + "m"
	_proximity_slider.set_value_no_signal(v.proximity_filter_range)
	_write_proximity(v.proximity_filter_range)
	_open_mic_button.set_pressed_no_signal(v.open_mic_enabled)
	_open_mic_button.text = "켜짐" if v.open_mic_enabled else "꺼짐"
	_update_vad_visibility()
	_update_bind_label()


func _update_runtime_state() -> void:
	var net := _net()
	var lobby := _lobby()
	var voice := _voice()
	var players := _players()
	if net == null or voice == null or players == null:
		return
	_write_status_line(net, voice)
	_update_bind_label()
	_update_invite_button(net, lobby)
	_update_proximity_visibility(net)
	_refresh_peer_list(players, voice)


func _write_status_line(net: Node, voice: Node) -> void:
	if not net.IsActive():
		_status_label.text = "[color=gray]연결 끊김[/color]"
		return
	var transport: String = "Steam" if net.IsSteamTransport() else "ENet"
	var main: String
	if net.IsHost():
		var total: int = multiplayer.get_peers().size() + 1
		main = "[color=#8fc93a]호스팅 중[/color] (%s) — %d명" % [transport, total]
	else:
		main = "[color=#8fc93a]접속됨[/color] (%s)" % transport
	var voice_tag: String = " · [color=gray]음성 준비됨[/color]" if voice.IsSteamVoiceAvailable() else " · [color=#e05050]음성 없음[/color]"
	_status_label.text = main + voice_tag


func _update_bind_label() -> void:
	if not is_instance_valid(_ptt_bind_button):
		return
	var voice := _voice()
	if voice == null:
		return
	if voice.IsRebinding():
		_ptt_bind_button.text = "키를 누르세요…"
		return
	var suffix: String = "  ●" if voice.IsRecording() else ""
	_ptt_bind_button.text = voice.GetPttKeyName() + suffix


func _update_invite_button(net: Node, lobby: Node) -> void:
	if not is_instance_valid(_invite_button):
		return
	var active: bool = net.IsActive() and net.IsHost() and lobby and lobby.available and lobby.InLobby()
	_invite_button.disabled = not active


func _update_proximity_visibility(net: Node) -> void:
	var is_host: bool = net.IsHost() and net.IsActive()
	if is_instance_valid(_proximity_row_label):
		_proximity_row_label.visible = is_host
	if is_instance_valid(_proximity_row_control):
		_proximity_row_control.visible = is_host


func _update_vad_visibility() -> void:
	var voice := _voice()
	var on: bool = voice != null and voice.open_mic_enabled
	if is_instance_valid(_vad_row_label):
		_vad_row_label.visible = on
	if is_instance_valid(_vad_row_control):
		_vad_row_control.visible = on


func _refresh_peer_list(players: Node, voice: Node) -> void:
	if not is_instance_valid(_peer_container):
		return
	var my_id: int = multiplayer.get_unique_id()
	var ids: Array = players.peer_names.keys()
	ids.sort()
	var seen: Dictionary = {}
	for id in ids:
		if id == my_id:
			continue
		seen[id] = true
		var row: Dictionary = _peer_rows.get(id, {})
		if row.is_empty() or not is_instance_valid(row.get("root", null)):
			row = _build_peer_row(id, voice)
			_peer_rows[id] = row
		var peer_name: String = str(players.peer_names[id])
		var speaking: bool = voice.IsPeerSpeaking(id)
		(row.indicator as Label).text = "●" if speaking else "○"
		(row.indicator as Label).add_theme_color_override("font_color", ACCENT if speaking else MUTE)
		(row.name_label as Label).text = peer_name
		var current_vol: float = voice.GetPeerVolume(id)
		var s: HSlider = row.slider
		if abs(s.value - current_vol) > 0.001:
			s.set_value_no_signal(current_vol)
		(row.value_label as Label).text = str(int(round(current_vol * 100))) + "%"
	for cached_id in _peer_rows.keys().duplicate():
		if not seen.has(cached_id):
			var r = _peer_rows[cached_id]
			if is_instance_valid(r.get("root", null)):
				r.root.queue_free()
			_peer_rows.erase(cached_id)
	if is_instance_valid(_peer_toggle_button):
		_peer_toggle_button.visible = not _peer_rows.is_empty()
		var arrow: String = "▾" if _peers_expanded else "▸"
		_peer_toggle_button.text = "참가자 %s  %d" % [arrow, _peer_rows.size()]


func _build_peer_row(peer_id: int, voice: Node) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var indicator := Label.new()
	indicator.text = "○"
	indicator.add_theme_font_size_override("font_size", FONT_SIZE)
	indicator.custom_minimum_size = Vector2(12, 0)
	row.add_child(indicator)
	var name_label := Label.new()
	name_label.add_theme_font_size_override("font_size", FONT_SIZE)
	name_label.custom_minimum_size = Vector2(80, 0)
	row.add_child(name_label)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 2.0
	slider.step = 0.05
	slider.value = voice.GetPeerVolume(peer_id)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(70, 0)
	slider.value_changed.connect(func(v): _on_peer_volume_changed(peer_id, v))
	row.add_child(slider)
	var value_label := Label.new()
	value_label.add_theme_font_size_override("font_size", FONT_SIZE)
	value_label.add_theme_color_override("font_color", ACCENT)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.custom_minimum_size = Vector2(VALUE_WIDTH, 0)
	row.add_child(value_label)
	_peer_container.add_child(row)
	return {"root": row, "indicator": indicator, "name_label": name_label, "slider": slider, "value_label": value_label}


func _on_invite_pressed() -> void:
	var lobby := _lobby()
	if lobby:
		lobby.OpenInviteOverlay()


func _on_ptt_bind_pressed() -> void:
	var v := _voice()
	if v:
		v.BeginRebindPtt()


func _on_open_mic_toggled(pressed: bool) -> void:
	var v := _voice()
	if v:
		v.SetOpenMic(pressed)
	_open_mic_button.text = "켜짐" if pressed else "꺼짐"
	_update_vad_visibility()


func _on_vad_changed(val: float) -> void:
	_vad_value.text = String.num(val, 2)
	var v := _voice()
	if v:
		v.SetVadThreshold(val)


func _on_mic_gain_changed(val: float) -> void:
	_write_percent(_mic_gain_value, val)
	var v := _voice()
	if v:
		v.SetMicGain(val)


func _on_master_changed(val: float) -> void:
	_write_percent(_master_value, val)
	var v := _voice()
	if v:
		v.SetMasterVolume(val)


func _on_range_changed(val: float) -> void:
	_range_value.text = str(int(round(val))) + "m"
	var v := _voice()
	if v:
		v.SetMaxHearingDistance(val)


func _on_proximity_changed(val: float) -> void:
	_write_proximity(val)
	var v := _voice()
	if v:
		v.SetProximityFilterRange(val)


func _on_peer_volume_changed(peer_id: int, val: float) -> void:
	var v := _voice()
	if v:
		v.SetPeerVolume(peer_id, val)


func _write_percent(label: Label, val: float) -> void:
	if is_instance_valid(label):
		label.text = str(int(round(val * 100))) + "%"


func _write_proximity(val: float) -> void:
	if is_instance_valid(_proximity_value):
		_proximity_value.text = "꺼짐" if val <= 0.0 else str(int(round(val))) + "m"
