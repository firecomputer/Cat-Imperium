extends Node

signal initialized
signal turn_started(turn_number: int)
signal turn_completed(turn_number: int)
signal country_economy_changed(country_id: int)
signal construction_changed(country_id: int, province_id: int)
signal military_changed(country_id: int)
signal fronts_changed(war_id: StringName)
signal province_control_changed(province_id: int, old_controller_id: int, new_controller_id: int)
signal combat_resolved(report: Dictionary)
signal war_state_changed(war_id: StringName)
signal game_loaded

const ECONOMY_CATALOG_PATH := "res://data/economy_catalog.json"
const MILITARY_CATALOG_PATH := "res://data/military_catalog.json"
const DEFAULT_SAVE_PATH := "user://savegame.json"
const SAVE_SCHEMA_VERSION := 3
const LEGACY_SCENARIO_ID := "east_asia_economy"
const SCENARIO_ID := "east_asia_military"
const ACTIVE_COUNTRY_CODES: Array[StringName] = [&"KOR", &"PRK", &"CHN", &"JPN"]
const PLAYER_COUNTRY_CODE := &"KOR"
const TURN_DAYS := 7

const CountryClass = preload("res://scripts/country.gd")
const ItemClass = preload("res://scripts/item.gd")
const EconomyServiceClass = preload("res://scripts/economy_service.gd")
const ConstructionServiceClass = preload("res://scripts/construction_service.gd")
const SaveServiceClass = preload("res://scripts/save_service.gd")
const MilitaryServiceClass = preload("res://scripts/military_service.gd")
const TerritoryServiceClass = preload("res://scripts/territory_service.gd")
const WarServiceClass = preload("res://scripts/war_service.gd")

const CONSTRUCTION_DAYS := ConstructionServiceClass.CONSTRUCTION_DAYS
const BUILDING_CIVILIAN := ConstructionServiceClass.BUILDING_CIVILIAN
const BUILDING_MILITARY := ConstructionServiceClass.BUILDING_MILITARY
const BUILDING_DOCKYARD := ConstructionServiceClass.BUILDING_DOCKYARD
const CONSTRUCTION_REQUIREMENTS := ConstructionServiceClass.REQUIREMENTS

var countries_by_id: Dictionary = {}
var countries_by_code: Dictionary = {}
var items_by_id: Dictionary = {}
var item_order: Array[StringName] = []
var equipment_by_id: Dictionary = {}
var equipment_order: Array[StringName] = []
var province_states: Dictionary = {}
var sample_country: CountryClass
var player_country_id := 0
var current_turn := 0
var elapsed_days := 0
var start_date := "2026-01-01"
var is_initialized := false

var _catalog: Dictionary = {}
var _military_catalog: Dictionary = {}
var _economy_service := EconomyServiceClass.new()
var _construction_service := ConstructionServiceClass.new()
var _save_service := SaveServiceClass.new()
var _military_service := MilitaryServiceClass.new()
var _territory_service := TerritoryServiceClass.new()
var _war_service := WarServiceClass.new()
var wars_by_id: Dictionary = _war_service.wars_by_id
var fronts_by_id: Dictionary = _war_service.fronts_by_id
var _scenario_default_snapshot: Dictionary = {}


func _ready() -> void:
	if ProvinceMapDB.is_loaded:
		_initialize_countries()
	else:
		ProvinceMapDB.database_loaded.connect(_initialize_countries, CONNECT_ONE_SHOT)


func get_country(country_id: int) -> CountryClass:
	return countries_by_id.get(country_id)


func get_country_by_code(country_code: StringName) -> CountryClass:
	return countries_by_code.get(country_code)


func get_player_country() -> CountryClass:
	return get_country(player_country_id)


func get_item(item_id: StringName) -> ItemClass:
	return items_by_id.get(item_id)


func get_equipment(item_id: StringName) -> ItemClass:
	return equipment_by_id.get(item_id)


func get_army(country_id: int, army_id: StringName) -> Resource:
	var country := get_country(country_id)
	return country.armies_by_id.get(army_id) if country != null else null


func get_war(war_id: StringName) -> Dictionary:
	return wars_by_id.get(war_id, {}).duplicate(true)


func get_front(front_id: StringName) -> Dictionary:
	return fronts_by_id.get(front_id, {}).duplicate(true)


func get_province_state(province_id: int) -> Dictionary:
	return province_states.get(province_id, {}).duplicate(true)


func get_date_string() -> String:
	var unix_time := Time.get_unix_time_from_datetime_string("%sT00:00:00" % start_date)
	unix_time += elapsed_days * 86400
	var date := Time.get_date_dict_from_unix_time(int(unix_time))
	return "%04d-%02d-%02d" % [date.year, date.month, date.day]


func get_construction_requirements(building_type: StringName) -> Dictionary:
	return _construction_service.get_requirements(building_type)


func start_scenario(scenario_id: String = SCENARIO_ID) -> Dictionary:
	if scenario_id != SCENARIO_ID:
		return _result(false, "알 수 없는 시나리오입니다.")
	if not ProvinceMapDB.is_loaded:
		return _result(false, "프로빈스 지도가 아직 준비되지 않았습니다.")
	var catalog_result := _load_catalog()
	if not catalog_result.ok:
		return catalog_result

	countries_by_id.clear()
	countries_by_code.clear()
	sample_country = null
	player_country_id = 0
	current_turn = 0
	elapsed_days = 0
	start_date = str(_catalog.get("start_date", "2026-01-01"))
	var presets: Dictionary = _catalog.get("countries", {})
	var military_presets: Dictionary = _military_catalog.get("countries", {})
	for record: Dictionary in ProvinceMapDB.countries:
		var country_code := StringName(str(record.get("code", "")))
		if country_code not in ACTIVE_COUNTRY_CODES:
			continue
		var country: CountryClass = CountryClass.new()
		country.load_map_record(record)
		country.apply_scenario_preset(presets.get(str(country_code), {}))
		_initialize_country_market(country, presets.get(str(country_code), {}))
		_military_service.initialize_country(country, military_presets.get(str(country_code), {}), equipment_by_id)
		countries_by_id[country.id] = country
		countries_by_code[country.code] = country

	if countries_by_code.size() != ACTIVE_COUNTRY_CODES.size():
		return _result(false, "동아시아 군사 시나리오 국가 데이터를 모두 찾지 못했습니다.")
	_territory_service.initialize(_ordered_countries(), province_states)
	_war_service.reset()
	sample_country = countries_by_code.get(PLAYER_COUNTRY_CODE)
	player_country_id = sample_country.id
	is_initialized = true
	_scenario_default_snapshot = _build_snapshot().duplicate(true)
	initialized.emit()
	return _result(true)


func advance_turn() -> Dictionary:
	if not is_initialized:
		return _result(false, "게임이 초기화되지 않았습니다.")
	turn_started.emit(current_turn + 1)
	_economy_service.advance_week(_ordered_countries(), items_by_id, item_order)
	var production_events := _military_service.advance_production(_ordered_countries(), equipment_by_id)
	_military_service.reinforce_countries(_ordered_countries(), equipment_by_id)
	var war_result := _war_service.advance_wars(
		countries_by_id,
		province_states,
		equipment_by_id,
		_territory_service
	)
	for event: Dictionary in production_events:
		military_changed.emit(int(event.country_id))
	for capture: Dictionary in war_result.captures:
		province_control_changed.emit(
			int(capture.province_id),
			int(capture.old_controller_id),
			int(capture.new_controller_id)
		)
	for report: Dictionary in war_result.combat_reports:
		combat_resolved.emit(report)
	for surrender: Dictionary in war_result.surrenders:
		war_state_changed.emit(StringName(str(surrender.war_id)))
	for war_id: Variant in wars_by_id:
		fronts_changed.emit(StringName(str(war_id)))
	for country: CountryClass in _ordered_countries():
		_economy_service.ensure_allocations(country, items_by_id, item_order)
	_run_ai_decisions()
	_advance_construction()
	current_turn += 1
	elapsed_days += TURN_DAYS
	for country: CountryClass in _ordered_countries():
		country_economy_changed.emit(country.id)
		military_changed.emit(country.id)
	turn_completed.emit(current_turn)
	return _result(true)


func set_military_production_line(
	country_id: int,
	line_id: StringName,
	item_id: StringName,
	assigned_factories: int
) -> Dictionary:
	var country := get_country(country_id)
	if country == null or country.id != player_country_id:
		return _result(false, "플레이어 국가의 군수 생산만 변경할 수 있습니다.")
	var result := _military_service.set_production_line(country, line_id, item_id, assigned_factories, equipment_by_id)
	if result.ok:
		military_changed.emit(country.id)
	return result


func create_army(country_id: int, army_id: StringName, display_name: String, target_personnel: int) -> Dictionary:
	var country := get_country(country_id)
	if country == null or country.id != player_country_id:
		return _result(false, "플레이어 국가에서만 부대를 창설할 수 있습니다.")
	var result := _military_service.create_army(country, army_id, display_name, target_personnel)
	if result.ok:
		_military_service.reinforce_country(country, equipment_by_id)
		military_changed.emit(country.id)
	return result


func disband_army(country_id: int, army_id: StringName) -> Dictionary:
	var country := get_country(country_id)
	if country == null or country.id != player_country_id:
		return _result(false, "플레이어 국가의 부대만 해산할 수 있습니다.")
	var result := _military_service.disband_army(country, army_id)
	if result.ok:
		military_changed.emit(country.id)
	return result


func set_army_personnel_target(country_id: int, army_id: StringName, target: int) -> Dictionary:
	var country := get_country(country_id)
	if country == null or country.id != player_country_id:
		return _result(false, "플레이어 국가의 부대만 변경할 수 있습니다.")
	var result := _military_service.set_army_personnel_target(country, army_id, target)
	if result.ok:
		military_changed.emit(country.id)
	return result


func set_army_equipment_target(country_id: int, army_id: StringName, item_id: StringName, count: int) -> Dictionary:
	var country := get_country(country_id)
	if country == null or country.id != player_country_id:
		return _result(false, "플레이어 국가의 부대만 변경할 수 있습니다.")
	var result := _military_service.set_army_equipment_target(country, army_id, item_id, count, equipment_by_id)
	if result.ok:
		military_changed.emit(country.id)
	return result


func set_army_supply_priority(country_id: int, army_id: StringName, priority: int) -> Dictionary:
	var country := get_country(country_id)
	if country == null or country.id != player_country_id:
		return _result(false, "플레이어 국가의 부대만 변경할 수 있습니다.")
	var result := _military_service.set_supply_priority(country, army_id, priority)
	if result.ok:
		military_changed.emit(country.id)
	return result


func declare_war(attacker_country_id: int, defender_country_id: int) -> Dictionary:
	if attacker_country_id != player_country_id:
		return _result(false, "플레이어 국가만 선전포고할 수 있습니다.")
	var result := _war_service.declare_war(
		get_country(attacker_country_id),
		get_country(defender_country_id),
		countries_by_id,
		province_states
	)
	if result.ok:
		war_state_changed.emit(result.war_id)
		fronts_changed.emit(result.war_id)
	return result


func assign_army_to_front(country_id: int, army_id: StringName, front_id: StringName) -> Dictionary:
	var country := get_country(country_id)
	if country == null or country.id != player_country_id:
		return _result(false, "플레이어 국가의 부대만 배정할 수 있습니다.")
	var result := _war_service.assign_army_to_front(country, army_id, front_id)
	if result.ok:
		military_changed.emit(country.id)
	return result


func set_offensive_target(country_id: int, front_id: StringName, province_id: int) -> Dictionary:
	var country := get_country(country_id)
	if country == null or country.id != player_country_id:
		return _result(false, "플레이어 국가의 공세만 지정할 수 있습니다.")
	var result := _war_service.set_offensive_target(country, front_id, province_id, province_states)
	if result.ok:
		fronts_changed.emit(StringName(str(fronts_by_id[front_id].war_id)))
	return result


func allocate_aircraft(country_id: int, front_id: StringName, item_id: StringName, count: int) -> Dictionary:
	var country := get_country(country_id)
	if country == null or country.id != player_country_id:
		return _result(false, "플레이어 국가의 항공기만 배정할 수 있습니다.")
	var result := _war_service.allocate_aircraft(country, front_id, item_id, count, equipment_by_id)
	if result.ok:
		military_changed.emit(country.id)
	return result


func set_consumer_ratio(country_id: int, percent: int) -> Dictionary:
	var country := get_country(country_id)
	if country == null:
		return _result(false, "국가를 찾을 수 없습니다.")
	if country_id != player_country_id:
		return _result(false, "플레이어 국가의 정책만 변경할 수 있습니다.")
	country.consumer_ratio = percent
	_economy_service.ensure_allocations(country, items_by_id, item_order)
	country_economy_changed.emit(country.id)
	return _result(true)


func set_consumption_tax_rate(country_id: int, percent: float) -> Dictionary:
	var country := get_country(country_id)
	if country == null:
		return _result(false, "국가를 찾을 수 없습니다.")
	if country_id != player_country_id:
		return _result(false, "플레이어 국가의 정책만 변경할 수 있습니다.")
	country.consumption_tax_rate = percent / 100.0
	country_economy_changed.emit(country.id)
	return _result(true)


func set_property_tax_rate(country_id: int, percent: float) -> Dictionary:
	var country := get_country(country_id)
	if country == null:
		return _result(false, "국가를 찾을 수 없습니다.")
	if country_id != player_country_id:
		return _result(false, "플레이어 국가의 정책만 변경할 수 있습니다.")
	country.property_tax_rate = percent / 100.0
	country_economy_changed.emit(country.id)
	return _result(true)


func set_production_allocation(country_id: int, item_id: StringName, factory_count: int) -> Dictionary:
	var country := get_country(country_id)
	if country == null or not items_by_id.has(item_id):
		return _result(false, "국가 또는 품목을 찾을 수 없습니다.")
	if country_id != player_country_id:
		return _result(false, "플레이어 국가의 생산만 변경할 수 있습니다.")
	if factory_count < 0:
		return _result(false, "공장 수는 음수가 될 수 없습니다.")
	var current := int(country.production_allocations.get(item_id, 0))
	var requested_total := country.get_allocated_consumer_factories() - current + factory_count
	if requested_total > country.get_effective_consumer_factories():
		return _result(false, "소비재 공장 한도를 초과합니다. 다른 품목 배정을 먼저 줄이세요.")
	if factory_count == 0:
		country.production_allocations.erase(item_id)
	else:
		country.production_allocations[item_id] = factory_count
	country_economy_changed.emit(country.id)
	return _result(true)


func start_construction(country_id: int, province_id: int, building_type: StringName) -> Dictionary:
	return _start_construction_internal(country_id, province_id, building_type, true)


func cancel_construction(country_id: int, province_id: int) -> Dictionary:
	var country := get_country(country_id)
	var result := _construction_service.cancel(country, player_country_id, province_id)
	if result.ok:
		_economy_service.ensure_allocations(country, items_by_id, item_order)
		construction_changed.emit(country.id, province_id)
		country_economy_changed.emit(country.id)
	return result


func save_game(path: String = DEFAULT_SAVE_PATH) -> Dictionary:
	if not is_initialized:
		return _result(false, "저장할 게임이 없습니다.")
	var data := _build_snapshot()
	return _save_service.write_file(path, data)


func load_game(path: String = DEFAULT_SAVE_PATH) -> Dictionary:
	var read_result := _save_service.read_file(path)
	if not read_result.ok:
		return read_result
	var data: Dictionary = read_result.data
	if int(data.get("schema_version", -1)) == 1:
		var migration := _save_service.migrate_v1(data, _scenario_default_snapshot, LEGACY_SCENARIO_ID)
		if not migration.ok:
			return migration
		data = migration.data
	elif int(data.get("schema_version", -1)) == 2:
		var migration := _save_service.migrate_v2(data, SCENARIO_ID)
		if not migration.ok:
			return migration
		data = migration.data
	var active_country_ids := {}
	for country: CountryClass in _ordered_countries():
		active_country_ids[country.id] = true
	var validation := _save_service.validate(data, {
		"schema_version": SAVE_SCHEMA_VERSION,
		"scenario_id": SCENARIO_ID,
		"player_country_id": player_country_id,
		"expected_country_count": ACTIVE_COUNTRY_CODES.size(),
		"countries_by_id": countries_by_id,
		"item_order": item_order,
		"items_by_id": items_by_id,
		"construction_requirements": CONSTRUCTION_REQUIREMENTS,
		"construction_days": CONSTRUCTION_DAYS,
		"equipment_by_id": equipment_by_id,
		"province_states": province_states,
		"active_country_ids": active_country_ids,
	})
	if not validation.ok:
		return validation
	var start_result := start_scenario(str(data.get("scenario_id", "")))
	if not start_result.ok:
		return start_result
	_save_service.apply_countries(data, countries_by_id)
	_territory_service.apply_control_data(data.get("province_control", {}), countries_by_id, province_states)
	_war_service.apply_save_data(data.get("war_state", {}))
	current_turn = int(data.get("turn", 0))
	elapsed_days = int(data.get("elapsed_days", 0))
	start_date = str(data.get("start_date", start_date))
	player_country_id = int(data.get("player_country_id", player_country_id))
	game_loaded.emit()
	for country: CountryClass in _ordered_countries():
		country_economy_changed.emit(country.id)
		military_changed.emit(country.id)
	for war_id: Variant in wars_by_id:
		war_state_changed.emit(StringName(str(war_id)))
		fronts_changed.emit(StringName(str(war_id)))
	return _result(true, "게임을 불러왔습니다.")


func _initialize_countries() -> void:
	if is_initialized:
		return
	var result := start_scenario()
	if not result.ok:
		push_error(result.message)


func _load_catalog() -> Dictionary:
	if not _catalog.is_empty() and not items_by_id.is_empty() and not _military_catalog.is_empty() and not equipment_by_id.is_empty():
		return _result(true)
	var file := FileAccess.open(ECONOMY_CATALOG_PATH, FileAccess.READ)
	if file == null:
		return _result(false, "경제 품목 데이터를 열 수 없습니다.")
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return _result(false, "경제 품목 데이터 형식이 잘못되었습니다.")
	_catalog = parsed
	var tax_parameters: Dictionary = _catalog.get("tax_parameters", {})
	for key: String in ["civilian_factory_tax_value", "consumption_tax_alpha", "property_tax_alpha"]:
		if (
			not tax_parameters.has(key)
			or typeof(tax_parameters[key]) not in [TYPE_INT, TYPE_FLOAT]
			or not is_finite(float(tax_parameters[key]))
			or float(tax_parameters[key]) < 0.0
		):
			return _result(false, "경제 세금 보정값이 잘못되었습니다.")
	_economy_service.configure(tax_parameters)
	items_by_id.clear()
	item_order.clear()
	for record: Dictionary in _catalog.get("items", []):
		var item: ItemClass = ItemClass.new()
		item.load_catalog_record(record)
		if item.id.is_empty() or items_by_id.has(item.id):
			return _result(false, "경제 품목 ID가 없거나 중복되었습니다.")
		items_by_id[item.id] = item
		item_order.append(item.id)
	var military_file := FileAccess.open(MILITARY_CATALOG_PATH, FileAccess.READ)
	if military_file == null:
		return _result(false, "군사 장비 데이터를 열 수 없습니다.")
	var military_parsed: Variant = JSON.parse_string(military_file.get_as_text())
	if typeof(military_parsed) != TYPE_DICTIONARY:
		return _result(false, "군사 장비 데이터 형식이 잘못되었습니다.")
	_military_catalog = military_parsed
	equipment_by_id.clear()
	equipment_order.clear()
	for record: Dictionary in _military_catalog.get("items", []):
		var equipment: ItemClass = ItemClass.new()
		equipment.load_catalog_record(record)
		if equipment.id.is_empty() or equipment_by_id.has(equipment.id) or equipment.category != ItemClass.Category.MILITARY:
			return _result(false, "군사 장비 ID 또는 분류가 잘못되었습니다.")
		for material_id: Variant in equipment.input_materials:
			if not items_by_id.has(material_id):
				return _result(false, "군사 장비 투입재가 경제 카탈로그에 없습니다.")
		equipment_by_id[equipment.id] = equipment
		equipment_order.append(equipment.id)
	return _result(true)


func _initialize_country_market(country: CountryClass, preset: Dictionary) -> void:
	_economy_service.initialize_country_market(country, preset, items_by_id, item_order)


func _ordered_countries() -> Array:
	var result: Array = []
	for country_code: StringName in ACTIVE_COUNTRY_CODES:
		var country: CountryClass = countries_by_code.get(country_code)
		if country != null:
			result.append(country)
	return result


func _run_ai_decisions() -> void:
	for country: CountryClass in _ordered_countries():
		if country.id == player_country_id:
			continue
		_economy_service.update_ai_country_production(country, items_by_id, item_order)
		_military_service.update_ai_production(country, equipment_by_id)
		if country.construction_projects.is_empty() and country.get_trade_factories() > 0:
			for province_id: int in country.owned_province_ids:
				if not _construction_service.has_project(country, province_id):
					var result := _start_construction_internal(country.id, province_id, BUILDING_CIVILIAN, false)
					if result.ok:
						break
	_war_service.update_ai(countries_by_id, player_country_id, province_states, equipment_by_id)


func _start_construction_internal(
	country_id: int,
	province_id: int,
	building_type: StringName,
	require_player: bool
) -> Dictionary:
	var country := get_country(country_id)
	var province: Dictionary = ProvinceMapDB.get_province(province_id) if country != null else {}
	var result := _construction_service.start(
		country,
		player_country_id,
		province_id,
		building_type,
		require_player,
		province,
		items_by_id
	)
	if result.ok:
		_economy_service.ensure_allocations(country, items_by_id, item_order)
		construction_changed.emit(country.id, province_id)
		country_economy_changed.emit(country.id)
	return result


func _advance_construction() -> void:
	var countries := _ordered_countries()
	var completed := _construction_service.advance_week(countries, TURN_DAYS)
	for country: CountryClass in countries:
		_economy_service.ensure_allocations(country, items_by_id, item_order)
	for event: Dictionary in completed:
		construction_changed.emit(event.country.id, int(event.province_id))


func _build_snapshot() -> Dictionary:
	return _save_service.build_snapshot(_ordered_countries(), {
		"schema_version": SAVE_SCHEMA_VERSION,
		"scenario_id": SCENARIO_ID,
		"turn": current_turn,
		"elapsed_days": elapsed_days,
		"start_date": start_date,
		"player_country_id": player_country_id,
		"province_control": _territory_service.to_save_data(province_states),
		"war_state": _war_service.to_save_data(),
	})


func _result(ok: bool, message: String = "") -> Dictionary:
	return {"ok": ok, "message": message}
