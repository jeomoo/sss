extends RefCounted


# v0.13.25: MultiSaveSlots(MSS) SlotPanel용 controller wrapper.
# 원래 MSS의 Main.gd가 controller인데 그건 slot 선택 후 vanilla New Game/Continue 흐름을
# 자동 호출함 (싱글 흐름). 코옵 호스트는 다른 흐름(LoadScene/Modes.show)이 필요해서
# wrapper가 sync_in/wipe만 하고 vanilla 호출 대신 _on_complete callback 발사.


var _mss: Node
var _on_complete: Callable  # callback signature: func(slot_n: int, is_new: bool) -> void


func _init(mss_main: Node, on_complete: Callable) -> void:
	_mss = mss_main
	_on_complete = on_complete


func is_slot_occupied(n: int) -> bool:
	if _mss and _mss.has_method("is_slot_occupied"):
		return _mss.is_slot_occupied(n)
	return false


func slot_metadata(n: int) -> Dictionary:
	if _mss and _mss.has_method("slot_metadata"):
		return _mss.slot_metadata(n)
	return {}


func queue_load_slot(n: int) -> void:
	# load: 기존 slot 그대로 sync in
	print("[CoopSlot] queue_load_slot(%d) called, mss=%s" % [n, str(_mss)])  # v0.13.48 진단
	if _mss == null:
		return
	if _mss.has_method("set_active_slot"):
		_mss.set_active_slot(n)
	if _mss.has_method("sync_in"):
		_mss.sync_in(n)
		print("[CoopSlot] sync_in(%d) done, callback valid=%s" % [n, str(_on_complete.is_valid())])
	if _on_complete.is_valid():
		_on_complete.call(n, false)


func queue_new_slot(n: int, display_name: String = "") -> void:
	# new: slot wipe + 이름 설정 + sync in (빈 user:// 상태 만들기)
	if _mss == null:
		return
	if _mss.has_method("set_active_slot"):
		_mss.set_active_slot(n)
	if _mss.has_method("wipe_slot"):
		_mss.wipe_slot(n)
	if display_name != "" and _mss.has_method("set_slot_display_name"):
		_mss.set_slot_display_name(n, display_name)
	if _mss.has_method("sync_in"):
		_mss.sync_in(n)
	if _on_complete.is_valid():
		_on_complete.call(n, true)


func cancel_pending_new_flow() -> void:
	# SlotPanel back/cancel — 아무 동작 X (vanilla 호출 안 했으니 cleanup 불필요)
	pass


func set_slot_display_name(n: int, display_name: String) -> void:
	if _mss and _mss.has_method("set_slot_display_name"):
		_mss.set_slot_display_name(n, display_name)


func wipe_slot(n: int) -> void:
	if _mss and _mss.has_method("wipe_slot"):
		_mss.wipe_slot(n)
