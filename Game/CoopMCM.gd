extends Node

# v0.5: 코옵 MCM 설정. 토글 결과는 Engine.set_meta로 노출 → AISync 등이 읽음(디커플).
# MCM 없으면 기본값 메타만 세팅하고 조용히 패스. 호스트 권위 기능이라 호스트 머신 설정만 실효.
# (VostokQoL/MSS와 동일 패턴: set_value("Bool", key, {meta}) + RegisterConfiguration)

const MCM_HELPERS_PATH := "res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres"
const MOD_ID := "rtv-coop"
const MOD_NAME := "RTV 코옵 (KR)"
const CONFIG_DIR := "user://MCM/RTVCoop"
const CONFIG_PATH := "user://MCM/RTVCoop/config.ini"

var _mcm = null


func _ready() -> void:
	# MCM 유무와 무관하게 기본값 먼저 (AISync가 get_meta 기본 true로 읽긴 하지만 명시)
	Engine.set_meta("coop_threat_targeting", true)
	_mcm = load(MCM_HELPERS_PATH) if ResourceLoader.exists(MCM_HELPERS_PATH) else null
	if _mcm == null:
		print("[CoopMCM] MCM 없음 — 설정 기본값(위협 타게팅=ON)")
		return
	_ensure_dir(CONFIG_DIR)
	var cfg := _build_config()
	if not FileAccess.file_exists(CONFIG_PATH):
		cfg.save(CONFIG_PATH)
	else:
		_mcm.CheckConfigurationHasUpdated(MOD_ID, cfg, CONFIG_PATH)
	var loaded := ConfigFile.new()
	if loaded.load(CONFIG_PATH) == OK:
		_apply(loaded)
	_mcm.RegisterConfiguration(
		MOD_ID, MOD_NAME, CONFIG_DIR,
		"코옵 설정. 위협 가중 타게팅 = 적 AI가 '가장 가까운 사람'뿐 아니라 자기를 쏜 사람에게도 어그로(호스트 기준).",
		{ "config.ini": _on_save }
	)
	print("[CoopMCM] config registered")


func _build_config() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.set_value("Bool", "threat_targeting", {
		"name":     "위협 가중 타게팅",
		"tooltip":  "켜면 적 AI가 가장 가까운 사람만 노리지 않고, 자기를 쏜 사람에게도 어그로가 분산됩니다(7초 감쇠). 끄면 기존 '최근접' 방식. 호스트 적용.",
		"default":  true,
		"value":    true,
		"menu_pos": 1
	})
	return cfg


func _on_save(cfg: ConfigFile) -> void:
	_apply(cfg)


func _apply(cfg: ConfigFile) -> void:
	var entry = cfg.get_value("Bool", "threat_targeting", null)
	if entry is Dictionary:
		Engine.set_meta("coop_threat_targeting", bool(entry.get("value", true)))


func _ensure_dir(path: String) -> void:
	var dir = DirAccess.open("user://")
	if dir != null:
		dir.make_dir_recursive(path.replace("user://", ""))
