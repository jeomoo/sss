extends CanvasLayer



const RTVCoop = preload("res://mods/RTVCoop/Game/Coop.gd")

var label: Label
var font: FontFile = load("res://Fonts/Lora-Medium.ttf")


func _ready() -> void:
	layer = 90
	label = Label.new()
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("outline_size", 5)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.anchor_left = 0.0
	label.anchor_right = 1.0
	label.anchor_top = 0.0
	label.offset_top = 80
	label.offset_bottom = 130
	label.visible = false
	# v0.13.11: 상단 가로띠 클릭 통과 — 잠자기 ready 상태에서도 UI 조작 가능
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)


func _process(_delta: float) -> void:
	# v0.13.54: 수면 준비 카운트는 ChatOverlay(채팅)로 이관됨 — 상단 라벨 표시 폐지.
	if label.visible:
		label.visible = false
	set_process(false)
