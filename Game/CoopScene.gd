class_name CoopScene extends Node


func current_map() -> Node:
	return get_tree().current_scene if get_tree() else null


func get_map() -> Node:
	var s := current_map()
	return s if s != null and s.name == "Map" else null


func core() -> Node:
	var m := current_map()
	return m.get_node_or_null("Core") if m else null


func core_ui() -> Node:
	var c := core()
	return c.get_node_or_null("UI") if c else null


func interface() -> Node:
	var u := core_ui()
	return u.get_node_or_null("Interface") if u else null


func get_path_or_null(relative_path: String) -> Node:
	var m := current_map()
	return m.get_node_or_null(relative_path) if m else null
