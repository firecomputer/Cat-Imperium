extends SceneTree

const TEST_SAVE_PATH := "user://economy_test_save.json"
const ItemClass = preload("res://scripts/item.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var game_state := root.get_node_or_null("GameState")
	if not _check(game_state != null, "GameState autoload is missing"):
		return
	if not game_state.is_initialized:
		await game_state.initialized
	var result: Dictionary = game_state.start_scenario()
	if not _check(result.ok, "Economy scenario failed to start: %s" % result.message):
		return
	if not _check(game_state.countries_by_id.size() == 4, "East Asia military scenario did not load four countries"):
		return
	if not _check(game_state.item_order.size() == 13, "Civilian item catalog did not load 13 unique items"):
		return

	var korea = game_state.get_player_country()
	if not _check(korea != null and korea.code == &"KOR", "Korea is not the player country"):
		return
	if not _check(korea.civilian_factories == 10, "Korea did not receive its scenario factories"):
		return
	if not _check(korea.get_effective_consumer_factories() == 4, "40% of ten factories was not four"):
		return
	if not _check(korea.get_trade_factories() == 6, "Initial trade factory count was not six"):
		return
	if not _check(
		is_equal_approx(game_state.get_trade_dollar_capacity(korea.id), 600.0),
		"Six trade factories did not create $600 of weekly private trade dollars"
	):
		return
	var initial_output_history_valid: bool = korea.weekly_output_value_history.size() == 52
	for output_value: float in korea.weekly_output_value_history:
		if not is_equal_approx(output_value, 630.0):
			initial_output_history_valid = false
			break
	if not _check(
		is_equal_approx(korea.real_gdp, 1646739.0)
		and initial_output_history_valid,
		"Korea did not start from map GDP and 52 weeks of configured output"
	):
		return
	var elasticity_growth: float = game_state._economy_service._annual_gdp_growth(120.0, 100.0)
	if not _check(
		is_equal_approx(elasticity_growth, pow(1.2, 0.25) - 1.0),
		"GDP output growth did not use the configured 0.25 elasticity"
	):
		return

	var first_province: int = korea.owned_province_ids[0]
	var second_province: int = korea.owned_province_ids[1]
	var treasury_before: float = korea.treasury
	var wood_before := float(korea.inventory[&"wood"])
	result = game_state.start_construction(korea.id, first_province, game_state.BUILDING_CIVILIAN)
	if not _check(result.ok, "First civilian construction failed: %s" % result.message):
		return
	result = game_state.start_construction(korea.id, second_province, game_state.BUILDING_MILITARY)
	if not _check(result.ok, "Second military construction failed: %s" % result.message):
		return
	if not _check(
		korea.get_effective_consumer_factories() == 4
		and korea.get_active_construction_count() == 2
		and korea.get_trade_factories() == 4,
		"10 factories at 40% with two projects did not split 4/2/4"
	):
		return
	if not _check(korea.treasury == treasury_before - 12500.0, "Construction costs were not paid at start"):
		return
	if not _check(float(korea.inventory[&"wood"]) == wood_before - 50.0, "Construction materials were not consumed"):
		return
	result = game_state.start_construction(korea.id, first_province, game_state.BUILDING_CIVILIAN)
	if not _check(not result.ok, "A province accepted two simultaneous construction projects"):
		return
	var foreign_province: int = game_state.get_country_by_code(&"JPN").owned_province_ids[0]
	result = game_state.start_construction(korea.id, foreign_province, game_state.BUILDING_CIVILIAN)
	if not _check(not result.ok, "Construction was allowed in a foreign province"):
		return
	result = game_state.start_construction(
		game_state.get_country_by_code(&"CHN").id,
		game_state.get_country_by_code(&"CHN").owned_province_ids[0],
		game_state.BUILDING_CIVILIAN
	)
	if not _check(not result.ok, "Public construction API allowed the player to control an AI country"):
		return

	for turn: int in 14:
		result = game_state.advance_turn()
		if not _check(result.ok, "Turn advance failed during construction"):
			return
	if not _check(korea.construction_projects.size() == 2, "Construction completed before 100 days"):
		return
	if not _check(int(korea.construction_projects[0].remaining_days) == 2, "Fourteen turns did not leave two construction days"):
		return
	result = game_state.advance_turn()
	if not _check(result.ok, "Fifteenth construction turn failed"):
		return
	if not _check(korea.construction_projects.is_empty(), "Construction did not complete on turn fifteen"):
		return
	if not _check(korea.civilian_factories == 11 and korea.military_factories == 4, "Completed buildings did not update national factory totals"):
		return

	for country in game_state.countries_by_id.values():
		if not _check(country.treasury >= 0.0 and is_finite(country.treasury), "Treasury became negative or non-finite"):
			return
		if not _check(country.standard_of_living >= 0.0 and country.standard_of_living <= 10.0, "Living standard escaped its range"):
			return
		for item_id: StringName in game_state.item_order:
			var item = game_state.get_item(item_id)
			var price := float(country.prices[item_id])
			if not _check(float(country.inventory[item_id]) >= 0.0, "Inventory became negative"):
				return
			if not _check(price >= item.minimum_price and price <= item.maximum_price, "Price escaped its configured range"):
				return

	result = game_state.start_scenario()
	if not _check(result.ok, "Scenario reset failed before fiscal test"):
		return
	korea = game_state.get_player_country()
	game_state.set_consumption_tax_rate(korea.id, 0)
	game_state.set_property_tax_rate(korea.id, 0)
	game_state.advance_turn()
	if not _check(is_zero_approx(float(korea.weekly_stats.tax_revenue)), "Zero tax rate generated revenue"):
		return
	var low_tax_sol: float = korea.standard_of_living
	game_state.start_scenario()
	korea = game_state.get_player_country()
	game_state.set_consumption_tax_rate(korea.id, 50)
	game_state.set_property_tax_rate(korea.id, 0)
	game_state.advance_turn()
	if not _check(
		float(korea.weekly_stats.consumption_tax_revenue) > 0.0
		and is_zero_approx(float(korea.weekly_stats.property_tax_revenue)),
		"Consumption tax was not independent from property tax"
	):
		return
	var expected_consumption_tax: float = (
		float(korea.weekly_stats.consumption_value)
		+ float(korea.get_allocated_consumer_factories()) * 100.0
	) * 0.5 * game_state._economy_service.consumption_tax_alpha
	if not _check(
		is_equal_approx(float(korea.weekly_stats.consumption_tax_revenue), expected_consumption_tax),
		"Consumption tax did not include the civilian-factory tax value"
	):
		return
	if not _check(korea.standard_of_living < low_tax_sol, "Higher tax did not reduce the living-standard path"):
		return
	game_state.start_scenario()
	korea = game_state.get_player_country()
	game_state._economy_service.advance_week([korea], game_state.items_by_id, game_state.item_order)
	var expected_baseline_consumption_tax: float = (
		float(korea.weekly_stats.consumption_value)
		+ float(korea.get_allocated_consumer_factories())
		* game_state._economy_service.civilian_factory_tax_value
	) * korea.consumption_tax_rate * game_state._economy_service.consumption_tax_alpha
	var expected_baseline_property_tax: float = (
		float(korea.standard_of_living)
		* float(korea.real_gdp)
		* float(korea.property_tax_rate)
		* game_state._economy_service.property_tax_alpha
		/ 52.0
	)
	var balanced_weekly_tax := float(korea.weekly_stats.tax_revenue)
	if not _check(
		is_equal_approx(
			float(korea.weekly_stats.consumption_tax_revenue),
			expected_baseline_consumption_tax
		)
		and is_equal_approx(
			float(korea.weekly_stats.property_tax_revenue),
			expected_baseline_property_tax
		)
		and balanced_weekly_tax >= 900.0
		and balanced_weekly_tax <= 1100.0,
		"Korea's default weekly tax revenue escaped the balanced $900-$1,100 range"
	):
		return

	game_state.start_scenario()
	korea = game_state.get_player_country()
	game_state.set_consumption_tax_rate(korea.id, 0)
	game_state.set_property_tax_rate(korea.id, 50)
	var gdp_before_property_week: float = korea.real_gdp
	game_state._economy_service.advance_week([korea], game_state.items_by_id, game_state.item_order)
	if not _check(
		is_zero_approx(float(korea.weekly_stats.consumption_tax_revenue))
		and float(korea.weekly_stats.property_tax_revenue) > 0.0,
		"Property tax was not independent from consumption tax"
	):
		return
	var expected_output_value := 0.0
	var resource_output_value := 0.0
	for item_id: StringName in game_state.item_order:
		var item = game_state.get_item(item_id)
		var item_output_value := (
			float(korea.weekly_stats[item_id].produced) * float(korea.prices[item_id])
		)
		expected_output_value += item_output_value
		if item.civilian_kind == ItemClass.CivilianKind.RESOURCE:
			resource_output_value += item_output_value
	var short_term_output: float = game_state._economy_service._history_average(
		korea.weekly_output_value_history,
		12
	)
	var long_term_output: float = game_state._economy_service._history_average(
		korea.weekly_output_value_history,
		52
	)
	var annual_growth: float = game_state._economy_service._annual_gdp_growth(
		short_term_output,
		long_term_output
	)
	var expected_gdp := gdp_before_property_week * pow(1.0 + annual_growth, 1.0 / 52.0)
	if not _check(
		korea.weekly_output_value_history.size() == 52
		and resource_output_value > 0.0
		and is_equal_approx(float(korea.weekly_stats.domestic_production_value), expected_output_value)
		and is_equal_approx(float(korea.weekly_stats.short_term_output_value), short_term_output)
		and is_equal_approx(float(korea.weekly_stats.long_term_output_value), long_term_output)
		and is_equal_approx(float(korea.weekly_stats.annual_gdp_growth_rate), annual_growth)
		and is_equal_approx(korea.real_gdp, expected_gdp),
		"GDP did not use all civilian output and the 12/52-week growth signal"
	):
		return
	var expected_property_tax: float = (
		float(korea.standard_of_living)
		* float(korea.real_gdp)
		* 0.5
		* game_state._economy_service.property_tax_alpha
		/ 52.0
	)
	if not _check(
		is_equal_approx(float(korea.weekly_stats.property_tax_revenue), expected_property_tax),
		"Property tax did not match the configured formula"
	):
		return

	game_state.start_scenario()
	korea = game_state.get_player_country()
	var gdp_before_zero_week: float = korea.real_gdp
	korea.consumer_ratio = 0
	korea.production_allocations.clear()
	game_state._economy_service.advance_week([korea], game_state.items_by_id, game_state.item_order)
	var minimum_weekly_factor := pow(0.88, 1.0 / 52.0)
	if not _check(
		korea.weekly_output_value_history.size() == 52
		and is_zero_approx(float(korea.weekly_stats.domestic_production_value))
		and korea.real_gdp < gdp_before_zero_week,
		"A zero-production week did not lower GDP gradually"
	):
		return
	if not _check(
		korea.real_gdp >= gdp_before_zero_week * minimum_weekly_factor,
		"A single week exceeded the annual -12% GDP contraction limit"
	):
		return

	game_state.start_scenario()
	korea = game_state.get_player_country()
	korea.consumer_ratio = 0
	korea.production_allocations.clear()
	korea.weekly_output_value_history.clear()
	for _week: int in 52:
		korea.weekly_output_value_history.append(0.0)
	var gdp_before_collapse: float = korea.real_gdp
	for _week: int in 52:
		game_state._economy_service.advance_week([korea], game_state.items_by_id, game_state.item_order)
	if not _check(
		is_equal_approx(korea.real_gdp, gdp_before_collapse * 0.88),
		"Fifty-two maximum-contraction weeks did not produce exactly -12% GDP"
	):
		return

	game_state.start_scenario()
	korea = game_state.get_player_country()
	var gdp_before_surge: float = korea.real_gdp
	for _week: int in 52:
		korea.weekly_output_value_history.clear()
		for _seed_week: int in 52:
			korea.weekly_output_value_history.append(0.0)
		game_state._economy_service.advance_week([korea], game_state.items_by_id, game_state.item_order)
	if not _check(
		is_equal_approx(korea.real_gdp, gdp_before_surge * 1.12),
		"Fifty-two maximum-growth weeks did not produce exactly +12% GDP"
	):
		return
	if not _check(
		is_equal_approx(game_state._economy_service._annual_gdp_growth(1.0, 0.0), 0.12)
		and is_equal_approx(game_state._economy_service._annual_gdp_growth(0.0, 0.0), -0.12),
		"Zero-baseline GDP growth fallbacks escaped the annual limits"
	):
		return

	game_state.start_scenario()
	korea = game_state.get_player_country()
	korea.weekly_output_value_history.clear()
	for _week: int in 52:
		korea.weekly_output_value_history.append(123456.0)
	for _week: int in 52:
		game_state._economy_service.advance_week([korea], game_state.items_by_id, game_state.item_order)
	var initial_seed_expired := true
	for output_value: float in korea.weekly_output_value_history:
		if is_equal_approx(output_value, 123456.0):
			initial_seed_expired = false
			break
	if not _check(initial_seed_expired, "Configured output seed did not expire after 52 weeks"):
		return

	game_state.start_scenario()
	korea = game_state.get_player_country()
	game_state._economy_service.advance_week([korea], game_state.items_by_id, game_state.item_order)
	if not _check(
		is_zero_approx(float(korea.weekly_stats.import_value)) and korea.real_gdp > 0.0,
		"Closed economy domestic production did not produce real GDP"
	):
		return

	game_state.start_scenario()
	korea = game_state.get_player_country()
	result = game_state.set_consumer_ratio(korea.id, 100)
	if not _check(result.ok, "Consumer ratio could not be raised for the zero-trade test"):
		return
	for item_id: StringName in game_state.item_order:
		korea.inventory[item_id] = 0.0
	game_state._economy_service.advance_week(
		game_state._ordered_countries(),
		game_state.items_by_id,
		game_state.item_order
	)
	if not _check(
		korea.get_trade_factories() == 0
		and is_zero_approx(game_state.get_trade_dollar_capacity(korea.id))
		and is_zero_approx(float(korea.weekly_stats.trade_dollars_generated))
		and is_zero_approx(float(korea.weekly_stats.trade_dollars_spent))
		and is_zero_approx(float(korea.weekly_stats.import_value)),
		"A country without trade factories still generated private dollars or imported goods"
	):
		return

	game_state.start_scenario()
	korea = game_state.get_player_country()
	var gdp_before_trade_week: float = korea.real_gdp
	var treasuries_before_trade := {}
	for country in game_state.countries_by_id.values():
		country.consumption_tax_rate = 0.0
		country.property_tax_rate = 0.0
		treasuries_before_trade[country.id] = country.treasury
	for item_id: StringName in game_state.item_order:
		korea.inventory[item_id] = 0.0
	game_state._economy_service.advance_week(
		game_state._ordered_countries(),
		game_state.items_by_id,
		game_state.item_order
	)
	var trade_week_output := 0.0
	for item_id: StringName in game_state.item_order:
		trade_week_output += (
			float(korea.weekly_stats[item_id].produced) * float(korea.prices[item_id])
		)
	var trade_left_all_treasuries_unchanged := true
	for country in game_state.countries_by_id.values():
		if not is_equal_approx(
			float(country.treasury),
			float(treasuries_before_trade[country.id])
		):
			trade_left_all_treasuries_unchanged = false
			break
	if not _check(
		float(korea.weekly_stats.import_value) > 0.0
		and is_equal_approx(float(korea.weekly_stats.trade_dollars_generated), 600.0)
		and is_equal_approx(
			float(korea.weekly_stats.trade_dollars_spent),
			float(korea.weekly_stats.import_value)
		)
		and float(korea.weekly_stats.trade_dollars_spent) <= 600.0
		and trade_left_all_treasuries_unchanged
		and is_equal_approx(float(korea.weekly_stats.domestic_production_value), trade_week_output)
		and korea.real_gdp <= gdp_before_trade_week * pow(1.12, 1.0 / 52.0)
		and korea.real_gdp >= gdp_before_trade_week * pow(0.88, 1.0 / 52.0),
		"Private trade dollars, treasury isolation, or the GDP trade boundary regressed"
	):
		return

	game_state.start_scenario()
	korea = game_state.get_player_country()
	game_state.set_consumption_tax_rate(korea.id, 33)
	game_state.set_property_tax_rate(korea.id, 17)
	game_state.advance_turn()
	var saved_turn: int = game_state.current_turn
	var saved_treasury: float = korea.treasury
	var saved_real_gdp: float = korea.real_gdp
	var saved_output_history: Array[float] = korea.weekly_output_value_history.duplicate()
	result = game_state.save_game(TEST_SAVE_PATH)
	if not _check(result.ok, "Test save failed: %s" % result.message):
		return
	game_state.set_consumption_tax_rate(korea.id, 0)
	game_state.set_property_tax_rate(korea.id, 0)
	game_state.advance_turn()
	result = game_state.load_game(TEST_SAVE_PATH)
	if not _check(result.ok, "Test load failed: %s" % result.message):
		return
	korea = game_state.get_player_country()
	if not _check(game_state.current_turn == saved_turn, "Save did not restore the turn"):
		return
	if not _check(
		is_equal_approx(korea.consumption_tax_rate, 0.33)
		and is_equal_approx(korea.property_tax_rate, 0.17),
		"Save did not restore the independent tax rates"
	):
		return
	if not _check(is_equal_approx(korea.treasury, saved_treasury), "Save did not restore the treasury"):
		return
	if not _check(is_equal_approx(korea.real_gdp, saved_real_gdp), "Save did not restore real GDP"):
		return
	var output_history_restored: bool = (
		korea.weekly_output_value_history.size() == saved_output_history.size()
	)
	if output_history_restored:
		for index: int in saved_output_history.size():
			if not is_equal_approx(korea.weekly_output_value_history[index], saved_output_history[index]):
				output_history_restored = false
				break
	if not _check(output_history_restored, "Save did not restore GDP output history"):
		return
	var legacy_v3_result: Dictionary = game_state._save_service.read_file(TEST_SAVE_PATH)
	if not _check(legacy_v3_result.ok, "Could not reopen save for v3 GDP migration test"):
		return
	var legacy_v3_data: Dictionary = legacy_v3_result.data
	legacy_v3_data.schema_version = 3
	for country_data: Dictionary in legacy_v3_data.countries:
		country_data.real_gdp = 123.0
		country_data.weekly_real_gdp_history = [1.0, 2.0, 3.0]
		country_data.erase("weekly_output_value_history")
	var legacy_v3_file := FileAccess.open(TEST_SAVE_PATH, FileAccess.WRITE)
	if not _check(legacy_v3_file != null, "Could not create v3 GDP migration fixture"):
		return
	legacy_v3_file.store_string(JSON.stringify(legacy_v3_data))
	legacy_v3_file = null
	result = game_state.load_game(TEST_SAVE_PATH)
	if not _check(result.ok, "v3 GDP migration failed: %s" % result.message):
		return
	korea = game_state.get_player_country()
	var migrated_output_history_valid: bool = korea.weekly_output_value_history.size() == 52
	for output_value: float in korea.weekly_output_value_history:
		if not is_equal_approx(output_value, 630.0):
			migrated_output_history_valid = false
			break
	if not _check(
		migrated_output_history_valid
		and is_equal_approx(korea.real_gdp, 1646739.0)
		and is_equal_approx(korea.treasury, saved_treasury)
		and is_equal_approx(korea.consumption_tax_rate, 0.33)
		and is_equal_approx(korea.property_tax_rate, 0.17),
		"v3 migration did not rebase GDP while preserving other country state"
	):
		return

	var state_before_invalid_load: float = korea.treasury
	result = game_state.save_game(TEST_SAVE_PATH)
	if not _check(result.ok, "Could not create v4 output-history validation fixture"):
		return
	var invalid_history_result: Dictionary = game_state._save_service.read_file(TEST_SAVE_PATH)
	if not _check(invalid_history_result.ok, "Could not reopen v4 output-history fixture"):
		return
	var invalid_history_data: Dictionary = invalid_history_result.data
	invalid_history_data.countries[0].weekly_output_value_history.pop_back()
	var invalid_history_file := FileAccess.open(TEST_SAVE_PATH, FileAccess.WRITE)
	if not _check(invalid_history_file != null, "Could not write invalid output-history fixture"):
		return
	invalid_history_file.store_string(JSON.stringify(invalid_history_data))
	invalid_history_file = null
	result = game_state.load_game(TEST_SAVE_PATH)
	if not _check(not result.ok, "A v4 save with a short output history was accepted"):
		return
	if not _check(korea.treasury == state_before_invalid_load, "Rejected output history changed live game state"):
		return

	var corrupt_file := FileAccess.open(TEST_SAVE_PATH, FileAccess.WRITE)
	corrupt_file.store_string("{not valid json")
	corrupt_file = null
	result = game_state.load_game(TEST_SAVE_PATH)
	if not _check(not result.ok, "Corrupt save file was accepted"):
		return
	if not _check(korea.treasury == state_before_invalid_load, "Corrupt load changed live game state"):
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE_PATH))

	game_state.start_scenario()
	for turn: int in 100:
		result = game_state.advance_turn()
		if not _check(result.ok, "100-turn stability run failed"):
			return
	for country in game_state.countries_by_id.values():
		var accounted_factories: int = (
			country.get_effective_consumer_factories()
			+ country.get_active_construction_count()
			+ country.get_trade_factories()
		)
		if not _check(accounted_factories == country.civilian_factories, "Factory allocation stopped balancing"):
			return
		for item_id: StringName in game_state.item_order:
			if not _check(
				is_finite(float(country.inventory[item_id]))
				and is_finite(float(country.prices[item_id]))
				and float(country.inventory[item_id]) >= 0.0,
				"100-turn run produced an invalid market value"
			):
				return

	game_state.start_scenario()
	korea = game_state.get_player_country()
	var main_scene := load("res://Main.tscn") as PackedScene
	var main := main_scene.instantiate()
	root.add_child(main)
	await process_frame
	var economy_ui := main.get_node_or_null("EconomyUI")
	if not _check(economy_ui != null, "Main scene is missing the economy UI"):
		return
	if not _check(
		str(economy_ui.call("_format_gdp", 1646739.0)) == "$1.65T",
		"Economy UI did not format map GDP as real US dollars"
	):
		return
	economy_ui.call("_on_consumer_ratio_changed", 42.0)
	economy_ui.call("_on_consumption_tax_rate_changed", 25.0)
	economy_ui.call("_on_property_tax_rate_changed", 15.0)
	if not _check(
		korea.consumer_ratio == 42
		and is_equal_approx(korea.consumption_tax_rate, 0.25)
		and is_equal_approx(korea.property_tax_rate, 0.15)
		and "무역 구매력 $600/주" in str(economy_ui._trade_dollars_label.text)
		and str(economy_ui._treasury_label.text).begins_with("국고 $")
		and str(economy_ui._tax_income_label.text).begins_with("세수 $")
		and "₩" not in str(economy_ui._treasury_label.text)
		and "₩" not in str(economy_ui._tax_income_label.text),
		"Economy UI policy controls did not reach GameState"
	):
		return
	economy_ui.call("_on_province_selected", korea.owned_province_ids[0])
	economy_ui.call("_on_start_construction", game_state.BUILDING_CIVILIAN)
	if not _check(korea.construction_projects.size() == 1, "Construction UI did not start a project on the selected province"):
		return
	main.queue_free()
	print("OK: economy allocation, private trade dollars, output-trend GDP, fiscal policy, save/load, AI, and 100-turn stability verified")
	quit(0)


func _check(condition: bool, message: String) -> bool:
	if condition:
		return true
	push_error(message)
	quit(1)
	return false
