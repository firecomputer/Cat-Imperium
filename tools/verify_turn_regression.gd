extends SceneTree

const CHECKPOINT_TURNS: Array[int] = [1, 15, 100]
const EXPECTED_CHECKPOINT_HASHES := {
	1: "4a9de63e828ba9beeae2e9bd5f704e99069d63fdc906d12d4cfd93e9758df04c",
	15: "6f62e6edef98f7c8c3b67137374fc9e7a5bb130525c96a1e25a69f51109d614f",
	100: "895e62bf24990c25474e1209154ad74c00320630fbcf617813379402dcc71b94",
}

var _events: Array[Dictionary] = []
var _game_state: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_game_state = root.get_node_or_null("GameState")
	if not _check(_game_state != null, "GameState autoload is missing"):
		return
	if not _game_state.is_initialized:
		await _game_state.initialized

	_game_state.turn_started.connect(_on_turn_started)
	_game_state.country_economy_changed.connect(_on_country_economy_changed)
	_game_state.construction_changed.connect(_on_construction_changed)
	_game_state.turn_completed.connect(_on_turn_completed)

	var baseline := _run_checkpoints(false)
	if baseline.is_empty():
		return
	var reordered := _run_checkpoints(true)
	if reordered.is_empty():
		return
	for turn: int in CHECKPOINT_TURNS:
		if not _check(
			str(baseline[turn]) == str(reordered[turn]),
			"Country dictionary order changed the turn %d result" % turn
		):
			return
		var expected := str(EXPECTED_CHECKPOINT_HASHES[turn])
		if expected.is_empty():
			print("TURN_REGRESSION_HASH[%d]=%s" % [turn, baseline[turn]])
		elif not _check(str(baseline[turn]) == expected, "Turn %d baseline changed" % turn):
			return

	if not _check(
		_economy_week_hash(false) == _economy_week_hash(true),
		"EconomyService result changed when its country input order was reversed"
	):
		return
	if not _verify_turn_boundary_and_signal_order():
		return
	if not _verify_cancel_contract():
		return

	print("OK: deterministic checkpoints, order independence, turn boundary, signals, and cancellation verified")
	quit(0)


func _run_checkpoints(reverse_country_dictionaries: bool) -> Dictionary:
	var result: Dictionary = _game_state.start_scenario()
	if not _check(result.ok, "Scenario failed to start: %s" % result.message):
		return {}
	if reverse_country_dictionaries:
		_reverse_country_dictionaries()
	var hashes := {}
	for turn: int in range(1, CHECKPOINT_TURNS[-1] + 1):
		result = _game_state.advance_turn()
		if not _check(result.ok, "Turn %d failed: %s" % [turn, result.message]):
			return {}
		if turn in CHECKPOINT_TURNS:
			hashes[turn] = _snapshot_hash()
	return hashes


func _reverse_country_dictionaries() -> void:
	var reversed_by_code := {}
	var reversed_by_id := {}
	var codes: Array = _game_state.ACTIVE_COUNTRY_CODES.duplicate()
	codes.reverse()
	for code: StringName in codes:
		var country = _game_state.get_country_by_code(code)
		reversed_by_code[code] = country
		reversed_by_id[country.id] = country
	_game_state.countries_by_code = reversed_by_code
	_game_state.countries_by_id = reversed_by_id


func _economy_week_hash(reverse_countries: bool) -> String:
	var result: Dictionary = _game_state.start_scenario()
	if not _check(result.ok, "Scenario reset failed before direct economy verification"):
		return ""
	var countries: Array = []
	for code: StringName in _game_state.ACTIVE_COUNTRY_CODES:
		countries.append(_game_state.get_country_by_code(code))
	if reverse_countries:
		countries.reverse()
	_game_state._economy_service.advance_week(countries, _game_state.items_by_id, _game_state.item_order)
	_game_state._economy_service.update_ai_production(
		countries,
		_game_state.player_country_id,
		_game_state.items_by_id,
		_game_state.item_order
	)
	return _snapshot_hash()


func _verify_turn_boundary_and_signal_order() -> bool:
	var result: Dictionary = _game_state.start_scenario()
	if not _check(result.ok, "Scenario reset failed before turn-boundary verification"):
		return false
	var korea = _game_state.get_player_country()
	var province_id: int = korea.owned_province_ids[0]
	result = _game_state.start_construction(korea.id, province_id, _game_state.BUILDING_CIVILIAN)
	if not _check(result.ok, "Turn-boundary construction failed to start"):
		return false
	korea.construction_projects[0].remaining_days = _game_state.TURN_DAYS
	result = _game_state.set_consumer_ratio(korea.id, 100)
	if not _check(result.ok, "Turn-boundary consumer policy failed"):
		return false

	_events.clear()
	result = _game_state.advance_turn()
	if not _check(result.ok, "Turn-boundary advance failed"):
		return false
	if not _check(not _events.is_empty() and _events[0].kind == "started", "turn_started was not the first turn signal"):
		return false
	if not _check(_events[-1].kind == "completed", "turn_completed was not the last turn signal"):
		return false
	if not _check(int(_events[0].observed_turn) == 0, "turn_started was emitted after incrementing the turn"):
		return false
	if not _check(int(_events[-1].observed_turn) == 1, "turn_completed was emitted before incrementing the turn"):
		return false
	var completion_signal_index := -1
	var first_final_country_signal_index := -1
	for index: int in _events.size():
		var event: Dictionary = _events[index]
		if (
			event.kind == "construction"
			and int(event.country_id) == korea.id
			and int(event.province_id) == province_id
		):
			completion_signal_index = index
		if event.kind == "country" and int(event.observed_turn) == 1 and first_final_country_signal_index < 0:
			first_final_country_signal_index = index
	if not _check(
		completion_signal_index > 0 and completion_signal_index < first_final_country_signal_index,
		"Construction completion was not signaled before final country refresh signals"
	):
		return false
	if not _check(korea.civilian_factories == 11, "Construction did not complete at the seven-day boundary"):
		return false
	var produced_factories := 0.0
	for item_id: StringName in _game_state.item_order:
		var item = _game_state.get_item(item_id)
		produced_factories += float(korea.weekly_stats[item_id].produced) / maxf(item.production_per_factory, 0.001)
	if not _check(is_equal_approx(produced_factories, 9.0), "A factory completed this turn contributed production too early"):
		return false
	return true


func _verify_cancel_contract() -> bool:
	var result: Dictionary = _game_state.start_scenario()
	if not _check(result.ok, "Scenario reset failed before cancellation verification"):
		return false
	var korea = _game_state.get_player_country()
	var province_id: int = korea.owned_province_ids[0]
	result = _game_state.start_construction(korea.id, province_id, _game_state.BUILDING_CIVILIAN)
	if not _check(result.ok, "Cancellation project failed to start"):
		return false
	var treasury_after_start: float = korea.treasury
	var wood_after_start := float(korea.inventory[&"wood"])
	result = _game_state.cancel_construction(korea.id, province_id)
	if not _check(result.ok, "Cancellation command failed"):
		return false
	if not _check(korea.construction_projects.is_empty(), "Cancelled project remained active"):
		return false
	if not _check(korea.get_trade_factories() == 6, "Cancelled project did not release its civilian factory"):
		return false
	if not _check(
		is_equal_approx(korea.treasury, treasury_after_start)
		and is_equal_approx(float(korea.inventory[&"wood"]), wood_after_start),
		"Cancellation refunded spent money or materials"
	):
		return false
	return true


func _snapshot_hash() -> String:
	var countries: Array = []
	for code: StringName in _game_state.ACTIVE_COUNTRY_CODES:
		var country = _game_state.get_country_by_code(code)
		countries.append(country.to_save_data())
	var snapshot := {
		"turn": _game_state.current_turn,
		"elapsed_days": _game_state.elapsed_days,
		"date": _game_state.get_date_string(),
		"countries": countries,
	}
	return JSON.stringify(_canonicalize(snapshot)).sha256_text()


func _canonicalize(value: Variant) -> Variant:
	if typeof(value) == TYPE_DICTIONARY:
		var source: Dictionary = value
		var keys: Array = source.keys()
		keys.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
		var result := {}
		for key: Variant in keys:
			result[str(key)] = _canonicalize(source[key])
		return result
	if typeof(value) == TYPE_ARRAY:
		var result: Array = []
		for entry: Variant in value:
			result.append(_canonicalize(entry))
		return result
	return value


func _on_turn_started(_turn_number: int) -> void:
	_events.append({"kind": "started", "observed_turn": _game_state.current_turn})


func _on_country_economy_changed(country_id: int) -> void:
	_events.append({"kind": "country", "country_id": country_id, "observed_turn": _game_state.current_turn})


func _on_construction_changed(country_id: int, province_id: int) -> void:
	_events.append({
		"kind": "construction",
		"country_id": country_id,
		"province_id": province_id,
		"observed_turn": _game_state.current_turn,
	})


func _on_turn_completed(_turn_number: int) -> void:
	_events.append({"kind": "completed", "observed_turn": _game_state.current_turn})


func _check(condition: bool, message: String) -> bool:
	if condition:
		return true
	push_error(message)
	quit(1)
	return false
