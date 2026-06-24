# res://mods/RTVCoop/Game/Commands/ChatCommands.gd
extends RefCounted

# ==============================================================================
# Command Context
# ==============================================================================
class CommandContext:
	var command_name: String
	var arguments: Array
	var chat_overlay: Node  # ChatOverlay 인스턴스 (메시지 출력용 및 multiplayer 조회용)
	
	func _init(p_cmd: String, p_args: Array, p_overlay: Node) -> void:
		command_name = p_cmd
		arguments = p_args
		chat_overlay = p_overlay


# ==============================================================================
# Base Command Class
# ==============================================================================
class ChatCommand:
	func get_names() -> Array:
		return []
		
	func get_description() -> String:
		return ""
		
	func execute(context: CommandContext) -> void:
		pass


# ==============================================================================
# Concrete Commands
# ==============================================================================

# 1. 끼임 탈출 명령어
class UnstuckCommand extends ChatCommand:
	func get_names() -> Array:
		return ["unstuck", "stuck", "탈출", "끼임"]
		
	func get_description() -> String:
		return "  /탈출, /unstuck : 캐릭터 지형 끼임 탈출 시도"
		
	func execute(context: CommandContext) -> void:
		var RTVCoop = load("res://mods/RTVCoop/Game/Coop.gd")
		var coop = RTVCoop.get_instance()
		if coop == null or coop.players == null:
			context.chat_overlay.add_message("[System] 끼임 탈출 실패: Coop 인스턴스가 존재하지 않습니다.", "ffd060")
			return
			
		var local_ctrl = coop.players.GetLocalController()
		if local_ctrl and is_instance_valid(local_ctrl) and local_ctrl.is_inside_tree():
			var current_pos: Vector3 = local_ctrl.global_position
			var world_3d = local_ctrl.get_world_3d()
			var target_pos: Vector3 = current_pos + Vector3(0, 1.5, 0)
			var via_nav: bool = false
			
			if world_3d:
				var nav_map = world_3d.get_navigation_map()
				if nav_map and nav_map.is_valid():
					var closest = NavigationServer3D.map_get_closest_point(nav_map, current_pos)
					if closest != Vector3.ZERO and current_pos.distance_to(closest) < 5.0:
						target_pos = closest + Vector3(0, 0.1, 0)
						via_nav = true
						
			local_ctrl.global_position = target_pos
			if via_nav:
				context.chat_overlay.add_message("[System] 가장 가까운 이동 가능 구역(NavMesh)으로 탈출했습니다.", "#7fd0ff")
			else:
				context.chat_overlay.add_message("[System] 지면 근처 공중(1.5m 위)으로 이동하여 탈출을 시도했습니다.", "#7fd0ff")
		else:
			context.chat_overlay.add_message("[System] 끼임 탈출 실패: 로컬 캐릭터 노드를 찾을 수 없습니다.", "ffd060")


# 2. 도움말 명령어
class HelpCommand extends ChatCommand:
	var registry: RefCounted
	
	func _init(p_registry: RefCounted) -> void:
		registry = p_registry
		
	func get_names() -> Array:
		return ["help", "도움말", "명령어"]
		
	func get_description() -> String:
		return "  /도움말, /help : 사용 가능한 명령어 표시"
		
	func execute(context: CommandContext) -> void:
		context.chat_overlay.add_message("[System] 사용 가능한 명령어 목록:", "white")
		
		var seen_commands := []
		for cmd in registry.commands.values():
			if cmd in seen_commands:
				continue
			seen_commands.append(cmd)
			var desc = cmd.get_description()
			if desc != "":
				context.chat_overlay.add_message(desc, "#7fd0ff")


# 3. [DEBUG] 실시간 3D 좌표 조회 명령어
class CoordsCommand extends ChatCommand:
	func get_names() -> Array:
		return ["coords", "좌표", "pos"]
		
	func get_description() -> String:
		return "  /좌표, /coords : 현재 플레이어의 실시간 3D 위치 좌표 표시"
		
	func execute(context: CommandContext) -> void:
		var RTVCoop = load("res://mods/RTVCoop/Game/Coop.gd")
		var coop = RTVCoop.get_instance()
		if coop == null or coop.players == null:
			context.chat_overlay.add_message("[System] 좌표 조회 실패: Coop 인스턴스가 존재하지 않습니다.", "ffd060")
			return
			
		var local_ctrl = coop.players.GetLocalController()
		if local_ctrl and is_instance_valid(local_ctrl) and local_ctrl.is_inside_tree():
			var pos = local_ctrl.global_position
			context.chat_overlay.add_message("[System] 현재 위치 좌표: X: %.2f, Y: %.2f, Z: %.2f" % [pos.x, pos.y, pos.z], "#7fd0ff")
		else:
			context.chat_overlay.add_message("[System] 좌표 조회 실패: 로컬 캐릭터 노드를 찾을 수 없습니다.", "ffd060")


# 4. [DEBUG] 멀티플레이어 핑 및 연결 상태 테스트 명령어
class PingCommand extends ChatCommand:
	func get_names() -> Array:
		return ["ping", "핑"]
		
	func get_description() -> String:
		return "  /핑, /ping : 현재 자신의 멀티플레이어 상태 및 핑 정보 표시"
		
	func execute(context: CommandContext) -> void:
		if not context.chat_overlay.multiplayer:
			context.chat_overlay.add_message("[System] 멀티플레이어 서비스가 비활성화 상태입니다.", "ffd060")
			return
			
		var peer_id = context.chat_overlay.multiplayer.get_unique_id()
		var is_server = context.chat_overlay.multiplayer.is_server()
		var role_str = "Host/Server" if is_server else "Client"
		context.chat_overlay.add_message("[System] Pong! 상태: %s | Peer ID: %d" % [role_str, peer_id], "#7fd0ff")


# ==============================================================================
# Command Registry & Router
# ==============================================================================
class CommandRegistry:
	var commands: Dictionary = {}
	
	func register_command(cmd: ChatCommand) -> void:
		for name in cmd.get_names():
			commands[name.to_lower()] = cmd
			
	func execute_raw(raw_text: String, chat_overlay: Node) -> bool:
		if not raw_text.begins_with("/"):
			return false
			
		# `/` 이후의 문자를 공백 기준으로 파싱하되 인자가 없는 경우도 커버
		var parts := raw_text.substr(1).split(" ", false)
		if parts.is_empty():
			return false
			
		var cmd_name := parts[0].to_lower()
		var args: Array = []
		for i in range(1, parts.size()):
			args.append(parts[i])
			
		if commands.has(cmd_name):
			var context = CommandContext.new(cmd_name, args, chat_overlay)
			commands[cmd_name].execute(context)
			return true
		else:
			chat_overlay.add_message("[System] 알 수 없는 명령어입니다: /%s" % cmd_name, "ffd060")
			return true
