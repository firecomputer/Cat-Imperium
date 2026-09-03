extends Control

const EmpireSystem = preload("res://sim/systems/empire_system.gd")

## M9 관전 화면. 시뮬은 뷰를 참조하지 않고, 이 호스트가 tick 이후 상태와 이벤트를
## 단방향으로 읽는다.

const MapRendererScript = preload("res://view/map_renderer.gd")
const LineChartScript = preload("res://view/line_chart.gd")

const BG := Color("0a101a")
const PANEL := Color("111b29")
const PANEL_ALT := Color("172334")
const BORDER := Color("26384d")
const TEXT := Color("dce7f1")
const MUTED := Color("8fa2b5")
const ACCENT := Color("f2b84b")
const GOOD := Color("5dd39e")
const BAD := Color("ef6f7b")
const BLUE := Color("5ab0f2")

## 1배속 = 1턴 3초. 관전은 사건을 눈으로 따라갈 수 있어야 한다.
const BASE_TICKS_PER_SECOND := 1.0 / 3.0
const SPEEDS := [1, 2, 4, 8, 16, 32]
## 무거운 패널(BBCode 재파싱·차트)은 프레임마다 갱신하지 않는다.
## 한 프레임에 몰아치는 틱 수 상한. 최고 배속도 초당 10.7틱이라 4면 충분하고,
## 프레임이 한 번 밀렸을 때 수백 ms 짜리 따라잡기 프레임이 생기는 것을 막는다.
const MAX_TICKS_PER_FRAME := 2
const UI_REFRESH_INTERVAL := 0.25
const LOG_MAX_LINES := 260
const LOG_KEEP_LINES := 200
## 차트는 마지막 140개만 쓰므로 기록을 무한정 쌓을 이유가 없다.
const HISTORY_CAP := 2000
const HISTORY_TRIM := 500
## 소비가 끝난 이벤트는 잘라 낸다. 장시간 관전에서 events 가 계속 자란다.
const EVENT_TRIM_AT := 4000

var world: WorldState
var paused := true
var speed_index := 0
var tick_accumulator := 0.0
var selected_province := -1
var selected_nation := -1
var event_cursor := 0
var event_lines: Array[String] = []

var _ui_timer := 0.0
## 프로빈스 → {start, last, losses{국가:누적사상자}, power{국가:직전전력}}.
## 매 턴 쏟아지는 battle_resolved 를 기록 두 줄로 줄이고, 전투 패널의 재료가 된다.
var _active_battles: Dictionary = {}
## 전투 패널이 보고 있는 프로빈스. -1 이면 닫혀 있다.
var battle_province := -1

var nation_gdp_history: Dictionary = {}
var nation_debt_history: Dictionary = {}
var world_gdp_history: Array[float] = []

var map_renderer
var chart
var tabs: TabContainer
var seed_input: SpinBox
var play_button: Button
var speed_buttons: Array[Button] = []
var turn_label: Label
var world_label: Label
var cash_label: Label
var nation_title: Label
var nation_detail: RichTextLabel
var market_category: OptionButton
var market_list: ItemList
var market_detail: RichTextLabel
var trade_quantity: SpinBox
var trade_status: Label
var portfolio_detail: RichTextLabel
var event_log: RichTextLabel
var war_toggle: Button
var search_panel: PanelContainer
var search_input: LineEdit
var search_list: ItemList
var battle_panel: PanelContainer
var battle_title: Label
var battle_detail: RichTextLabel

var market_selected := {
	Market.AssetKind.BOND: -1,
	Market.AssetKind.PROVINCE: -1,
	Market.AssetKind.CHARACTER: -1,
}
var _last_market_refresh_turn := -999


func _ready() -> void:
	_build_theme()
	_build_ui()
	call_deferred("_new_world")


func _process(delta: float) -> void:
	_ui_timer += delta
	if paused or world == null:
		return
	tick_accumulator += delta * BASE_TICKS_PER_SECOND * SPEEDS[speed_index]
	var ticks := mini(int(tick_accumulator), MAX_TICKS_PER_FRAME)
	if ticks <= 0:
		return
	tick_accumulator -= ticks
	for i in range(ticks):
		SimClock.tick(world)
		_record_history()
	_process_new_events()
	map_renderer.on_world_advanced()
	_refresh_header()
	if _ui_timer >= UI_REFRESH_INTERVAL:
		_refresh_panels(false)


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_SPACE:
			_toggle_pause()
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6:
			_set_speed(int(event.keycode - KEY_1))
		KEY_PERIOD:
			_step_once()
		KEY_F:
			_open_search()
		KEY_ESCAPE:
			_close_search()
			_close_battle()


func _build_theme() -> void:
	var ui_theme := Theme.new()
	ui_theme.default_font_size = 14
	# 한글이 없는 기본 폰트를 쓰면 글자마다 시스템 폰트 대체 탐색이 돌아
	# RichTextLabel 한 줄에 1.7ms 씩 든다 (40줄 69ms). 한글 폰트를 직접 지정한다.
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Noto Sans CJK KR", "Noto Sans KR",
		"Malgun Gothic", "Apple SD Gothic Neo", "NanumGothic", "Sans-Serif"])
	ui_theme.default_font = font
	for type in ["Label", "Button", "CheckButton", "OptionButton", "ItemList",
			"TabContainer", "RichTextLabel", "SpinBox", "LineEdit"]:
		ui_theme.set_color("font_color", type, TEXT)
	ui_theme.set_color("font_hover_color", "Button", Color.WHITE)
	ui_theme.set_color("font_pressed_color", "Button", ACCENT)
	ui_theme.set_color("font_selected_color", "ItemList", Color.WHITE)
	ui_theme.set_color("font_unselected_color", "TabContainer", MUTED)
	ui_theme.set_color("font_selected_color", "TabContainer", ACCENT)
	theme = ui_theme


func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = BG
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var root_box := VBoxContainer.new()
	root_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_box.add_theme_constant_override("separation", 0)
	add_child(root_box)
	root_box.add_child(_build_top_bar())

	var body := HSplitContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.split_offset = 820
	body.add_theme_constant_override("separation", 1)
	root_box.add_child(body)
	body.add_child(_build_map_panel())
	body.add_child(_build_side_panel())
	add_child(_build_search_overlay())


func _build_top_bar() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 62
	panel.add_theme_stylebox_override("panel", _panel_style(Color("0e1723"), 0, false))
	var margin := MarginContainer.new()
	_set_margins(margin, 16, 10, 16, 10)
	panel.add_child(margin)
	var row := HBoxContainer.new()
	# 배속 버튼이 3개에서 6개로 늘었다. 1280 폭에서 오른쪽 자산 표시가 잘리지 않게 좁힌다.
	row.add_theme_constant_override("separation", 6)
	margin.add_child(row)

	var brand := _label("CAT IMPERIUM", 21, ACCENT)
	brand.tooltip_text = "결정론적 고양이 문명 관전 시뮬레이션"
	row.add_child(brand)
	row.add_child(_v_separator())
	row.add_child(_label("SEED", 11, MUTED))
	seed_input = SpinBox.new()
	seed_input.min_value = 1
	seed_input.max_value = 999999999
	seed_input.value = 1
	seed_input.custom_minimum_size.x = 102
	seed_input.allow_greater = false
	seed_input.allow_lesser = false
	row.add_child(seed_input)
	var generate := _button("새 세계")
	generate.pressed.connect(_new_world)
	row.add_child(generate)
	row.add_child(_v_separator())

	play_button = _button("▶ 재생")
	play_button.custom_minimum_size.x = 84
	play_button.pressed.connect(_toggle_pause)
	row.add_child(play_button)
	var step := _button("한 턴")
	step.tooltip_text = ". 키"
	step.pressed.connect(_step_once)
	row.add_child(step)
	for i in range(SPEEDS.size()):
		var button := _button("%dx" % SPEEDS[i])
		button.toggle_mode = true
		button.button_pressed = i == speed_index
		button.tooltip_text = "%d 키 · 1턴 %.1f초" % [
			i + 1, 1.0 / (BASE_TICKS_PER_SECOND * SPEEDS[i])]
		for state in ["normal", "hover", "pressed"]:
			var style: StyleBoxFlat = button.get_theme_stylebox(state).duplicate()
			style.content_margin_left = 4
			style.content_margin_right = 4
			button.add_theme_stylebox_override(state, style)
		button.pressed.connect(_set_speed.bind(i))
		speed_buttons.append(button)
		row.add_child(button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	turn_label = _label("TURN —", 15, TEXT)
	row.add_child(turn_label)
	world_label = _label("세계 생성 중", 12, MUTED)
	world_label.custom_minimum_size.x = 150
	row.add_child(world_label)
	row.add_child(_v_separator())
	cash_label = _label("자산 —", 14, GOOD)
	cash_label.custom_minimum_size.x = 170
	cash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(cash_label)
	return panel


func _build_map_panel() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _panel_style(Color("0c1521"), 0, false))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	panel.add_child(box)

	var toolbar_panel := PanelContainer.new()
	toolbar_panel.custom_minimum_size.y = 42
	toolbar_panel.add_theme_stylebox_override("panel", _panel_style(PANEL_ALT, 0, false))
	var toolbar_margin := MarginContainer.new()
	_set_margins(toolbar_margin, 10, 6, 10, 6)
	toolbar_panel.add_child(toolbar_margin)
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 6)
	toolbar_margin.add_child(toolbar)
	toolbar.add_child(_label("지도 레이어", 12, MUTED))
	var group := ButtonGroup.new()
	group.allow_unpress = false
	for i in range(MapRendererScript.MODE_NAMES.size()):
		var button := _button(MapRendererScript.MODE_NAMES[i])
		button.toggle_mode = true
		button.button_group = group
		button.button_pressed = i == MapRendererScript.MapMode.POLITICAL
		button.pressed.connect(_set_map_mode.bind(i))
		toolbar.add_child(button)
	war_toggle = _button("전쟁 표시")
	war_toggle.toggle_mode = true
	war_toggle.button_pressed = true
	war_toggle.tooltip_text = "군대·교전·공성·전선 오버레이"
	war_toggle.toggled.connect(_set_show_war)
	toolbar.add_child(war_toggle)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)
	toolbar.add_child(_label("휠 확대 · 우클릭 이동 · 클릭 선택 · F 검색", 11, MUTED))
	box.add_child(toolbar_panel)

	map_renderer = MapRendererScript.new()
	map_renderer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_renderer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map_renderer.province_selected.connect(_on_province_selected)
	map_renderer.battle_selected.connect(_on_battle_selected)
	box.add_child(map_renderer)
	map_renderer.add_child(_build_battle_overlay())
	return panel


## 전투 패널은 지도 위에 뜬다. 전황을 지도와 같이 읽는 것이 목적이라 사이드 탭으로
## 빼면 시선이 갈린다. map_renderer 의 자식이라 지도 영역 밖으로 나가지 않는다.
func _build_battle_overlay() -> Control:
	battle_panel = PanelContainer.new()
	battle_panel.visible = false
	battle_panel.add_theme_stylebox_override("panel", _panel_style(Color("0e1723"), 6, true))
	battle_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	battle_panel.offset_left = 12
	battle_panel.offset_right = 384
	battle_panel.offset_top = -156
	battle_panel.offset_bottom = -12
	var margin := MarginContainer.new()
	_set_margins(margin, 12, 8, 12, 10)
	battle_panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	margin.add_child(box)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	box.add_child(head)
	battle_title = _label("", 15, TEXT)
	battle_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(battle_title)
	var close := _button("✕")
	close.pressed.connect(_close_battle)
	head.add_child(close)

	battle_detail = RichTextLabel.new()
	battle_detail.bbcode_enabled = true
	battle_detail.fit_content = false
	battle_detail.scroll_active = true
	battle_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	battle_detail.add_theme_color_override("default_color", TEXT)
	battle_detail.add_theme_font_size_override("normal_font_size", 12)
	box.add_child(battle_detail)
	return battle_panel


func _build_side_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 395
	panel.add_theme_stylebox_override("panel", _panel_style(PANEL, 0, false))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	panel.add_child(box)

	tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.custom_minimum_size.y = 440
	tabs.tab_changed.connect(_on_tab_changed)
	box.add_child(tabs)
	tabs.add_child(_build_nation_tab())
	tabs.add_child(_build_market_tab())
	tabs.add_child(_build_event_tab())

	var chart_panel := PanelContainer.new()
	chart_panel.add_theme_stylebox_override("panel", _panel_style(PANEL_ALT, 0, false))
	chart = LineChartScript.new()
	chart_panel.add_child(chart)
	box.add_child(chart_panel)
	return panel


func _build_nation_tab() -> Control:
	var margin := MarginContainer.new()
	margin.name = "국가"
	_set_margins(margin, 14, 14, 14, 10)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 9)
	margin.add_child(box)
	nation_title = _label("지도에서 프로빈스를 선택하세요", 21, TEXT)
	box.add_child(nation_title)
	nation_detail = RichTextLabel.new()
	nation_detail.bbcode_enabled = true
	nation_detail.fit_content = false
	nation_detail.scroll_active = true
	nation_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	nation_detail.add_theme_color_override("default_color", TEXT)
	nation_detail.add_theme_font_size_override("normal_font_size", 13)
	box.add_child(nation_detail)
	return margin


func _build_market_tab() -> Control:
	var margin := MarginContainer.new()
	margin.name = "시장"
	_set_margins(margin, 12, 12, 12, 10)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	margin.add_child(box)

	var category_row := HBoxContainer.new()
	category_row.add_child(_label("상품", 12, MUTED))
	market_category = OptionButton.new()
	market_category.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	market_category.add_item("국채", Market.AssetKind.BOND)
	market_category.add_item("프로빈스 지분", Market.AssetKind.PROVINCE)
	market_category.add_item("인물 후원", Market.AssetKind.CHARACTER)
	market_category.item_selected.connect(_on_market_category)
	category_row.add_child(market_category)
	box.add_child(category_row)

	market_list = ItemList.new()
	market_list.custom_minimum_size.y = 180
	market_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	market_list.select_mode = ItemList.SELECT_SINGLE
	market_list.item_selected.connect(_on_market_item)
	box.add_child(market_list)

	market_detail = RichTextLabel.new()
	market_detail.bbcode_enabled = true
	market_detail.custom_minimum_size.y = 108
	market_detail.fit_content = false
	box.add_child(market_detail)

	var trade_row := HBoxContainer.new()
	trade_row.add_child(_label("수량", 12, MUTED))
	trade_quantity = SpinBox.new()
	trade_quantity.min_value = 1
	trade_quantity.max_value = 100
	trade_quantity.value = 1
	trade_quantity.custom_minimum_size.x = 80
	trade_row.add_child(trade_quantity)
	var buy_button := _button("매수")
	buy_button.pressed.connect(_trade.bind(true))
	trade_row.add_child(buy_button)
	var sell_button := _button("매도")
	sell_button.pressed.connect(_trade.bind(false))
	trade_row.add_child(sell_button)
	trade_status = _label("", 11, MUTED)
	trade_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	trade_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	trade_row.add_child(trade_status)
	box.add_child(trade_row)

	portfolio_detail = RichTextLabel.new()
	portfolio_detail.bbcode_enabled = true
	portfolio_detail.custom_minimum_size.y = 92
	portfolio_detail.fit_content = false
	portfolio_detail.scroll_active = true
	box.add_child(portfolio_detail)
	return margin


func _build_event_tab() -> Control:
	var margin := MarginContainer.new()
	margin.name = "기록"
	_set_margins(margin, 12, 12, 12, 10)
	event_log = RichTextLabel.new()
	event_log.bbcode_enabled = true
	event_log.scroll_following = true
	event_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	event_log.meta_clicked.connect(_on_log_meta_clicked)
	event_log.meta_hover_started.connect(_on_log_meta_hover)
	event_log.meta_hover_ended.connect(_on_log_meta_hover_end)
	margin.add_child(event_log)
	return margin


## F 키 검색. 기록에서 본 국가를 지도에서 찾는 가장 빠른 길이다.
func _build_search_overlay() -> Control:
	search_panel = PanelContainer.new()
	search_panel.visible = false
	search_panel.add_theme_stylebox_override("panel", _panel_style(Color("0e1723"), 6, true))
	search_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	search_panel.anchor_left = 0.5
	search_panel.anchor_right = 0.5
	search_panel.offset_left = -230
	search_panel.offset_right = 230
	search_panel.offset_top = 90
	var margin := MarginContainer.new()
	_set_margins(margin, 12, 10, 12, 10)
	search_panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	margin.add_child(box)
	box.add_child(_label("국가 이름 또는 프로빈스 번호  ·  Enter 이동 · Esc 닫기", 11, MUTED))
	search_input = LineEdit.new()
	search_input.placeholder_text = "검색"
	search_input.text_changed.connect(_on_search_changed)
	search_input.text_submitted.connect(_on_search_submitted)
	box.add_child(search_input)
	search_list = ItemList.new()
	search_list.custom_minimum_size.y = 220
	search_list.select_mode = ItemList.SELECT_SINGLE
	search_list.item_selected.connect(_on_search_picked)
	box.add_child(search_list)
	return search_panel


func _new_world() -> void:
	paused = true
	tick_accumulator = 0.0
	play_button.text = "▶ 재생"
	var seed := int(seed_input.value)
	world = WorldState.create(seed)
	selected_province = world.nations[0].capital if not world.nations.is_empty() else 0
	selected_nation = world.provinces[selected_province].owner_nation
	market_selected[Market.AssetKind.BOND] = selected_nation
	market_selected[Market.AssetKind.PROVINCE] = selected_province
	market_selected[Market.AssetKind.CHARACTER] = _best_character_for(selected_nation)
	event_cursor = world.events.size()
	event_lines.clear()
	_active_battles.clear()
	_close_battle()
	event_log.text = ""
	_append_log("[color=#f2b84b]세계 생성[/color]  seed %d · 프로빈스 %d · 국가 %d" % [
		seed, world.provinces.size(), world.nations.size()])
	nation_gdp_history.clear()
	nation_debt_history.clear()
	world_gdp_history.clear()
	_record_history()
	_last_market_refresh_turn = -999
	map_renderer.set_world(world)
	map_renderer.focus_province(selected_province)
	_refresh_all(true)


func _toggle_pause() -> void:
	if world == null:
		return
	paused = not paused
	play_button.text = "▶ 재생" if paused else "Ⅱ 정지"


func _step_once() -> void:
	if world == null:
		return
	paused = true
	play_button.text = "▶ 재생"
	SimClock.tick(world)
	_record_history()
	_process_new_events()
	map_renderer.on_world_advanced()
	_refresh_all(false)


func _set_speed(index: int) -> void:
	speed_index = clampi(index, 0, SPEEDS.size() - 1)
	for i in range(speed_buttons.size()):
		speed_buttons[i].button_pressed = i == speed_index


func _set_map_mode(value: int) -> void:
	map_renderer.set_mode(value)


func _set_show_war(enabled: bool) -> void:
	map_renderer.set_show_war(enabled)


func _on_province_selected(province_id: int) -> void:
	selected_province = province_id
	selected_nation = world.provinces[province_id].owner_nation
	market_selected[Market.AssetKind.PROVINCE] = province_id
	if selected_nation >= 0:
		market_selected[Market.AssetKind.BOND] = selected_nation
		var best := _best_character_for(selected_nation)
		if best >= 0:
			market_selected[Market.AssetKind.CHARACTER] = best
	_refresh_nation()
	_refresh_chart()
	if tabs.current_tab == 1:
		_refresh_market_list(true)


func _on_tab_changed(_tab: int) -> void:
	_refresh_chart()
	if tabs.current_tab == 1:
		_refresh_market_list(true)


func _on_market_category(index: int) -> void:
	var kind := market_category.get_item_id(index)
	if int(market_selected.get(kind, -1)) < 0:
		match kind:
			Market.AssetKind.BOND:
				market_selected[kind] = selected_nation
			Market.AssetKind.PROVINCE:
				market_selected[kind] = selected_province
			Market.AssetKind.CHARACTER:
				market_selected[kind] = _best_character_for(selected_nation)
	_refresh_market_list(true)


func _on_market_item(index: int) -> void:
	if index < 0 or index >= market_list.item_count:
		return
	var kind := _current_market_kind()
	market_selected[kind] = int(market_list.get_item_metadata(index))
	_refresh_market_detail()


func _trade(is_buy: bool) -> void:
	if world == null:
		return
	var kind := _current_market_kind()
	var asset_id := int(market_selected.get(kind, -1))
	var units := int(trade_quantity.value)
	var ok := Market.buy(world, kind, asset_id, units) if is_buy \
		else Market.sell(world, kind, asset_id, units)
	trade_status.text = ("매수 완료" if is_buy else "매도 완료") if ok else \
		("자금 또는 상품을 확인하세요" if is_buy else "보유 수량을 확인하세요")
	trade_status.add_theme_color_override("font_color", GOOD if ok else BAD)
	_process_new_events()
	_refresh_all(true)


func _refresh_all(force_market: bool) -> void:
	if world == null:
		return
	_refresh_header()
	_refresh_panels(force_market)


## 매 프레임 갱신해도 되는 값. 라벨 두어 개라 비용이 없다.
func _refresh_header() -> void:
	turn_label.text = "TURN %03d" % world.turn
	var alive := 0
	var wars := 0
	for n in world.nations:
		if n.is_alive:
			alive += 1
	for war in world.wars:
		if war.is_active:
			wars += 1
	world_label.text = "국가 %d · 전쟁 %d · GDP %s" % [alive, wars, _short(world.world_gdp())]
	var worth := Market.net_worth(world)
	var return_pct := (worth / PlayerPortfolio.STARTING_CASH - 1.0) * 100.0
	cash_label.text = "현금 %s  자산 %s (%+.1f%%)" % [
		_short(world.portfolio.cash), _short(worth), return_pct]


## BBCode 재파싱과 차트를 포함하는 무거운 쪽. 최소 UI_REFRESH_INTERVAL 간격으로만 돈다.
func _refresh_panels(force_market: bool) -> void:
	_ui_timer = 0.0
	_refresh_nation()
	_refresh_market_list(force_market)
	_refresh_portfolio()
	_refresh_chart()
	_refresh_battle()


func _refresh_nation() -> void:
	if selected_nation < 0 or selected_nation >= world.nations.size():
		nation_title.text = "소유국 없음"
		nation_detail.text = ""
		return
	var n: Nation = world.nations[selected_nation]
	nation_title.text = _nation_name(n.id)
	var status := "반란 세력" if n.is_rebel else ("속국" if n.overlord >= 0 \
		else ("생존" if n.is_alive else "멸망"))
	var cities := 0
	for pid in n.provinces:
		if world.provinces[pid].has_city:
			cities += 1
	var debt_ratio := n.debt / maxf(n.gdp, 1.0) * 100.0

	var lines := PackedStringArray()
	lines.append("[color=#8fa2b5]%s[/color]" % status)
	lines.append(_stat("GDP / 인구", "%s / %s" % [_short(n.gdp), _short(n.population)]))
	lines.append(_stat("영토 / 도시", "%d / %d" % [n.provinces.size(), cities]))
	lines.append(_stat("신용 / 인플레", "%.0f%% / %+.1f%%" % [
		n.credit_rating * 100.0, n.inflation * 100.0]))
	lines.append(_stat("부채 / GDP", "%s / %.0f%%" % [_short(n.debt), debt_ratio]))
	lines.append(_stat("평균 불만", "%.0f%%" % (n.avg_unrest * 100.0)))
	lines.append(_stat("육군 / 함선", "%s / %d" % [
		_short(Military.total_troops(world, n)), Naval.total_ships(world, n)]))
	lines.append(_stat("전쟁 / 동맹", "%d / %d" % [n.wars.size(), n.allies.size()]))
	var root: Nation = world.nations[EmpireSystem.realm_root(world, n.id)]
	lines.append(_stat("직할 / 속국", "%d / %d" % [n.provinces.size(), root.vassals.size()]))
	lines.append(_stat("제국권 / 권위", "%.1f%% / %.0f%%" % [
		EmpireSystem.realm_share(world, n) * 100.0, root.imperial_authority * 100.0]))
	lines.append(_stat("행정부하 / 수용력", "%.1f / %.1f%s" % [
		root.admin_load, root.admin_capacity,
		" · 초과 %.0f%%" % (root.overextension * 100.0) if root.overextension > 0.0 else ""]))
	if n.overlord >= 0:
		lines.append(_stat("종주국 / 충성도", "%s / %.0f%%" % [
			_nation_name(n.overlord), n.vassal_loyalty * 100.0]))

	if selected_province >= 0 and selected_province < world.provinces.size():
		var p: Province = world.provinces[selected_province]
		lines.append("")
		lines.append("[color=#8fa2b5]선택 지역[/color]  프로빈스 %03d%s" % [
			p.id, " · 도시" if p.has_city else ""])
		lines.append(_stat("GDP / 인구", "%s / %s" % [_short(p.gdp), _short(p.population)]))
		lines.append(_stat("인프라 / 1인 GDP", "%.2f / %s" % [p.infra, _short(p.gdp_pc)]))
		lines.append(_stat("불만 / 보급", "%.0f%% / %.0f%%" % [
			p.unrest * 100.0, p.supply * 100.0]))
		lines.append(_stat("통합도", "%.0f%%" % (p.integration * 100.0)))
		lines.append(_stat("성장 여력", "%+.1f%%" % (Market.growth_headroom(p) * 100.0)))
		if p.occupied_by_nation >= 0:
			lines.append(_stat("점령", _nation_name(p.occupied_by_nation)))
		if p.siege_by_nation >= 0 and p.siege_progress > 0.0:
			lines.append(_stat("공성", "%s %.0f%%" % [
				_nation_name(p.siege_by_nation), p.siege_progress]))

	var laws := PackedStringArray()
	for category in Law.CATEGORIES:
		var law: Law = n.laws.get(category)
		if law != null:
			laws.append("%s: %s" % [category, law.id])
	lines.append("")
	lines.append("[color=#8fa2b5]법률[/color]")
	lines.append(" · ".join(laws))

	var advisors := PackedStringArray()
	for cid in n.characters:
		var c: Character = world.characters[cid]
		if c.is_alive and c.role != Character.Role.NONE and c.role != Character.Role.GENERAL:
			advisors.append("%s · %s %.0f" % [
				c.name, Character.role_name(c.role), c.score_for(c.role)])
		if advisors.size() >= 5:
			break
	if not advisors.is_empty():
		lines.append("")
		lines.append("[color=#8fa2b5]핵심 고문[/color]")
		lines.append_array(advisors)
	nation_detail.text = "\n".join(lines)


## [table] BBCode 는 한 번 파싱에 수십 ms 가 든다. 매 턴 갱신하는 패널에는 쓰지 않는다.
func _stat(label: String, value: String) -> String:
	return "[color=#8fa2b5]%s[/color]  %s" % [label, value]


func _refresh_market_list(force: bool) -> void:
	if world == null:
		return
	if not force and world.turn - _last_market_refresh_turn < 5:
		_refresh_market_detail()
		return
	_last_market_refresh_turn = world.turn
	var kind := _current_market_kind()
	var wanted := int(market_selected.get(kind, -1))
	market_list.clear()
	var assets := _market_assets(kind)
	var selected_index := -1
	for asset_id in assets:
		var id := int(asset_id)
		var held := world.portfolio.quantity(kind, id)
		var marker := "◆ " if held > 0 else ""
		var index := market_list.add_item(marker + _asset_row(kind, id))
		market_list.set_item_metadata(index, id)
		if id == wanted:
			selected_index = index
	if selected_index < 0 and market_list.item_count > 0:
		selected_index = 0
		wanted = int(market_list.get_item_metadata(0))
		market_selected[kind] = wanted
	if selected_index >= 0:
		market_list.select(selected_index)
		market_list.ensure_current_is_visible()
	_refresh_market_detail()


func _refresh_market_detail() -> void:
	if world == null:
		return
	var kind := _current_market_kind()
	var id := int(market_selected.get(kind, -1))
	if id < 0:
		market_detail.text = "거래할 상품이 없습니다."
		return
	var held := world.portfolio.quantity(kind, id)
	var value := Market.price(world, kind, id)
	match kind:
		Market.AssetKind.BOND:
			if id >= world.nations.size():
				return
			var n: Nation = world.nations[id]
			market_detail.text = "[b]%s 국채[/b]  [color=#f2b84b]%s[/color]\n" % [
				_nation_name(id), _money(value)]
			market_detail.text += "신용 %.0f%% · 인플레 %+.1f%% · 표면 수익 %.1f%%\n보유 %d주" % [
				n.credit_rating * 100.0, n.inflation * 100.0,
				Credit.interest_rate(n) * 100.0, held]
		Market.AssetKind.PROVINCE:
			if id >= world.provinces.size():
				return
			var p: Province = world.provinces[id]
			market_detail.text = "[b]프로빈스 %03d 지분[/b]  [color=#f2b84b]%s[/color]\n" % [
				id, _money(value)]
			market_detail.text += "%s · GDP %s · 성장 여력 %+.1f%%\n불만 %.0f%% · 보급 %.0f%% · 보유 %d주" % [
				_nation_name(p.owner_nation), _short(p.gdp), Market.growth_headroom(p) * 100.0,
				p.unrest * 100.0, p.supply * 100.0, held]
		Market.AssetKind.CHARACTER:
			if id >= world.characters.size():
				return
			var c: Character = world.characters[id]
			market_detail.text = "[b]%s 후원[/b]  [color=#f2b84b]%s[/color]\n" % [c.name, _money(value)]
			market_detail.text += "%s · %s · 최적 %s\n지능 %.0f · 사교 %.0f · 창의 %.0f · 건강 %.0f · 보유 %d주" % [
				_nation_name(c.nation_id), Character.role_name(c.role), Character.role_name(c.best_role()),
				c.intelligence, c.charisma, c.creativity, c.health, held]


func _refresh_portfolio() -> void:
	var lines := PackedStringArray()
	for kind in [Market.AssetKind.BOND, Market.AssetKind.PROVINCE, Market.AssetKind.CHARACTER]:
		var book := world.portfolio.holdings(kind)
		var ids: Array = book.keys()
		ids.sort()
		for asset_id in ids:
			var id := int(asset_id)
			var units := int(book[asset_id])
			var value := Market.price(world, kind, id) * units
			lines.append("%s ×%d  %s" % [_asset_name(kind, id), units, _money(value)])
	var body := "보유 자산 없음" if lines.is_empty() else "\n".join(lines.slice(0, 8))
	portfolio_detail.text = "[color=#8fa2b5]포트폴리오 · 누적 배당 %s[/color]\n%s" % [
		_money(world.portfolio.total_dividends), body]


## 140줄을 매번 다시 파싱하지 않고 새 줄만 덧붙인다. 상한을 넘을 때만 재구성한다.
func _append_log(line: String) -> void:
	event_lines.append(line)
	event_log.append_text(line + "\n")
	if event_lines.size() > LOG_MAX_LINES:
		event_lines = event_lines.slice(event_lines.size() - LOG_KEEP_LINES)
		event_log.text = "\n".join(event_lines) + "\n"


func _refresh_chart() -> void:
	if world == null:
		return
	if not chart.is_visible_in_tree():
		return
	if tabs.current_tab == 1:
		chart.set_data("포트폴리오 추이", [
			{"name": "순자산", "color": GOOD, "values": world.portfolio.net_worth_history},
			{"name": "현금", "color": BLUE, "values": world.portfolio.cash_history},
		])
	elif tabs.current_tab == 2:
		chart.set_data("세계 GDP", [
			{"name": "세계 GDP", "color": ACCENT, "values": world_gdp_history},
		])
	else:
		var gdp: Array = nation_gdp_history.get(selected_nation, [])
		var debt: Array = nation_debt_history.get(selected_nation, [])
		chart.set_data("%s 경제" % _nation_name(selected_nation), [
			{"name": "GDP", "color": GOOD, "values": gdp},
			{"name": "부채", "color": BAD, "values": debt},
		])


func _record_history() -> void:
	if world == null:
		return
	world_gdp_history.append(world.world_gdp())
	if world_gdp_history.size() > HISTORY_CAP:
		world_gdp_history = world_gdp_history.slice(HISTORY_TRIM)
	for n in world.nations:
		if not nation_gdp_history.has(n.id):
			nation_gdp_history[n.id] = ([] as Array[float])
			nation_debt_history[n.id] = ([] as Array[float])
		var gdp: Array = nation_gdp_history[n.id]
		var debt: Array = nation_debt_history[n.id]
		gdp.append(n.gdp)
		debt.append(n.debt)
		if gdp.size() > HISTORY_CAP:
			nation_gdp_history[n.id] = gdp.slice(HISTORY_TRIM)
			nation_debt_history[n.id] = debt.slice(HISTORY_TRIM)


func _process_new_events() -> void:
	while event_cursor < world.events.size():
		var event: Dictionary = world.events[event_cursor]
		event_cursor += 1
		if str(event.get("kind", "")) == "battle_resolved":
			_note_battle(event)
			continue
		var line := _event_text(event)
		if line.is_empty():
			continue
		_append_log(line)
	_close_finished_battles()
	# 소비가 끝난 이벤트는 버린다. 배치 도구는 실행이 끝난 뒤 전체 배열을 읽으므로 무관하다.
	if event_cursor >= EVENT_TRIM_AT:
		world.events = world.events.slice(event_cursor)
		event_cursor = 0


## battle_resolved 는 교전중인 프로빈스마다 매 턴 뜬다. 그대로 찍으면 기록이 잠기므로
## 프로빈스별로 개시·종료 두 줄만 남긴다.
func _note_battle(event: Dictionary) -> void:
	var pid := int(event.get("province", -1))
	if pid < 0:
		return
	var turn := int(event.get("turn", world.turn))
	var na := int(event.get("nation", -1))
	var nb := int(event.get("nation_b", -1))
	if not _active_battles.has(pid):
		_append_log(_prefix(turn) + "[color=#ff5964]전투[/color]  %s · %s ↔ %s" % [
			_province_link(pid), _nation_link(na), _nation_link(nb)])
		_active_battles[pid] = {"start": turn, "losses": {}, "power": {}}
	var battle: Dictionary = _active_battles[pid]
	battle["last"] = turn
	# 어느 쪽이 army_a 로 잡히는지는 턴마다 바뀐다. 국가 id 로 쌓아야 누적이 맞는다.
	var losses: Dictionary = battle["losses"]
	losses[na] = int(losses.get(na, 0)) + int(event.get("casualties_a", 0))
	losses[nb] = int(losses.get(nb, 0)) + int(event.get("casualties_b", 0))
	var power: Dictionary = battle["power"]
	power[na] = float(event.get("power_a", 0.0))
	power[nb] = float(event.get("power_b", 0.0))


func _close_finished_battles() -> void:
	var pids: Array = _active_battles.keys()
	pids.sort()
	for pid in pids:
		var battle: Dictionary = _active_battles[pid]
		# 이벤트의 turn 은 증가 전 값이다. 직전 턴까지 싸웠으면 아직 진행중이다.
		if int(battle["last"]) >= world.turn - 1:
			continue
		_active_battles.erase(pid)
		_append_log(_prefix(world.turn) + "전투 종료  %s" % _province_link(int(pid)))


func _on_battle_selected(province_id: int) -> void:
	battle_province = province_id
	battle_panel.visible = true
	_refresh_battle()


func _close_battle() -> void:
	battle_province = -1
	battle_panel.visible = false


## 교전 프로빈스에 서 있는 국가별 합계. 사기·보급은 병력 가중 평균이라 나눠 쓴다.
func _battle_sides(pid: int) -> Dictionary:
	var sides := {}
	for army_id: int in world.armies_at(pid):
		var army: Army = world.armies[army_id]
		if not army.is_alive:
			continue
		var slot: Dictionary = sides.get(army.nation_id,
			{"troops": 0, "morale": 0.0, "supply": 0.0})
		slot["troops"] = int(slot["troops"]) + army.troops
		slot["morale"] = float(slot["morale"]) + army.morale * army.troops
		slot["supply"] = float(slot["supply"]) + army.supply_ratio * army.troops
		sides[army.nation_id] = slot
	return sides


## [table] BBCode 는 비싸다(_stat 주석). 막대는 블록 문자로 그린다.
func _bar(share: float) -> String:
	var filled := clampi(int(round(share * 10.0)), 0, 10)
	return "█".repeat(filled) + "░".repeat(10 - filled)


func _refresh_battle() -> void:
	if battle_province < 0:
		return
	if not _active_battles.has(battle_province):
		_close_battle()
		return
	var pid := battle_province
	var battle: Dictionary = _active_battles[pid]
	var p: Province = world.provinces[pid]
	battle_title.text = "⚔ 프로빈스 %03d · %d턴째" % [
		pid, maxi(world.turn - int(battle["start"]), 1)]

	var losses: Dictionary = battle["losses"]
	var power: Dictionary = battle["power"]
	var order: Array = losses.keys()
	order.sort()
	var total := 0.0
	for nid: int in order:
		total += maxf(float(power.get(nid, 0.0)), 0.0)

	var live := _battle_sides(pid)
	var lines := PackedStringArray()
	for nid: int in order:
		var strength := maxf(float(power.get(nid, 0.0)), 0.0)
		var share := strength / total if total > 0.0 else 0.0
		# 막대 색은 지도의 국가색과 같다. 그래야 패널과 마커가 같은 편으로 읽힌다.
		var color: Color = map_renderer._nation_color(nid)
		lines.append("%s  [color=#%s]%s[/color] %d%%" % [
			_nation_name(nid), color.to_html(false), _bar(share),
			int(round(share * 100.0))])
		var slot: Dictionary = live.get(nid, {})
		var troops := int(slot.get("troops", 0))
		var detail := "  [color=#8fa2b5]전력[/color] %s · [color=#8fa2b5]병력[/color] %s" % [
			_short(strength), _short(troops)]
		if troops > 0:
			detail += " · [color=#8fa2b5]사기[/color] %.2f · [color=#8fa2b5]보급[/color] %.2f" % [
				float(slot["morale"]) / troops, float(slot["supply"]) / troops]
		detail += " · [color=#8fa2b5]누적손실[/color] %s" % _short(float(losses[nid]))
		lines.append(detail)

	var terrain_names := ["평지", "구릉", "산악"]
	lines.append(_stat("방어 이점", "%s ×%.2f (%s)" % [
		terrain_names[p.terrain], WarAI.defense_mult(p), _nation_name(p.controller())]))
	if p.siege_by_nation >= 0 and p.siege_progress > 0.0:
		lines.append(_stat("공성", "%s %s %d%%" % [
			_nation_name(p.siege_by_nation), _bar(p.siege_progress / 100.0),
			int(p.siege_progress)]))
	battle_detail.text = "\n".join(lines)


func _event_text(event: Dictionary) -> String:
	var turn := int(event.get("turn", world.turn))
	var prefix := _prefix(turn)
	match str(event.get("kind", "")):
		"war_declared":
			var attacker := int(event.get("nation", -1))
			var defender := int(event.get("defender", -1))
			return prefix + "%s  %s → %s · %s" % [
				_war_link([attacker, defender], "[color=#ef6f7b]전쟁[/color]"),
				_nation_link(attacker), _nation_link(defender),
				War.goal_name(int(event.get("goal", War.Goal.CONQUEST)))]
		"war_joined":
			return prefix + "참전  %s → %s 진영" % [
				_nation_link(int(event.get("nation", -1))),
				str(event.get("side", ""))]
		"war_ended":
			return prefix + "강화  %s ↔ %s · %s" % [
				_nation_link(int(event.get("nation", -1))),
				_nation_link(int(event.get("defender", -1))), str(event.get("reason", ""))]
		"peace_signed":
			return prefix + "[color=#5ab0f2]평화 조약[/color]  %s ↔ %s" % [
				_nation_link(int(event.get("winner", event.get("nation", -1)))),
				_nation_link(int(event.get("loser", event.get("defender", -1))))]
		"alliance_ended":
			return prefix + "동맹 해지  %s ↔ %s · %s" % [
				_nation_link(int(event.get("nation", -1))),
				_nation_link(int(event.get("ally", -1))), str(event.get("reason", ""))]
		"vassalized":
			return prefix + "속국화  %s ← %s" % [
				_nation_link(int(event.get("nation", -1))),
				_nation_link(int(event.get("vassal", -1)))]
		"vassal_released":
			return prefix + "속국 이탈  %s ← %s · %s" % [
				_nation_link(int(event.get("nation", -1))),
				_nation_link(int(event.get("vassal", -1))), str(event.get("reason", ""))]
		"tribute_paid":
			return prefix + "공납  %s → %s · %s" % [
				_nation_link(int(event.get("vassal", -1))),
				_nation_link(int(event.get("nation", -1))),
				_money(float(event.get("amount", 0.0)))]
		"vassal_loyalty_crisis":
			return prefix + "[color=#ef6f7b]속국 충성 위기[/color]  %s · %.0f%%" % [
				_nation_link(int(event.get("vassal", -1))),
				float(event.get("loyalty", 0.0)) * 100.0]
		"independence_war":
			return prefix + "[color=#f2b84b]독립전쟁[/color]  %s → %s" % [
				_nation_link(int(event.get("nation", -1))),
				_nation_link(int(event.get("overlord", -1)))]
		"imperial_authority_changed":
			return prefix + "제국 권위  %s · %.0f%% · %s" % [
				_nation_link(int(event.get("nation", -1))),
				float(event.get("authority", 0.0)) * 100.0,
				str(event.get("reason", ""))]
		"alliance_formed":
			var a := int(event.get("nation", -1))
			var b := int(event.get("ally", -1))
			return prefix + "%s  %s + %s" % [
				_war_link([a, b], "[color=#5ab0f2]동맹[/color]"),
				_nation_link(a), _nation_link(b)]
		"rebellion":
			return prefix + "[color=#f2b84b]반란[/color]  %s ← %s · %s" % [
				_nation_link(int(event.get("rebel", -1))),
				_nation_link(int(event.get("nation", -1))),
				_province_link(int(event.get("province", -1)))]
		"rebel_war_end":
			return prefix + "반란전 종료  %s · %s" % [
				_nation_link(int(event.get("nation", -1))), str(event.get("result", ""))]
		"province_occupied":
			return prefix + "점령  %s ← %s" % [
				_province_link(int(event.get("province", -1))),
				_nation_link(int(event.get("nation", -1)))]
		"province_liberated":
			return prefix + "탈환  %s · %s" % [
				_province_link(int(event.get("province", -1))),
				_nation_link(int(event.get("nation", -1)))]
		"embarked":
			# 치안 분견대는 평시에 섬 주둔지로 계속 오간다. 전쟁 기록이 아니다.
			if bool(event.get("garrison", false)):
				return ""
			return prefix + "[color=#5ab0f2]승선[/color]  %s · %s → %s · %s (%s)" % [
				_nation_link(int(event.get("nation", -1))),
				_province_link(int(event.get("from", -1))),
				_province_link(int(event.get("to", -1))),
				_zone_link(int(event.get("zone", -1))),
				_short(float(event.get("troops", 0)))]
		"amphibious_landing":
			if bool(event.get("garrison", false)):
				return ""
			return prefix + "[color=#5ab0f2]상륙[/color]  %s · %s · %s (%s)" % [
				_nation_link(int(event.get("nation", -1))),
				_province_link(int(event.get("to", -1))),
				_zone_link(int(event.get("zone", -1))),
				_short(float(event.get("troops", 0)))]
		"convoy_sunk":
			return prefix + "[color=#ff5964]수송선단 격침[/color]  %s · %s (%s)" % [
				_nation_link(int(event.get("nation", -1))),
				_zone_link(int(event.get("zone", -1))),
				_short(float(event.get("troops", 0)))]
		"naval_control_changed":
			var holder := int(event.get("nation", -1))
			if holder < 0:
				return prefix + "제해권 상실  %s · %s" % [
					_nation_link(int(event.get("lost", -1))),
					_zone_link(int(event.get("zone", -1)))]
			return prefix + "제해권  %s · %s" % [
				_nation_link(holder), _zone_link(int(event.get("zone", -1)))]
		"naval_battle":
			return prefix + "[color=#5ab0f2]해전[/color]  %s ↔ %s · %s" % [
				_nation_link(int(event.get("nation", -1))),
				_nation_link(int(event.get("nation_b", event.get("enemy", -1)))),
				_zone_link(int(event.get("zone", -1)))]
		"province_ceded":
			return prefix + "영토 할양  %s → %s" % [
				_province_link(int(event.get("province", -1))),
				_nation_link(int(event.get("nation", -1)))]
		"province_assimilated":
			return prefix + "문화 동화  %s · %s → %s" % [
				_province_link(int(event.get("province", -1))),
				Culture.NAMES[int(event.get("from_culture", 0))],
				Culture.NAMES[int(event.get("culture", 0))]]
		"national_default":
			return prefix + "[color=#ef6f7b]국가 파산[/color]  %s" % \
				_nation_link(int(event.get("nation", -1)))
		"city_founded":
			return prefix + "[color=#5dd39e]도시 탄생[/color]  %s · %s" % [
				_nation_link(int(event.get("nation", -1))),
				_province_link(int(event.get("province", -1)))]
		"character_died":
			if int(event.get("role", Character.Role.NONE)) != Character.Role.NONE:
				return prefix + "인물 사망  %s · %s" % [str(event.get("name", "")),
					Character.role_name(int(event.get("role", Character.Role.NONE)))]
		"market_trade":
			var side := "매수" if event.get("side", "") == "buy" else "매도"
			return prefix + "[color=#5dd39e]%s[/color]  %s ×%d @ %s" % [side,
				_asset_name(int(event.get("asset_kind", 0)), int(event.get("asset", -1))),
				int(event.get("units", 0)), _money(float(event.get("price", 0.0)))]
	return ""


func _prefix(turn: int) -> String:
	return "[color=#60778c]T%03d[/color]  " % turn


## 기록의 국가·지역은 전부 지도로 가는 링크다. "어디 국가인지"를 글로 설명하지 않는다.
func _nation_link(nation_id: int) -> String:
	if nation_id < 0 or world == null or nation_id >= world.nations.size():
		return "—"
	return "[url=n:%d][color=#9ec8ea]%s[/color][/url]" % [nation_id, _nation_name(nation_id)]


func _province_link(province_id: int) -> String:
	if province_id < 0:
		return "—"
	return "[url=p:%d][color=#9ec8ea]프로빈스 %03d[/color][/url]" % [province_id, province_id]


func _zone_link(zone_id: int) -> String:
	if zone_id < 0:
		return "—"
	return "[url=z:%d][color=#9ec8ea]해역 %03d[/color][/url]" % [zone_id, zone_id]


func _war_link(nation_ids: Array, label: String) -> String:
	var ids := PackedStringArray()
	for id in nation_ids:
		if int(id) >= 0:
			ids.append(str(int(id)))
	if ids.is_empty():
		return label
	return "[url=w:%s]%s[/url]" % [",".join(ids), label]


func _on_log_meta_clicked(meta: Variant) -> void:
	_jump_to(str(meta))


func _on_log_meta_hover(meta: Variant) -> void:
	var ids := _nations_of_meta(str(meta))
	if not ids.is_empty():
		map_renderer.highlight_nations(ids, 0.0)


func _on_log_meta_hover_end(_meta: Variant) -> void:
	map_renderer.clear_highlight()


func _nations_of_meta(meta: String) -> Array[int]:
	var out: Array[int] = []
	if world == null:
		return out
	var parts := meta.split(":")
	if parts.size() != 2:
		return out
	match parts[0]:
		"n":
			out.append(int(parts[1]))
		"w":
			for token in parts[1].split(","):
				out.append(int(token))
		"p":
			var pid := int(parts[1])
			if pid >= 0 and pid < world.provinces.size():
				var holder := world.provinces[pid].controller()
				if holder >= 0:
					out.append(holder)
	return out


## 기록·검색에서 고른 대상으로 지도를 옮기고 몇 초간 강조한다.
func _jump_to(meta: String) -> void:
	if world == null:
		return
	var parts := meta.split(":")
	if parts.size() != 2:
		return
	var highlight := _nations_of_meta(meta)
	match parts[0]:
		"p":
			var pid := int(parts[1])
			if pid < 0 or pid >= world.provinces.size():
				return
			_on_province_selected(pid)
			map_renderer.focus_province(pid, true)
		"n":
			var nation_id := int(parts[1])
			if nation_id < 0 or nation_id >= world.nations.size():
				return
			_focus_nation(nation_id)
		"z":
			map_renderer.focus_zone(int(parts[1]))
		"w":
			if highlight.is_empty():
				return
			_focus_nation(highlight[0])
	if not highlight.is_empty():
		map_renderer.highlight_nations(highlight)


func _focus_nation(nation_id: int) -> void:
	var n: Nation = world.nations[nation_id]
	var target := n.capital
	if target < 0 or target >= world.provinces.size():
		target = n.provinces[0] if not n.provinces.is_empty() else -1
	if target < 0:
		return
	_on_province_selected(target)
	map_renderer.focus_province(target, true)


func _open_search() -> void:
	if world == null:
		return
	search_panel.visible = true
	search_input.text = ""
	search_input.grab_focus()
	_on_search_changed("")


func _close_search() -> void:
	if search_panel == null or not search_panel.visible:
		return
	search_panel.visible = false
	search_input.release_focus()


func _on_search_changed(query: String) -> void:
	search_list.clear()
	if world == null:
		return
	var needle := query.strip_edges().to_lower()
	for n in world.nations:
		if not n.is_alive:
			continue
		var label := _nation_name(n.id)
		if not needle.is_empty() and not label.to_lower().contains(needle):
			continue
		var index := search_list.add_item("%s · 영토 %d" % [label, n.provinces.size()])
		search_list.set_item_metadata(index, "n:%d" % n.id)
		if search_list.item_count >= 20:
			break
	if needle.is_valid_int():
		var pid := int(needle)
		if pid >= 0 and pid < world.provinces.size():
			var index := search_list.add_item("프로빈스 %03d · %s" % [
				pid, _nation_name(world.provinces[pid].controller())])
			search_list.set_item_metadata(index, "p:%d" % pid)


func _on_search_submitted(_text: String) -> void:
	if search_list.item_count == 0:
		return
	_jump_to(str(search_list.get_item_metadata(0)))
	_close_search()


func _on_search_picked(index: int) -> void:
	_jump_to(str(search_list.get_item_metadata(index)))
	_close_search()


func _market_assets(kind: int) -> Array[int]:
	var out: Array[int] = []
	match kind:
		Market.AssetKind.BOND:
			for n in world.nations:
				if n.is_alive:
					out.append(n.id)
		Market.AssetKind.PROVINCE:
			for p in world.provinces:
				out.append(p.id)
		Market.AssetKind.CHARACTER:
			for c in world.characters:
				if c.is_alive:
					out.append(c.id)
	# 비교자에서 매번 가격을 다시 구하면 O(n log n) 번 계산된다. 한 번만 구해 둔다.
	var price := {}
	for asset_id in out:
		price[asset_id] = Market.price(world, kind, asset_id)
	out.sort_custom(func(a: int, b: int) -> bool:
		var pa: float = price[a]
		var pb: float = price[b]
		if is_equal_approx(pa, pb):
			return a < b
		return pa > pb)
	return out


func _asset_row(kind: int, asset_id: int) -> String:
	return "%s    %s" % [_asset_name(kind, asset_id), _money(Market.price(world, kind, asset_id))]


func _asset_name(kind: int, asset_id: int) -> String:
	match kind:
		Market.AssetKind.BOND:
			return "%s 국채" % _nation_name(asset_id)
		Market.AssetKind.PROVINCE:
			return "프로빈스 %03d" % asset_id
		Market.AssetKind.CHARACTER:
			if asset_id >= 0 and asset_id < world.characters.size():
				return world.characters[asset_id].name
	return "알 수 없는 자산"


func _best_character_for(nation_id: int) -> int:
	if world == null or nation_id < 0 or nation_id >= world.nations.size():
		return -1
	var best := -1
	var best_price := -1.0
	for cid in world.nations[nation_id].characters:
		var c: Character = world.characters[cid]
		if not c.is_alive:
			continue
		var value := Market.character_stake_price(c, world.turn)
		if value > best_price:
			best_price = value
			best = cid
	return best


func _current_market_kind() -> int:
	return market_category.get_item_id(market_category.selected)


func _nation_name(nation_id: int) -> String:
	if world == null or nation_id < 0 or nation_id >= world.nations.size():
		return "—"
	var n: Nation = world.nations[nation_id]
	if n.name.is_empty():
		return "%s #%02d" % [Culture.NAMES[n.culture], n.id]
	return "%s (%s)" % [n.name, Culture.NAMES[n.culture]]


func _short(value: float) -> String:
	var absolute := absf(value)
	if absolute >= 1000000000.0:
		return "%.2fB" % (value / 1000000000.0)
	if absolute >= 1000000.0:
		return "%.2fM" % (value / 1000000.0)
	if absolute >= 1000.0:
		return "%.1fK" % (value / 1000.0)
	return "%.1f" % value


func _money(value: float) -> String:
	return "¤%s" % _short(value)


func _label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _button(value: String) -> Button:
	var button := Button.new()
	button.text = value
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_stylebox_override("normal", _panel_style(Color("182638"), 5, true))
	button.add_theme_stylebox_override("hover", _panel_style(Color("22364d"), 5, true))
	button.add_theme_stylebox_override("pressed", _panel_style(Color("31465d"), 5, true))
	return button


func _panel_style(color: Color, radius: int, outlined: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	if outlined:
		style.border_color = BORDER
		style.set_border_width_all(1)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	return style


func _v_separator() -> VSeparator:
	var separator := VSeparator.new()
	separator.custom_minimum_size.x = 8
	separator.add_theme_color_override("separator", BORDER)
	return separator


func _set_margins(container: MarginContainer, left: int, top: int,
		right: int, bottom: int) -> void:
	container.add_theme_constant_override("margin_left", left)
	container.add_theme_constant_override("margin_top", top)
	container.add_theme_constant_override("margin_right", right)
	container.add_theme_constant_override("margin_bottom", bottom)
