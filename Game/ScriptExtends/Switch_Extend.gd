extends "res://Scripts/Switch.gd"


func ApplySwitchState(newActive: bool) -> void:
	active = newActive
	if active:
		Activate()
	else:
		Deactivate()
	PlaySwitch()
