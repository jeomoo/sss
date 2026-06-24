extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")
const AI_GUARD_SCENE = preload("res://AI/Guard/AI_Guard.tscn")

# v0.10 TraderGuard 좌표 dict — 사용자가 디버그 오버레이로 측정한 trader 옆 자리.
# 한국어/영어 mapName 양쪽 등록 (한글패치 변동 대응).
const GUARD_SPAWN_COORDS = {
	"Village": [
		Vector3(51.02, 0.40, 60.06),
		Vector3(50.88, 0.46, 65.93),
	],
	"마을": [
		Vector3(51.02, 0.40, 60.06),
		Vector3(50.88, 0.46, 65.93),
	],
	"School": [
		Vector3(44.81, 9.00, 45.18),
		Vector3(50.72, 9.00, 46.77),
	],
	"학교": [
		Vector3(44.81, 9.00, 45.18),
		Vector3(50.72, 9.00, 46.77),
	],
}

func _log(msg: String) -> void:
	var l = Engine.get_meta("CoopLogger", null)
	if l: l.log_msg("LoaderHooks", msg)

func _setup_hooks() -> void:
	CoopHook.register(self, "loader-loadscene-pre", _on_loadscene_pre)
	CoopHook.register(self, "loader-loadscene-post", _on_loadscene_post)
	CoopHook.register_replace_or_post(self, "loader-savecharacter", _replace_savecharacter, _post_savecharacter)
	CoopHook.register_replace_or_post(self, "loader-saveworld", _replace_saveworld, _post_saveworld)
	CoopHook.register_replace_or_post(self, "loader-saveshelter", _replace_saveshelter, _post_saveshelter)
	CoopHook.register_replace_or_post(self, "loader-savetrader", _replace_savetrader, _post_savetrader)
	# v0.6: FormatSave hook — 호스트가 새 게임 시작 시 클라들의 in-memory coopCharacterBuffer 도 reset.
	# vanilla FormatSave는 호스트 PC의 .tres 파일만 지우고 클라 측 buffer는 그대로 남음.
	CoopHook.register(self, "loader-formatsave-post", _on_formatsave_post)
	# v0.9: SaveTaskNotes sync — 누가 노트북에 추가/제거하든 모든 peer 노트북에 mirror.
	# vanilla SaveTaskNotes는 user://Traders.tres taskNotes 배열에 각자 별도 저장만 함.
	CoopHook.register(self, "loader-savetasknotes-post", _post_save_task_notes)


func _post_save_task_notes(task, add) -> void:
	if not CoopAuthority.is_active() or quest == null or task == null:
		return
	var path: String = task.resource_path
	if path == "":
		push_warning("[LoaderHooks] SaveTaskNotes called with task lacking resource_path")
		return
	if CoopAuthority.is_host():
		quest.BroadcastNoteChange.rpc(path, add)
	else:
		quest.SubmitNoteChange.rpc_id(1, path, add)


func _on_formatsave_post() -> void:
	if not CoopAuthority.is_active() or not CoopAuthority.is_host():
		return
	const RTVCoopRef = preload("res://mods/RTVCoop/Game/Coop.gd")
	var coop_ref = RTVCoopRef.get_instance()
	if coop_ref and coop_ref.players and coop_ref.players.has_method("BroadcastCoopNewGame"):
		coop_ref.players.BroadcastCoopNewGame()
		_log("FormatSave POST: broadcast new game → all clients clear coopCharacterBuffer")
	# v0.5: 레거시 하위폴더 세이브도 삭제. vanilla FormatSave는 root .tres만 지워서 coop/players/*.tres
	# (v0.13.57~66 잔재)가 남고, CoopCharacterBuffer._save_path 마이그레이션이 그걸 root로 부활시킴 →
	# 새 게임인데도 *늦게 조인한 클라*가 이전 인벤/배고픔/갈증을 그대로 들고 들어옴 (TryDeliverTo가 부활본 전달).
	_wipe_legacy_coop_saves()


func _wipe_legacy_coop_saves() -> void:
	const SUBDIR := "user://coop/players"
	var dir := DirAccess.open(SUBDIR)
	if dir == null:
		_log("FormatSave: legacy coop/players 없음 (부활 소스 없음)")
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	var removed: int = 0
	while f != "":
		if not dir.current_is_dir() and f.ends_with(".tres"):
			if DirAccess.remove_absolute(SUBDIR + "/" + f) == OK:
				removed += 1
		f = dir.get_next()
	dir.list_dir_end()
	_log("FormatSave: wiped %d legacy coop/players save(s) (새 게임 부활 방지)" % removed)
	print("[LoaderHooks] FormatSave wiped %d legacy coop/players save(s)" % removed)


var _scene_visit_counter: int = 0

func _on_loadscene_pre(scene_name: String = "") -> void:
	if not CoopAuthority.is_active():
		return
	var session: int = players.coop_session_seed if players and "coop_session_seed" in players else 0
	if session == 0:
		if CoopAuthority.is_host() and players and players.has_method("_ensure_session_seed"):
			session = players._ensure_session_seed()
	if session == 0:
		_log("LoadScene PRE: NO session seed available, skipping RNG seed")
		return
	_scene_visit_counter += 1
	if players:
		players.scene_visit_count = _scene_visit_counter
	var scene_seed: int = session ^ hash(scene_name) ^ (_scene_visit_counter * 7919)
	seed(scene_seed)
	_log("LoadScene PRE: seeded RNG with %d (session=%d scene='%s' visit=%d)" % [scene_seed, session, scene_name, _scene_visit_counter])


func _on_loadscene_post(scene_name: String = "") -> void:
	if CoopAuthority.is_active():
		randomize()
		_log("LoadScene POST: restored random")
	var tree = get_tree()
	if tree == null:
		return
	await tree.process_frame
	if get_tree() == null or events == null:
		return
	var map: Node = coop.scene.current_map() if coop and coop.scene else null
	events.scene_ready.emit(map)
	events.map_loaded.emit(scene_name)
	# v0.9.6: 도둑질 차단 (_strip_trader_display_items_client) 호출 제거.
	# v0.10: TraderGuard NPC PoC — 좌표 dict에 따라 trader 옆 자리에 idle guard spawn.
	# v0.11.7: 맵 변경 시 GuardSync aggro 리셋 (새 맵 idle state 시작)
	if CoopAuthority.is_active():
		if guard and "is_aggro" in guard:
			guard.is_aggro = false
			guard.aggro_until = 0.0 if "aggro_until" in guard else null
		tree = get_tree()
		if tree == null:
			return
		await tree.create_timer(1.0, false).timeout
		if get_tree() == null:
			return
		_enable_trader_display_items()
		_spawn_trader_guards(scene_name)
		_cleanup_client_ai_points()




func _enable_trader_display_items() -> void:
	# v0.10: vanilla TraderDisplay._ready가 child.collision.disabled = true로 진열 item interact 차단.
	# 우리 디자인은 훔침 허용 + 옆 가드가 보복이라 collision 강제 활성화. 호스트/클라 모두 적용.
	if players == null:
		return
	var count: int = 0
	for node in get_tree().get_nodes_in_group("Item"):
		if not is_instance_valid(node):
			continue
		if players._is_trader_display_item(node):
			if "collision" in node and node.collision and "disabled" in node.collision:
				if node.collision.disabled:
					node.collision.disabled = false
					count += 1
	print("[LoaderHooks] re-enabled %d trader display item collisions (anti-vanilla-block)" % count)


func _spawn_trader_guards(scene_name: String) -> void:
	if not CoopAuthority.is_host():
		return
	var current: Node = coop.scene.current_map() if coop and coop.scene else null
	if current == null:
		return
	var map_name_prop = current.get("mapName")
	var map_name: String = str(map_name_prop) if map_name_prop != null else current.name
	# raw mapName + scene_name 양쪽 시도
	var coords: Array = []
	if GUARD_SPAWN_COORDS.has(map_name):
		coords = GUARD_SPAWN_COORDS[map_name]
	elif GUARD_SPAWN_COORDS.has(scene_name):
		coords = GUARD_SPAWN_COORDS[scene_name]
	if coords.is_empty():
		print("[LoaderHooks] TraderGuard skip — no coords for map='%s' scene='%s'" % [map_name, scene_name])
		return
	for pos in coords:
		_spawn_single_guard(current, pos, map_name)


func _spawn_single_guard(map: Node, pos: Vector3, map_name: String) -> void:
	var g = AI_GUARD_SCENE.instantiate()
	g.name = "TraderGuard_%s_%d" % [map_name, randi() % 10000]
	g.set_meta("coop_trader_guard", true)
	g.set_meta("coop_spawn_pos", pos)  # AIHooks가 자리 고정에 사용
	g.add_to_group("CoopTraderGuard")
	map.add_child(g)
	g.global_position = pos
	# v0.11.8: 포탑형 — vanilla AI 본문 완전 차단 (frame 보호 + AISpawner issue 회피).
	# 무적 + 자리 고정 + 우리 raycast/look_at으로 통제. 영구 aggro + 모든 player 가까운 순 공격.
	g.set_physics_process(false)
	g.set_process(false)
	if "pause" in g:
		g.pause = true
	if "animator" in g and g.animator:
		g.animator.active = false
	# v0.11.9: AI 그룹 제거 — 클라 측에서 "AI" tooltip 뜨는 issue. PlayerModel 패턴 차용.
	if g.is_in_group("AI"):
		g.remove_from_group("AI")
	_strip_interactable_groups(g)
	# v0.13.15: vanilla AI_Guard.tscn에 박힌 'Gizmo' Label3D (text="AI", 디버그 라벨) 숨김.
	# 3D 라벨이라 멀리서도 클라 머리 위에 보임.
	_hide_debug_labels(g)
	_make_hitbox_immortal(g)
	var animPlayer: AnimationPlayer = g.get_node_or_null("Guard/Animations")
	if animPlayer:
		animPlayer.play("Rifle_Idle", 0.3)
	# v0.13.51: idle facing = 상점 주인(Trader) 쪽. vanilla AI 씬 기본 회전은 고정 월드 방향이라
	# 가드가 엉뚱한 데를 봄 → 가장 가까운 "Trader" 그룹 노드로 수평 look_at. (aggro 시엔 GuardSync가 player로 회전)
	_face_nearest_trader(g, pos)
	print("[LoaderHooks] TraderGuard spawned at %v in '%s' (turret mode)" % [pos, map_name])


func _face_nearest_trader(g: Node3D, pos: Vector3) -> void:
	# v0.13.51: 가드 idle facing을 가장 가까운 Trader(상점 주인)로. 수평만 회전(피치 0 유지).
	var nearest: Node3D = null
	var best_sq: float = INF
	for t in get_tree().get_nodes_in_group("Trader"):
		if not is_instance_valid(t) or not (t is Node3D):
			continue
		var d: float = pos.distance_squared_to((t as Node3D).global_position)
		if d < best_sq:
			best_sq = d
			nearest = t as Node3D
	if nearest == null:
		print("[LoaderHooks] TraderGuard facing skip — no Trader node found")
		return
	var look_pos: Vector3 = nearest.global_position
	look_pos.y = g.global_position.y  # 수평만 — 위/아래로 안 기울게
	if g.global_position.distance_to(look_pos) > 0.05:
		g.look_at(look_pos, Vector3.UP, true)


func _strip_interactable_groups(node: Node) -> void:
	# v0.11.9: AI scene 안에 Interactable/Item 등 tooltip 트리거 그룹 노드 제거
	if node.is_in_group("Interactable"):
		node.remove_from_group("Interactable")
	if node.is_in_group("Item"):
		node.remove_from_group("Item")
	if node.is_in_group("AI"):
		node.remove_from_group("AI")
	for child in node.get_children():
		_strip_interactable_groups(child)


func _hide_debug_labels(node: Node) -> void:
	# v0.13.15: vanilla AI scene에 박힌 Label3D ('Gizmo' 노드, text="AI") 숨김.
	# Label3D는 3D 공간에 그려져 멀리서도 보임 → 클라 시야에 거슬림.
	if node is Label3D:
		node.visible = false
		return
	for child in node.get_children():
		_hide_debug_labels(child)


func _make_hitbox_immortal(node: Node) -> void:
	# vanilla AI Hitbox StaticBody는 layer=64. 그것만 0으로 → 총알 hit X (무적).
	# AI Body (layer=2), PhysicalBone (layer=256), Detector/LOS 등은 vanilla 그대로.
	if node is CollisionObject3D and node.collision_layer == 64:
		node.collision_layer = 0
	for child in node.get_children():
		_make_hitbox_immortal(child)


func _disable_detection_recursive(node: Node) -> void:
	# Detector Area3D + LOS RayCast3D의 collision_mask를 0으로.
	# 원본 mask는 meta에 저장 — GuardSync._activate_aggro에서 복원.
	if node is Area3D and node.collision_mask != 0:
		node.set_meta("coop_guard_original_mask", node.collision_mask)
		node.collision_mask = 0
	elif node is RayCast3D and node.collision_mask != 0:
		node.set_meta("coop_guard_original_mask", node.collision_mask)
		node.collision_mask = 0
	for child in node.get_children():
		_disable_detection_recursive(child)


func _strip_trader_display_items_client() -> void:
	if players == null:
		return
	var trader_count: int = get_tree().get_nodes_in_group("Trader").size()
	var item_count: int = get_tree().get_nodes_in_group("Item").size()
	var disabled: int = 0
	# v0.9.4: vanilla TraderDisplay._ready의 차단 메커니즘 (child.collision.disabled = true)을
	# 클라 측에서 명시 강제. group strip만으론 부족 (어디선가 collision이 다시 enabled되거나
	# Item 그룹에 추가됨 — 클라 한정으로 호스트/싱글에선 vanilla 차단 정상 동작).
	for node in get_tree().get_nodes_in_group("Item"):
		if not is_instance_valid(node):
			continue
		if players._is_trader_display_item(node):
			if "collision" in node and node.collision and "disabled" in node.collision:
				node.collision.disabled = true
			node.remove_from_group("Item")
			disabled += 1
	print("[LoaderHooks/CLIENT] anti-theft scan — traders=%d items=%d disabled=%d" % [trader_count, item_count, disabled])


func _replace_savecharacter() -> void:
	if CoopAuthority.is_client():
		CoopHook.skip_super()


func _post_savecharacter() -> void:
	if CoopAuthority.is_client():
		push_warning("[LoaderHooks] SaveCharacter ran as client; replace owned elsewhere")


func _replace_saveworld() -> void:
	if CoopAuthority.is_client():
		CoopHook.skip_super()


func _post_saveworld() -> void:
	pass


func _replace_saveshelter(_target = null) -> void:
	if CoopAuthority.is_client():
		CoopHook.skip_super()


func _post_saveshelter(_target = null) -> void:
	pass


func _replace_savetrader(_trader = null) -> void:
	if CoopAuthority.is_client():
		CoopHook.skip_super()


func _post_savetrader(_trader = null) -> void:
	pass


func _cleanup_client_ai_points() -> void:
	# 클라이언트일 때 맵 상의 AI_VP, AI_WP 디버그 포인트 메쉬/마커들 감춤 (스포너 비활성화 부작용 대응)
	if get_tree() == null:
		return
	if not CoopAuthority.is_active() or CoopAuthority.is_host():
		return
	var count: int = 0
	for group_name in ["AI_VP", "AI_WP"]:
		for node in get_tree().get_nodes_in_group(group_name):
			if is_instance_valid(node) and (node is Node3D):
				node.visible = false
				_hide_debug_labels(node)
				count += 1
	if count > 0:
		print("[LoaderHooks/CLIENT] Cleaned up %d AI_VP/AI_WP debug points" % count)


