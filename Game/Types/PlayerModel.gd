extends Node3D


var audioInstance3D = preload("res://Resources/AudioInstance3D.tscn")
var flashVFX = preload("res://Effects/Muzzle_Flash.tscn")
# v0.13.56: 플레이어 puppet을 Military 모델로 전환 (4종 스켈레톤·애니 동일이라 교체 안전).
# 트레이더 가드(LoaderHooks)는 별개로 여전히 Guard 사용.
const AI_MILITARY_SCENE = preload("res://AI/Military/AI_Military.tscn")
const SKIN_GREEN_PATH := "res://mods/RTVCoop/Skins/mil_green.png"
const SKIN_GRAY_PATH := "res://mods/RTVCoop/Skins/mil_gray.png"


var aiInstance: Node = null


var currentWeaponFile: String = ""
var currentAnim: String = ""
var currentWeaponNode: Node = null
var animPlayer: AnimationPlayer = null


const PUPPET_TRANSFORM = Transform3D(
    Vector3(-1, 0, 0),
    Vector3(0, 1, 0),
    Vector3(0, 0, -1),
    Vector3.ZERO
)

const RIFLE_GRIP = Transform3D(
    Vector3(-0.168531, 0.17101, 0.97075),
    Vector3(0.983905, -0.0301536, 0.176127),
    Vector3(0.0593909, 0.984808, -0.163175),
    Vector3(0.1, 0.12, 0.03)
)
const PISTOL_GRIP = Transform3D(
    Vector3(0.174912, 0.0847189, 0.980934),
    Vector3(0.982636, 0.047607, -0.179328),
    Vector3(-0.0618917, 0.995267, -0.07492),
    Vector3(0.073, 0.108, 0.01)
)


func _ready():

    aiInstance = AI_MILITARY_SCENE.instantiate()
    aiInstance.name = "AI"
    aiInstance.set_meta("coop_puppet_mode", true)
    aiInstance.transform = PUPPET_TRANSFORM
    add_child(aiInstance)

    if aiInstance.is_in_group("AI"):
        aiInstance.remove_from_group("AI")

    _isolate_puppet_resources(aiInstance)
    _apply_puppet_skin()
    _coop_strip_puppet_pickups(aiInstance)
    var gizmo = aiInstance.get_node_or_null("Gizmo")
    if gizmo:
        gizmo.hide()
    if aiInstance.container:
        var container_collider = aiInstance.container.get_node_or_null("StaticBody3D")
        if container_collider == null:
            for child in aiInstance.container.get_children():
                if child is StaticBody3D:
                    container_collider = child
                    break
        if container_collider:
            container_collider.collision_layer = 0
            container_collider.collision_mask = 0
            if container_collider.is_in_group("Interactable"):
                container_collider.remove_from_group("Interactable")

    # 화면 밖 최적화 기능(유령 버그 원인) 모조리 제거
    _remove_visibility_enablers(aiInstance)

    aiInstance.show()
    aiInstance.pause = true
    # fix9.6: Gemini의 _disable_puppet_collisions 호출 제거. base 동작 복원.
    # aiInstance만 layer/mask=0으로 → host가 puppet body 못 봄 (통과)
    # Hitbox는 vanilla 그대로 → host가 hitbox와 충돌 → user-pass 불가 (사용자 원함)
    # PhysicalBone3D vanilla → ragdoll 정상 ground 위 안착
    aiInstance.collision_layer = 0
    aiInstance.collision_mask = 0
    aiInstance.process_mode = Node.PROCESS_MODE_ALWAYS

    if aiInstance.skeleton:
        aiInstance.skeleton.process_mode = Node.PROCESS_MODE_INHERIT
        aiInstance.skeleton.show_rest_only = false
        aiInstance.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE

    if aiInstance.animator:
        aiInstance.animator.active = false

    animPlayer = aiInstance.find_child("Animations", true, false)

    if animPlayer:
        animPlayer.play("Rifle_Idle", 0.3)

    call_deferred("CaptureInitialWeaponFile")


func CaptureInitialWeaponFile():
    var tree = get_tree()
    if tree == null:
        return
    await tree.physics_frame
    tree = get_tree()
    if tree == null:
        return
    await tree.physics_frame
    if not is_instance_valid(self) or get_tree() == null:
        return
    if aiInstance && aiInstance.weapon && aiInstance.weapon.slotData && aiInstance.weapon.slotData.itemData:
        currentWeaponFile = aiInstance.weapon.slotData.itemData.file


func _remove_visibility_enablers(node: Node) -> void:
    # fix9.8: extra_cull_margin=16384 제거. 그게 호스트 시야 밖 puppet mesh를 항상 visible로
    # 판단하게 만들어 skel.advance 등 매 frame 처리 → 호스트 FPS 급락.
    # vanilla 0 그대로 두면 frustum cull 정상 → 시야 밖이면 skip.
    if node.process_mode == Node.PROCESS_MODE_DISABLED:
        node.process_mode = Node.PROCESS_MODE_INHERIT
    for child in node.get_children():
        if child is VisibleOnScreenEnabler3D or child is VisibleOnScreenNotifier3D:
            var path = child.get("enable_node_path")
            if path:
                var target_node = child.get_node_or_null(path)
                if target_node and target_node.process_mode == Node.PROCESS_MODE_DISABLED:
                    target_node.process_mode = Node.PROCESS_MODE_INHERIT
            child.queue_free()
        _remove_visibility_enablers(child)

# fix9.6: _disable_puppet_collisions 함수 제거됨. base 처리 복원.

func _isolate_puppet_resources(ai: Node) -> void:
    if ai.mesh:
        if ai.mesh.mesh:
            ai.mesh.mesh = ai.mesh.mesh.duplicate(true)
        if ai.mesh.skin:
            ai.mesh.skin = ai.mesh.skin.duplicate(true)
        for i in ai.mesh.get_surface_override_material_count():
            var mat = ai.mesh.get_active_material(i)
            if mat:
                ai.mesh.set_surface_override_material(i, mat.duplicate(true))
    if ai.animator and ai.animator.tree_root:
        ai.animator.tree_root = ai.animator.tree_root.duplicate(true)


func _apply_puppet_skin() -> void:
    # v0.13.56: 플레이어별 외형 — peer_id 기준 고정 배정 (한 세션 동안 일관 = 누가 누군지 구분).
    # 0=바닐라(원본) / 1=그린 / 2=그레이. _isolate_puppet_resources가 머티리얼을 per-puppet
    # 복제한 뒤라 albedo 교체가 다른 puppet에 영향 없음.
    var pid: int = 0
    var par = get_parent()
    if par and "peer_id" in par:
        pid = int(par.peer_id)
    var variant: int = pid % 3
    if variant == 0:
        return  # 바닐라 텍스처 그대로
    var path: String = SKIN_GREEN_PATH if variant == 1 else SKIN_GRAY_PATH
    if not FileAccess.file_exists(path):
        push_warning("[PlayerModel] skin not found: " + path)
        return
    var bytes := FileAccess.get_file_as_bytes(path)
    if bytes.is_empty():
        return
    var img := Image.new()
    # 런타임 PNG 로드 (mod 텍스처는 import 안 거치므로 buffer로 직접 디코드)
    if img.load_png_from_buffer(bytes) != OK:
        return
    var tex := ImageTexture.create_from_image(img)
    if aiInstance == null or aiInstance.mesh == null:
        return
    var mat = aiInstance.mesh.get_active_material(0)
    if mat is ShaderMaterial:
        mat.set_shader_parameter("albedo", tex)
    elif mat is BaseMaterial3D:
        mat.albedo_texture = tex


func _coop_strip_puppet_pickups(node: Node) -> void:
    if node is Pickup:
        if node.is_in_group("Item"):
            node.remove_from_group("Item")
        if node is CollisionObject3D:
            node.collision_layer = 0
            node.collision_mask = 0
        if node.has_method("Freeze"):
            node.Freeze()
    for child in node.get_children():
        _coop_strip_puppet_pickups(child)


func _pick_animation(state: Dictionary) -> String:
    var weaponType: String = state.get("weapon", "rifle")
    var prefix = "Pistol" if weaponType == "pistol" else "Rifle"
    var condition: String = state.get("animCondition", "Group")
    var blend: float = state.get("animBlend", 1.0)

    match condition:
        "Group":
            return prefix + "_Idle"
        "Guard":
            return prefix + "_Guard"
        "MovementLow":
            # v0.9.1: sprint 분기 추가. LocalStateSync._gather_state_cached가 호스트
            # sprint 시 (weaponPosition=1 자동 lower) MovementLow + animBlend=2.0 broadcast
            # 하는데 여기서 Walk_F만 반환해서 클라 puppet은 walking 모션 + 위치는 sprint 속도.
            if blend >= 1.5:
                return prefix + "_Sprint_F"
            else:
                return prefix + "_Walk_F"
        "Movement":
            if blend >= 4.0:
                return prefix + "_Sprint_F"
            elif blend >= 2.0:
                return prefix + "_Aim_Run_F"
            else:
                return prefix + "_Aim_Walk_F"
        "Defend":
            return prefix + "_Aim_Idle"
        "Combat":
            return prefix + "_Aim_Walk_F"
        "Hunt":
            if blend >= 0.5:
                return prefix + "_Aim_Crouch_F"
            else:
                return prefix + "_Aim_Crouch_Idle"

    return prefix + "_Idle"


func ApplyAnimState(state: Dictionary):

    if !aiInstance:
        return

    if !animPlayer:
        animPlayer = aiInstance.find_child("Animations", true, false)
        if !animPlayer:
            return

    if !aiInstance.visible:
        aiInstance.show()
    if aiInstance.pause:
        aiInstance.pause = false
    if aiInstance.skeleton && aiInstance.skeleton.show_rest_only:
        aiInstance.skeleton.show_rest_only = false

    var weaponType: String = state.get("weapon", "rifle")
    var hasWeapon: bool = state.get("hasWeapon", true)


    var targetAnim = _pick_animation(state)
    if targetAnim != currentAnim:
        animPlayer.play(targetAnim, 0.3)
        currentAnim = targetAnim
    elif not animPlayer.is_playing() and targetAnim != "":
        animPlayer.play(targetAnim)


    var weaponFile: String = state.get("weaponFile", "")
    if weaponFile != currentWeaponFile:
        SwapWeapon(weaponFile)
        currentWeaponFile = weaponFile

    if aiInstance.weapons:
        for child in aiInstance.weapons.get_children():
            child.visible = hasWeapon


    var is_firing: bool = state.get("isFiring", false)
    var shots: int = state.get("shots", 0)
    var suppressed: bool = state.get("suppressed", false)
    var fireMode: int = state.get("fireMode", 1)
    if not is_firing and _active_fire_audio and is_instance_valid(_active_fire_audio):
        _active_fire_audio.stop()
        _active_fire_audio.queue_free()
        _active_fire_audio = null
    for i in shots:
        PlayPuppetFireEffect(suppressed, fireMode)

    _apply_puppet_attachments(state.get("attachments", []))
    _apply_puppet_flashlight(state.get("flashlight", false))
    _apply_puppet_spine_pitch(state.get("pitch", 0.0))
    _apply_puppet_backpack(state.get("backpackFile", ""))
    _update_puppet_flashlight_transform()


func OnPuppetDeath():
    if !aiInstance:
        return
    if animPlayer:
        animPlayer.stop()
        # fix8.1: _process의 brute-force 강제 재생이 시체에서 다시 walk 모션을 켜는 걸 막음
        currentAnim = ""
    if aiInstance.animator:
        aiInstance.animator.active = false
    if aiInstance.skeleton:
        if _spine_bone >= 0:
            aiInstance.skeleton.set_bone_global_pose_override(_spine_bone, Transform3D(), 0.0, false)
        aiInstance.skeleton.Activate(Vector3(0, 0, -1), 20)
        # fix9.8: simulationTime=999.0 *복원* (base 동작). fix9.0에서 잘못 제거함.
        # 999초 동안 ragdoll active 유지 → 매 frame ground와 안정적 충돌 → 안 빠짐.
        # vanilla 10초로 두면 DeactivateBones 직전 점진 통과 후 잠긴 위치가 ground 아래.
        aiInstance.skeleton.simulationTime = 999.0


func OnPuppetRespawn():
    if !aiInstance:
        return

    if aiInstance.skeleton:
        aiInstance.skeleton.DeactivateBones()
        aiInstance.skeleton.isActive = false
        aiInstance.skeleton.simulationTimer = 0.0
        aiInstance.skeleton.show_rest_only = false
        aiInstance.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE

    # Keep the AnimationTree disabled — puppets use direct AnimationPlayer. Fuck you, AnimationTree.
    if aiInstance.animator:
        aiInstance.animator.active = false

    if !animPlayer:
        animPlayer = aiInstance.find_child("Animations", true, false)
    if animPlayer:
        currentAnim = ""
        animPlayer.play("Rifle_Idle", 0.3)


func PlayPuppetWeaponAudio(audio_key: String) -> void:
    # v0.13.4: 일반화된 무기 audio — vanilla ItemData 필드명을 audio_key로 받음
    # reloadEmpty, reloadTactical, charge, magazineAttachEmpty, magazineAttachTactical,
    # magazineDetach, ammoCheck, insertStart, insertEnd 등
    # v0.13.38 진단: puppet audio 재생 경로 추적
    if not currentWeaponNode:
        print("[PlayerModel] puppet audio FAIL: no currentWeaponNode (key=%s)" % audio_key)
        return
    if not currentWeaponNode.slotData or not currentWeaponNode.slotData.itemData:
        print("[PlayerModel] puppet audio FAIL: no slotData/itemData (key=%s)" % audio_key)
        return
    var weaponData = currentWeaponNode.slotData.itemData
    if not weaponData.get(audio_key):
        print("[PlayerModel] puppet audio FAIL: weaponData has no '%s'" % audio_key)
        return
    var audio_resource = weaponData.get(audio_key)
    if audio_resource == null:
        print("[PlayerModel] puppet audio FAIL: '%s' resource null" % audio_key)
        return
    var audio = audioInstance3D.instantiate()
    if audio.has_signal("finished"):
        audio.finished.connect(func(): audio.queue_free())
    
    # v0.6.6: 총구(Muzzle) 노드를 구하여 자식으로 부착 (3D 공간음향 및 본 트랙 추적 안정화)
    var attach_node = currentWeaponNode
    var muzzleNode = currentWeaponNode.get_node_or_null("Muzzle")
    if muzzleNode:
        attach_node = muzzleNode
        
    attach_node.add_child(audio)
    if "global_position" in audio and "global_position" in attach_node:
        audio.global_position = attach_node.global_position
    # v0.6.7: 감쇠 거리를 현실적인 재장전 소리 전파 범위(2m ~ 15m)로 축소 및 현실화
    audio.PlayInstance(audio_resource, 2, 15)
    print("[PlayerModel] puppet audio PLAYED: %s on node %s" % [audio_key, attach_node.name])


func PlayPuppetFireEffect(suppressed: bool = false, fireMode: int = 1):
    if !currentWeaponNode:
        return
    var muzzleNode = currentWeaponNode.get_node_or_null("Muzzle")
    if !muzzleNode:
        return
    if !suppressed:
        var flash = flashVFX.instantiate()
        muzzleNode.add_child(flash)
        flash.Emit(true, 0.05)
    if _active_fire_audio and is_instance_valid(_active_fire_audio):
        _active_fire_audio.stop()
        _active_fire_audio.queue_free()
        _active_fire_audio = null
    var audio = audioInstance3D.instantiate()
    if audio.has_signal("finished"):
        audio.finished.connect(func(): audio.queue_free())
    muzzleNode.add_child(audio)
    if currentWeaponNode.slotData and currentWeaponNode.slotData.itemData:
        var weaponData = currentWeaponNode.slotData.itemData
        if suppressed and weaponData.get("fireSuppressed"):
            audio.PlayInstance(weaponData.fireSuppressed, 20, 200)
        elif fireMode == 2 and weaponData.get("fireAuto"):
            audio.PlayInstance(weaponData.fireAuto, 20, 200)
            _active_fire_audio = audio
        elif weaponData.get("fireSemi"):
            audio.PlayInstance(weaponData.fireSemi, 20, 200)


func SwapWeapon(file: String):
    if !aiInstance || !aiInstance.weapons:
        return

    if _active_fire_audio and is_instance_valid(_active_fire_audio):
        _active_fire_audio.stop()
        _active_fire_audio.queue_free()
        _active_fire_audio = null

    for child in aiInstance.weapons.get_children():
        child.queue_free()

    if file == "":
        return

    var scene = Database.get(file)
    if !scene:
        return

    var weapon = scene.instantiate()
    aiInstance.weapons.add_child(weapon)
    currentWeaponNode = weapon

    if weapon.is_in_group("Item"):
        weapon.remove_from_group("Item")
    weapon.collision_layer = 0
    weapon.collision_mask = 0
    weapon.freeze = true

    if weapon.slotData && weapon.slotData.itemData && weapon.slotData.itemData.weaponType == "Pistol":
        weapon.transform = PISTOL_GRIP
    else:
        weapon.transform = RIFLE_GRIP
    weapon.show()

    if weapon.slotData && weapon.slotData.itemData:
        var weaponData = weapon.slotData.itemData
        if weaponData.weaponAction != "Manual" && weaponData.compatible.size() > 0:
            if weaponData.compatible[0].subtype == "Magazine":
                var attachments = weapon.get_node_or_null("Attachments")
                if attachments:
                    var magazine = attachments.get_node_or_null(weaponData.compatible[0].file)
                    if magazine:
                        magazine.show()


var _current_attachments: Array = []
var _current_flashlight: bool = false
var _spine_bone: int = -1
var _spine_pitch: float = 0.0
var _spine_target: float = 0.0
var _force_pm_accum: float = 0.0  # v0.13.36 _force_process_mode throttle


func _force_process_mode(node: Node) -> void:
    if node.process_mode == Node.PROCESS_MODE_DISABLED:
        node.process_mode = Node.PROCESS_MODE_INHERIT
    for child in node.get_children():
        _force_process_mode(child)

func _process(delta: float) -> void:
    if !aiInstance or !aiInstance.skeleton:
        return

    # v0.13.36: _force_process_mode가 매 frame 전체 노드 트리 재귀 → puppet 수백 노드 × 매 frame ×
    # puppet 수 = frame drop 주범. process_mode가 DISABLED 되는 건 드문 이벤트라 0.5초마다로 충분.
    _force_pm_accum -= delta
    if _force_pm_accum <= 0.0:
        _force_pm_accum = 0.5
        _force_process_mode(aiInstance)
        
    if animPlayer:
        if not animPlayer.active:
            animPlayer.active = true
        if not animPlayer.is_playing() and currentAnim != "":
            animPlayer.play(currentAnim)
            
    var skel: Skeleton3D = aiInstance.skeleton
    # fix9.7: skel.advance를 mesh visible 시에만 호출.
    # 호스트 시야 밖일 때 Godot가 자체 cull하는데 우리가 매 frame forced advance하면
    # cull 무시되어 호스트 FPS 급락. visible일 때만 호출하면 시야 내 정상 + 시야 밖 cull.
    if animPlayer and animPlayer.is_playing() and skel.has_method("advance") and aiInstance.visible:
        skel.advance(delta)
        
    var puppet = get_parent()
    if puppet and (puppet.get("isDead") or puppet.get("isDowned")):
        return
    if _spine_bone < 0:
        _spine_bone = aiInstance.spineData.bone if aiInstance.spineData else 12
    _spine_pitch = lerp(_spine_pitch, _spine_target, clampf(10.0 * delta, 0.0, 1.0))
    var bonePose: Transform3D = skel.get_bone_global_pose_no_override(_spine_bone)
    bonePose.basis = bonePose.basis.rotated(bonePose.basis.x, -_spine_pitch * 0.7)
    skel.set_bone_global_pose_override(_spine_bone, bonePose, 1.0, true)


func _apply_puppet_attachments(attachmentFiles: Array):
    if !currentWeaponNode or attachmentFiles == _current_attachments:
        return
    _current_attachments = attachmentFiles.duplicate()

    var attachments = currentWeaponNode.get_node_or_null("Attachments")
    if !attachments:
        return

    for child in attachments.get_children():
        child.hide()

    for file in attachmentFiles:
        var node = attachments.get_node_or_null(str(file))
        if node:
            node.show()


var _current_backpack_file: String = ""
var _current_backpack_node: Node = null
var _active_fire_audio: Node = null

func _apply_puppet_backpack(file: String):
    if file == _current_backpack_file:
        return
    var l = Engine.get_meta("CoopLogger", null)
    if l and file != "":
        l.log_msg("PlayerModel", "backpack file='%s' backpacks_node=%s" % [file, str(aiInstance.backpacks != null) if aiInstance else "no_ai"])
    _current_backpack_file = file
    if _current_backpack_node and is_instance_valid(_current_backpack_node):
        _current_backpack_node.queue_free()
        _current_backpack_node = null
    if file == "" or !aiInstance or !aiInstance.backpacks:
        return
    var scene = Database.get(file)
    if !scene:
        if l: l.log_msg("PlayerModel", "  → Database.get('%s') returned null" % file)
        return
    var bp = scene.instantiate()
    aiInstance.backpacks.add_child(bp)
    bp.transform = Transform3D(
        Vector3(-1, 0, 0),
        Vector3(0, 0.97, 0.24),
        Vector3(0, 0.24, -0.97),
        Vector3(0, -0.05, -0.25)
    )
    _current_backpack_node = bp
    if bp.is_in_group("Item"):
        bp.remove_from_group("Item")
    if bp is CollisionObject3D:
        bp.collision_layer = 0
        bp.collision_mask = 0
    if bp.has_method("Freeze"):
        bp.Freeze()
    bp.show()
    var bp_mesh = bp.get_node_or_null("Mesh")
    if bp_mesh:
        bp_mesh.visibility_range_end = 400.0


func _apply_puppet_spine_pitch(pitch: float):
    _spine_target = pitch


var _puppet_spotlight: SpotLight3D = null

func _apply_puppet_flashlight(on: bool):
    if on == _current_flashlight:
        return
    _current_flashlight = on

    if !aiInstance:
        return

    if on:
        if !_puppet_spotlight:
            _puppet_spotlight = SpotLight3D.new()
            _puppet_spotlight.name = "_coop_flashlight"
            _puppet_spotlight.spot_angle = 30.0
            _puppet_spotlight.spot_range = 50.0
            _puppet_spotlight.light_energy = 20.0
            _puppet_spotlight.light_color = Color.WHITE
            _puppet_spotlight.shadow_enabled = false
            aiInstance.add_child(_puppet_spotlight)
        _puppet_spotlight.visible = true
    else:
        if _puppet_spotlight:
            _puppet_spotlight.visible = false


func _update_puppet_flashlight_transform():
    if !_puppet_spotlight or !_puppet_spotlight.visible:
        return
    if aiInstance and aiInstance.eyes:
        _puppet_spotlight.global_position = aiInstance.eyes.global_position
        _puppet_spotlight.global_basis = aiInstance.eyes.global_basis * Basis(Vector3.UP, PI)
