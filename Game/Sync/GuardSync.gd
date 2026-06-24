extends "res://mods/RTVCoop/Game/Sync/BaseSync.gd"


# v0.11.8 포탑형 — vanilla AI 본문 차단 (LoaderHooks에서 set_physics_process false).
# 우리 통제 = look_at + raycast 사격 + LOS 검증. 영구 aggro + 모든 player 가까운 순 공격.
# 맵 리셋 시 LoaderHooks._on_loadscene_post에서 is_aggro=false → idle 복귀.


const LOOK_INTERVAL: float = 1.0  # v0.13.17 transform cascade 부담 감소 (0.5 → 1.0)
const SHOOT_INTERVAL: float = 1.2
const DAMAGE_PER_SHOT: float = 8.0
const GUARD_PENETRATION: int = 30  # v0.13.50 호스트 WeaponDamage용 (방어구 protection<이값 이면 관통). 튜닝 가능


var is_aggro: bool = false
var aggro_until: float = 0.0  # LoaderHooks 호환용 (사용 X)
var look_accum: float = 0.0
var shoot_accum: float = 0.0


func _sync_key() -> String:
	return "guard"


func _physics_process(delta: float) -> void:
	if not CoopAuthority.is_active() or not is_aggro:
		return
	# 0.5초마다 look_at (각 가드별로 가장 가까운 player)
	look_accum += delta
	if look_accum >= LOOK_INTERVAL:
		look_accum = 0.0
		_update_look_at_nearest()
	# 호스트만 1.2초마다 raycast 사격
	if not CoopAuthority.is_host():
		return
	shoot_accum += delta
	if shoot_accum >= SHOOT_INTERVAL:
		shoot_accum = 0.0
		_do_shoot_all_guards()


func _update_look_at_nearest() -> void:
	var players: Array = _get_all_players()
	if players.is_empty():
		return
	for guard in get_tree().get_nodes_in_group("CoopTraderGuard"):
		if not is_instance_valid(guard) or not (guard is Node3D):
			continue
		var g3: Node3D = guard as Node3D
		var nearest: Node3D = _nearest_player_to(g3, players)
		if nearest == null:
			continue
		var look_pos: Vector3 = nearest.global_position
		look_pos.y = g3.global_position.y
		if g3.global_position.distance_to(look_pos) > 0.05:
			g3.look_at(look_pos, Vector3.UP, true)


func _do_shoot_all_guards() -> void:
	var players: Array = _get_all_players()
	if players.is_empty():
		return
	# space_state — players[0]의 world (모든 노드 동일 world 가정)
	var space = (players[0] as Node3D).get_world_3d().direct_space_state
	var hits: int = 0
	# [임시 진단] 클라가 호스트보다 적게 맞는 원인 추적: 타겟 분산 / 빗맞음 / 체인실패 분리.
	var tgt_host: int = 0
	var tgt_puppet: int = 0
	var miss_noray: int = 0
	var miss_chain: int = 0
	var chain_hit_name: String = "-"
	for guard in get_tree().get_nodes_in_group("CoopTraderGuard"):
		if not is_instance_valid(guard) or not (guard is Node3D):
			continue
		var g3: Node3D = guard as Node3D
		var nearest: Node3D = _nearest_player_to(g3, players)
		if nearest == null:
			continue
		if "peer_id" in nearest:
			tgt_puppet += 1
		else:
			tgt_host += 1
		var from: Vector3 = g3.global_position + Vector3(0, 1.5, 0)
		var to: Vector3 = nearest.global_position + Vector3(0, 1.0, 0)
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to)
		query.exclude = [g3.get_rid()]  # 가드 자기 몸 제외(ray가 자기 layer2 body에 막히는 것 방지)
		# v0.13.50: layer 2(플레이어 Controller body) 추가. 호스트 본인은 layer-64 Hitbox가 없고
		# "Player" 그룹 Controller(layer 2)만 있어 mask=65(terrain+Hitbox)로는 ray가 호스트를 관통 →
		# 뒤 벽 명중(chain_match FAIL)으로 데미지 0이었음. puppet은 vanilla AI body라 layer 64 Hitbox 보유.
		query.collision_mask = 67  # terrain(1) + 플레이어 body(2) + Hitbox(64)
		var result: Dictionary = space.intersect_ray(query)
		if not result.has("collider"):
			miss_noray += 1
			continue
		var hit = result.collider
		# v0.5 데미지 경로 통일: 콜라이더 종류(body layer2 / Hitbox layer64) 무관, 타겟 체인 확인되면
		# nearest.child(0)(=host Controller의 Character / puppet의 PuppetHurtbox)로 penetration 일관 적용.
		if not _hit_is_target_chain(hit, nearest):
			miss_chain += 1
			chain_hit_name = str(hit.name)
			continue
		var dmg_node: Node = nearest.get_child(0) if nearest.get_child_count() > 0 else null
		if dmg_node and dmg_node.has_method("WeaponDamage"):
			dmg_node.WeaponDamage(int(DAMAGE_PER_SHOT), GUARD_PENETRATION)
			hits += 1
			_guard_fire_fx(guard)
	# [임시 진단] 항상 출력 — 클라 적게 맞는 원인(타겟분산/빗맞음/체인실패) 분리.
	print("[GuardSync/HOST] volley: target host=%d puppet=%d | hits=%d | miss no-ray=%d chain-fail=%d(last=%s)" % [
		tgt_host, tgt_puppet, hits, miss_noray, miss_chain, chain_hit_name])
	BroadcastGuardVolley.rpc()


func _guard_fire_fx(guard: Node) -> void:
	# vanilla 가드 PlayFire/PlayTail = 발사 사운드 + muzzle flash → ai-playfire hook이 클라 puppet에 mirror.
	# (v0.13.20: AFK 폴더 launch가 진짜 crash 원인이었고 PlayFire 자체는 안전 — 복원됨)
	if guard.has_method("PlayFire") and guard.weapon and is_instance_valid(guard.weapon):
		guard.PlayFire()
	if guard.has_method("PlayTail") and guard.weapon and is_instance_valid(guard.weapon):
		guard.PlayTail()


func _nearest_player_to(g3: Node3D, players: Array) -> Node3D:
	var nearest: Node3D = null
	var nearest_dist_sq: float = INF
	for p in players:
		if not is_instance_valid(p) or not (p is Node3D):
			continue
		var p3: Node3D = p as Node3D
		var d: float = g3.global_position.distance_squared_to(p3.global_position)
		if d < nearest_dist_sq:
			nearest_dist_sq = d
			nearest = p3
	return nearest


func _get_all_players() -> Array:
	var result: Array = []
	var p: Node = _players_ref()
	if p == null:
		return result
	# v0.13.16: 쓰러진(downed) player는 사격 대상에서 제외 — 누운 상태에서 가드가 마무리 사격하는 거 방지
	var coop_ref := RTVCoop.get_instance()
	var downed_sync = coop_ref.get_sync("downed") if coop_ref else null
	var my_id: int = multiplayer.get_unique_id()
	if p.has_method("GetLocalController"):
		var local = p.GetLocalController()
		if local and is_instance_valid(local):
			if downed_sync == null or not downed_sync.is_peer_downed(my_id):
				result.append(local)
	if "remote_players" in p:
		for peer_id in p.remote_players:
			var puppet = p.remote_players[peer_id]
			if not is_instance_valid(puppet):
				continue
			if downed_sync and downed_sync.is_peer_downed(peer_id):
				continue
			result.append(puppet)
	return result


func _hit_is_target_chain(hit: Node, target: Node) -> bool:
	var node: Node = hit
	while node:
		if node == target:
			return true
		node = node.get_parent()
	return false


func _players_ref() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.players if coop else null


@rpc("any_peer", "reliable", "call_remote")
func SubmitTheft(perp_id: int) -> void:
	if not multiplayer.is_server():
		return
	print("[GuardSync/HOST] SubmitTheft perp=%d" % perp_id)
	_activate_aggro()
	BroadcastTheftAggro.rpc()


@rpc("authority", "reliable", "call_local")
func BroadcastTheftAggro() -> void:
	print("[GuardSync] BroadcastTheftAggro — 영구 적대 모드 시작")
	_activate_aggro()
	var chat = Engine.get_meta("ChatOverlay", null)
	if chat and chat.has_method("add_message"):
		chat.add_message("[b]주인장:[/b] 어이 친구 그 손버릇은 부모님이 알려주던가?", "#ffa040")


@rpc("authority", "reliable", "call_remote")
func BroadcastGuardVolley() -> void:
	# Phase D — 클라 측 muzzle flash + audio mirror
	pass


func _activate_aggro() -> void:
	if is_aggro:
		return
	is_aggro = true
	look_accum = 0.0
	shoot_accum = 0.0
	# v0.13.17: aim 자세 transition(0.5초) 후 animation freeze. 그동안 진행되던 매 frame
	# skeleton bone update + PhysicalBone3D physics가 frame drop 원인 추정 (가드 4명 × bones).
	var anim_players: Array = []
	for guard in get_tree().get_nodes_in_group("CoopTraderGuard"):
		if not is_instance_valid(guard):
			continue
		var animPlayer: AnimationPlayer = guard.get_node_or_null("Guard/Animations")
		if animPlayer:
			animPlayer.play("Rifle_Aim_Idle", 0.3)
			anim_players.append(animPlayer)
	# 0.5초 transition 끝나면 speed_scale=0으로 freeze (마지막 pose 유지, bone update 없음)
	var tree = get_tree()
	if tree == null:
		return
	await tree.create_timer(0.5, false).timeout
	if not is_instance_valid(self) or get_tree() == null:
		return
	for ap in anim_players:
		if is_instance_valid(ap):
			ap.speed_scale = 0.0
	print("[GuardSync] %d guards anim frozen (frame drop fix attempt)" % anim_players.size())
