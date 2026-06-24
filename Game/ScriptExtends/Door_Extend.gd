extends "res://Scripts/Door.gd"


func ApplyDoorState(newOpen: bool) -> void:
	isOpen = newOpen
	animationTime = 4.0
	handleMoving = true
	if openAngle.y > 0.0:
		handleTarget = Vector3(0, 0, -45)
	else:
		handleTarget = Vector3(0, 0, 45)
	PlayDoor()
	isOccupied = true
	occupiedTimer = 0.0


func ApplyDoorUnlock() -> void:
	locked = false
	if linked:
		linked.locked = false
	PlayUnlock()
