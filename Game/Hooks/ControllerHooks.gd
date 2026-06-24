extends "res://mods/RTVCoop/HookKit/BaseHook.gd"


# v0.13.29: vanilla Controller.MovementStates 완전 격리.
# v0.13.37: InputDirection도 격리 — WASD를 이벤트 기반으로 (frame-independent).
# v0.13.46: sprint dip은 OS jitter 아님 (진단: PRESS/RELEASE 간격 수 초 = 정상 입력).
#   대신 window FOCUS OUT/IN이 잦은 게 단서 (같은 PC 두 창 의심). debounce/velocity 보완 전부 폐기.
#   sprint = 순수 이벤트 기반 _sprint_held. focus 원인은 환경 확인 후 대응.


const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

# inputDirection N-frame dip tolerance (WASD 이벤트 기반이라 거의 안 쓰이지만 안전망)
const INPUT_DIP_TOLERANCE_FRAMES: int = 2
var _input_dir_dip_count: int = 1000

const MOVE_ACTIONS := ["forward", "backward", "left", "right"]
var _move_keys := {"forward": false, "backward": false, "left": false, "right": false}
var _sprint_held := false
var _sprint_just_pressed := false  # toggle 모드용 1-frame 플래그


func _input(event: InputEvent) -> void:
	for action in MOVE_ACTIONS:
		if event.is_action_pressed(action):
			_move_keys[action] = true
		elif event.is_action_released(action):
			_move_keys[action] = false
	if event.is_action_pressed("sprint"):
		_sprint_held = true
		_sprint_just_pressed = true
	elif event.is_action_released("sprint"):
		_sprint_held = false


func _setup_hooks() -> void:
	CoopHook.register_replace_or_post(self,
		"controller-inputdirection",
		_replace_controller_inputdirection,
		_post_controller_inputdirection)
	CoopHook.register_replace_or_post(self,
		"controller-movementstates",
		_replace_controller_movementstates,
		_post_controller_movementstates)


# v0.13.37: vanilla InputDirection 격리. Input.get_vector(polling) 대신 이벤트 기반 키 상태로
# inputDirection 구성 → frame drop이 와도 WASD dip 없음. 게임패드는 polling fallback.
func _replace_controller_inputdirection(_delta: float) -> void:
	var controller := CoopHook.caller()
	if controller == null:
		return
	var kb_dir := Vector2(
		(1.0 if _move_keys["right"] else 0.0) - (1.0 if _move_keys["left"] else 0.0),
		(1.0 if _move_keys["backward"] else 0.0) - (1.0 if _move_keys["forward"] else 0.0)
	)
	var final_dir: Vector2
	if kb_dir != Vector2.ZERO:
		if kb_dir.length() > 1.0:
			kb_dir = kb_dir.normalized()
		final_dir = kb_dir
	else:
		final_dir = Input.get_vector("left", "right", "forward", "backward")  # 게임패드 fallback
	controller.inputDirection = final_dir
	if controller.gameData:
		controller.gameData.inputDirection = final_dir
	CoopHook.skip_super()


func _post_controller_inputdirection(_delta: float) -> void:
	pass


func _replace_controller_movementstates(delta: float) -> void:
	var controller := CoopHook.caller()
	if controller == null:
		return
	var gd = controller.gameData
	if gd == null:
		return

	# vanilla idle 결정 (Controller.gd:178-181 그대로)
	gd.isIdle = not gd.isMoving

	# inputDirection N-frame dip tolerance (안전망)
	var _has_input_now: bool = controller.inputDirection != Vector2.ZERO
	if _has_input_now:
		_input_dir_dip_count = 0
	else:
		_input_dir_dip_count = mini(_input_dir_dip_count + 1, 1000)
	var _effective_moving: bool = _has_input_now or _input_dir_dip_count <= INPUT_DIP_TOLERANCE_FRAMES

	if _effective_moving:
		gd.isMoving = true
		if gd.isCrouching:
			if gd.sprintMode == 2 and _sprint_just_pressed:
				controller.sprintToggle = not controller.sprintToggle
			gd.isCrouching = true
			gd.isWalking = false
			gd.isRunning = false
			controller.currentSpeed = lerp(controller.currentSpeed, controller.crouchSpeed, delta * 2.5)
		else:
			var input_sprint: bool = false
			if gd.sprintMode == 1:
				input_sprint = _sprint_held  # 이벤트 기반 hold 상태
			elif gd.sprintMode == 2:
				if _sprint_just_pressed:
					controller.sprintToggle = not controller.sprintToggle
				input_sprint = controller.sprintToggle
			if input_sprint:
				controller.currentSpeed = lerp(controller.currentSpeed, controller.sprintSpeed, delta * 1.0)
				gd.isWalking = false
				gd.isRunning = true
				gd.isCrouching = false
			else:
				controller.currentSpeed = lerp(controller.currentSpeed, controller.walkSpeed, delta * 2.5)
				gd.isWalking = true
				gd.isRunning = false
				gd.isCrouching = false
	else:
		# 정지 (Controller.gd:241-249 그대로)
		controller.currentSpeed = lerp(controller.currentSpeed, 0.0, delta * 5.0)
		gd.isMoving = false
		gd.isWalking = false
		gd.isRunning = false
		if gd.sprintMode == 2 and _sprint_just_pressed:
			controller.sprintToggle = not controller.sprintToggle

	_sprint_just_pressed = false
	CoopHook.skip_super()


func _post_controller_movementstates(_delta: float) -> void:
	pass
