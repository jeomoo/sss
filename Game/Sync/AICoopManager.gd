extends "res://mods/RTVCoop/Game/Sync/BaseSync.gd"

# RTVCoop 중앙 집중식 CPU 최적화 아키텍처 (AICoopManager2.gd)
# 하이브리드 C++ GDExtension 버전
# 무거운 배칭, 거리 계산, 레이캐스트 제어 로직은 C++ 코어(AICoopManagerExt)로 이관되었습니다.

var _ext: Node

func _sync_key() -> String:
	return "coop_manager"

func _ready() -> void:
	_load_gdextension()
	# C++ GDExtension 클래스 인스턴스화
	if ClassDB.class_exists("AICoopManagerExt"):
		_ext = ClassDB.instantiate("AICoopManagerExt")
		add_child(_ext)
		print("[AICoopManager2] C++ 하이브리드 모듈 (AICoopManagerExt) 로드 성공.")
	else:
		push_error("[AICoopManager2] AICoopManagerExt 클래스를 찾을 수 없습니다! DLL 컴파일 및 GDExtension 등록 상태를 확인하세요.")

func _load_gdextension() -> void:
	if ClassDB.class_exists("AICoopManagerExt"):
		return
		
	# 모드 파일(.vmz) 내부에 DLL이 있을 경우 OS에서 LoadLibrary로 직접 읽을 수 없으므로 user:// 로 추출
	var ext_path = "res://mods/RTVCoop/bin/rtv_coop.gdextension"
	var dll_path = "res://mods/RTVCoop/bin/rtv_coop.windows.release.x86_64.dll"
	
	if not FileAccess.file_exists(dll_path):
		print("[AICoopManager2] 패키지 내부에 DLL 파일이 없습니다: ", dll_path)
		return
		
	var user_dir = "user://rtvcoop_ext"
	if not DirAccess.dir_exists_absolute(user_dir):
		DirAccess.make_dir_absolute(user_dir)
		
	var ext_user_path = user_dir + "/rtv_coop.gdextension"
	var dll_user_path = user_dir + "/rtv_coop.windows.release.x86_64.dll"
	
	# DLL 추출
	if FileAccess.file_exists(dll_path):
		var bytes = FileAccess.get_file_as_bytes(dll_path)
		var f = FileAccess.open(dll_user_path, FileAccess.WRITE)
		if f:
			f.store_buffer(bytes)
			f.close()
			
	# GDEXTENSION 설정 파일 생성 (추출된 OS 절대 경로 DLL을 가리키도록 수정)
	var dll_os_path = ProjectSettings.globalize_path(dll_user_path).replace("\\", "/")
	var ext_content = """[configuration]
entry_symbol = "rtv_coop_library_init"
compatibility_minimum = "4.2"

[libraries]
windows.debug.x86_64 = "%s"
windows.release.x86_64 = "%s"
""" % [dll_os_path, dll_os_path]

	var f2 = FileAccess.open(ext_user_path, FileAccess.WRITE)
	if f2:
		f2.store_string(ext_content)
		f2.close()
		
	# 절대경로 GDExtension 로드
	var status = GDExtensionManager.load_extension(ext_user_path)
	print("[AICoopManager2] 런타임 GDExtension 로드 상태: ", status)

func register_ai(a: Node) -> void:
	if _ext and is_instance_valid(a):
		_ext.register_ai(a)

func unregister_ai(id: int) -> void:
	if _ext:
		_ext.unregister_ai(id)

func request_raycast(ai_id: int, from_pos: Vector3, to_pos: Vector3, callback_func: String) -> void:
	if _ext:
		_ext.request_raycast(ai_id, from_pos, to_pos, callback_func)

func _physics_process(delta: float) -> void:
	if not CoopAuthority.is_active() or not CoopAuthority.is_host():
		return

	if not _ext:
		return

	var coop_inst := RTVCoop.get_instance()
	var players_ref = coop_inst.players if coop_inst else null
	if players_ref == null:
		return

	# C++ 코어로 전달할 플레이어 위치 배열 수집 (단순 반복문은 GDScript에서 처리하여 넘김)
	var player_positions: Array[Vector3] = []
	
	var local_ctrl = players_ref.GetLocalController() if players_ref.has_method("GetLocalController") else null
	if local_ctrl and is_instance_valid(local_ctrl) and not local_ctrl.get("isDead", false):
		player_positions.append(local_ctrl.global_position)

	for id in players_ref.remote_players:
		var puppet = players_ref.remote_players[id]
		if is_instance_valid(puppet) and not puppet.get("isDead", false) and not puppet.get("isDowned", false):
			player_positions.append(puppet.global_position)

	# ---------------------------------------------------------
	# C++ 코어 틱 실행 (연산 90% 이상 이관)
	# 결과로 Sleep/Wake 처리해야 할 AI의 UUID 리스트를 Dictionary로 반환받습니다.
	# ---------------------------------------------------------
	var rpc_actions: Dictionary = _ext.process_host_tick(delta, player_positions)
	
	if rpc_actions.is_empty():
		return

	var ai_sync = _sync("ai")
	if ai_sync == null or not ai_sync.has_method("SetAISleepState"):
		return

	# C++ 코어에서 연산한 결과에 따라 네트워크 RPC 상태 동기화만 스크립트에서 수행
	if rpc_actions.has("sleep") and rpc_actions["sleep"].size() > 0:
		for uuid in rpc_actions["sleep"]:
			ai_sync.SetAISleepState.rpc(uuid, true)
			print("[AICoopManager2] AI uuid=%d 수면 상태 전환 (C++ Core)" % uuid)
			
	if rpc_actions.has("wake") and rpc_actions["wake"].size() > 0:
		for uuid in rpc_actions["wake"]:
			ai_sync.SetAISleepState.rpc(uuid, false)
			print("[AICoopManager2] AI uuid=%d 활성 상태 전환 (C++ Core)" % uuid)
