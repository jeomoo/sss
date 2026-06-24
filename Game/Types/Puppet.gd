class_name Puppet extends CharacterBody3D



const RTVCoop = preload("res://mods/RTVCoop/Game/Coop.gd")

const LERP_SPEED := 18.0


var peer_id: int = 0
var isDead: bool = false
var isDowned: bool = false

var targetPosition: Vector3 = Vector3.ZERO
var targetRotation: Vector3 = Vector3.ZERO
var hasTarget: bool = false

var cameraPosition: Vector3:
	get:
		var cy: float = 1.6
		var coop := RTVCoop.get_instance()
		var proxy: Node = coop.get_player_proxy(peer_id) if coop else null
		if proxy and proxy.get("sync_anim_condition") == "Hunt":
			cy = 0.9
		return global_position + Vector3(0, cy, 0)

var isFiring: bool:
	get:
		var coop := RTVCoop.get_instance()
		var proxy: Node = coop.get_player_proxy(peer_id) if coop else null
		return proxy.sync_is_firing if proxy else false

var isRunning: bool:
	get:
		var coop := RTVCoop.get_instance()
		var proxy: Node = coop.get_player_proxy(peer_id) if coop else null
		if proxy:
			var cond: String = proxy.sync_anim_condition
			var blend: float = proxy.sync_anim_blend
			if cond in ["Movement", "MovementLow"] and blend >= 4.0:
				return true
		return false

var isWalking: bool:
	get:
		var coop := RTVCoop.get_instance()
		var proxy: Node = coop.get_player_proxy(peer_id) if coop else null
		if proxy:
			var cond: String = proxy.sync_anim_condition
			var blend: float = proxy.sync_anim_blend
			if cond in ["Movement", "MovementLow"] and blend >= 0.5 and blend < 4.0:
				return true
		return false

var isReloading: bool:
	get:
		return false

var isAiming: bool:
	get:
		var coop := RTVCoop.get_instance()
		var proxy: Node = coop.get_player_proxy(peer_id) if coop else null
		if proxy:
			return proxy.sync_anim_condition in ["Combat", "Defend"]
		return false

var isCrouching: bool:
	get:
		var coop := RTVCoop.get_instance()
		var proxy: Node = coop.get_player_proxy(peer_id) if coop else null
		if proxy:
			return proxy.sync_anim_condition == "Hunt"
		return false

var flashlight: bool:
	get:
		var coop := RTVCoop.get_instance()
		var proxy: Node = coop.get_player_proxy(peer_id) if coop else null
		return proxy.sync_flashlight if proxy else false

var playerVector: Vector3:
	get:
		return -global_transform.basis.z

var isTrading: bool:
	get:
		return false

@onready var playerModel: Node = get_node_or_null("PlayerModel")


func _ready() -> void:
	add_to_group("Player")
	add_to_group("CoopPlayer")
	# BodyCollider 강제 보정 (원점 중심 방지 및 높이/오프셋 확실히 고정)
	var body_collider: CollisionShape3D = get_node_or_null("BodyCollider")
	if body_collider:
		body_collider.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.9, 0))
		if body_collider.shape is CapsuleShape3D:
			body_collider.shape = body_collider.shape.duplicate() # 리소스 공유 방지
			body_collider.shape.height = 1.8
			body_collider.shape.radius = 0.35
			print("[RTVCoop][Puppet] BodyCollider forced to height=1.8, y=0.9")

	# Hitbox (StaticBody3D) 강제 보정
	var hitbox: StaticBody3D = get_node_or_null("Hitbox")
	if hitbox:
		hitbox.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.9, 0))
		var hitbox_shape: CollisionShape3D = hitbox.get_node_or_null("CollisionShape3D")
		if hitbox_shape and hitbox_shape.shape is CapsuleShape3D:
			hitbox_shape.shape = hitbox_shape.shape.duplicate()
			hitbox_shape.shape.height = 1.8
			hitbox_shape.shape.radius = 0.4
			print("[RTVCoop][Puppet] Hitbox forced to height=1.8, y=0.9")




func _physics_process(delta: float) -> void:
	if hasTarget and not isDowned:
		global_position = global_position.lerp(targetPosition, LERP_SPEED * delta)
		global_rotation.y = lerp_angle(global_rotation.y, targetRotation.y, LERP_SPEED * delta)
		force_update_transform()


# v0.3: Antigravity 패턴 — fast state RPC 수신용. 4필드 단순 packet.
# v0.4: rotation은 기존 broadcast가 처리 (puppet PUPPET_TRANSFORM 보정 의도와 일관성).
# fast broadcast는 *위치만* 빠른 sync. 기존 broadcast가 rotation/anim 처리.
func push_state(packet: Dictionary) -> void:
	const SNAP_THRESHOLD_SQ: float = 25.0
	if packet.has("p"):
		targetPosition = packet["p"]
		if global_position.distance_squared_to(targetPosition) > SNAP_THRESHOLD_SQ:
			global_position = targetPosition
	# v0.4: rotation 전송 무시. 기존 SetTarget가 처리.
	hasTarget = true


func SetTarget(pos: Vector3, rot: Vector3) -> void:
	targetPosition = pos
	targetRotation = rot
	if not hasTarget:
		global_position = pos
		global_rotation = rot
		hasTarget = true


func ApplyAnimState(state: Dictionary) -> void:
	if isDead or isDowned:
		return
	if playerModel and playerModel.has_method("ApplyAnimState"):
		playerModel.ApplyAnimState(state)


func OnDowned() -> void:
	isDowned = true
	_set_hitbox_interactable(true)
	if playerModel and playerModel.has_method("OnPuppetDeath"):
		playerModel.OnPuppetDeath()


func OnRevived() -> void:
	isDowned = false
	_set_hitbox_interactable(false)
	if playerModel and playerModel.has_method("OnPuppetRespawn"):
		playerModel.OnPuppetRespawn()


func OnDeath() -> void:
	isDead = true
	isDowned = false
	_set_hitbox_interactable(false)
	if playerModel and playerModel.has_method("OnPuppetDeath"):
		playerModel.OnPuppetDeath()


func OnRespawn() -> void:
	isDead = false
	if playerModel and playerModel.has_method("OnPuppetRespawn"):
		playerModel.OnPuppetRespawn()


func Interact() -> void:
	pass


func UpdateTooltip() -> void:
	if not isDowned:
		return
	var gd = preload("res://Resources/GameData.tres")
	var player_name: String = "Player %d" % peer_id
	var coop := RTVCoop.get_instance()
	if coop and coop.players and coop.players.has_method("GetPlayerName"):
		player_name = coop.players.GetPlayerName(peer_id)
	gd.tooltip = "Revive " + player_name


func _set_hitbox_interactable(enabled: bool) -> void:
	var hitbox: Node = get_node_or_null("Hitbox")
	if hitbox == null:
		return
	if enabled:
		if not hitbox.is_in_group("Interactable"):
			hitbox.add_to_group("Interactable")
		hitbox.collision_layer = 128
		# v0.7.4: downed hitbox 적당히. 누운 시체 전체 정도, 과도하게 크지 않게.
		hitbox.position = Vector3(0, 0.4, 0)
		var shape: CollisionShape3D = hitbox.get_node_or_null("CollisionShape3D")
		if shape and shape.shape is CapsuleShape3D:
			shape.shape = shape.shape.duplicate()
			shape.shape.height = 1.5
			shape.shape.radius = 0.55
	else:
		if hitbox.is_in_group("Interactable"):
			hitbox.remove_from_group("Interactable")
		hitbox.collision_layer = 64
		hitbox.position = Vector3(0, 0.9, 0)
		var shape: CollisionShape3D = hitbox.get_node_or_null("CollisionShape3D")
		if shape and shape.shape is CapsuleShape3D:
			shape.shape = shape.shape.duplicate()
			shape.shape.height = 1.8
			shape.shape.radius = 0.4


func WeaponDamage(_type: String, finalDamage: float) -> void:
	var coop := RTVCoop.get_instance()
	if coop == null:
		return
	var iac: Node = coop.get_sync("interactable")
	if iac and iac.has_method("RequestPlayerDamage"):
		iac.RequestPlayerDamage(peer_id, int(finalDamage), 0)
