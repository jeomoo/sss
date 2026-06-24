extends "res://mods/RTVCoop/HookKit/BaseHook.gd"


const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")

func _setup_hooks() -> void:
    CoopHook.register_replace_or_post(self, "layouts-_ready", _replace_layouts_ready, _post_layouts_ready)


func _replace_layouts_ready() -> void:
    var layouts := CoopHook.caller()
    if layouts == null or not CoopAuthority.is_active() or not CoopAuthority.is_client():
        return
    for child in layouts.get_children():
        child.hide()
    CoopHook.skip_super()


func _post_layouts_ready() -> void:
    pass
