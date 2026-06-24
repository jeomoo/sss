extends "res://Scripts/Layouts.gd"


func _ready() -> void:
    var is_coop_client: bool = false
    if Engine.has_meta("Coop"):
        var coop = Engine.get_meta("Coop")
        if coop and coop.net and coop.net.has_method("IsActive") and coop.net.IsActive():
            if coop.net.has_method("IsClient") and coop.net.IsClient():
                is_coop_client = true
    if is_coop_client:
        for child in get_children():
            child.hide()
        return
    super()
