extends "res://mods/RTVCoop/HookKit/BaseHook.gd"


# v0.13.30: vanilla Handling.WeaponHandling 완전 격리 (서버 격리 디자인 확장).
# 호스트가 가끔 조준 안 되는 버그 — vanilla state stuck/dip이 원인 추정.
# vanilla 로직 1:1 복제 + 매 frame deterministic하게 isAiming/isCanted 결정 → vanilla 안 거침.


const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")


func _setup_hooks() -> void:
	CoopHook.register_replace_or_post(self,
		"handling-weaponhandling",
		_replace_handling_weaponhandling,
		_post_handling_weaponhandling)


func _replace_handling_weaponhandling(delta: float) -> void:
	var handling := CoopHook.caller()
	if handling == null:
		return
	var gd = handling.gameData
	if gd == null:
		CoopHook.skip_super()
		return
	if gd.freeze:
		CoopHook.skip_super()
		return

	# position/rotation lerp (Handling.gd:57-60)
	handling.position = lerp(handling.position, Vector3(-handling.targetPosition.x, handling.targetPosition.y, -handling.targetPosition.z), delta * handling.handlingSpeed)
	handling.rotation_degrees.x = lerp(handling.rotation_degrees.x, handling.targetRotation.x, delta * handling.handlingSpeed)
	handling.rotation_degrees.y = lerp(handling.rotation_degrees.y, handling.targetRotation.y, delta * handling.handlingSpeed)
	handling.rotation_degrees.z = lerp(handling.rotation_degrees.z, handling.targetRotation.z, delta * handling.handlingSpeed)

	var data = handling.data
	if data == null:
		CoopHook.skip_super()
		return

	# isClearing (vanilla:63-66)
	if gd.isClearing:
		handling.targetPosition = data.collisionPosition
		handling.targetRotation = data.collisionRotation
		CoopHook.skip_super()
		return

	# collision (vanilla:69-77)
	if handling.collision.is_colliding():
		handling.targetPosition = data.collisionPosition
		handling.targetRotation = data.collisionRotation
		gd.isColliding = true
		gd.isAiming = false
		gd.isCanted = false
		CoopHook.skip_super()
		return
	else:
		gd.isColliding = false

	# isPlacing (vanilla:80-84)
	if gd.isPlacing:
		gd.weaponPosition = 1
		handling.targetPosition = data.lowPosition
		handling.targetRotation = data.lowRotation
		CoopHook.skip_super()
		return

	# isInspecting (vanilla:87-90)
	if gd.isInspecting:
		handling.targetPosition = data.inspectPosition
		handling.targetRotation = data.inspectRotation
		CoopHook.skip_super()
		return

	# isRunning / isChecking / isReloading (vanilla:93-109)
	var is_manual: bool = data.weaponAction == "Manual"
	if gd.isRunning or gd.isChecking or (gd.isReloading and not is_manual):
		if gd.weaponPosition == 1:
			handling.aimToggle = false
			gd.isAiming = false
			gd.isCanted = false
			handling.targetPosition = data.lowPosition
			handling.targetRotation = data.lowRotation
			CoopHook.skip_super()
			return
		elif gd.weaponPosition == 2:
			handling.aimToggle = false
			gd.isAiming = false
			gd.isCanted = false
			handling.targetPosition = data.highPosition
			handling.targetRotation = data.highRotation
			CoopHook.skip_super()
			return

	# aim 입력 판정 (aimMode 1 = hold, 2 = toggle)
	var aim_input: bool = false
	if gd.aimMode == 1:
		aim_input = Input.is_action_pressed("aim")
	elif gd.aimMode == 2:
		if Input.is_action_just_pressed("aim"):
			handling.aimToggle = not handling.aimToggle
		aim_input = handling.aimToggle

	if aim_input:
		if Input.is_action_just_pressed("canted") and not gd.interaction:
			handling.canted = not handling.canted

		if handling.canted:
			gd.isCanted = true
			gd.isAiming = false
			handling.targetPosition = data.cantedPosition
			handling.targetRotation = data.cantedRotation
		else:
			gd.isCanted = false
			gd.isAiming = true

			if handling.get_parent().activeOptic:
				handling.targetPosition = Vector3(0.0, 0.0 - handling.get_parent().aimOffset, data.aimPosition.z)
			else:
				handling.targetPosition = data.aimPosition
			handling.targetRotation = data.aimRotation

			if gd.isScoped and not gd.PIP:
				handling.targetPosition -= Vector3(0.0, 0.0, 0.1)
	else:
		gd.isAiming = false
		gd.isCanted = false

		if gd.weaponPosition == 2:
			handling.targetPosition = data.highPosition
			handling.targetRotation = data.highRotation
		elif gd.weaponPosition == 1:
			handling.targetPosition = data.lowPosition
			handling.targetRotation = data.lowRotation

	CoopHook.skip_super()


func _post_handling_weaponhandling(_delta: float) -> void:
	pass
