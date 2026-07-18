extends SceneTree

const SAVE_PATH := "user://verify_military_save.json"
const LEGACY_SAVE_PATH := "user://verify_military_v1.json"

var _game_state: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_game_state = root.get_node_or_null("GameState")
	if not _check(_game_state != null, "GameState autoload is missing"):
		return
	if not _game_state.is_initialized:
		await _game_state.initialized
	if not _verify_catalog_production_and_supply():
		return
	if not _verify_front_combat_occupation_and_surrender():
		return
	if not _verify_save_v3_v2_and_v1_migration():
		return
	_cleanup_save(SAVE_PATH)
	_cleanup_save(LEGACY_SAVE_PATH)
	print("OK: military production, supply, fronts, combat, occupation, surrender, and save migration verified")
	quit(0)


func _verify_catalog_production_and_supply() -> bool:
	var result: Dictionary = _game_state.start_scenario()
	if not _check(result.ok, "Military scenario failed to start"):
		return false
	if not _check(_game_state.countries_by_code.size() == 4, "Military scenario did not load four countries"):
		return false
	if not _check(_game_state.get_country_by_code(&"PRK") != null, "PRK military preset is missing"):
		return false
	if not _check(_game_state.equipment_by_id.size() == 9, "Military catalog did not load nine equipment types"):
		return false
	var korea = _game_state.get_player_country()
	var army = korea.armies_by_id.get(&"KOR-army-001")
	if not _check(army != null and army.total_personnel == 60000, "Korean starting army is invalid"):
		return false
	var infantry_before: int = int(army.get_equipment_count(&"infantry_equipment"))
	var steel_before := float(korea.inventory[&"steel"])
	_game_state._military_service.advance_production([korea], _game_state.equipment_by_id)
	_game_state._military_service.reinforce_country(korea, _game_state.equipment_by_id)
	if not _check(army.get_equipment_count(&"infantry_equipment") > infantry_before, "Produced equipment was not issued to the army"):
		return false
	if not _check(float(korea.inventory[&"steel"]) < steel_before, "Military production did not consume economic materials"):
		return false
	if not _check(float(korea.military_production_lines[0].efficiency) > 0.5, "Production-line efficiency did not increase"):
		return false
	result = _game_state.set_military_production_line(korea.id, &"too-large", &"tank", korea.military_factories + 1)
	if not _check(not result.ok, "Military factory over-allocation was accepted"):
		return false
	result = _game_state.set_army_equipment_target(korea.id, army.id, &"tank", 40000)
	if not _check(not result.ok, "Army armor cap was not enforced"):
		return false
	var manpower_before: int = int(korea.available_manpower)
	result = _game_state.create_army(korea.id, &"KOR-army-test", "검증군", 1000)
	if not _check(result.ok and korea.available_manpower == manpower_before - 1000, "Army creation did not consume available manpower"):
		return false
	result = _game_state.disband_army(korea.id, &"KOR-army-test")
	if not _check(result.ok and korea.available_manpower == manpower_before, "Army disbandment did not return surviving manpower"):
		return false
	korea.available_manpower = 1000
	_game_state._military_service.create_army(korea, &"KOR-priority-low", "저우선군", 1000)
	_game_state._military_service.create_army(korea, &"KOR-priority-high", "고우선군", 1000)
	_game_state._military_service.set_supply_priority(korea, &"KOR-priority-low", 0)
	_game_state._military_service.set_supply_priority(korea, &"KOR-priority-high", 2)
	_game_state._military_service.reinforce_country(korea, _game_state.equipment_by_id)
	if not _check(
		korea.armies_by_id[&"KOR-priority-high"].total_personnel == 1000
		and korea.armies_by_id[&"KOR-priority-low"].total_personnel == 0,
		"Supply priority did not control reinforcement order"
	):
		return false
	_game_state._war_service.update_ai(
		_game_state.countries_by_id,
		_game_state.player_country_id,
		_game_state.province_states,
		_game_state.equipment_by_id
	)
	if not _check(_game_state.wars_by_id.is_empty(), "Military AI declared war during peace"):
		return false
	return true


func _verify_front_combat_occupation_and_surrender() -> bool:
	var result: Dictionary = _game_state.start_scenario()
	if not _check(result.ok, "Scenario reset failed before war verification"):
		return false
	var korea = _game_state.get_country_by_code(&"KOR")
	var north_korea = _game_state.get_country_by_code(&"PRK")
	result = _game_state.declare_war(korea.id, north_korea.id)
	if not _check(result.ok, "KOR could not declare war on PRK"):
		return false
	var war_id: StringName = result.war_id
	var war: Dictionary = _game_state.get_war(war_id)
	if not _check(not war.get("front_ids", []).is_empty(), "Actual KOR-PRK border did not create a front"):
		return false
	var front_id := StringName(str(war.front_ids[0]))
	result = _game_state.allocate_aircraft(korea.id, front_id, &"fighter", 20)
	if not _check(result.ok, "Aircraft could not be allocated as front support"):
		return false
	result = _game_state.allocate_aircraft(korea.id, front_id, &"fighter", 41)
	if not _check(not result.ok, "Aircraft allocation exceeded the national stockpile"):
		return false
	result = _game_state.assign_army_to_front(korea.id, &"KOR-army-001", front_id)
	if not _check(result.ok, "Korean army could not be assigned to the front"):
		return false
	var target := _set_reachable_deep_target(korea.id, front_id, north_korea.controlled_province_ids)
	if not _check(target > 0, "No reachable PRK offensive target was found"):
		return false
	var korean_control_before: int = int(korea.controlled_province_ids.size())
	result = _game_state.advance_turn()
	if not _check(result.ok, "Preparation turn failed"):
		return false
	if not _check(korea.controlled_province_ids.size() == korean_control_before, "A province was captured during the mandatory preparation turn"):
		return false
	var korean_army = korea.armies_by_id[&"KOR-army-001"]
	var northern_army = north_korea.armies_by_id[&"PRK-army-001"]
	korean_army.target_personnel = korean_army.total_personnel + korea.available_manpower
	northern_army.total_personnel = 1000
	northern_army.target_personnel = 1000
	result = _game_state.advance_turn()
	if not _check(result.ok, "First combat turn failed"):
		return false
	if not _check(korea.controlled_province_ids.size() > korean_control_before, "Superior offensive force did not capture a province"):
		return false
	if not _check(korean_army.assigned_front_id == front_id, "Front identity or army assignment was not preserved after occupation"):
		return false
	var factory_province := _find_controlled_factory_province(north_korea)
	if factory_province > 0:
		var buildings: Dictionary = north_korea.province_buildings[factory_province]
		var transferred := 0
		for count: Variant in buildings.values():
			transferred += int(count)
		var korea_factories_before: int = int(korea.civilian_factories + korea.military_factories + korea.dockyards)
		var capture: Dictionary = _game_state._territory_service.capture_province(
			factory_province,
			korea,
			_game_state.countries_by_id,
			_game_state.province_states
		)
		if not _check(capture.ok, "Factory province could not be occupied"):
			return false
		if not _check(
			korea.civilian_factories + korea.military_factories + korea.dockyards == korea_factories_before + transferred,
			"Occupied factories were not transferred immediately"
		):
			return false
	for province_id: int in north_korea.owned_province_ids.duplicate():
		if int(_game_state.province_states[province_id].controller_country_id) == north_korea.id:
			_game_state._territory_service.capture_province(
				province_id,
				korea,
				_game_state.countries_by_id,
				_game_state.province_states
			)
	result = _game_state.advance_turn()
	if not _check(result.ok and north_korea.is_surrendered, "PRK did not surrender after losing every legal province"):
		return false
	if not _check(not bool(_game_state.get_war(war_id).active), "War remained active after surrender"):
		return false
	return true


func _verify_save_v3_v2_and_v1_migration() -> bool:
	var result: Dictionary = _game_state.start_scenario()
	if not _check(result.ok, "Scenario reset failed before save verification"):
		return false
	var korea = _game_state.get_country_by_code(&"KOR")
	var north_korea = _game_state.get_country_by_code(&"PRK")
	result = _game_state.declare_war(korea.id, north_korea.id)
	if not _check(result.ok, "Could not create war before v3 save"):
		return false
	var saved_war_id := StringName(str(result.war_id))
	var saved_front_id := StringName(str(_game_state.get_war(saved_war_id).front_ids[0]))
	result = _game_state.assign_army_to_front(korea.id, &"KOR-army-001", saved_front_id)
	if not _check(result.ok, "Could not assign army before v2 save"):
		return false
	result = _game_state.save_game(SAVE_PATH)
	if not _check(result.ok, "Military v3 save failed"):
		return false
	_game_state.wars_by_id.clear()
	result = _game_state.load_game(SAVE_PATH)
	if not _check(result.ok, "Military v3 load failed: %s" % result.message):
		return false
	if not _check(_game_state.wars_by_id.has(saved_war_id), "Active war did not survive v3 save/load"):
		return false
	var v2_result: Dictionary = _game_state._save_service.read_file(SAVE_PATH)
	if not _check(v2_result.ok, "Could not reopen v3 save for v2 migration test"):
		return false
	var v2_data: Dictionary = v2_result.data
	v2_data.schema_version = 2
	for country_data: Dictionary in v2_data.countries:
		country_data.tax_rate = 0.27
		country_data.erase("real_gdp")
		country_data.erase("consumption_tax_rate")
		country_data.erase("property_tax_rate")
	var v2_file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if not _check(v2_file != null, "Could not create v2 migration fixture"):
		return false
	v2_file.store_string(JSON.stringify(v2_data))
	v2_file = null
	result = _game_state.load_game(SAVE_PATH)
	if not _check(result.ok, "v2 save migration failed: %s" % result.message):
		return false
	korea = _game_state.get_country_by_code(&"KOR")
	if not _check(
		_game_state.wars_by_id.has(saved_war_id)
		and is_equal_approx(korea.consumption_tax_rate, 0.27)
		and is_equal_approx(korea.property_tax_rate, 0.27)
		and is_equal_approx(korea.real_gdp, 1646739.0)
		and korea.weekly_output_value_history.size() == 52,
		"v2 migration did not preserve military state and split the legacy tax rate"
	):
		return false
	var corrupt_result: Dictionary = _game_state._save_service.read_file(SAVE_PATH)
	if not _check(corrupt_result.ok, "Could not reopen migrated v2 save for corruption test"):
		return false
	var corrupt_data: Dictionary = corrupt_result.data
	for country_data: Dictionary in corrupt_data.countries:
		if int(country_data.id) == korea.id:
			country_data.armies[0].assigned_front_id = "missing-front"
	var corrupt_file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if not _check(corrupt_file != null, "Could not write corrupt military save"):
		return false
	corrupt_file.store_string(JSON.stringify(corrupt_data))
	corrupt_file = null
	var turn_before_corrupt_load: int = int(_game_state.current_turn)
	result = _game_state.load_game(SAVE_PATH)
	if not _check(not result.ok, "Unknown army front assignment was accepted"):
		return false
	if not _check(_game_state.current_turn == turn_before_corrupt_load, "Rejected military save changed the live game"):
		return false

	result = _game_state.start_scenario()
	if not _check(result.ok, "Scenario reset failed before v1 migration"):
		return false
	var legacy: Dictionary = _game_state._build_snapshot().duplicate(true)
	legacy.schema_version = 1
	legacy.scenario_id = _game_state.LEGACY_SCENARIO_ID
	legacy.turn = 7
	legacy.elapsed_days = 49
	legacy.erase("province_control")
	legacy.erase("war_state")
	var legacy_countries: Array = []
	for country_data: Dictionary in legacy.countries:
		if int(country_data.id) == north_korea.id:
			continue
		country_data.tax_rate = 0.19
		country_data.erase("real_gdp")
		country_data.erase("consumption_tax_rate")
		country_data.erase("property_tax_rate")
		for key: String in [
			"controlled_province_ids", "available_manpower", "military_stockpile",
			"military_production_lines", "armies", "is_surrendered"
		]:
			country_data.erase(key)
		country_data.province_buildings = {}
		legacy_countries.append(country_data)
	legacy.countries = legacy_countries
	var file := FileAccess.open(LEGACY_SAVE_PATH, FileAccess.WRITE)
	if not _check(file != null, "Could not create v1 migration fixture"):
		return false
	file.store_string(JSON.stringify(legacy))
	file = null
	result = _game_state.load_game(LEGACY_SAVE_PATH)
	if not _check(result.ok, "v1 save migration failed: %s" % result.message):
		return false
	if not _check(_game_state.current_turn == 7 and _game_state.countries_by_code.size() == 4, "v1 turn or PRK state was not migrated"):
		return false
	if not _check(
		_game_state.get_country_by_code(&"KOR").armies_by_id.has(&"KOR-army-001"),
		"v1 migration did not supply default military state"
	):
		return false
	korea = _game_state.get_country_by_code(&"KOR")
	if not _check(
		is_equal_approx(korea.consumption_tax_rate, 0.19)
		and is_equal_approx(korea.property_tax_rate, 0.19),
		"v1 migration did not split the legacy tax rate"
	):
		return false
	return true


func _set_reachable_deep_target(country_id: int, front_id: StringName, provinces: Array[int]) -> int:
	var candidates: Array[int] = provinces.duplicate()
	candidates.sort()
	candidates.reverse()
	for province_id: int in candidates:
		var result: Dictionary = _game_state.set_offensive_target(country_id, front_id, province_id)
		if result.ok:
			return province_id
	return 0


func _find_controlled_factory_province(country: Resource) -> int:
	var province_ids: Array = country.province_buildings.keys()
	province_ids.sort()
	for province_id: Variant in province_ids:
		if int(_game_state.province_states[int(province_id)].controller_country_id) == country.id:
			return int(province_id)
	return 0


func _cleanup_save(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _check(condition: bool, message: String) -> bool:
	if condition:
		return true
	push_error(message)
	quit(1)
	return false
