class_name SyncTickService extends Node

# Antigravity 작품 기반 tick manager. 기존 SyncService(module locator)와 별개.
# autoload-style singleton. 게임 _physics_process / render frame과 분리된 고정 tick (20Hz).
# 하위 sync 모듈들이 on_sync_tick 시그널 구독 → 변경점 있을 때만 직렬화 + RPC.
# v0.1: 호스트 character vanilla _physics_process frame에서 sync 부담 분리하여
# vanilla MovementStates 등이 깨끗하게 돌도록 함.

const TICK_RATE_HZ: float = 20.0
const TICK_INTERVAL: float = 1.0 / TICK_RATE_HZ

var _timer: float = 0.0

signal on_sync_tick


func _ready() -> void:
	# 물리 프로세스 가변성 피하고 _process(render frame timing) 사용
	set_physics_process(false)
	set_process(true)


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= TICK_INTERVAL:
		_timer -= TICK_INTERVAL
		on_sync_tick.emit()
