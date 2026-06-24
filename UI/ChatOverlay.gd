extends CanvasLayer


# v0.11: VostokRelayChat 스타일 채팅 오버레이 — 우리 모드 자체 구현 (외부 mod 의존 없음).
# 좌하단 RichTextLabel + 최근 8개 메시지 + 8초 fade.
# 호스트/클라 모두 자기 측 signal로 chat 표시 (broadcast 불필요 — 각자 동일 signal 받음).


const RTVCoop = preload("res://mods/RTVCoop/Game/Coop.gd")

# v0.11.4: passive 모드 = 메시지 5초 표시 후 1.5초 fade → 투명. active 모드 (엔터 토글) = 항상 표시 + scroll.
const MAX_MESSAGES_PASSIVE := 8
const MAX_MESSAGES_ACTIVE := 30
const FADE_DELAY := 5.0
const FADE_DURATION := 1.5

const COLOR_JOIN := "#7fff7f"
const COLOR_LEAVE := "#ffd060"
const COLOR_DEATH := "#ff5050"
const COLOR_TASK := "#7fd0ff"
const COLOR_SYSTEM := "white"


var panel: PanelContainer
var label: RichTextLabel
var input_box: LineEdit
var messages: Array = []
var active_mode: bool = false
var input_mode: bool = false
var last_message_time: float = -999.0
var gameData: Resource = preload("res://Resources/GameData.tres")

# Command Pattern & Text Glitch Effect variables
const ChatCommands = preload("res://mods/RTVCoop/Game/Commands/ChatCommands.gd")
var _registry: ChatCommands.CommandRegistry
const GLITCH_DECODE_SPEED := 4.0


func _ready() -> void:
	layer = 99
	Engine.set_meta("ChatOverlay", self)
	_init_commands()

	# v0.11.4: PanelContainer + RichTextLabel. 반투명 배경 + 둥근 모서리.
	panel = PanelContainer.new()
	panel.anchor_left = 0.0
	panel.anchor_right = 0.0
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 20
	panel.offset_right = 540
	panel.offset_top = -340
	panel.offset_bottom = -130
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.55)
	sb.border_color = Color(1, 1, 1, 0.15)
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", sb)

	# v0.13.7: panel 안에 VBoxContainer로 label + input_box 통합 (이전엔 input이 panel 밖)
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# vbox.mouse_filter=STOP이면 panel IGNORE 무효화됨 — 자식까지 IGNORE
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(vbox)

	label = RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.scroll_following = true
	label.add_theme_font_size_override("normal_font_size", 15)
	label.add_theme_color_override("default_color", Color(1, 1, 1, 0.95))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(label)

	add_child(panel)
	panel.modulate.a = 0.0  # 처음엔 투명

	# v0.13.6/v0.13.7: 사용자 채팅 입력 박스 — panel 안 vbox 자식으로 통합
	input_box = LineEdit.new()
	input_box.placeholder_text = "메시지 입력 (엔터=전송 / ESC=취소)"
	input_box.visible = false
	input_box.max_length = 200
	input_box.add_theme_font_size_override("font_size", 14)
	input_box.text_submitted.connect(_on_chat_submitted)
	vbox.add_child(input_box)

	# CoopEvents signal listener
	var tree = get_tree()
	if tree == null:
		return
	await tree.process_frame
	if not is_instance_valid(self) or get_tree() == null:
		return
	var coop := RTVCoop.get_instance()
	if coop and coop.events:
		if coop.events.has_signal("peer_joined"):
			coop.events.peer_joined.connect(_on_peer_joined)
		if coop.events.has_signal("peer_left"):
			coop.events.peer_left.connect(_on_peer_left)
		if coop.events.has_signal("transport_disconnected"):
			coop.events.transport_disconnected.connect(_on_transport_disconnected)
	print("[ChatOverlay] ready — listening to CoopEvents")


# Command Pattern implementation
func _init_commands() -> void:
	_registry = ChatCommands.CommandRegistry.new()
	_registry.register_command(ChatCommands.UnstuckCommand.new())
	_registry.register_command(ChatCommands.HelpCommand.new(_registry))
	_registry.register_command(ChatCommands.CoordsCommand.new())
	_registry.register_command(ChatCommands.PingCommand.new())


func _execute_command(raw_text: String) -> bool:
	return _registry.execute_raw(raw_text, self)


var _name_cache: Dictionary = {}  # v0.13.54 peer_id→이름


func _on_peer_joined(peer_id: int, display_name: String) -> void:
	var name_to_show: String = display_name if display_name != "" else ("Player#" + str(peer_id))
	_name_cache[peer_id] = name_to_show
	if peer_id == multiplayer.get_unique_id():
		add_message("[System] 로비에 입장했습니다 (%s)" % name_to_show, COLOR_SYSTEM)
	else:
		add_message("[System] [b]%s[/b] 님이 접속했습니다" % name_to_show, COLOR_JOIN)


func _on_peer_left(peer_id: int) -> void:
	var disp: String = ""
	var coop := RTVCoop.get_instance()
	if coop and coop.players and "peer_names" in coop.players and coop.players.peer_names.has(peer_id):
		disp = str(coop.players.peer_names[peer_id])
	if disp == "":
		disp = str(_name_cache.get(peer_id, "Player#" + str(peer_id)))
	_name_cache.erase(peer_id)
	add_message("[System] [b]%s[/b] 님이 나갔습니다" % disp, COLOR_LEAVE)


func _on_transport_disconnected() -> void:
	add_message("[System] 연결이 끊어졌습니다", COLOR_LEAVE)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ENTER:
			if input_mode:
				pass
			else:
				_enter_input_mode()
				get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_ESCAPE and input_mode:
			_exit_input_mode()
			get_viewport().set_input_as_handled()


func _enter_input_mode() -> void:
	input_mode = true
	active_mode = true
	panel.modulate.a = 1.0
	label.scroll_active = true
	input_box.visible = true
	input_box.clear()
	input_box.grab_focus()
	if gameData:
		gameData.freeze = true


func _exit_input_mode() -> void:
	input_mode = false
	active_mode = false
	input_box.visible = false
	input_box.release_focus()
	label.scroll_active = false
	if gameData:
		gameData.freeze = false


func _on_chat_submitted(text: String) -> void:
	var trimmed: String = text.strip_edges()
	if trimmed.length() > 0:
		if not _execute_command(trimmed):
			_send_chat(trimmed)
	_exit_input_mode()


func _send_chat(text: String) -> void:
	var coop_ref = RTVCoop.get_instance()
	var my_id: int = multiplayer.get_unique_id()
	var my_name: String = "Player"
	if coop_ref and coop_ref.players and "peer_names" in coop_ref.players:
		my_name = str(coop_ref.players.peer_names.get(my_id, "Player"))
	if multiplayer.is_server():
		BroadcastUserChat.rpc(my_id, my_name, text)
	else:
		SubmitUserChat.rpc_id(1, my_name, text)


@rpc("any_peer", "reliable", "call_remote")
func SubmitUserChat(sender_name: String, text: String) -> void:
	if not multiplayer.is_server():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	BroadcastUserChat.rpc(sender_id, sender_name, text)


@rpc("authority", "reliable", "call_local")
func BroadcastUserChat(sender_id: int, sender_name: String, text: String) -> void:
	var color: String = "#ffffff"
	if sender_id == multiplayer.get_unique_id():
		color = "#a0e0ff"
	var safe_text: String = text.replace("[", "[lb]")
	add_message("[b]%s:[/b] %s" % [sender_name, safe_text], color)


func add_message(text: String, color: String = "white") -> void:
	messages.append({
		"text": text,
		"color": color,
		"time": float(Time.get_ticks_msec()) / 1000.0,
		"glitch_progress": 0.0
	})
	var max_keep: int = MAX_MESSAGES_ACTIVE if active_mode else MAX_MESSAGES_PASSIVE
	while messages.size() > max_keep:
		messages.pop_front()
	last_message_time = float(Time.get_ticks_msec()) / 1000.0
	_refresh()


func _process(delta: float) -> void:
	# 1. Glitch progress update
	if not messages.is_empty():
		var last_msg = messages[-1]
		if last_msg.get("glitch_progress", 1.0) < 1.0:
			last_msg["glitch_progress"] = minf(1.0, last_msg["glitch_progress"] + delta * GLITCH_DECODE_SPEED)
			_refresh()

	# 2. Fade overlay logic
	if active_mode:
		panel.modulate.a = 1.0
		return
	if messages.is_empty():
		panel.modulate.a = 0.0
		return
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	var elapsed: float = now - last_message_time
	if elapsed < FADE_DELAY:
		panel.modulate.a = 1.0
	elif elapsed < FADE_DELAY + FADE_DURATION:
		panel.modulate.a = 1.0 - (elapsed - FADE_DELAY) / FADE_DURATION
	else:
		panel.modulate.a = 0.0


func _scramble_text(text: String, progress: float) -> String:
	if progress >= 1.0:
		return text
	var result: String = ""
	var in_tag: bool = false
	var i: int = 0
	var n: int = text.length()
	var chars := ["%", "$", "#", "@", "?", "*", "&", "!", "x", "z", "0", "7"]
	
	var total_chars: int = 0
	for c in text:
		if c == "[":
			in_tag = true
		elif c == "]":
			in_tag = false
			continue
		if not in_tag:
			total_chars += 1
	
	var reveal_count := int(float(total_chars) * progress)
	var current_char_idx: int = 0
	in_tag = false
	
	while i < n:
		var c: String = text[i]
		if c == "[":
			in_tag = true
		
		if in_tag:
			result += c
			if c == "]":
				in_tag = false
		else:
			if current_char_idx < reveal_count:
				result += c
			else:
				result += chars[randi() % chars.size()]
			current_char_idx += 1
		i += 1
	return result


func _refresh() -> void:
	if messages.is_empty():
		label.text = ""
		return
	var lines: PackedStringArray = PackedStringArray()
	for m in messages:
		var display_text: String = _scramble_text(m.text, m.get("glitch_progress", 1.0))
		lines.append("[color=" + str(m.color) + "]" + display_text + "[/color]")
	label.text = "\n".join(lines)
