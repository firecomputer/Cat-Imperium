extends Node

signal initialized
signal turn_started(turn_number: int)
signal turn_completed(turn_number: int)
signal country_economy_changed(country_id: int)
signal construction_changed(country_id: int, province_id: int)
signal game_loaded

const ECONOMY_CATALOG_PATH := "res://data/economy_catalog.json"
const DEFAULT_SAVE_PATH := "user://savegame.json"
const SAVE_SCHEMA_VERSION := 1
const SCENARIO_ID := "east_asia_economy"
const ACTIVE_COUNTRY_CODES: Array[StringName] = [&"KOR", &"CHN", &"JPN"]
const PLAYER_COUNTRY_CODE := &"KOR"
const TURN_DAYS := 7
const CONSTRUCTION_DAYS := 100

const BUILDING_CIVILIAN := &"civilian_factory"
const BUILDING_MILITARY := &"military_factory"
const BUILDING_DOCKYARD := &"dockyard"
const CONSTRUCTION_REQUIREMENTS := {
	BUILDING_CIVILIAN: {
		"cost": 5000.0,
		"materials": {&"wood": 30.0, &"concrete": 40.0, &"steel": 20.0, &"glass": 10.0},
	},
	BUILDING_MILITARY: {
		"cost": 7500.0,
		"materials": {&"wood": 20.0, &"concrete": 40.0, &"steel": 40.0, &"glass": 10.0},
	},
	BUILDING_DOCKYARD: {
		"cost": 8000.0,
		"materials": {&"wood": 40.0, &"concrete": 30.0, &"steel": 30.0, &"glass": 10.0},
	},
}

const CountryClass = preload("res://scripts/country.gd")
const ItemClass = preload("res://scripts/item.gd")

var countries_by_id: Dictionary = {}
var countries_by_code: Dictionary = {}
var items_by_id: Dictionary = {}
var item_order: Array[StringName] = []
var sample_country: CountryClass
var player_country_id := 0
var current_turn := 0
var elapsed_days := 0
var start_date := "2026-01-01"
var is_initialized := false

var _catalog: Dictionary = {}


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


func get_date_string() -> String:
	var unix_time := Time.get_unix_time_from_datetime_string("%sT00:00:00" % start_date)
	unix_time += elapsed_days * 86400
	var date := Time.get_date_dict_from_unix_time(int(unix_time))
	return "%04d-%02d-%02d" % [date.year, date.month, date.day]


func get_construction_requirements(building_type: StringName) -> Dictionary:
	return CONSTRUCTION_REQUIREMENTS.get(building_type, {}).duplicate(true)


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
	for record: Dictionary in ProvinceMapDB.countries:
		var country_code := StringName(str(record.get("code", "")))
		if country_code not in ACTIVE_COUNTRY_CODES:
			continue
		var country: CountryClass = CountryClass.new()
		country.load_map_record(record)
		country.apply_scenario_preset(presets.get(str(country_code), {}))
		_initialize_country_market(country, presets.get(str(country_code), {}))
		countries_by_id[country.id] = country
		countries_by_code[country.code] = country

	if countries_by_code.size() != ACTIVE_COUNTRY_CODES.size():
		return _result(false, "한·중·일 시나리오 국가 데이터를 모두 찾지 못했습니다.")
	sample_country = countries_by_code.get(PLAYER_COUNTRY_CODE)
	player_country_id = sample_country.id
	is_initialized = true
	initialized.emit()
	return _result(true)


func advance_turn() -> Dictionary:
	if not is_initialized:
		return _result(false, "게임이 초기화되지 않았습니다.")
	turn_started.emit(current_turn + 1)
	for country: CountryClass in _ordered_countries():
		_ensure_allocations(country)
		country.reset_weekly_stats(item_order)
	_produce_goods()
	_run_trade()
	_consume_and_update_economies()
	_run_ai_decisions()
	_advance_construction()
	current_turn += 1
	elapsed_days += TURN_DAYS
	for country: CountryClass in _ordered_countries():
		country_economy_changed.emit(country.id)
	turn_completed.emit(current_turn)
	return _result(true)


func set_consumer_ratio(country_id: int, percent: int) -> Dictionary:
	var country := get_country(country_id)
	if country == null:
		return _result(false, "국가를 찾을 수 없습니다.")
	if country_id != player_country_id:
		return _result(false, "플레이어 국가의 정책만 변경할 수 있습니다.")
	country.consumer_ratio = percent
	_ensure_allocations(country)
	country_economy_changed.emit(country.id)
	return _result(true)


func set_tax_rate(country_id: int, percent: float) -> Dictionary:
	var country := get_country(country_id)
	if country == null:
		return _result(false, "국가를 찾을 수 없습니다.")
	if country_id != player_country_id:
		return _result(false, "플레이어 국가의 정책만 변경할 수 있습니다.")
	country.tax_rate = percent / 100.0
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
	if country == null or country_id != player_country_id:
		return _result(false, "플레이어 국가의 건설만 취소할 수 있습니다.")
	for index: int in country.construction_projects.size():
		var project: Dictionary = country.construction_projects[index]
		if int(project.get("province_id", 0)) == province_id:
			country.construction_projects.remove_at(index)
			_ensure_allocations(country)
			construction_changed.emit(country.id, province_id)
			country_economy_changed.emit(country.id)
			return _result(true, "건설을 취소했습니다. 이미 사용한 비용과 자재는 환불되지 않습니다.")
	return _result(false, "취소할 건설이 없습니다.")


func save_game(path: String = DEFAULT_SAVE_PATH) -> Dictionary:
	if not is_initialized:
		return _result(false, "저장할 게임이 없습니다.")
	var country_data: Array = []
	for country: CountryClass in _ordered_countries():
		country_data.append(country.to_save_data())
	var data := {
		"schema_version": SAVE_SCHEMA_VERSION,
		"scenario_id": SCENARIO_ID,
		"turn": current_turn,
		"elapsed_days": elapsed_days,
		"start_date": start_date,
		"player_country_id": player_country_id,
		"countries": country_data,
	}
	var temporary_path := "%s.tmp" % path
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return _result(false, "저장 파일을 만들 수 없습니다.")
	file.store_string(JSON.stringify(data, "  "))
	file = null
	var target_absolute := ProjectSettings.globalize_path(path)
	var temporary_absolute := ProjectSettings.globalize_path(temporary_path)
	var backup_path := "%s.bak" % path
	var backup_absolute := ProjectSettings.globalize_path(backup_path)
	if FileAccess.file_exists(path):
		if FileAccess.file_exists(backup_path):
			DirAccess.remove_absolute(backup_absolute)
		var backup_error := DirAccess.rename_absolute(target_absolute, backup_absolute)
		if backup_error != OK:
			DirAccess.remove_absolute(temporary_absolute)
			return _result(false, "기존 저장 파일을 보호할 수 없습니다.")
	var rename_error := DirAccess.rename_absolute(temporary_absolute, target_absolute)
	if rename_error != OK:
		if FileAccess.file_exists(backup_path):
			DirAccess.rename_absolute(backup_absolute, target_absolute)
		return _result(false, "임시 저장 파일을 확정할 수 없습니다.")
	if FileAccess.file_exists(backup_path):
		DirAccess.remove_absolute(backup_absolute)
	return _result(true, "게임을 저장했습니다.")


func load_game(path: String = DEFAULT_SAVE_PATH) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _result(false, "저장 파일이 없습니다.")
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK:
		return _result(false, "저장 파일 형식이 올바르지 않습니다.")
	var parsed: Variant = parser.data
	if typeof(parsed) != TYPE_DICTIONARY:
		return _result(false, "저장 파일 형식이 올바르지 않습니다.")
	var data: Dictionary = parsed
	var validation := _validate_save_data(data)
	if not validation.ok:
		return validation
	var start_result := start_scenario(str(data.get("scenario_id", "")))
	if not start_result.ok:
		return start_result
	for country_data: Dictionary in data.get("countries", []):
		var country := get_country(int(country_data.get("id", 0)))
		country.apply_save_data(country_data)
	current_turn = int(data.get("turn", 0))
	elapsed_days = int(data.get("elapsed_days", 0))
	start_date = str(data.get("start_date", start_date))
	player_country_id = int(data.get("player_country_id", player_country_id))
	game_loaded.emit()
	for country: CountryClass in _ordered_countries():
		country_economy_changed.emit(country.id)
	return _result(true, "게임을 불러왔습니다.")


func _initialize_countries() -> void:
	if is_initialized:
		return
	var result := start_scenario()
	if not result.ok:
		push_error(result.message)


func _load_catalog() -> Dictionary:
	if not _catalog.is_empty() and not items_by_id.is_empty():
		return _result(true)
	var file := FileAccess.open(ECONOMY_CATALOG_PATH, FileAccess.READ)
	if file == null:
		return _result(false, "경제 품목 데이터를 열 수 없습니다.")
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return _result(false, "경제 품목 데이터 형식이 잘못되었습니다.")
	_catalog = parsed
	items_by_id.clear()
	item_order.clear()
	for record: Dictionary in _catalog.get("items", []):
		var item: ItemClass = ItemClass.new()
		item.load_catalog_record(record)
		if item.id.is_empty() or items_by_id.has(item.id):
			return _result(false, "경제 품목 ID가 없거나 중복되었습니다.")
		items_by_id[item.id] = item
		item_order.append(item.id)
	return _result(true)


func _initialize_country_market(country: CountryClass, preset: Dictionary) -> void:
	country.inventory.clear()
	country.prices.clear()
	var resources: Dictionary = preset.get("resources", {})
	for item_id: StringName in item_order:
		var item: ItemClass = items_by_id[item_id]
		country.prices[item_id] = item.base_price
		if item.civilian_kind == ItemClass.CivilianKind.RESOURCE:
			country.inventory[item_id] = float(resources.get(str(item_id), 0.0))
		else:
			var turns := 2.0 if item.civilian_kind == ItemClass.CivilianKind.ESSENTIAL else 1.0
			country.inventory[item_id] = _calculate_demand(country, item) * turns
	country.reset_weekly_stats(item_order)
	_ensure_allocations(country)


func _ordered_countries() -> Array:
	var result: Array = []
	for country_code: StringName in ACTIVE_COUNTRY_CODES:
		var country: CountryClass = countries_by_code.get(country_code)
		if country != null:
			result.append(country)
	return result


func _produce_goods() -> void:
	for country: CountryClass in _ordered_countries():
		for item_id: StringName in item_order:
			var factories := int(country.production_allocations.get(item_id, 0))
			if factories <= 0:
				continue
			var item: ItemClass = items_by_id[item_id]
			var amount := factories * item.production_per_factory
			country.inventory[item_id] = float(country.inventory.get(item_id, 0.0)) + amount
			var stats: Dictionary = country.weekly_stats[item_id]
			stats.produced = amount
			country.weekly_stats[item_id] = stats


func _run_trade() -> void:
	var working_inventory := {}
	var working_treasury := {}
	var requests: Array = []
	for country: CountryClass in _ordered_countries():
		working_inventory[country.id] = country.inventory.duplicate(true)
		working_treasury[country.id] = country.treasury
		var candidates := _trade_candidates(country, working_inventory[country.id])
		if candidates.is_empty():
			continue
		for slot: int in country.get_trade_factories():
			requests.append({
				"buyer_id": country.id,
				"slot": slot,
				"priority": float(candidates[0].price),
				"candidates": candidates,
			})
	requests.sort_custom(_sort_trade_requests)
	var transactions: Array = []
	for request: Dictionary in requests:
		var buyer: CountryClass = get_country(int(request.buyer_id))
		for candidate: Dictionary in request.candidates:
			var item_id := StringName(str(candidate.item_id))
			var item: ItemClass = items_by_id[item_id]
			var seller := _find_trade_seller_working(buyer, item, working_inventory)
			if seller == null:
				continue
			var seller_stock: Dictionary = working_inventory[seller.id]
			var buyer_stock: Dictionary = working_inventory[buyer.id]
			var surplus := float(seller_stock.get(item_id, 0.0)) - _target_inventory(seller, item)
			var quantity := minf(item.trade_batch_size, maxf(surplus, 0.0))
			var seller_price := float(seller.prices.get(item_id, item.base_price))
			var unit_cost := seller_price * 1.1
			quantity = minf(quantity, float(working_treasury[buyer.id]) / maxf(unit_cost, 0.001))
			if quantity < 0.01:
				continue
			buyer_stock[item_id] = float(buyer_stock.get(item_id, 0.0)) + quantity
			seller_stock[item_id] = float(seller_stock.get(item_id, 0.0)) - quantity
			working_inventory[buyer.id] = buyer_stock
			working_inventory[seller.id] = seller_stock
			working_treasury[buyer.id] = float(working_treasury[buyer.id]) - quantity * unit_cost
			working_treasury[seller.id] = float(working_treasury[seller.id]) + quantity * seller_price
			transactions.append({"buyer": buyer, "seller": seller, "item_id": item_id, "quantity": quantity})
			break
	for country: CountryClass in _ordered_countries():
		country.inventory = working_inventory[country.id]
		country.treasury = float(working_treasury[country.id])
	for transaction: Dictionary in transactions:
		var buyer_stats: Dictionary = transaction.buyer.weekly_stats[transaction.item_id]
		buyer_stats.imported = float(buyer_stats.imported) + float(transaction.quantity)
		transaction.buyer.weekly_stats[transaction.item_id] = buyer_stats
		var seller_stats: Dictionary = transaction.seller.weekly_stats[transaction.item_id]
		seller_stats.exported = float(seller_stats.exported) + float(transaction.quantity)
		transaction.seller.weekly_stats[transaction.item_id] = seller_stats


func _trade_candidates(buyer: CountryClass, stock: Dictionary) -> Array:
	var candidates: Array = []
	for item_id: StringName in item_order:
		var item: ItemClass = items_by_id[item_id]
		var target := _target_inventory(buyer, item)
		var amount := float(stock.get(item_id, 0.0))
		if amount + 0.001 < target:
			candidates.append({"item_id": item_id, "price": _target_price(buyer, item, amount)})
	candidates.sort_custom(_sort_trade_candidates)
	return candidates


func _find_trade_seller_working(buyer: CountryClass, item: ItemClass, working_inventory: Dictionary) -> CountryClass:
	var result: CountryClass
	var best_price := INF
	for seller: CountryClass in _ordered_countries():
		if seller == buyer:
			continue
		var seller_stock: Dictionary = working_inventory[seller.id]
		var surplus := float(seller_stock.get(item.id, 0.0)) - _target_inventory(seller, item)
		var price := float(seller.prices.get(item.id, item.base_price))
		if surplus >= 0.01 and (price < best_price or (is_equal_approx(price, best_price) and (result == null or seller.id < result.id))):
			result = seller
			best_price = price
	return result


func _sort_trade_requests(a: Dictionary, b: Dictionary) -> bool:
	if is_equal_approx(float(a.priority), float(b.priority)):
		if int(a.buyer_id) == int(b.buyer_id):
			return int(a.slot) < int(b.slot)
		return int(a.buyer_id) < int(b.buyer_id)
	return float(a.priority) > float(b.priority)


func _sort_trade_candidates(a: Dictionary, b: Dictionary) -> bool:
	if is_equal_approx(float(a.price), float(b.price)):
		return str(a.item_id) < str(b.item_id)
	return float(a.price) > float(b.price)


func _consume_and_update_economies() -> void:
	for country: CountryClass in _ordered_countries():
		var essential_requested := 0.0
		var essential_consumed := 0.0
		var luxury_requested := 0.0
		var luxury_consumed := 0.0
		var affordability_weight := 0.0
		var affordability_total := 0.0
		var taxable_value := 0.0
		for item_id: StringName in item_order:
			var item: ItemClass = items_by_id[item_id]
			var demand := _calculate_demand(country, item)
			var consumed := minf(demand, float(country.inventory.get(item_id, 0.0)))
			country.inventory[item_id] = maxf(float(country.inventory.get(item_id, 0.0)) - consumed, 0.0)
			var new_price := lerpf(
				float(country.prices.get(item_id, item.base_price)),
				_target_price(country, item, float(country.inventory.get(item_id, 0.0))),
				0.5
			)
			country.prices[item_id] = clampf(new_price, item.minimum_price, item.maximum_price)
			var stats: Dictionary = country.weekly_stats[item_id]
			stats.demand = demand
			stats.consumed = consumed
			country.weekly_stats[item_id] = stats
			if item.civilian_kind == ItemClass.CivilianKind.ESSENTIAL:
				var weighted_demand := demand * item.standard_of_living_weight
				var weighted_consumption := consumed * item.standard_of_living_weight
				essential_requested += weighted_demand
				essential_consumed += weighted_consumption
				affordability_weight += weighted_demand
				affordability_total += weighted_demand * clampf(
					item.base_price / maxf(float(country.prices[item_id]), 0.001), 0.0, 1.0
				)
			elif item.civilian_kind == ItemClass.CivilianKind.LUXURY:
				luxury_requested += demand
				luxury_consumed += consumed
			if item.civilian_kind != ItemClass.CivilianKind.RESOURCE:
				taxable_value += consumed * float(country.prices[item_id])

		var essential_fulfillment := essential_consumed / maxf(essential_requested, 0.001)
		var luxury_fulfillment := luxury_consumed / maxf(luxury_requested, 0.001)
		var affordability := affordability_total / maxf(affordability_weight, 0.001)
		var tax_burden := 1.0 - country.tax_rate * 0.5
		var target_sol := 10.0 * (
			0.60 * clampf(essential_fulfillment, 0.0, 1.0)
			+ 0.25 * clampf(affordability, 0.0, 1.0)
			+ 0.15 * clampf(luxury_fulfillment, 0.0, 1.0)
		) * tax_burden
		country.standard_of_living = lerpf(country.standard_of_living, target_sol, 0.25)
		var tax_revenue := taxable_value * country.tax_rate * (0.5 + country.standard_of_living / 20.0)
		country.treasury += tax_revenue
		country.weekly_stats.tax_revenue = tax_revenue


func _calculate_demand(country: CountryClass, item: ItemClass) -> float:
	if item.civilian_kind == ItemClass.CivilianKind.RESOURCE:
		return 0.0
	var demand := country.demand_index * item.demand_per_index
	if item.civilian_kind == ItemClass.CivilianKind.LUXURY:
		demand *= country.standard_of_living / 10.0
		demand *= 1.0 - country.tax_rate * 0.5
	return maxf(demand, 0.0)


func _target_inventory(country: CountryClass, item: ItemClass) -> float:
	if item.civilian_kind == ItemClass.CivilianKind.RESOURCE:
		return 40.0
	return _calculate_demand(country, item) * 2.0


func _target_price(country: CountryClass, item: ItemClass, stock: float) -> float:
	var target := _target_inventory(country, item)
	var scarcity := clampf((target - stock) / maxf(target, 1.0), -1.0, 1.0)
	return clampf(item.base_price * (1.0 + 1.5 * scarcity), item.minimum_price, item.maximum_price)


func _ensure_allocations(country: CountryClass) -> void:
	var capacity := country.get_effective_consumer_factories()
	while country.get_allocated_consumer_factories() > capacity:
		var remove_item := _most_overstocked_allocated_item(country)
		if remove_item.is_empty():
			break
		var count := int(country.production_allocations.get(remove_item, 0)) - 1
		if count <= 0:
			country.production_allocations.erase(remove_item)
		else:
			country.production_allocations[remove_item] = count
	while country.get_allocated_consumer_factories() < capacity:
		var add_item := _best_production_item(country)
		if add_item.is_empty():
			break
		country.production_allocations[add_item] = int(country.production_allocations.get(add_item, 0)) + 1


func _most_overstocked_allocated_item(country: CountryClass) -> StringName:
	var result := StringName()
	var best_ratio := -INF
	for key: Variant in country.production_allocations:
		var item_id := StringName(str(key))
		if int(country.production_allocations[key]) <= 0 or not items_by_id.has(item_id):
			continue
		var item: ItemClass = items_by_id[item_id]
		var ratio := float(country.inventory.get(item_id, 0.0)) / maxf(_target_inventory(country, item), 1.0)
		if ratio > best_ratio:
			best_ratio = ratio
			result = item_id
	return result


func _best_production_item(country: CountryClass) -> StringName:
	var result := StringName()
	var best_score := -INF
	for item_id: StringName in item_order:
		var item: ItemClass = items_by_id[item_id]
		var planned_output := int(country.production_allocations.get(item_id, 0)) * item.production_per_factory
		var projected_stock := float(country.inventory.get(item_id, 0.0)) + planned_output
		var target := _target_inventory(country, item)
		var shortage := (target - projected_stock) / maxf(target, 1.0)
		var score := shortage * 100.0 + _target_price(country, item, projected_stock)
		if item.civilian_kind == ItemClass.CivilianKind.ESSENTIAL:
			score += 20.0
		if score > best_score:
			best_score = score
			result = item_id
	return result


func _run_ai_decisions() -> void:
	for country: CountryClass in _ordered_countries():
		if country.id == player_country_id:
			continue
		country.production_allocations.clear()
		_ensure_allocations(country)
		if country.construction_projects.is_empty() and country.get_trade_factories() > 0:
			for province_id: int in country.owned_province_ids:
				if not _province_has_construction(country, province_id):
					var result := _start_construction_internal(country.id, province_id, BUILDING_CIVILIAN, false)
					if result.ok:
						break


func _start_construction_internal(
	country_id: int,
	province_id: int,
	building_type: StringName,
	require_player: bool
) -> Dictionary:
	var country := get_country(country_id)
	if country == null:
		return _result(false, "국가를 찾을 수 없습니다.")
	if require_player and country_id != player_country_id:
		return _result(false, "플레이어 국가에서만 건설할 수 있습니다.")
	if not CONSTRUCTION_REQUIREMENTS.has(building_type):
		return _result(false, "알 수 없는 건물 종류입니다.")
	if province_id not in country.owned_province_ids:
		return _result(false, "해당 국가가 소유한 프로빈스가 아닙니다.")
	if _province_has_construction(country, province_id):
		return _result(false, "이 프로빈스에서는 이미 건설이 진행 중입니다.")
	if country.get_trade_factories() <= 0:
		return _result(false, "건설에 전환할 무역 민간공장이 없습니다.")
	var province: Dictionary = ProvinceMapDB.get_province(province_id)
	if building_type == BUILDING_DOCKYARD and not bool(province.get("water_border", false)):
		return _result(false, "조선소는 해안 프로빈스에만 건설할 수 있습니다.")
	var requirements: Dictionary = CONSTRUCTION_REQUIREMENTS[building_type]
	var cost := float(requirements.cost)
	if country.treasury < cost:
		return _result(false, "국고가 부족합니다.")
	var materials: Dictionary = requirements.materials
	for item_id: Variant in materials:
		if float(country.inventory.get(item_id, 0.0)) < float(materials[item_id]):
			var item: ItemClass = items_by_id.get(item_id)
			var display_name := str(item_id) if item == null else item.display_name
			return _result(false, "%s 재고가 부족합니다." % display_name)
	country.treasury -= cost
	for item_id: Variant in materials:
		country.inventory[item_id] = float(country.inventory.get(item_id, 0.0)) - float(materials[item_id])
	country.construction_projects.append({
		"province_id": province_id,
		"building_type": str(building_type),
		"remaining_days": CONSTRUCTION_DAYS,
		"total_days": CONSTRUCTION_DAYS,
	})
	_ensure_allocations(country)
	construction_changed.emit(country.id, province_id)
	country_economy_changed.emit(country.id)
	return _result(true, "건설을 시작했습니다.")


func _province_has_construction(country: CountryClass, province_id: int) -> bool:
	for project: Dictionary in country.construction_projects:
		if int(project.get("province_id", 0)) == province_id:
			return true
	return false


func _advance_construction() -> void:
	for country: CountryClass in _ordered_countries():
		var active_projects: Array = []
		for project: Dictionary in country.construction_projects:
			project.remaining_days = int(project.get("remaining_days", CONSTRUCTION_DAYS)) - TURN_DAYS
			if int(project.remaining_days) > 0:
				active_projects.append(project)
				continue
			var province_id := int(project.get("province_id", 0))
			var building_type := StringName(str(project.get("building_type", "")))
			var buildings: Dictionary = country.province_buildings.get(province_id, {})
			buildings[building_type] = int(buildings.get(building_type, 0)) + 1
			country.province_buildings[province_id] = buildings
			match building_type:
				BUILDING_CIVILIAN:
					country.civilian_factories += 1
				BUILDING_MILITARY:
					country.military_factories += 1
				BUILDING_DOCKYARD:
					country.dockyards += 1
			construction_changed.emit(country.id, province_id)
		country.construction_projects = active_projects
		_ensure_allocations(country)


func _validate_save_data(data: Dictionary) -> Dictionary:
	if int(data.get("schema_version", -1)) != SAVE_SCHEMA_VERSION:
		return _result(false, "지원하지 않는 저장 파일 버전입니다.")
	if str(data.get("scenario_id", "")) != SCENARIO_ID:
		return _result(false, "다른 시나리오의 저장 파일입니다.")
	if int(data.get("turn", -1)) < 0 or int(data.get("elapsed_days", -1)) < 0:
		return _result(false, "저장된 턴 정보가 잘못되었습니다.")
	if int(data.get("player_country_id", 0)) != player_country_id:
		return _result(false, "저장된 플레이어 국가가 올바르지 않습니다.")
	var saved_countries: Array = data.get("countries", [])
	if saved_countries.size() != ACTIVE_COUNTRY_CODES.size():
		return _result(false, "저장된 국가 수가 올바르지 않습니다.")
	for country_data: Dictionary in saved_countries:
		var country := get_country(int(country_data.get("id", 0)))
		if country == null:
			return _result(false, "저장 파일에 알 수 없는 국가가 있습니다.")
		if (
			not _is_nonnegative_number(country_data.get("treasury"))
			or not _is_nonnegative_number(country_data.get("standard_of_living"))
			or float(country_data.get("standard_of_living", 11.0)) > 10.0
			or not _is_nonnegative_number(country_data.get("tax_rate"))
			or float(country_data.get("tax_rate", 1.0)) > 0.5
			or int(country_data.get("civilian_factories", -1)) < 0
			or int(country_data.get("military_factories", -1)) < 0
			or int(country_data.get("dockyards", -1)) < 0
			or int(country_data.get("consumer_ratio", -1)) < 0
			or int(country_data.get("consumer_ratio", 101)) > 100
		):
			return _result(false, "저장된 국가 경제 수치가 잘못되었습니다.")
		var inventory: Dictionary = country_data.get("inventory", {})
		var prices: Dictionary = country_data.get("prices", {})
		for item_id: StringName in item_order:
			if (
				not inventory.has(str(item_id))
				or not prices.has(str(item_id))
				or not _is_nonnegative_number(inventory.get(str(item_id)))
				or not _is_nonnegative_number(prices.get(str(item_id)))
			):
				return _result(false, "저장된 품목 상태가 잘못되었습니다.")
		var allocations: Dictionary = country_data.get("production_allocations", {})
		var allocation_total := 0
		for item_key: String in allocations:
			if not items_by_id.has(StringName(item_key)) or int(allocations[item_key]) < 0:
				return _result(false, "저장된 생산 배정이 잘못되었습니다.")
			allocation_total += int(allocations[item_key])
		var projects: Array = country_data.get("construction_projects", [])
		if projects.size() > int(country_data.get("civilian_factories", 0)):
			return _result(false, "저장된 건설 수가 민간공장 수를 초과합니다.")
		var project_provinces := {}
		for project: Variant in projects:
			if typeof(project) != TYPE_DICTIONARY:
				return _result(false, "저장된 건설 정보가 잘못되었습니다.")
			var project_data: Dictionary = project
			var province_id := int(project_data.get("province_id", 0))
			var building_type := StringName(str(project_data.get("building_type", "")))
			if (
				province_id not in country.owned_province_ids
				or project_provinces.has(province_id)
				or not CONSTRUCTION_REQUIREMENTS.has(building_type)
				or int(project_data.get("remaining_days", 0)) <= 0
				or int(project_data.get("remaining_days", 0)) > CONSTRUCTION_DAYS
			):
				return _result(false, "저장된 건설 프로젝트가 잘못되었습니다.")
			project_provinces[province_id] = true
		var consumer_capacity := mini(
			floori(float(int(country_data.get("civilian_factories", 0)) * int(country_data.get("consumer_ratio", 0))) / 100.0),
			maxi(int(country_data.get("civilian_factories", 0)) - projects.size(), 0)
		)
		if allocation_total > consumer_capacity:
			return _result(false, "저장된 생산 배정이 소비재 공장 한도를 초과합니다.")
		var province_buildings: Dictionary = country_data.get("province_buildings", {})
		for province_key: String in province_buildings:
			var province_id := int(province_key)
			if province_id not in country.owned_province_ids or typeof(province_buildings[province_key]) != TYPE_DICTIONARY:
				return _result(false, "저장된 프로빈스 건물 정보가 잘못되었습니다.")
			for building_key: String in province_buildings[province_key]:
				if (
					not CONSTRUCTION_REQUIREMENTS.has(StringName(building_key))
					or int(province_buildings[province_key][building_key]) < 0
				):
					return _result(false, "저장된 프로빈스 건물 수가 잘못되었습니다.")
	return _result(true)


func _is_nonnegative_number(value: Variant) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value)) and float(value) >= 0.0


func _result(ok: bool, message: String = "") -> Dictionary:
	return {"ok": ok, "message": message}
