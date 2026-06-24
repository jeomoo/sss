extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")


func _log(msg: String) -> void:
	var l = Engine.get_meta("CoopLogger", null)
	if l: l.log_msg("TransitionHooks", msg)


func _setup_hooks() -> void:
	# v0.13.13: replace hook 추가 — 클라일 때 vanilla LoadScene 차단해서 vote 시스템 강제.
	# 이걸로 클라 측에서도 InteractorHooks가 gd.transition=false 강제 안 해도 됨 →
	# vanilla HUD prompt(목적지 박스) 살아나는 효과.
	CoopHook.register_replace_or_post(self, "transition-interact", _replace_transition_interact, _on_transition_interact_post)


func _replace_transition_interact() -> void:
	var tr := CoopHook.caller()
	if tr == null or not CoopAuthority.is_active():
		return
	if tr.locked or tr.tutorialExit:
		# 잠긴 transition은 key check, tutorial은 즉시 이동 (싱글 흐름 유지)
		return
	if CoopAuthority.is_host():
		# 호스트 fire 케이스 = _execute_transition()이 vote 통과 후 직접 tr.Interact() 호출 시점.
		# vanilla 진행 → LoadScene + 기존 broadcast 메커니즘.
		return
	# 클라: vanilla LoadScene 차단. vote는 InteractorHooks._on_interactor_physics_post가 이미 처리.
	_log("[CLIENT] transition-interact replace fired (LoadScene 차단): %s" % str(tr.name))
	CoopHook.skip_super()


func _on_transition_interact_post() -> void:
	var tr := CoopHook.caller()
	if tr == null or not CoopAuthority.is_host() or not CoopAuthority.is_active():
		return
	if tr.locked or tr.tutorialExit:
		return
	if interactable:
		interactable.BroadcastTransitionDrain.rpc(tr.energy, tr.hydration)
