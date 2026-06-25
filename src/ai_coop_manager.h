#ifndef AI_COOP_MANAGER_H
#define AI_COOP_MANAGER_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <vector>

namespace godot {

class AICoopManagerExt : public Node {
	GDCLASS(AICoopManagerExt, Node)

private:
	struct AIRecord {
		uint64_t instance_id;
		int lod;
		int tick_accum;
		bool is_asleep;
		int network_uuid;
	};

	std::vector<AIRecord> _ai_list;
	
	double _sleep_timer = 0.0;
	const double SLEEP_CHECK_INTERVAL = 0.5;

protected:
	static void _bind_methods();

public:
	AICoopManagerExt();
	~AICoopManagerExt();

	void register_ai(Node *a);
	void unregister_ai(uint64_t id);
	void request_raycast(uint64_t ai_id, Vector3 from_pos, Vector3 to_pos, String callback_func);
	
	// Returns a dictionary containing "sleep": Array[int], "wake": Array[int]
	Dictionary process_host_tick(double delta, const Array &player_positions);
};

} // namespace godot

#endif // AI_COOP_MANAGER_H
