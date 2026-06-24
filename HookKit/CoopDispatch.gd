class_name CoopDispatch extends RefCounted



const CoopHook = preload("res://mods/RTVCoop/HookKit/CoopHook.gd")

static func caller() -> Node:
	return CoopHook.caller()


static func caller_script_path() -> String:
	var c := caller()
	if c == null:
		return ""
	var s: Script = c.get_script()
	return s.resource_path if s else ""


static func caller_is(type_path: String) -> bool:
	return caller_script_path() == type_path


static func caller_has_method(method: StringName) -> bool:
	var c := caller()
	return c != null and c.has_method(method)


static func caller_get(prop: StringName, default: Variant = null) -> Variant:
	var c := caller()
	if c == null:
		return default
	return c.get(prop) if prop in c else default
