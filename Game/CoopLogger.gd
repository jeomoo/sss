extends Node


# fix5: file logging disabled. The per-line flush() to NTFS was syncing the disk on
# every log call, blocking the main thread and dropping FPS noticeably. Console output
# via print() still works for live debugging. To re-enable persistent logs for crash
# analysis, restore the _file branch and throttle flush() to ~1Hz.
var _peer_label: String = "UNKNOWN"


func _ready() -> void:
	print("[CoopLogger] file logging disabled (fix5) — console output only")


func set_peer_label(label: String) -> void:
	_peer_label = label
	log_msg("CoopLogger", "Peer label set to: %s" % label)


func log_msg(tag: String, msg: String) -> void:
	print("[%s] [%s] [%s] %s" % [
		Time.get_time_string_from_system(),
		_peer_label,
		tag,
		msg
	])


func _exit_tree() -> void:
	pass
