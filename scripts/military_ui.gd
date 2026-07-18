class_name MilitaryUI
extends VBoxContainer

signal result_reported(result: Dictionary)

const MUTED := Color("#9cabc2")
const GOOD := Color("#7bd88f")
const BAD := Color("#ff7b72")

var selected_province_id := 0
var _selected_army_id: StringName
var _selected_war_id: StringName
var _selected_front_id: StringName
var _combat_reports: Array[Dictionary] = []
var _pending_war_target_id := 0

var _production_page: VBoxContainer
var _army_page: VBoxContainer
var _war_page: VBoxContainer
var _war_confirmation: ConfirmationDialog


func _ready() -> void:
	custom_minimum_size.x = 414.0
	add_theme_constant_override("separation", 8)
	_build_navigation()
	_build_war_confirmation()
	_connect_signals()
	_refresh_all()


func set_selected_province(province_id: int) -> void:
	selected_province_id = province_id
	if _war_page != null and _war_page.visible:
		_refresh_war_page()


func refresh() -> void:
	_refresh_all()


func _build_navigation() -> void:
	var navigation := HBoxContainer.new()
	navigation.add_theme_constant_override("separation", 4)
	add_child(navigation)
	for specification: Array in [
		["군수 생산", "production"],
		["부대", "army"],
		["전쟁", "war"],
	]:
		var button := Button.new()
		button.text = str(specification[0])
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_show_page.bind(str(specification[1])))
		navigation.add_child(button)
	_production_page = VBoxContainer.new()
	_production_page.add_theme_constant_override("separation", 6)
	add_child(_production_page)
	_army_page = VBoxContainer.new()
	_army_page.add_theme_constant_override("separation", 6)
	_army_page.visible = false
	add_child(_army_page)
	_war_page = VBoxContainer.new()
	_war_page.add_theme_constant_override("separation", 6)
	_war_page.visible = false
	add_child(_war_page)


func _build_war_confirmation() -> void:
	_war_confirmation = ConfirmationDialog.new()
	_war_confirmation.title = "선전포고 확인"
	_war_confirmation.ok_button_text = "선전포고"
	_war_confirmation.cancel_button_text = "취소"
	_war_confirmation.confirmed.connect(_confirm_declare_war)
	add_child(_war_confirmation)


func _connect_signals() -> void:
	GameState.military_changed.connect(_on_military_changed)
	GameState.fronts_changed.connect(_on_fronts_changed)
	GameState.combat_resolved.connect(_on_combat_resolved)
	GameState.war_state_changed.connect(_on_war_state_changed)
	GameState.province_control_changed.connect(_on_province_control_changed)
	GameState.game_loaded.connect(_on_game_loaded)


func _show_page(page_name: String) -> void:
	_production_page.visible = page_name == "production"
	_army_page.visible = page_name == "army"
	_war_page.visible = page_name == "war"
	_refresh_all()


func _refresh_all() -> void:
	if not GameState.is_initialized:
		return
	_refresh_production_page()
	_refresh_army_page()
	_refresh_war_page()


func _refresh_production_page() -> void:
	_clear_children(_production_page)
	var country = GameState.get_player_country()
	if country == null:
		return
	_production_page.add_child(_title("군수 생산"))
	var used_factories := _used_military_factories(country)
	_production_page.add_child(_label("군수공장 %d · 배정 %d · 미사용 %d" % [
		country.military_factories,
		used_factories,
		maxi(country.military_factories - used_factories, 0),
	]))
	var hint := _label("장비 재고와 생산선 공장 배정", MUTED)
	_production_page.add_child(hint)
	for item_id: StringName in GameState.equipment_order:
		var item = GameState.get_equipment(item_id)
		var line := _production_line_for_item(country, item_id)
		var assigned := int(line.get("assigned_factories", 0))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		_production_page.add_child(row)
		var name_label := _label(item.display_name)
		name_label.custom_minimum_size.x = 126
		row.add_child(name_label)
		var stock_label := _label("재고 %s" % _compact_number(int(country.military_stockpile.get(item_id, 0))))
		stock_label.custom_minimum_size.x = 92
		row.add_child(stock_label)
		var minus := Button.new()
		minus.text = "−"
		minus.custom_minimum_size.x = 30
		minus.disabled = assigned <= 0
		minus.pressed.connect(_adjust_production.bind(item_id, -1))
		row.add_child(minus)
		var count_label := _label(str(assigned))
		count_label.custom_minimum_size.x = 26
		count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_child(count_label)
		var plus := Button.new()
		plus.text = "+"
		plus.custom_minimum_size.x = 30
		plus.disabled = used_factories >= country.military_factories
		plus.pressed.connect(_adjust_production.bind(item_id, 1))
		row.add_child(plus)
		if not line.is_empty():
			var efficiency := _label("효율 %d%%" % roundi(float(line.get("efficiency", 0.5)) * 100.0), MUTED)
			efficiency.custom_minimum_size.x = 65
			row.add_child(efficiency)


func _refresh_army_page() -> void:
	_clear_children(_army_page)
	var country = GameState.get_player_country()
	if country == null:
		return
	_army_page.add_child(_title("부대 관리"))
	_army_page.add_child(_label("가용 인력 %s · 부대 %d개" % [
		_compact_number(country.available_manpower),
		country.armies_by_id.size(),
	]))
	var create_row := HBoxContainer.new()
	create_row.add_theme_constant_override("separation", 4)
	_army_page.add_child(create_row)
	var name_input := LineEdit.new()
	name_input.placeholder_text = "새 부대 이름"
	name_input.custom_minimum_size.x = 150
	name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	create_row.add_child(name_input)
	var personnel_input := SpinBox.new()
	personnel_input.min_value = 1000
	personnel_input.max_value = 1000000
	personnel_input.step = 1000
	personnel_input.value = mini(10000, maxi(country.available_manpower, 1000))
	personnel_input.custom_minimum_size.x = 112
	create_row.add_child(personnel_input)
	var create_button := Button.new()
	create_button.text = "창설"
	create_button.disabled = country.available_manpower <= 0
	create_button.pressed.connect(_create_army.bind(name_input, personnel_input))
	create_row.add_child(create_button)

	var army_ids: Array = country.armies_by_id.keys()
	army_ids.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
	if not army_ids.is_empty() and not country.armies_by_id.has(_selected_army_id):
		_selected_army_id = StringName(str(army_ids[0]))
	var selector := HBoxContainer.new()
	selector.add_theme_constant_override("separation", 4)
	_army_page.add_child(selector)
	for army_id_value: Variant in army_ids:
		var army_id := StringName(str(army_id_value))
		var army = country.armies_by_id[army_id]
		var button := Button.new()
		button.text = "%s\n%s/%s" % [army.display_name, _compact_number(army.total_personnel), _compact_number(army.target_personnel)]
		button.toggle_mode = true
		button.button_pressed = army_id == _selected_army_id
		button.pressed.connect(_select_army.bind(army_id))
		selector.add_child(button)
	if _selected_army_id.is_empty() or not country.armies_by_id.has(_selected_army_id):
		_army_page.add_child(_label("부대를 창설하세요.", MUTED))
		return
	_army_page.add_child(HSeparator.new())
	_build_selected_army(country, country.armies_by_id[_selected_army_id])


func _build_selected_army(country: Resource, army: Resource) -> void:
	var heading := HBoxContainer.new()
	_army_page.add_child(heading)
	var title_label := _title(army.display_name)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(title_label)
	var disband := Button.new()
	disband.text = "해산"
	disband.pressed.connect(_disband_army.bind(army.id))
	heading.add_child(disband)

	var personnel_row := HBoxContainer.new()
	_army_page.add_child(personnel_row)
	personnel_row.add_child(_fixed_label("인력 %s / 목표 %s" % [
		_compact_number(army.total_personnel), _compact_number(army.target_personnel),
	], 210))
	for delta: int in [-1000, 1000]:
		var button := Button.new()
		button.text = "−1천" if delta < 0 else "+1천"
		button.disabled = delta < 0 and army.target_personnel - 1000 < army.total_personnel
		button.pressed.connect(_adjust_personnel_target.bind(army.id, delta))
		personnel_row.add_child(button)

	var priority_row := HBoxContainer.new()
	_army_page.add_child(priority_row)
	priority_row.add_child(_fixed_label("보급 우선순위", 130))
	var priority := OptionButton.new()
	for name: String in ["낮음", "보통", "높음"]:
		priority.add_item(name)
	priority.selected = int(army.supply_priority)
	priority.item_selected.connect(_set_priority.bind(army.id))
	priority_row.add_child(priority)

	var front_row := HBoxContainer.new()
	_army_page.add_child(front_row)
	front_row.add_child(_fixed_label("소속 전선", 130))
	var front_selector := OptionButton.new()
	front_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	front_selector.add_item("전선 선택")
	front_selector.set_item_metadata(0, "")
	front_selector.set_item_disabled(0, true)
	var eligible_fronts := _player_front_ids()
	for front_id: StringName in eligible_fronts:
		front_selector.add_item(str(front_id))
		front_selector.set_item_metadata(front_selector.item_count - 1, str(front_id))
		if front_id == army.assigned_front_id:
			front_selector.selected = front_selector.item_count - 1
	front_selector.item_selected.connect(_assign_front.bind(army.id, front_selector))
	front_row.add_child(front_selector)

	_army_page.add_child(_label("장비 충족", MUTED))
	for item_id: StringName in GameState.equipment_order:
		var item = GameState.get_equipment(item_id)
		if str(item.equipment_group) == "aircraft":
			continue
		var current := int(army.get_equipment_count(item_id))
		var target := int(army.get_equipment_target(item_id))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		_army_page.add_child(row)
		row.add_child(_fixed_label(item.display_name, 120))
		row.add_child(_fixed_label("%s / %s" % [_compact_number(current), _compact_number(target)], 115))
		var step := _equipment_step(str(item.equipment_group))
		var minus := Button.new()
		minus.text = "−%s" % _compact_number(step)
		minus.disabled = target <= 0
		minus.pressed.connect(_adjust_equipment_target.bind(army.id, item_id, -step))
		row.add_child(minus)
		var plus := Button.new()
		plus.text = "+%s" % _compact_number(step)
		plus.pressed.connect(_adjust_equipment_target.bind(army.id, item_id, step))
		row.add_child(plus)


func _refresh_war_page() -> void:
	_clear_children(_war_page)
	var country = GameState.get_player_country()
	if country == null:
		return
	_war_page.add_child(_title("전쟁과 전선"))
	_build_declaration_section(country)
	var war_ids := _player_war_ids(country.id)
	if not war_ids.is_empty() and not GameState.wars_by_id.has(_selected_war_id):
		_selected_war_id = war_ids[0]
	if war_ids.is_empty():
		_selected_war_id = &""
		_selected_front_id = &""
		_war_page.add_child(_label("진행 중인 전쟁이 없습니다.", MUTED))
		_build_combat_log()
		return
	var war_selector := OptionButton.new()
	for war_id: StringName in war_ids:
		var war: Dictionary = GameState.get_war(war_id)
		var enemy_id := int(war.defender_country_id) if int(war.attacker_country_id) == country.id else int(war.attacker_country_id)
		var enemy = GameState.get_country(enemy_id)
		war_selector.add_item("%s 전쟁" % enemy.display_name)
		war_selector.set_item_metadata(war_selector.item_count - 1, str(war_id))
		if war_id == _selected_war_id:
			war_selector.selected = war_selector.item_count - 1
	war_selector.item_selected.connect(_select_war.bind(war_selector))
	_war_page.add_child(war_selector)
	_build_selected_war(country)
	_build_combat_log()


func _build_declaration_section(country: Resource) -> void:
	_war_page.add_child(_label("선전포고", MUTED))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	_war_page.add_child(row)
	var country_ids: Array = GameState.countries_by_id.keys()
	country_ids.sort()
	for country_id_value: Variant in country_ids:
		var target = GameState.get_country(int(country_id_value))
		if target == null or target.id == country.id:
			continue
		var button := Button.new()
		button.text = target.display_name
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var existing_war := _countries_at_war(country.id, target.id)
		var shares_border := _countries_share_controlled_border(country.id, target.id)
		button.disabled = country.is_surrendered or target.is_surrendered or existing_war or not shares_border
		if existing_war:
			button.tooltip_text = "이미 전쟁 중입니다."
		elif not shares_border:
			button.tooltip_text = "현재 지배 영토가 맞닿지 않아 육상 전선을 만들 수 없습니다."
		button.pressed.connect(_request_declare_war.bind(target.id))
		row.add_child(button)


func _build_selected_war(country: Resource) -> void:
	var war: Dictionary = GameState.get_war(_selected_war_id)
	if war.is_empty():
		return
	var enemy_id := int(war.defender_country_id) if int(war.attacker_country_id) == country.id else int(war.attacker_country_id)
	var enemy = GameState.get_country(enemy_id)
	var state_text := "준비 중 · %d턴" % int(war.get("preparation_turns_remaining", 0)) if int(war.get("preparation_turns_remaining", 0)) > 0 else "교전 중"
	if not bool(war.get("active", false)):
		state_text = "종료 · %s 항복" % GameState.get_country(int(war.get("surrendered_country_id", 0))).display_name
	_war_page.add_child(_label("대한민국 대 %s · %s" % [enemy.display_name, state_text]))
	var front_ids: Array[StringName] = []
	for front_id_value: Variant in war.get("front_ids", []):
		var front_id := StringName(str(front_id_value))
		if GameState.fronts_by_id.has(front_id):
			front_ids.append(front_id)
	if front_ids.is_empty():
		_war_page.add_child(_label("활성 육상 전선이 없습니다.", BAD))
		_selected_front_id = &""
		return
	if _selected_front_id not in front_ids:
		_selected_front_id = front_ids[0]
	var selector := OptionButton.new()
	for front_id: StringName in front_ids:
		selector.add_item(str(front_id))
		selector.set_item_metadata(selector.item_count - 1, str(front_id))
		if front_id == _selected_front_id:
			selector.selected = selector.item_count - 1
	selector.item_selected.connect(_select_front.bind(selector))
	_war_page.add_child(selector)
	_build_front_detail(country, enemy)


func _build_front_detail(country: Resource, enemy: Resource) -> void:
	var front: Dictionary = GameState.get_front(_selected_front_id)
	if front.is_empty():
		return
	var friendly_armies := _armies_on_front(country, _selected_front_id)
	var enemy_armies := _armies_on_front(enemy, _selected_front_id)
	_war_page.add_child(_label("아군 %d개 부대 · %s명 / 적군 %d개 부대 · %s명" % [
		friendly_armies.size(), _compact_number(_army_personnel(friendly_armies)),
		enemy_armies.size(), _compact_number(_army_personnel(enemy_armies)),
	]))
	var targets: Dictionary = front.get("targets", {})
	var target_id := int(targets.get(str(country.id), 0))
	var target_text := "없음" if target_id <= 0 else "프로빈스 #%d" % target_id
	_war_page.add_child(_label("공세 목표: %s" % target_text))
	var target_row := HBoxContainer.new()
	target_row.add_theme_constant_override("separation", 4)
	_war_page.add_child(target_row)
	var selected_text := "지도에서 적 프로빈스를 선택하세요." if selected_province_id <= 0 else "선택: 프로빈스 #%d" % selected_province_id
	var selection := _label(selected_text, MUTED)
	selection.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	target_row.add_child(selection)
	var set_target := Button.new()
	set_target.text = "목표 지정"
	set_target.disabled = selected_province_id <= 0
	set_target.pressed.connect(_set_offensive_target)
	target_row.add_child(set_target)
	var clear_target := Button.new()
	clear_target.text = "해제"
	clear_target.disabled = target_id <= 0
	clear_target.pressed.connect(_clear_offensive_target)
	target_row.add_child(clear_target)

	_war_page.add_child(_label("항공 지원", MUTED))
	var allocations: Dictionary = front.get("air_allocations", {}).get(str(country.id), {})
	for item_id: StringName in GameState.equipment_order:
		var item = GameState.get_equipment(item_id)
		if str(item.equipment_group) != "aircraft":
			continue
		var count := int(allocations.get(str(item_id), 0))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		_war_page.add_child(row)
		row.add_child(_fixed_label(item.display_name, 145))
		row.add_child(_fixed_label("배정 %d / 재고 %d" % [count, int(country.military_stockpile.get(item_id, 0))], 145))
		var minus := Button.new()
		minus.text = "−5"
		minus.disabled = count <= 0
		minus.pressed.connect(_adjust_aircraft.bind(item_id, -5))
		row.add_child(minus)
		var plus := Button.new()
		plus.text = "+5"
		plus.pressed.connect(_adjust_aircraft.bind(item_id, 5))
		row.add_child(plus)


func _build_combat_log() -> void:
	_war_page.add_child(HSeparator.new())
	_war_page.add_child(_label("최근 전투 결과", MUTED))
	if _combat_reports.is_empty():
		_war_page.add_child(_label("아직 해결된 전투가 없습니다."))
		return
	for index: int in range(_combat_reports.size() - 1, maxi(_combat_reports.size() - 5, -1), -1):
		var report: Dictionary = _combat_reports[index]
		var captures: Array = report.get("captures", [])
		_war_page.add_child(_label("%s · 전투력 %.0f : %.0f · 손실 %s : %s · 점령 %d" % [
			str(report.get("front_id", "전선")),
			float(report.get("power_a", 0.0)), float(report.get("power_b", 0.0)),
			_compact_number(int(report.get("losses_a", 0))), _compact_number(int(report.get("losses_b", 0))),
			captures.size(),
		]))


func _adjust_production(item_id: StringName, delta: int) -> void:
	var country = GameState.get_player_country()
	var line := _production_line_for_item(country, item_id)
	var line_id := StringName(str(line.get("id", "%s-ui-%s" % [country.code, item_id])))
	var assigned := int(line.get("assigned_factories", 0))
	_report(GameState.set_military_production_line(country.id, line_id, item_id, maxi(assigned + delta, 0)))


func _create_army(name_input: LineEdit, personnel_input: SpinBox) -> void:
	var country = GameState.get_player_country()
	var number := 1
	var army_id := StringName("%s-army-ui-%03d" % [country.code, number])
	while country.armies_by_id.has(army_id):
		number += 1
		army_id = StringName("%s-army-ui-%03d" % [country.code, number])
	var display_name := name_input.text.strip_edges()
	if display_name.is_empty():
		display_name = "대한민국 제%d군" % (country.armies_by_id.size() + 1)
	var result := GameState.create_army(country.id, army_id, display_name, roundi(personnel_input.value))
	if result.ok:
		_selected_army_id = army_id
	_report(result)


func _select_army(army_id: StringName) -> void:
	_selected_army_id = army_id
	_refresh_army_page()


func _disband_army(army_id: StringName) -> void:
	var result := GameState.disband_army(GameState.player_country_id, army_id)
	if result.ok:
		_selected_army_id = &""
	_report(result)


func _adjust_personnel_target(army_id: StringName, delta: int) -> void:
	var army = GameState.get_army(GameState.player_country_id, army_id)
	_report(GameState.set_army_personnel_target(GameState.player_country_id, army_id, maxi(army.target_personnel + delta, army.total_personnel)))


func _set_priority(index: int, army_id: StringName) -> void:
	_report(GameState.set_army_supply_priority(GameState.player_country_id, army_id, index))


func _assign_front(index: int, army_id: StringName, selector: OptionButton) -> void:
	var front_id := StringName(str(selector.get_item_metadata(index)))
	if front_id.is_empty():
		_refresh_army_page()
		return
	_report(GameState.assign_army_to_front(GameState.player_country_id, army_id, front_id))


func _adjust_equipment_target(army_id: StringName, item_id: StringName, delta: int) -> void:
	var army = GameState.get_army(GameState.player_country_id, army_id)
	_report(GameState.set_army_equipment_target(GameState.player_country_id, army_id, item_id, maxi(army.get_equipment_target(item_id) + delta, 0)))


func _request_declare_war(target_country_id: int) -> void:
	var target = GameState.get_country(target_country_id)
	if target == null:
		return
	_pending_war_target_id = target_country_id
	_war_confirmation.dialog_text = "%s에 선전포고하시겠습니까?\n선전포고 후 첫 턴은 전투 준비 기간입니다." % target.display_name
	_war_confirmation.popup_centered(Vector2i(420, 180))


func _confirm_declare_war() -> void:
	var result := GameState.declare_war(GameState.player_country_id, _pending_war_target_id)
	_pending_war_target_id = 0
	if result.ok:
		_selected_war_id = StringName(str(result.war_id))
		_selected_front_id = &""
	_report(result)


func _select_war(index: int, selector: OptionButton) -> void:
	_selected_war_id = StringName(str(selector.get_item_metadata(index)))
	_selected_front_id = &""
	_refresh_war_page()


func _select_front(index: int, selector: OptionButton) -> void:
	_selected_front_id = StringName(str(selector.get_item_metadata(index)))
	_refresh_war_page()


func _set_offensive_target() -> void:
	_report(GameState.set_offensive_target(GameState.player_country_id, _selected_front_id, selected_province_id))


func _clear_offensive_target() -> void:
	_report(GameState.set_offensive_target(GameState.player_country_id, _selected_front_id, 0))


func _adjust_aircraft(item_id: StringName, delta: int) -> void:
	var front := GameState.get_front(_selected_front_id)
	var allocations: Dictionary = front.get("air_allocations", {}).get(str(GameState.player_country_id), {})
	var current := int(allocations.get(str(item_id), 0))
	_report(GameState.allocate_aircraft(GameState.player_country_id, _selected_front_id, item_id, maxi(current + delta, 0)))


func _report(result: Dictionary) -> void:
	result_reported.emit(result)
	_refresh_all()


func _on_military_changed(country_id: int) -> void:
	if country_id == GameState.player_country_id:
		_refresh_all()


func _on_fronts_changed(_war_id: StringName) -> void:
	_refresh_army_page()
	_refresh_war_page()


func _on_combat_resolved(report: Dictionary) -> void:
	_combat_reports.append(report.duplicate(true))
	if _combat_reports.size() > 20:
		_combat_reports.pop_front()
	_refresh_war_page()


func _on_war_state_changed(_war_id: StringName) -> void:
	_refresh_all()


func _on_province_control_changed(_province_id: int, _old_controller_id: int, _new_controller_id: int) -> void:
	_refresh_war_page()


func _on_game_loaded() -> void:
	_selected_army_id = &""
	_selected_war_id = &""
	_selected_front_id = &""
	_combat_reports.clear()
	_refresh_all()


func _production_line_for_item(country: Resource, item_id: StringName) -> Dictionary:
	for line: Dictionary in country.military_production_lines:
		if str(line.get("item_id", "")) == str(item_id):
			return line
	return {}


func _used_military_factories(country: Resource) -> int:
	var total := 0
	for line: Dictionary in country.military_production_lines:
		total += int(line.get("assigned_factories", 0))
	return total


func _player_war_ids(country_id: int) -> Array[StringName]:
	var result: Array[StringName] = []
	var ids: Array = GameState.wars_by_id.keys()
	ids.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
	for war_id_value: Variant in ids:
		var war: Dictionary = GameState.wars_by_id[war_id_value]
		if country_id in [int(war.attacker_country_id), int(war.defender_country_id)]:
			result.append(StringName(str(war_id_value)))
	return result


func _player_front_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for war_id: StringName in _player_war_ids(GameState.player_country_id):
		var war: Dictionary = GameState.get_war(war_id)
		if not bool(war.get("active", false)):
			continue
		for front_id_value: Variant in war.get("front_ids", []):
			var front_id := StringName(str(front_id_value))
			if GameState.fronts_by_id.has(front_id):
				result.append(front_id)
	return result


func _countries_at_war(country_a_id: int, country_b_id: int) -> bool:
	for war: Dictionary in GameState.wars_by_id.values():
		if not bool(war.get("active", false)):
			continue
		if country_a_id in [int(war.attacker_country_id), int(war.defender_country_id)] and country_b_id in [int(war.attacker_country_id), int(war.defender_country_id)]:
			return true
	return false


func _countries_share_controlled_border(country_a_id: int, country_b_id: int) -> bool:
	var country_a = GameState.get_country(country_a_id)
	if country_a == null:
		return false
	for province_id: int in country_a.controlled_province_ids:
		var province: Dictionary = ProvinceMapDB.get_province(province_id)
		for neighbor_id_value: Variant in province.get("neighbors", []):
			var neighbor_id := int(neighbor_id_value)
			if int(GameState.province_states.get(neighbor_id, {}).get("controller_country_id", 0)) == country_b_id:
				return true
	return false


func _armies_on_front(country: Resource, front_id: StringName) -> Array:
	var result: Array = []
	for army: Resource in country.armies_by_id.values():
		if army.assigned_front_id == front_id:
			result.append(army)
	return result


func _army_personnel(armies: Array) -> int:
	var result := 0
	for army: Resource in armies:
		result += int(army.total_personnel)
	return result


func _equipment_step(group: String) -> int:
	match group:
		"infantry":
			return 1000
		"armor":
			return 10
		_:
			return 100


func _clear_children(container: Container) -> void:
	for child: Node in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _title(text: String) -> Label:
	var label := _label(text)
	label.add_theme_font_size_override("font_size", 18)
	return label


func _label(text: String, color: Color = Color.WHITE) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", color)
	return label


func _fixed_label(text: String, width: float) -> Label:
	var label := _label(text)
	label.custom_minimum_size.x = width
	return label


func _compact_number(value: int) -> String:
	if absi(value) >= 1000000:
		return "%.1fm" % (float(value) / 1000000.0)
	if absi(value) >= 1000:
		return "%.1fk" % (float(value) / 1000.0)
	return str(value)
