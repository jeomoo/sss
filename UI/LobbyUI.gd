extends CanvasLayer



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")
const RTVCoop = preload("res://mods/RTVCoop/Game/Coop.gd")

const ACCENT := Color(0.56, 0.79, 0.23, 1.0)
const STATUS_UPDATE_INTERVAL := 0.2


var fontMedium: FontFile = load("res://Fonts/Lora-Medium.ttf")
var fontSemiBold: FontFile = load("res://Fonts/Lora-SemiBold.ttf")


var coopButton: Button = null
var coopPanel: Control = null
var menuMain: Control = null

var steamLabel: RichTextLabel
var statusLabel: RichTextLabel
var playersLabel: RichTextLabel
var hostBtn: Button
var inviteBtn: Button
var dcBtn: Button
var continueBtn: Button
var newGameBtn: Button
var waitingLabel: RichTextLabel

var settingsToggleBtn: Button
var settingsContainer: VBoxContainer
var lootSlider: HSlider
var statsSlider: HSlider
var aiSlider: HSlider
var dayRateSlider: HSlider
var nightRateSlider: HSlider
var lootValueLabel: Label
var statsValueLabel: Label
var aiValueLabel: Label
var dayRateValueLabel: Label
var nightRateValueLabel: Label

# fix6: ENet direct connect UI. Metro Mod Loader has no mechanism to register
# GDExtension at boot, so GodotSteam never loads → Steam P2P path is structurally
# unreliable. ENet over a virtual LAN (Tailscale, Hamachi, ZeroTier) or real LAN
# works without Steam.
var directHostBtn: Button
var directJoinBtn: Button
var ipInput: LineEdit
var localIpLabel: RichTextLabel
# fix6.6: hide local IPs behind a click toggle. The IP label was visible in screenshots
# / streams, which the user reasonably wanted private. Default hidden, click to reveal.
var ipRevealBtn: Button
var _ip_visible: bool = false

var injected: bool = false
var steam_signals_hooked: bool = false
var _status_accum: float = 0.0

# fix5-kr-v2: cache last-rendered label text. The status loop reassigns
# playersLabel / statusLabel / steamLabel every 200ms even when the content is
# identical, which triggers a RichTextLabel BBCode reparse on each tick and shows
# up as a visible flicker on the player roster. Only write when the value changes.
var _last_status_text: String = ""
var _last_players_text: String = ""
var _last_steam_text: String = ""

# fix6.3.1: cache Loader.ValidateShelter() result. Vanilla Loader prints
# "Shelter missing -> Load disabled" every call AND does disk I/O; LobbyUI was hitting it
# at 5Hz, flooding the log and blocking the main thread. Re-check only every ~5s.
var _shelter_check_accum: float = 999.0
var _shelter_has_save: bool = false
const SHELTER_RECHECK_INTERVAL := 5.0


func _net() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.net if coop else null


func _lobby() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.lobby if coop else null


func _players() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.players if coop else null


func _settings() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.settings if coop else null


func _ready() -> void:
	layer = 50


func _process(delta: float) -> void:
	_hook_steam_signals_once()

	var scene := get_tree().current_scene
	if scene == null:
		return

	if scene.name != "Map":
		if not injected:
			_try_inject(scene)
		if coopPanel and coopPanel.visible:
			_status_accum += delta
			if _status_accum >= STATUS_UPDATE_INTERVAL:
				_status_accum = 0.0
				_update_status()
	else:
		if coopPanel:
			coopPanel.hide()
		injected = false
		coopButton = null
		coopPanel = null
		menuMain = null
		_status_accum = 0.0


func _hook_steam_signals_once() -> void:
	if steam_signals_hooked:
		return
	var lobby := _lobby()
	if lobby == null:
		return
	lobby.lobby_created_ok.connect(_on_lobby_created_ok)
	lobby.lobby_create_failed.connect(_on_lobby_create_failed)
	lobby.lobby_joined_ok.connect(_on_lobby_joined_ok)
	lobby.lobby_join_failed.connect(_on_lobby_join_failed)
	steam_signals_hooked = true
	print("[LobbyUI] Steam lobby signals hooked")


func _try_inject(scene: Node) -> void:
	var buttons: Node = scene.get_node_or_null("Main/Buttons")
	if buttons == null:
		return
	menuMain = scene.get_node_or_null("Main")

	for child in buttons.get_children():
		if child.name == "CoopBtn":
			injected = true
			return

	if buttons.get_child_count() == 0:
		return

	var template_btn: Button = buttons.get_child(0)
	coopButton = template_btn.duplicate()
	coopButton.name = "CoopBtn"
	coopButton.text = "코옵"

	for sig in coopButton.get_signal_list():
		for conn in coopButton.get_signal_connection_list(sig.name):
			if coopButton.is_connected(sig.name, conn.callable):
				coopButton.disconnect(sig.name, conn.callable)

	coopButton.pressed.connect(_on_coop_pressed)
	buttons.add_child(coopButton)
	buttons.move_child(coopButton, 2)

	_create_panel(scene)
	injected = true
	print("[LobbyUI] Co-op button injected")


func _create_panel(scene: Node) -> void:
	coopPanel = Control.new()
	coopPanel.name = "CoopPanel"
	coopPanel.set_anchors_preset(Control.PRESET_FULL_RECT)
	coopPanel.hide()
	scene.add_child(coopPanel)

	var buttons: Node = scene.get_node_or_null("Main/Buttons")
	var template_btn: Button = buttons.get_child(0) if buttons and buttons.get_child_count() > 0 else null

	var button_column := VBoxContainer.new()
	button_column.anchor_left = 0.5
	button_column.anchor_right = 0.5
	button_column.anchor_top = 0.5
	button_column.anchor_bottom = 0.5
	button_column.offset_left = -160
	button_column.offset_right = 160
	button_column.offset_top = -150
	button_column.offset_bottom = 150
	button_column.grow_horizontal = Control.GROW_DIRECTION_BOTH
	button_column.grow_vertical = Control.GROW_DIRECTION_BOTH
	button_column.add_theme_constant_override("separation", 6)
	coopPanel.add_child(button_column)

	hostBtn = _clone_menu_btn(template_btn, "방 만들기")
	hostBtn.pressed.connect(_on_host)
	button_column.add_child(hostBtn)

	inviteBtn = _clone_menu_btn(template_btn, "친구 초대")
	inviteBtn.pressed.connect(_on_invite)
	button_column.add_child(inviteBtn)

	dcBtn = _clone_menu_btn(template_btn, "연결 끊기")
	dcBtn.pressed.connect(_on_dc)
	button_column.add_child(dcBtn)

	button_column.add_child(_divider())

	# fix6: direct ENet hosting / joining. Uses HostGameEnet / JoinGame on CoopNet.
	# For Tailscale: install Tailscale on both PCs, share host's 100.x.x.x IP.
	# For LAN: share host's 192.168.x.x IP. Last entered IP persists across sessions.
	directHostBtn = _clone_menu_btn(template_btn, "직접 호스트 (ENet)")
	directHostBtn.pressed.connect(_on_direct_host)
	button_column.add_child(directHostBtn)

	ipInput = LineEdit.new()
	ipInput.placeholder_text = "접속할 IP (예: 100.x.x.x)"
	ipInput.text = _load_last_ip()
	ipInput.add_theme_font_size_override("font_size", 13)
	ipInput.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button_column.add_child(ipInput)

	directJoinBtn = _clone_menu_btn(template_btn, "IP로 접속")
	directJoinBtn.pressed.connect(_on_direct_join)
	button_column.add_child(directJoinBtn)

	# fix6.6: small toggle button to show/hide local IPs. Hidden by default so the IP
	# isn't visible in screenshots / streams. Click once to reveal, click again to hide.
	ipRevealBtn = Button.new()
	ipRevealBtn.flat = true
	ipRevealBtn.text = "내 IP 표시 ▸"
	ipRevealBtn.add_theme_font_size_override("font_size", 11)
	ipRevealBtn.alignment = HORIZONTAL_ALIGNMENT_CENTER
	ipRevealBtn.pressed.connect(_toggle_ip_visibility)
	button_column.add_child(ipRevealBtn)

	localIpLabel = _make_label(11, "[color=gray]내 IP: 감지 중...[/color]")
	localIpLabel.visible = false  # fix6.6: hidden by default
	button_column.add_child(localIpLabel)

	button_column.add_child(_divider())

	continueBtn = _clone_menu_btn(template_btn, "이어하기")
	continueBtn.pressed.connect(_on_continue)
	button_column.add_child(continueBtn)

	newGameBtn = _clone_menu_btn(template_btn, "새 게임")
	newGameBtn.pressed.connect(_on_new_game)
	button_column.add_child(newGameBtn)

	waitingLabel = _make_label(13, "[center][color=#e0c850]호스트가 시작하기를 대기 중...[/color][/center]")
	waitingLabel.visible = false
	button_column.add_child(waitingLabel)

	button_column.add_child(_divider())

	var return_btn := _clone_menu_btn(template_btn, "뒤로")
	return_btn.pressed.connect(_on_return)
	button_column.add_child(return_btn)

	var game_theme := load("res://UI/Themes/Theme.tres")
	var info_panel := Panel.new()
	info_panel.anchor_left = 0.5
	info_panel.anchor_right = 0.5
	info_panel.anchor_top = 0.5
	info_panel.anchor_bottom = 0.5
	info_panel.offset_left = 190
	info_panel.offset_right = 510
	info_panel.offset_top = -200
	info_panel.offset_bottom = 200
	info_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	info_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	if game_theme:
		info_panel.theme = game_theme
	coopPanel.add_child(info_panel)

	var info_margin := MarginContainer.new()
	info_margin.anchor_right = 1.0
	info_margin.anchor_bottom = 1.0
	info_margin.add_theme_constant_override("margin_left", 16)
	info_margin.add_theme_constant_override("margin_top", 16)
	info_margin.add_theme_constant_override("margin_right", 16)
	info_margin.add_theme_constant_override("margin_bottom", 16)
	info_panel.add_child(info_margin)

	var info_outer := VBoxContainer.new()
	info_outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_outer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	info_margin.add_child(info_outer)

	var info_scroll := ScrollContainer.new()
	info_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	info_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	info_outer.add_child(info_scroll)

	var info_column := VBoxContainer.new()
	info_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_column.add_theme_constant_override("separation", 6)
	info_scroll.add_child(info_column)

	steamLabel = _make_label(13, "[color=gray]Steam: checking...[/color]")
	steamLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_column.add_child(steamLabel)

	statusLabel = _make_label(14, "연결 끊김")
	statusLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_column.add_child(statusLabel)

	info_column.add_child(_divider())

	var players_header := _make_label(11, "[color=gray]플레이어[/color]")
	players_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_column.add_child(players_header)

	playersLabel = _make_label(13, "[color=gray]연결되지 않음[/color]")
	playersLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_column.add_child(playersLabel)

	info_column.add_child(_divider())

	settingsToggleBtn = Button.new()
	settingsToggleBtn.text = "설정  ▸"
	settingsToggleBtn.add_theme_font_override("font", fontMedium)
	settingsToggleBtn.add_theme_font_size_override("font_size", 12)
	settingsToggleBtn.flat = true
	settingsToggleBtn.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	settingsToggleBtn.add_theme_color_override("font_hover_color", ACCENT)
	settingsToggleBtn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	settingsToggleBtn.pressed.connect(_toggle_settings)
	info_column.add_child(settingsToggleBtn)

	settingsContainer = VBoxContainer.new()
	settingsContainer.add_theme_constant_override("separation", 2)
	settingsContainer.visible = false
	info_column.add_child(settingsContainer)

	var loot_row := _create_setting_row("전리품", 0.0, 5.0, 0.25, 1.0)
	lootSlider = loot_row[0]
	lootValueLabel = loot_row[1]
	lootSlider.value_changed.connect(func(v): _on_setting_changed("loot_multiplier", v, lootValueLabel))
	settingsContainer.add_child(loot_row[2])

	var stats_row := _create_setting_row("스탯 감소", 0.0, 3.0, 0.25, 1.0)
	statsSlider = stats_row[0]
	statsValueLabel = stats_row[1]
	statsSlider.value_changed.connect(func(v): _on_setting_changed("stats_drain_multiplier", v, statsValueLabel))
	settingsContainer.add_child(stats_row[2])

	var ai_row := _create_setting_row("AI 수", 0.0, 3.0, 0.25, 1.0)
	aiSlider = ai_row[0]
	aiValueLabel = ai_row[1]
	aiSlider.value_changed.connect(func(v): _on_setting_changed("ai_multiplier", v, aiValueLabel))
	settingsContainer.add_child(ai_row[2])

	var day_row := _create_setting_row("낮 속도", 0.25, 5.0, 0.25, 1.0)
	dayRateSlider = day_row[0]
	dayRateValueLabel = day_row[1]
	dayRateSlider.value_changed.connect(func(v): _on_setting_changed("day_rate_multiplier", v, dayRateValueLabel))
	settingsContainer.add_child(day_row[2])

	var night_row := _create_setting_row("밤 속도", 0.25, 5.0, 0.25, 1.0)
	nightRateSlider = night_row[0]
	nightRateValueLabel = night_row[1]
	nightRateSlider.value_changed.connect(func(v): _on_setting_changed("night_rate_multiplier", v, nightRateValueLabel))
	settingsContainer.add_child(night_row[2])


func _make_label(size: int, text: String) -> RichTextLabel:
	var lbl := RichTextLabel.new()
	lbl.bbcode_enabled = true
	lbl.fit_content = true
	lbl.scroll_active = false
	lbl.add_theme_font_override("normal_font", fontMedium)
	lbl.add_theme_font_size_override("normal_font_size", size)
	lbl.text = text
	return lbl


func _create_setting_row(label_text: String, min_val: float, max_val: float, step: float, default: float) -> Array:
	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 0)
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var header := HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(header)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_override("font", fontMedium)
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(lbl)

	var val_lbl := Label.new()
	val_lbl.text = str(default) + "x"
	val_lbl.add_theme_font_override("font", fontMedium)
	val_lbl.add_theme_font_size_override("font_size", 12)
	val_lbl.add_theme_color_override("font_color", ACCENT)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.add_child(val_lbl)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = step
	slider.value = default
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(200, 20)
	container.add_child(slider)

	return [slider, val_lbl, container]


func _on_setting_changed(key: String, value: float, label: Label) -> void:
	label.text = str(value) + "x"
	var settings := _settings()
	if settings and CoopAuthority.is_host():
		settings.Set(key, value)


func _divider() -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, 6)
	return s


func _clone_menu_btn(template_btn, text: String) -> Button:
	if template_btn:
		var btn: Button = template_btn.duplicate()
		btn.text = text
		for sig in btn.get_signal_list():
			for conn in btn.get_signal_connection_list(sig.name):
				if btn.is_connected(sig.name, conn.callable):
					btn.disconnect(sig.name, conn.callable)
		return btn
	return _make_btn(text)


func _make_btn(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.add_theme_font_override("font", fontMedium)
	btn.add_theme_font_size_override("font_size", 14)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.12, 0.9)
	style.border_color = Color(0.25, 0.25, 0.25, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	btn.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate()
	hover.border_color = ACCENT
	hover.bg_color = Color(0.16, 0.16, 0.16, 0.9)
	btn.add_theme_stylebox_override("hover", hover)
	var pressed := style.duplicate()
	pressed.bg_color = Color(0.08, 0.08, 0.08, 0.9)
	btn.add_theme_stylebox_override("pressed", pressed)
	var disabled := style.duplicate()
	disabled.bg_color = Color(0.08, 0.08, 0.08, 0.5)
	disabled.border_color = Color(0.15, 0.15, 0.15, 0.5)
	btn.add_theme_stylebox_override("disabled", disabled)
	btn.add_theme_color_override("font_disabled_color", Color(0.3, 0.3, 0.3))
	return btn


func _update_status() -> void:
	var net := _net()
	var lobby := _lobby()

	var steam_text: String
	if lobby and lobby.available:
		steam_text = "[color=#8fc93a]스팀:[/color] " + lobby.MyName()
	elif lobby:
		steam_text = "[color=gray]스팀: 사용 불가[/color]"
	else:
		steam_text = "[color=gray]스팀: 미로드[/color]"
	if steam_text != _last_steam_text:
		steamLabel.text = steam_text
		_last_steam_text = steam_text

	var steam_ok: bool = lobby != null and lobby.available
	var is_host: bool = net != null and net.IsActive() and net.IsHost()
	var is_client: bool = net != null and net.IsActive() and not net.IsHost()
	var is_connected: bool = is_host or is_client

	var status_text: String
	if net == null:
		status_text = "[color=gray]네트워크 미로드[/color]"
	elif not net.IsActive():
		status_text = "[color=gray]연결 끊김[/color]"
	elif is_host:
		var peers: int = multiplayer.get_peers().size()
		var transport_tag: String = "Steam" if net.IsSteamTransport() else "ENet"
		status_text = "[color=#8fc93a]호스팅 중[/color] (%s) — %d명" % [transport_tag, peers + 1]
	else:
		var transport_tag2: String = "Steam" if net.IsSteamTransport() else "ENet"
		status_text = "[color=#8fc93a]접속됨[/color] (%s)" % transport_tag2
	if status_text != _last_status_text:
		statusLabel.text = status_text
		_last_status_text = status_text

	hostBtn.disabled = is_connected
	inviteBtn.disabled = not (is_host and steam_ok and lobby.InLobby())
	dcBtn.disabled = not is_connected

	# fix6: keep direct-connect controls in sync with active state.
	if directHostBtn != null:
		directHostBtn.disabled = is_connected
	if directJoinBtn != null:
		directJoinBtn.disabled = is_connected or (ipInput != null and ipInput.text.strip_edges() == "")
	if ipInput != null:
		ipInput.editable = not is_connected
	_refresh_local_ip_label()

	_update_player_list(is_connected)
	_update_start_buttons(is_host, is_client)


func _update_player_list(is_connected: bool) -> void:
	var players_text: String
	if not is_connected:
		players_text = "[color=gray]연결되지 않음[/color]"
	else:
		var players := _players()
		var names: Array = []
		var my_id: int = multiplayer.get_unique_id()
		if players and players.peer_names:
			var ids: Array = players.peer_names.keys()
			ids.sort()
			for id in ids:
				var name_str: String = str(players.peer_names[id])
				var tag: String = " [color=gray](나)[/color]" if id == my_id else ""
				var role: String = " [color=#8fc93a][호스트][/color]" if id == 1 else ""
				names.append(name_str + role + tag)
		if names.is_empty():
			players_text = "[color=gray]다른 플레이어 대기 중...[/color]"
		else:
			players_text = "\n".join(names)
	if players_text != _last_players_text:
		playersLabel.text = players_text
		_last_players_text = players_text


func _update_start_buttons(is_host: bool, is_client: bool) -> void:
	continueBtn.visible = is_host
	newGameBtn.visible = is_host
	waitingLabel.visible = is_client
	settingsToggleBtn.visible = is_host
	if not is_host:
		settingsContainer.visible = false

	if is_host:
		# fix6.3.1: cached shelter check. Vanilla Loader.ValidateShelter() prints
		# "Shelter missing -> Load disabled" and hits disk on every call; was being polled
		# at 5Hz, flooding the log + main-thread blocking → ~10 FPS in the lobby panel
		# once hosting. Re-check every 5s instead, plenty fast for save-state UX.
		_shelter_check_accum += get_process_delta_time()
		if _shelter_check_accum >= SHELTER_RECHECK_INTERVAL:
			_shelter_check_accum = 0.0
			_shelter_has_save = Loader.ValidateShelter() != ""
			# v0.13.47: MSS 통합 시 세이브는 user:// 아니라 MSS 슬롯에 보관됨. 슬롯 점유도 확인.
			# (이어하기 클릭 → _try_open_slot_panel("load") → 슬롯 선택 → sync_in → LoadScene)
			if not _shelter_has_save:
				var mss: Node = get_tree().root.get_node_or_null("MultiSaveSlotsMain")
				if mss and mss.has_method("any_slot_occupied") and mss.any_slot_occupied():
					_shelter_has_save = true
		continueBtn.disabled = not _shelter_has_save


func _toggle_settings() -> void:
	settingsContainer.visible = not settingsContainer.visible
	settingsToggleBtn.text = "설정  ▾" if settingsContainer.visible else "설정  ▸"


func _on_coop_pressed() -> void:
	if coopPanel and menuMain:
		coopPanel.show()
		menuMain.hide()
		_status_accum = STATUS_UPDATE_INTERVAL
		_update_status()


func _on_return() -> void:
	if coopPanel and menuMain:
		coopPanel.hide()
		menuMain.show()


func _on_host() -> void:
	var net := _net()
	if net == null or not net.HostGame():
		return
	var lobby := _lobby()
	if lobby and lobby.available:
		lobby.CreateLobby()


# fix6: direct ENet hosting / joining.
func _on_direct_host() -> void:
	var net := _net()
	if net == null:
		return
	if not net.HostGameEnet():
		return
	_refresh_local_ip_label()


func _on_direct_join() -> void:
	var net := _net()
	if net == null or ipInput == null:
		return
	var ip: String = ipInput.text.strip_edges()
	if ip == "":
		return
	_save_last_ip(ip)
	net.JoinGame(ip)


# fix6.6: toggle IP label visibility.
func _toggle_ip_visibility() -> void:
	_ip_visible = not _ip_visible
	if localIpLabel != null:
		localIpLabel.visible = _ip_visible
	if ipRevealBtn != null:
		ipRevealBtn.text = "내 IP 숨기기 ▾" if _ip_visible else "내 IP 표시 ▸"


func _refresh_local_ip_label() -> void:
	if localIpLabel == null:
		return
	var ips: Array = []
	var tailscale_ips: Array = []
	var lan_ips: Array = []
	for ip in IP.get_local_addresses():
		if ":" in ip:
			continue  # skip IPv6
		if ip == "127.0.0.1":
			continue
		if ip.begins_with("100."):
			tailscale_ips.append(ip)  # Tailscale CGNAT range
		elif ip.begins_with("192.168.") or ip.begins_with("10.") or _is_172_private(ip):
			lan_ips.append(ip)
		else:
			ips.append(ip)
	var parts: PackedStringArray = PackedStringArray()
	if not tailscale_ips.is_empty():
		parts.append("[color=#8fc93a]Tailscale:[/color] " + ", ".join(tailscale_ips))
	if not lan_ips.is_empty():
		parts.append("[color=#8fc93a]LAN:[/color] " + ", ".join(lan_ips))
	if not ips.is_empty():
		parts.append("[color=gray]기타:[/color] " + ", ".join(ips))
	if parts.is_empty():
		localIpLabel.text = "[color=gray]내 IP: (감지 실패)[/color]"
	else:
		localIpLabel.text = "\n".join(parts)


func _is_172_private(ip: String) -> bool:
	if not ip.begins_with("172."):
		return false
	var parts: PackedStringArray = ip.split(".")
	if parts.size() < 2:
		return false
	var second: int = int(parts[1])
	return second >= 16 and second <= 31


func _ip_save_path() -> String:
	return "user://coop_last_ip.txt"


func _load_last_ip() -> String:
	var path: String = _ip_save_path()
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var s: String = f.get_as_text().strip_edges()
	f.close()
	return s


func _save_last_ip(ip: String) -> void:
	var f := FileAccess.open(_ip_save_path(), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(ip)
	f.close()


func _on_invite() -> void:
	var lobby := _lobby()
	if lobby:
		lobby.OpenInviteOverlay()


func _on_dc() -> void:
	var net := _net()
	if net:
		net.Disconnect()
	var lobby := _lobby()
	if lobby:
		lobby.LeaveLobby()


func _on_continue() -> void:
	var net := _net()
	if net == null or not net.IsActive() or not net.IsHost():
		return
	# v0.13.25: MultiSaveSlots 있으면 slot 선택 panel 띄움. 없으면 기존 vanilla active slot 그대로.
	if _try_open_slot_panel("load", func(_n, _is_new): _do_continue_load()):
		return
	_do_continue_load()


func _do_continue_load() -> void:
	var target: String = Loader.ValidateShelter()
	# v0.13.49: vanilla ValidateShelter는 lastVisit > 0 비교라 lastVisit==0 세이브를 놓침
	# (슬롯3 Cabin.tres lastVisit=0 케이스). fallback으로 lastVisit >= 0 포함해서 직접 탐색.
	if target == "":
		target = _find_latest_shelter()
		print("[LobbyUI] ValidateShelter empty → fallback shelter='%s'" % target)
	if target == "":
		return
	if coopPanel:
		coopPanel.hide()
	Loader.LoadScene(target)


func _find_latest_shelter() -> String:
	var d := DirAccess.open("user://")
	if d == null:
		return ""
	d.list_dir_begin()
	var fn := d.get_next()
	var best := ""
	var best_visit := -1
	while fn != "":
		if fn.ends_with(".tres"):
			var res = load("user://" + fn)
			# ShelterSave만 lastVisit 필드 보유 (Cabin/Tent 등 은신처). duck typing으로 안전 체크.
			if res != null and ("lastVisit" in res):
				var lv: int = int(res.lastVisit)
				if lv > best_visit:
					best_visit = lv
					best = fn.replace(".tres", "")
		fn = d.get_next()
	d.list_dir_end()
	return best


func _on_new_game() -> void:
	var net := _net()
	if net == null or not net.IsActive() or not net.IsHost():
		return
	# v0.13.25: MultiSaveSlots 있으면 slot 선택 panel → 선택 후 vanilla difficulty(Modes) 표시
	if _try_open_slot_panel("new", func(_n, _is_new): _do_new_game_show_modes()):
		return
	_do_new_game_show_modes()


func _do_new_game_show_modes() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var modes: Node = scene.get_node_or_null("Modes")
	if coopPanel:
		coopPanel.hide()
	if modes:
		modes.show()


# v0.13.25: MultiSaveSlots SlotPanel 진입. autoload 없으면 false 리턴 → 호출자 fallback.
func _try_open_slot_panel(mode: String, on_complete: Callable) -> bool:
	var mss_main: Node = get_tree().root.get_node_or_null("MultiSaveSlotsMain")
	if mss_main == null:
		return false
	# v0.13.68: 벤더본 SlotPanel 우선(흡수 — 항상 존재). 없으면 standalone MSS 것 fallback.
	var SlotPanelScript = load("res://mods/RTVCoop/Vendor/MultiSaveSlots/SlotPanel.gd")
	if SlotPanelScript == null:
		SlotPanelScript = load("res://mods/MultiSaveSlots/SlotPanel.gd")
	if SlotPanelScript == null:
		push_warning("[LobbyUI] SlotPanel.gd load failed (벤더본+standalone 둘 다 없음)")
		return false
	var CoopSlotControllerScript = load("res://mods/RTVCoop/UI/CoopSlotController.gd")
	if CoopSlotControllerScript == null:
		return false
	var controller = CoopSlotControllerScript.new(mss_main, on_complete)
	var panel = SlotPanelScript.new()
	panel.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child(panel)
	panel.open(mode, controller)
	print("[LobbyUI] slot panel opened (mode=%s)" % mode)
	return true


func _on_lobby_created_ok(id: int) -> void:
	print("[LobbyUI] Steam lobby created: %d" % id)


func _on_lobby_create_failed(reason: String) -> void:
	print("[LobbyUI] Steam lobby create failed: %s" % reason)


func _on_lobby_joined_ok(_id: int, host_id: int) -> void:
	print("[LobbyUI] Steam lobby joined; host=%d — connecting peer" % host_id)
	var net := _net()
	if net:
		net.JoinSteam(host_id)


func _on_lobby_join_failed(reason: String) -> void:
	print("[LobbyUI] Steam lobby join failed: %s" % reason)
