@tool
extends "res://Scripts/Spawner.gd"


func _spawner_log(msg: String) -> void:
    var f = FileAccess.open("user://spawner_debug.txt", FileAccess.READ_WRITE) if FileAccess.file_exists("user://spawner_debug.txt") else FileAccess.open("user://spawner_debug.txt", FileAccess.WRITE)
    if f:
        f.seek_end()
        f.store_line("[%s] %s" % [Time.get_time_string_from_system(), msg])
        f.flush()


func _ready() -> void:
    if not Engine.is_editor_hint():
        var is_coop_client: bool = false
        var is_coop_active: bool = false
        if Engine.has_meta("Coop"):
            var coop = Engine.get_meta("Coop")
            if coop and coop.net and coop.net.has_method("IsActive") and coop.net.IsActive():
                is_coop_active = true
                if coop.net.has_method("IsClient") and coop.net.IsClient():
                    is_coop_client = true
        var sceneData = data as SpawnerSceneData
        if sceneData and sceneData.runtime:
            _spawner_log("RUNTIME spawner '%s' active=%s client=%s" % [str(get_path()), str(is_coop_active), str(is_coop_client)])
            if is_coop_client:
                _spawner_log("  → BLOCKED on client")
                return
            else:
                _spawner_log("  → ALLOWED (host or solo)")
    super()
