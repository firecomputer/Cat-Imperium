extends CanvasLayer

const PANEL_WIDTH := 450.0
const MUTED := Color("#9cabc2")
const GOOD := Color("#7bd88f")
const BAD := Color("#ff7b72")

var selected_province_id := 0
var _refreshing := false
var _economy_rows: Dictionary = {}

var _date_label: Label
var _treasury_label: Label
var _gdp_label: Label
var _tax_income_label: Label
var _living_standard_label: Label
var _factory_label: Label
var _leader_portrait: TextureRect
var _leader_name: Label
var _leader_trait: Label
var _consumer_slider: HSlider
var _consumer_value: Label
var _consumption_tax_slider: HSlider
var _consumption_tax_value: Label
var _property_tax_slider: HSlider
var _property_tax_value: Label
var _economy_scroll: ScrollContainer
var _construction_scroll: ScrollContainer
var _province_title: Label
var _province_detail: Label
var _project_detail: Label
var _active_projects_label: Label
var _build_buttons: Dictionary = {}
var _cancel_button: Button
var _status_label: Label


func _ready() -> void:
	layer = 10
	_build_ui()
	_connect_signals()
	if GameState.is_initialized:
		_refresh_all()
	else:
		GameState.initialized.connect(_refresh_all, CONNECT_ONE_SHOT)


func _build_ui() -> void:
	var root_control := Control.new()
	root_control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root_control)

	var top_panel := PanelContainer.new()
	top_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top_panel.offset_bottom = 54.0
	root_control.add_child(top_panel)
	var top_bar := HBoxContainer.new()
	top_bar.add_theme_constant_override("separation", 10)
	top_panel.add_child(top_bar)
	_date_label = _new_label("1턴 | 2026-01-01", 135)
	_treasury_label = _new_label("국고 -", 105)
	_gdp_label = _new_label("실질 GDP -", 125)
	_tax_income_label = _new_label("세수 -", 205)
	_living_standard_label = _new_label("생활수준 -", 100)
	_factory_label = _new_label("민간공장 -", 205)
	for label: Label in [_date_label, _treasury_label, _gdp_label, _tax_income_label, _living_standard_label, _factory_label]:
		top_bar.add_child(label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_bar.add_child(spacer)
	var end_turn := Button.new()
	end_turn.text = "턴 종료"
	end_turn.pressed.connect(_on_end_turn)
	top_bar.add_child(end_turn)
	var save_button := Button.new()
	save_button.text = "저장"
	save_button.pressed.connect(_on_save)
	top_bar.add_child(save_button)
	var load_button := Button.new()
	load_button.text = "불러오기"
	load_button.pressed.connect(_on_load)
	top_bar.add_child(load_button)

	var leader_panel := PanelContainer.new()
	leader_panel.position = Vector2(8, 62)
	leader_panel.size = Vector2(250, 138)
	root_control.add_child(leader_panel)
	var leader_box := HBoxContainer.new()
	leader_box.add_theme_constant_override("separation", 12)
	leader_panel.add_child(leader_box)
	_leader_portrait = TextureRect.new()
	_leader_portrait.custom_minimum_size = Vector2(96, 112)
	_leader_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_leader_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	leader_box.add_child(_leader_portrait)
	var leader_text := VBoxContainer.new()
	leader_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	leader_text.alignment = BoxContainer.ALIGNMENT_CENTER
	leader_box.add_child(leader_text)
	_leader_name = _new_label("고양이 지도자", 120)
	_leader_name.add_theme_font_size_override("font_size", 18)
	_leader_trait = _new_label("", 120)
	_leader_trait.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_leader_trait.add_theme_color_override("font_color", MUTED)
	leader_text.add_child(_leader_name)
	leader_text.add_child(_leader_trait)

	var right_panel := PanelContainer.new()
	right_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	right_panel.offset_left = -PANEL_WIDTH - 8.0
	right_panel.offset_top = 62.0
	right_panel.offset_right = -8.0
	right_panel.offset_bottom = -8.0
	root_control.add_child(right_panel)
	var right_box := VBoxContainer.new()
	right_box.add_theme_constant_override("separation", 8)
	right_panel.add_child(right_box)
	var tabs := HBoxContainer.new()
	right_box.add_child(tabs)
	var economy_tab := Button.new()
	economy_tab.text = "경제"
	economy_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	economy_tab.pressed.connect(_show_economy)
	tabs.add_child(economy_tab)
	var construction_tab := Button.new()
	construction_tab.text = "건설"
	construction_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	construction_tab.pressed.connect(_show_construction)
	tabs.add_child(construction_tab)

	_economy_scroll = ScrollContainer.new()
	_economy_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_box.add_child(_economy_scroll)
	_build_economy_content()
	_construction_scroll = ScrollContainer.new()
	_construction_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_construction_scroll.visible = false
	right_box.add_child(_construction_scroll)
	_build_construction_content()

	var status_panel := PanelContainer.new()
	status_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	status_panel.offset_left = 266.0
	status_panel.offset_right = -PANEL_WIDTH - 16.0
	status_panel.offset_top = -36.0
	status_panel.offset_bottom = -8.0
	root_control.add_child(status_panel)
	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status_label.text = "경제 탭에서 생산을 배정하거나 지도에서 프로빈스를 선택하세요."
	status_panel.add_child(_status_label)


func _build_economy_content() -> void:
	var content := VBoxContainer.new()
	content.custom_minimum_size.x = PANEL_WIDTH - 36.0
	content.add_theme_constant_override("separation", 6)
	_economy_scroll.add_child(content)
	var policy_title := _new_label("경제 정책", 0)
	policy_title.add_theme_font_size_override("font_size", 18)
	content.add_child(policy_title)
	var consumer_line := HBoxContainer.new()
	content.add_child(consumer_line)
	consumer_line.add_child(_new_label("소비재 비율", 88))
	_consumer_slider = HSlider.new()
	_consumer_slider.min_value = 0
	_consumer_slider.max_value = 100
	_consumer_slider.step = 1
	_consumer_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_consumer_slider.value_changed.connect(_on_consumer_ratio_changed)
	consumer_line.add_child(_consumer_slider)
	_consumer_value = _new_label("40%", 45)
	consumer_line.add_child(_consumer_value)
	var consumption_tax_line := HBoxContainer.new()
	content.add_child(consumption_tax_line)
	consumption_tax_line.add_child(_new_label("소비세율", 88))
	_consumption_tax_slider = HSlider.new()
	_consumption_tax_slider.min_value = 0
	_consumption_tax_slider.max_value = 50
	_consumption_tax_slider.step = 1
	_consumption_tax_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_consumption_tax_slider.value_changed.connect(_on_consumption_tax_rate_changed)
	consumption_tax_line.add_child(_consumption_tax_slider)
	_consumption_tax_value = _new_label("20%", 45)
	consumption_tax_line.add_child(_consumption_tax_value)
	var property_tax_line := HBoxContainer.new()
	content.add_child(property_tax_line)
	property_tax_line.add_child(_new_label("재산세율", 88))
	_property_tax_slider = HSlider.new()
	_property_tax_slider.min_value = 0
	_property_tax_slider.max_value = 50
	_property_tax_slider.step = 1
	_property_tax_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_property_tax_slider.value_changed.connect(_on_property_tax_rate_changed)
	property_tax_line.add_child(_property_tax_slider)
	_property_tax_value = _new_label("20%", 45)
	property_tax_line.add_child(_property_tax_value)

	var separator := HSeparator.new()
	content.add_child(separator)
	var table_title := _new_label("품목 시장", 0)
	table_title.add_theme_font_size_override("font_size", 18)
	content.add_child(table_title)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	content.add_child(header)
	for specification: Array in [
		["품목", 78], ["가격", 52], ["재고", 52], ["수요", 45],
		["생산", 45], ["무역", 52], ["배정", 80],
	]:
		var label := _new_label(str(specification[0]), int(specification[1]))
		label.add_theme_color_override("font_color", MUTED)
		header.add_child(label)
	for item_id: StringName in GameState.item_order:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		content.add_child(row)
		var name_label := _new_label("-", 78)
		var price_label := _new_label("-", 52)
		var inventory_label := _new_label("-", 52)
		var demand_label := _new_label("-", 45)
		var production_label := _new_label("-", 45)
		var trade_label := _new_label("-", 52)
		for label: Label in [name_label, price_label, inventory_label, demand_label, production_label, trade_label]:
			row.add_child(label)
		var allocation := HBoxContainer.new()
		allocation.custom_minimum_size.x = 80
		row.add_child(allocation)
		var minus := Button.new()
		minus.text = "−"
		minus.custom_minimum_size.x = 24
		minus.pressed.connect(_on_adjust_allocation.bind(item_id, -1))
		allocation.add_child(minus)
		var allocation_label := _new_label("0", 22)
		allocation_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		allocation.add_child(allocation_label)
		var plus := Button.new()
		plus.text = "+"
		plus.custom_minimum_size.x = 24
		plus.pressed.connect(_on_adjust_allocation.bind(item_id, 1))
		allocation.add_child(plus)
		_economy_rows[item_id] = {
			"name": name_label,
			"price": price_label,
			"inventory": inventory_label,
			"demand": demand_label,
			"production": production_label,
			"trade": trade_label,
			"allocation": allocation_label,
			"minus": minus,
			"plus": plus,
		}


func _build_construction_content() -> void:
	var content := VBoxContainer.new()
	content.custom_minimum_size.x = PANEL_WIDTH - 36.0
	content.add_theme_constant_override("separation", 10)
	_construction_scroll.add_child(content)
	_province_title = _new_label("프로빈스를 선택하세요", 0)
	_province_title.add_theme_font_size_override("font_size", 20)
	content.add_child(_province_title)
	_province_detail = _new_label("지도에서 건설할 한국 프로빈스를 클릭하세요.", 0)
	_province_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_province_detail)
	_project_detail = _new_label("", 0)
	_project_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_project_detail)
	for building: Dictionary in [
		{"id": GameState.BUILDING_CIVILIAN, "name": "민간공장", "cost": "₩5,000 | 목30 콘40 철20 유10"},
		{"id": GameState.BUILDING_MILITARY, "name": "군수공장", "cost": "₩7,500 | 목20 콘40 철40 유10"},
		{"id": GameState.BUILDING_DOCKYARD, "name": "조선소", "cost": "₩8,000 | 목40 콘30 철30 유10"},
	]:
		var button := Button.new()
		button.text = "%s 건설\n%s · 100일" % [building.name, building.cost]
		button.custom_minimum_size.y = 58
		button.pressed.connect(_on_start_construction.bind(building.id))
		content.add_child(button)
		_build_buttons[building.id] = button
	_cancel_button = Button.new()
	_cancel_button.text = "선택 프로빈스 건설 취소 (환불 없음)"
	_cancel_button.pressed.connect(_on_cancel_construction)
	content.add_child(_cancel_button)
	content.add_child(HSeparator.new())
	var projects_title := _new_label("국가 건설 현황", 0)
	projects_title.add_theme_font_size_override("font_size", 18)
	content.add_child(projects_title)
	_active_projects_label = _new_label("진행 중인 건설이 없습니다.", 0)
	_active_projects_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_active_projects_label)


func _connect_signals() -> void:
	GameState.turn_completed.connect(_on_turn_completed)
	GameState.country_economy_changed.connect(_on_country_changed)
	GameState.construction_changed.connect(_on_construction_changed)
	GameState.game_loaded.connect(_refresh_all)
	var main := get_parent()
	if main.has_signal("province_selected"):
		main.province_selected.connect(_on_province_selected)
	if main.has_signal("province_selection_cleared"):
		main.province_selection_cleared.connect(_on_province_selection_cleared)


func _refresh_all() -> void:
	var country = GameState.get_player_country()
	if country == null:
		return
	_refreshing = true
	_date_label.text = "%d턴 | %s" % [GameState.current_turn, GameState.get_date_string()]
	_treasury_label.text = "국고 ₩%s" % _compact_number(country.treasury)
	_gdp_label.text = "실질 GDP ₩%s" % _compact_number(country.real_gdp)
	_tax_income_label.text = "세수 ₩%s (소 %s / 재 %s)" % [
		_compact_number(float(country.weekly_stats.get("tax_revenue", 0.0))),
		_compact_number(float(country.weekly_stats.get("consumption_tax_revenue", 0.0))),
		_compact_number(float(country.weekly_stats.get("property_tax_revenue", 0.0))),
	]
	_living_standard_label.text = "생활수준 %.2f" % country.standard_of_living
	_factory_label.text = "민간 %d: 소비 %d / 건설 %d / 무역 %d" % [
		country.civilian_factories,
		country.get_effective_consumer_factories(),
		country.get_active_construction_count(),
		country.get_trade_factories(),
	]
	_leader_name.text = country.leader_name
	_leader_trait.text = "%s\n%s" % [country.display_name, country.leader_trait]
	_leader_portrait.modulate = country.leader_color
	if not country.leader_portrait.is_empty():
		_leader_portrait.texture = _load_svg_texture(country.leader_portrait)
	_consumer_slider.value = country.consumer_ratio
	_consumer_value.text = "%d%%" % country.consumer_ratio
	_consumption_tax_slider.value = country.consumption_tax_rate * 100.0
	_consumption_tax_value.text = "%d%%" % roundi(country.consumption_tax_rate * 100.0)
	_property_tax_slider.value = country.property_tax_rate * 100.0
	_property_tax_value.text = "%d%%" % roundi(country.property_tax_rate * 100.0)
	for item_id: StringName in GameState.item_order:
		var item = GameState.get_item(item_id)
		var row: Dictionary = _economy_rows[item_id]
		var stats: Dictionary = country.weekly_stats.get(item_id, {})
		row.name.text = item.display_name
		row.price.text = "%.1f" % float(country.prices.get(item_id, item.base_price))
		row.inventory.text = "%.1f" % float(country.inventory.get(item_id, 0.0))
		row.demand.text = "%.1f" % float(stats.get("demand", 0.0))
		row.production.text = "+%.1f" % float(stats.get("produced", 0.0))
		var net_trade := float(stats.get("imported", 0.0)) - float(stats.get("exported", 0.0))
		row.trade.text = "%+.1f" % net_trade
		row.trade.add_theme_color_override("font_color", GOOD if net_trade >= 0.0 else BAD)
		var allocation := int(country.production_allocations.get(item_id, 0))
		row.allocation.text = str(allocation)
		row.minus.disabled = allocation <= 0
		row.plus.disabled = country.get_allocated_consumer_factories() >= country.get_effective_consumer_factories()
	_refreshing = false
	_refresh_construction()


func _refresh_construction() -> void:
	var country = GameState.get_player_country()
	if country == null:
		return
	var active_lines: Array[String] = []
	for project: Dictionary in country.construction_projects:
		active_lines.append("#%d · %s · %d일 남음" % [
			int(project.province_id),
			_building_name(StringName(project.building_type)),
			int(project.remaining_days),
		])
	_active_projects_label.text = "진행 중인 건설이 없습니다." if active_lines.is_empty() else "\n".join(active_lines)
	if selected_province_id <= 0:
		_province_title.text = "프로빈스를 선택하세요"
		_province_detail.text = "지도에서 건설할 한국 프로빈스를 클릭하세요."
		_project_detail.text = ""
		_set_build_buttons_disabled(true)
		_cancel_button.disabled = true
		return
	var province: Dictionary = ProvinceMapDB.get_province(selected_province_id)
	var owner = GameState.get_country(int(province.get("country_id", 0)))
	var owner_name := str(province.get("country_name_ko", province.get("country_name", "알 수 없음")))
	_province_title.text = "%s 프로빈스 #%d" % [owner_name, selected_province_id]
	var coast := "해안" if bool(province.get("water_border", false)) else "내륙"
	var buildings: Dictionary = country.province_buildings.get(selected_province_id, {})
	_province_detail.text = "%s · 면적 %.0f㎢\n건물: 민간 %d / 군수 %d / 조선소 %d" % [
		coast,
		float(province.get("area_km2", 0.0)),
		int(buildings.get(GameState.BUILDING_CIVILIAN, 0)),
		int(buildings.get(GameState.BUILDING_MILITARY, 0)),
		int(buildings.get(GameState.BUILDING_DOCKYARD, 0)),
	]
	var selected_project: Dictionary = {}
	for project: Dictionary in country.construction_projects:
		if int(project.province_id) == selected_province_id:
			selected_project = project
			break
	var is_owned: bool = owner != null and owner.id == country.id
	if not is_owned:
		_project_detail.text = "다른 국가의 프로빈스에는 건설할 수 없습니다."
	elif not selected_project.is_empty():
		_project_detail.text = "%s 건설 중 · %d일 남음" % [
			_building_name(StringName(selected_project.building_type)),
			int(selected_project.remaining_days),
		]
	else:
		_project_detail.text = "건설 슬롯 사용 가능"
	_set_build_buttons_disabled(not is_owned or not selected_project.is_empty())
	_build_buttons[GameState.BUILDING_DOCKYARD].disabled = (
		_build_buttons[GameState.BUILDING_DOCKYARD].disabled
		or not bool(province.get("water_border", false))
	)
	_cancel_button.disabled = selected_project.is_empty()


func _set_build_buttons_disabled(disabled: bool) -> void:
	for button: Button in _build_buttons.values():
		button.disabled = disabled


func _on_end_turn() -> void:
	_show_result(GameState.advance_turn())


func _on_save() -> void:
	_show_result(GameState.save_game())


func _on_load() -> void:
	_show_result(GameState.load_game())


func _on_consumer_ratio_changed(value: float) -> void:
	if _refreshing:
		return
	_show_result(GameState.set_consumer_ratio(GameState.player_country_id, roundi(value)))


func _on_consumption_tax_rate_changed(value: float) -> void:
	if _refreshing:
		return
	_show_result(GameState.set_consumption_tax_rate(GameState.player_country_id, roundi(value)))


func _on_property_tax_rate_changed(value: float) -> void:
	if _refreshing:
		return
	_show_result(GameState.set_property_tax_rate(GameState.player_country_id, roundi(value)))


func _on_adjust_allocation(item_id: StringName, delta: int) -> void:
	var country = GameState.get_player_country()
	var current := int(country.production_allocations.get(item_id, 0))
	_show_result(GameState.set_production_allocation(country.id, item_id, current + delta))


func _on_start_construction(building_type: StringName) -> void:
	_show_result(GameState.start_construction(GameState.player_country_id, selected_province_id, building_type))


func _on_cancel_construction() -> void:
	_show_result(GameState.cancel_construction(GameState.player_country_id, selected_province_id))


func _on_turn_completed(_turn: int) -> void:
	_refresh_all()


func _on_country_changed(country_id: int) -> void:
	if country_id == GameState.player_country_id:
		_refresh_all()


func _on_construction_changed(country_id: int, _province_id: int) -> void:
	if country_id == GameState.player_country_id:
		_refresh_construction()


func _on_province_selected(province_id: int) -> void:
	selected_province_id = province_id
	_refresh_construction()


func _on_province_selection_cleared() -> void:
	selected_province_id = 0
	_refresh_construction()


func _show_economy() -> void:
	_economy_scroll.visible = true
	_construction_scroll.visible = false


func _show_construction() -> void:
	_economy_scroll.visible = false
	_construction_scroll.visible = true
	_refresh_construction()


func _show_result(result: Dictionary) -> void:
	_status_label.text = str(result.get("message", ""))
	_status_label.add_theme_color_override("font_color", GOOD if bool(result.get("ok", false)) else BAD)
	_refresh_all()


func _building_name(building_type: StringName) -> String:
	match building_type:
		GameState.BUILDING_CIVILIAN:
			return "민간공장"
		GameState.BUILDING_MILITARY:
			return "군수공장"
		GameState.BUILDING_DOCKYARD:
			return "조선소"
	return str(building_type)


func _new_label(text: String, minimum_width: float) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = minimum_width
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _compact_number(value: float) -> String:
	if absf(value) >= 1000000.0:
		return "%.1fm" % (value / 1000000.0)
	if absf(value) >= 1000.0:
		return "%.1fk" % (value / 1000.0)
	return "%.0f" % value


func _load_svg_texture(path: String) -> Texture2D:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var image := Image.new()
	if image.load_svg_from_string(file.get_as_text(), 1.0) != OK:
		return null
	return ImageTexture.create_from_image(image)
