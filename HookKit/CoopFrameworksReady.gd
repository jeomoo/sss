class_name CoopFrameworksReady extends RefCounted


static func is_available() -> bool:
	return Engine.has_meta("RTVModLib")


static func lib():
	return Engine.get_meta("RTVModLib", null)


static func wait_async() -> void:
	if not is_available():
		push_warning("[CoopFrameworksReady] RTVModLib not present; hooks unavailable")
		return
	var l = lib()
	if l._is_ready:
		return
	await l.frameworks_ready
