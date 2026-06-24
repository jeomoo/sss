extends "res://Scripts/Television.gd"


func _coop_remote_interact() -> void:
	set_meta("_coop_in_remote_interact", true)
	super.Interact()
	remove_meta("_coop_in_remote_interact")
