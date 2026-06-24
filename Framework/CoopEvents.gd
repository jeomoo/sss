class_name CoopEvents extends Node


signal peer_joined(peer_id: int, display_name: String)
signal peer_left(peer_id: int)
signal peer_renamed(peer_id: int, display_name: String)

signal authority_changed(is_host: bool)
signal transport_connected(mode: int)
signal transport_disconnected()

signal lobby_state_changed(state: int)
signal lobby_member_changed(member_id: int, state: int)
signal lobby_joined(lobby_id: int)
signal lobby_left()

signal map_loading(map_name: String)
signal map_loaded(map_name: String)
signal scene_ready(scene_root: Node)

signal puppet_spawned(peer_id: int, node: Node)
signal puppet_despawned(peer_id: int)

signal setting_changed(key: String, value: Variant)

signal furniture_lock_denied(fid: int)
