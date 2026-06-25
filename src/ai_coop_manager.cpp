#include "ai_coop_manager.h"
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/node3d.hpp>


using namespace godot;

void AICoopManagerExt::_bind_methods() {
	ClassDB::bind_method(D_METHOD("register_ai", "a"), &AICoopManagerExt::register_ai);
	ClassDB::bind_method(D_METHOD("unregister_ai", "id"), &AICoopManagerExt::unregister_ai);
	ClassDB::bind_method(D_METHOD("request_raycast", "ai_id", "from_pos", "to_pos", "callback_func"), &AICoopManagerExt::request_raycast);
	ClassDB::bind_method(D_METHOD("process_host_tick", "delta", "player_positions"), &AICoopManagerExt::process_host_tick);
}

AICoopManagerExt::AICoopManagerExt() {
}

AICoopManagerExt::~AICoopManagerExt() {
}

void AICoopManagerExt::register_ai(Node *a) {
	if (!a) return;
	uint64_t id = a->get_instance_id();
	
	// Check if already exists
	for (const auto& record : _ai_list) {
		if (record.instance_id == id) {
			return;
		}
	}
	
	AIRecord record;
	record.instance_id = id;
	record.lod = 0;
	record.tick_accum = UtilityFunctions::randi() % 10;
	record.is_asleep = false;
	
	if (a->has_meta("network_uuid")) {
		record.network_uuid = a->get_meta("network_uuid");
	} else {
		record.network_uuid = -1;
	}
	
	_ai_list.push_back(record);
}

void AICoopManagerExt::unregister_ai(uint64_t id) {
	for (auto it = _ai_list.begin(); it != _ai_list.end(); ++it) {
		if (it->instance_id == id) {
			_ai_list.erase(it);
			return;
		}
	}
}

void AICoopManagerExt::request_raycast(uint64_t ai_id, Vector3 from_pos, Vector3 to_pos, String callback_func) {
	// Not fully implemented in C++ core yet to keep it simple, 
	// typically raycasts should remain in GDScript or be processed here using direct space state.
}

Dictionary AICoopManagerExt::process_host_tick(double delta, const Array &player_positions) {
	Dictionary rpc_actions;
	Array sleep_uuids;
	Array wake_uuids;

	_sleep_timer += delta;
	bool check_sleep = false;
	if (_sleep_timer >= SLEEP_CHECK_INTERVAL) {
		_sleep_timer = 0.0;
		check_sleep = true;
	}

	for (auto &record : _ai_list) {
		Object *obj = ObjectDB::get_instance(record.instance_id);
		Node *a = Object::cast_to<Node>(obj);
		
		if (!a || a->is_queued_for_deletion() || a->get("dead")) {
			continue;
		}

		if (check_sleep && player_positions.size() > 0) {
			Node3D *ai_3d = Object::cast_to<Node3D>(a);
			if (!ai_3d) continue;

			Vector3 ai_pos = ai_3d->get_global_position();
			double min_dist = 999999.0;
			
			for (int i = 0; i < player_positions.size(); ++i) {
				Vector3 p_pos = player_positions[i];
				double d = ai_pos.distance_to(p_pos);
				if (d < min_dist) {
					min_dist = d;
				}
			}

			bool is_asleep = false;
			if (a->has_meta("coop_ai_asleep")) {
				is_asleep = a->get_meta("coop_ai_asleep");
			}

			int uuid = -1;
			if (a->has_meta("network_uuid")) {
				uuid = a->get_meta("network_uuid");
			}

			if (min_dist > 150.0) {
				if (!is_asleep) {
					a->set_meta("coop_ai_asleep", true);
					a->call("hide");
					a->set_process_mode(Node::PROCESS_MODE_DISABLED);
					
					Node *skeleton = Object::cast_to<Node>(a->get("skeleton"));
					if (skeleton) skeleton->set_process_mode(Node::PROCESS_MODE_DISABLED);
					
					Object *animator = a->get("animator");
					if (animator) animator->set("active", false);

					record.is_asleep = true;
					if (uuid != -1) {
						sleep_uuids.push_back(uuid);
					}
				}
			} else if (min_dist <= 135.0) {
				if (is_asleep) {
					a->set_meta("coop_ai_asleep", false);
					a->call("show");
					a->set_process_mode(Node::PROCESS_MODE_INHERIT);
					
					Node *skeleton = Object::cast_to<Node>(a->get("skeleton"));
					if (skeleton) skeleton->set_process_mode(Node::PROCESS_MODE_INHERIT);
					
					Object *animator = a->get("animator");
					if (animator) animator->set("active", true);

					record.is_asleep = false;
					if (uuid != -1) {
						wake_uuids.push_back(uuid);
					}
				}
			}
		}
	}

	if (sleep_uuids.size() > 0) rpc_actions["sleep"] = sleep_uuids;
	if (wake_uuids.size() > 0) rpc_actions["wake"] = wake_uuids;

	return rpc_actions;
}
