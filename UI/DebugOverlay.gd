extends CanvasLayer



const RTVCoop = preload("res://mods/RTVCoop/Game/Coop.gd")

const WHITE := "white"
const GREEN := "#8fc93a"
const RED := "#e05050"
const YELLOW := "#e0c850"
const BLUE := "#50a0e0"


var label: RichTextLabel
var font: FontFile = load("res://Fonts/Lora-Medium.ttf")
var gameData: Resource = preload("res://Resources/GameData.tres")


var _overlay_visible: bool = false


func _ready() -> void:
	layer = 100

	label = RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.add_theme_font_override("normal_font", font)
	label.add_theme_font_size_override("normal_font_size", 14)
	label.add_theme_color_override("default_color", Color(1, 1, 1, 0.85))

	label.anchor_left = 1.0
	label.anchor_right = 1.0
	label.anchor_top = 0.0
	label.anchor_bottom = 0.0
	label.offset_left = -260
	label.offset_right = -10
	label.offset_top = 10
	label.offset_bottom = 300
	label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	label.visible = false
	# v0.13.11: 인벤 우측 메뉴(이벤트/의뢰 노트 등) 클릭 통과 — F5 켜진 상태에서도 아래 UI 조작 가능
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE

	add_child(label)


func _val(color: String, value: String) -> String:
	return "[color=" + color + "]" + value + "[/color]"


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_F5:
			_overlay_visible = not _overlay_visible
			label.visible = _overlay_visible


func _process(_delta: float) -> void:
	if not _overlay_visible:
		return

	var coop := RTVCoop.get_instance()
	var net: Node = coop.net if coop else null
	var players: Node = coop.players if coop else null
	var lines: PackedStringArray = PackedStringArray()

	lines.append("[right]" + _val(YELLOW, "RTV COOP ALPHA") + "[/right]")

	if net == null:
		lines.append("[right]네트워크: " + _val(RED, "미로드") + "[/right]")
	elif not net.IsActive():
		lines.append("[right]네트워크: " + _val(RED, "연결 끊김") + "[/right]")
		lines.append("[right]" + _val(BLUE, "F9 호스트 | F10 접속") + "[/right]")
	elif net.IsHost():
		lines.append("[right]네트워크: " + _val(GREEN, "호스트") + " (" + _val(BLUE, str(multiplayer.get_unique_id())) + ")[/right]")
		lines.append("[right]피어: " + _val(GREEN, str(multiplayer.get_peers().size())) + "[/right]")
	else:
		lines.append("[right]네트워크: " + _val(GREEN, "클라이언트") + " (" + _val(BLUE, str(multiplayer.get_unique_id())) + ")[/right]")

	if players:
		if net and net.IsActive():
			lines.append("[right]나: " + _val(YELLOW, players.GetMyDisplayName()) + "[/right]")
			if players.peer_names.size() > 0:
				var ids: Array = players.peer_names.keys()
				ids.sort()
				for id in ids:
					if id == multiplayer.get_unique_id():
						continue
					lines.append("[right]· " + _val(BLUE, str(players.peer_names[id])) + "[/right]")
		lines.append("[right]퍼펫: " + _val(BLUE, str(players.remote_players.size())) + "[/right]")

	var scene := get_tree().current_scene
	if scene:
		var map_name: Variant = scene.get("mapName") if scene.get("mapName") else scene.name
		lines.append("[right]씬: " + _val(YELLOW, str(map_name)) + "[/right]")

	if gameData:
		var wpos: String = str(gameData.get("weaponPosition")) if gameData.get("weaponPosition") != null else "?"
		var moving: String = str(gameData.get("isMoving")) if gameData.get("isMoving") != null else "?"
		var running: String = str(gameData.get("isRunning")) if gameData.get("isRunning") != null else "?"
		var aiming: String = str(gameData.get("isAiming")) if gameData.get("isAiming") != null else "?"
		var crouching: String = str(gameData.get("isCrouching")) if gameData.get("isCrouching") != null else "?"
		lines.append("[right]무기위치: " + _val(YELLOW, wpos) + " 이동: " + _val(BLUE, moving) + " 달리기: " + _val(BLUE, running) + "[/right]")
		lines.append("[right]조준: " + _val(BLUE, aiming) + " 앉기: " + _val(BLUE, crouching) + "[/right]")

	# --- fix9: ghost diagnostics ---
	if coop:
		for child in coop.get_children():
			if child.get_script() and child.has_method("_on_character_physics_pre"):
				if "_diag_velocity" in child:
					var vel: Vector3 = child._diag_velocity
					var spd: float = Vector2(vel.x, vel.z).length()
					var spd_color: String = GREEN if spd > 0.5 else RED
					var mb: String = str(child._diag_moving_before) if "_diag_moving_before" in child else "?"
					var ma: String = str(child._diag_moving_after) if "_diag_moving_after" in child else "?"
					var mb_color: String = GREEN if child.get("_diag_moving_before") else RED
					var ma_color: String = GREEN if child.get("_diag_moving_after") else RED
					lines.append("[right]속도: " + _val(spd_color, "%.2f" % spd) + " pre: " + _val(mb_color, mb) + " post: " + _val(ma_color, ma) + "[/right]")
				break
	# Try to get CharacterHooks from the hook system instead
	var char_hooks = Engine.get_meta("_coop_char_hooks_diag", null)
	if char_hooks:
		var vel: Vector3 = char_hooks._diag_velocity
		var spd: float = Vector2(vel.x, vel.z).length()
		var spd_color: String = GREEN if spd > 0.5 else RED
		var mb_color: String = GREEN if char_hooks._diag_moving_before else RED
		var ma_color: String = GREEN if char_hooks._diag_moving_after else RED
		lines.append("[right]" + _val(YELLOW, "[fix9]") + " 속도: " + _val(spd_color, "%.2f" % spd) + " pre: " + _val(mb_color, str(char_hooks._diag_moving_before)) + " post: " + _val(ma_color, str(char_hooks._diag_moving_after)) + "[/right]")

	# v0.9.6: 에임 hit 좌표 — vanilla trader scene별 가드 spawn 좌표 측정 도구.
	# Camera에서 정면 50m raycast (모든 layer) → hit position 표시.
	var aim_scene := get_tree().current_scene
	var aim_camera: Node = aim_scene.get_node_or_null("Core/Camera") if aim_scene else null
	if aim_camera and aim_camera is Camera3D:
		var space = aim_camera.get_world_3d().direct_space_state
		var from: Vector3 = aim_camera.global_position
		var to: Vector3 = from + (-aim_camera.global_transform.basis.z) * 50.0
		var query := PhysicsRayQueryParameters3D.create(from, to)
		query.collision_mask = 0xFFFFFFFF
		var result: Dictionary = space.intersect_ray(query)
		if result.has("position"):
			var p: Vector3 = result.position
			var coll = result.get("collider", null)
			var coll_name: String = coll.name if coll else "?"
			lines.append("[right]에임: " + _val(YELLOW, "(%.2f, %.2f, %.2f)" % [p.x, p.y, p.z]) + "[/right]")
			lines.append("[right]대상: " + _val(BLUE, coll_name) + "[/right]")
		else:
			lines.append("[right]에임: " + _val(RED, "no hit") + "[/right]")

	lines.append("[right]FPS: " + _val(GREEN, str(Engine.get_frames_per_second())) + "[/right]")

	label.text = "\n".join(lines)
