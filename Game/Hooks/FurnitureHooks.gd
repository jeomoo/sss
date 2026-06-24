extends "res://mods/RTVCoop/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoop/Framework/CoopAuthority.gd")


func _setup_hooks() -> void:
	# v0.9: 가구 catalog 회수 sync — vanilla Furniture.Catalog가 owner.queue_free + AddToCatalog를
	# 부르는데, 호스트만 떼도 클라 측 노드는 그대로 남고 (또 클라가 떼면 카탈로그 복제). hook으로
	# 가구 노드 free를 모든 peer에 broadcast. catalog 항목 자체는 vanilla character buffer에 자동 sync.
	CoopHook.register_replace_or_post(self, "furniture-catalog", _replace_furniture_catalog, _post_furniture_catalog)


func _replace_furniture_catalog() -> void:
	var fc := CoopHook.caller()
	if fc == null or not CoopAuthority.is_active() or furniture == null:
		return
	var root: Node = fc.owner
	if root == null or not root.has_meta("coop_furniture_id"):
		# map scene에 처음부터 있던 가구 (coop_furniture_id 없음) — vanilla 통과
		return
	var fid: int = int(root.get_meta("coop_furniture_id"))

	if CoopAuthority.is_host():
		# 호스트: vanilla 통과 (자기 catalog +1 + 자기 측 가구 free) + 다른 peer 노드 free broadcast
		# BroadcastFurnitureRemove는 call_local — 호스트 자신도 receive하지만 vanilla로 이미 free됐으므로 무해
		print("[FurnitureSync/HOST] catalog hook fired fid=%d — vanilla pass + broadcast remove" % fid)
		furniture.BroadcastFurnitureRemove.rpc(fid)
		return
	else:
		# 클라: vanilla 통과 (자기 catalog +1 + 자기 측 가구 free) + 호스트 claim 요청
		# 호스트가 같은 fid 두 번째 받으면 reject — 시리얼 복제 방지
		print("[FurnitureSync/CLIENT] catalog hook fired fid=%d — vanilla pass + submit claim" % fid)
		furniture.SubmitFurnitureClaim.rpc_id(1, fid)
		return


func _post_furniture_catalog() -> void:
	pass
