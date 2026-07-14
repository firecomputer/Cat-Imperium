extends SceneTree

const TEST_SAVE_PATH := "user://economy_test_save.json"


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
	if not _check(game_state.countries_by_id.size() == 3, "East Asia scenario did not load three countries"):
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
	game_state.set_tax_rate(korea.id, 0)
	game_state.advance_turn()
	if not _check(is_zero_approx(float(korea.weekly_stats.tax_revenue)), "Zero tax rate generated revenue"):
		return
	var low_tax_sol: float = korea.standard_of_living
	game_state.start_scenario()
	korea = game_state.get_player_country()
	game_state.set_tax_rate(korea.id, 50)
	game_state.advance_turn()
	if not _check(float(korea.weekly_stats.tax_revenue) > 0.0, "Maximum tax rate generated no revenue"):
		return
	if not _check(korea.standard_of_living < low_tax_sol, "Higher tax did not reduce the living-standard path"):
		return

	game_state.start_scenario()
	korea = game_state.get_player_country()
	game_state.set_tax_rate(korea.id, 33)
	game_state.advance_turn()
	var saved_turn: int = game_state.current_turn
	var saved_treasury: float = korea.treasury
	result = game_state.save_game(TEST_SAVE_PATH)
	if not _check(result.ok, "Test save failed: %s" % result.message):
		return
	game_state.set_tax_rate(korea.id, 0)
	game_state.advance_turn()
	result = game_state.load_game(TEST_SAVE_PATH)
	if not _check(result.ok, "Test load failed: %s" % result.message):
		return
	korea = game_state.get_player_country()
	if not _check(game_state.current_turn == saved_turn, "Save did not restore the turn"):
		return
	if not _check(is_equal_approx(korea.tax_rate, 0.33), "Save did not restore the tax rate"):
		return
	if not _check(is_equal_approx(korea.treasury, saved_treasury), "Save did not restore the treasury"):
		return

	var state_before_invalid_load: float = korea.treasury
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
	economy_ui.call("_on_consumer_ratio_changed", 42.0)
	economy_ui.call("_on_tax_rate_changed", 25.0)
	if not _check(korea.consumer_ratio == 42 and is_equal_approx(korea.tax_rate, 0.25), "Economy UI policy controls did not reach GameState"):
		return
	economy_ui.call("_on_province_selected", korea.owned_province_ids[0])
	economy_ui.call("_on_start_construction", game_state.BUILDING_CIVILIAN)
	if not _check(korea.construction_projects.size() == 1, "Construction UI did not start a project on the selected province"):
		return
	main.queue_free()
	print("OK: economy allocation, construction, market, fiscal policy, save/load, AI, and 100-turn stability verified")
	quit(0)


func _check(condition: bool, message: String) -> bool:
	if condition:
		return true
	push_error(message)
	quit(1)
	return false
