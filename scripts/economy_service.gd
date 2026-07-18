extends RefCounted

const ItemClass = preload("res://scripts/item.gd")

const WEEKS_PER_YEAR := 52.0
const OUTPUT_EPSILON := 0.000001

var civilian_factory_tax_value := 100.0
var consumption_tax_alpha := 5.0
var property_tax_alpha := 0.005
var trade_dollars_per_factory := 100.0
var gdp_output_elasticity := 0.25
var gdp_max_annual_change := 0.12
var gdp_short_window_weeks := 12
var gdp_long_window_weeks := 52


func configure(
	tax_parameters: Dictionary,
	gdp_parameters: Dictionary,
	trade_parameters: Dictionary
) -> void:
	civilian_factory_tax_value = maxf(
		float(tax_parameters.get("civilian_factory_tax_value", 100.0)),
		0.0
	)
	consumption_tax_alpha = maxf(float(tax_parameters.get("consumption_tax_alpha", 5.0)), 0.0)
	property_tax_alpha = maxf(float(tax_parameters.get("property_tax_alpha", 0.005)), 0.0)
	trade_dollars_per_factory = maxf(
		float(trade_parameters.get("dollars_per_factory", 100.0)),
		0.0
	)
	gdp_output_elasticity = clampf(
		float(gdp_parameters.get("output_elasticity", 0.25)),
		OUTPUT_EPSILON,
		1.0
	)
	gdp_max_annual_change = clampf(
		float(gdp_parameters.get("max_annual_change", 0.12)),
		OUTPUT_EPSILON,
		0.99
	)
	gdp_short_window_weeks = maxi(int(gdp_parameters.get("short_window_weeks", 12)), 1)
	gdp_long_window_weeks = maxi(
		int(gdp_parameters.get("long_window_weeks", 52)),
		gdp_short_window_weeks
	)


func initialize_country_market(
	country: Resource,
	preset: Dictionary,
	items_by_id: Dictionary,
	item_order: Array[StringName]
) -> void:
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
			country.inventory[item_id] = calculate_demand(country, item) * turns
	country.reset_weekly_stats(item_order)
	ensure_allocations(country, items_by_id, item_order)
	var reference_output_value := _configured_output_value(country, items_by_id, item_order)
	country.weekly_output_value_history.clear()
	for _week: int in gdp_long_window_weeks:
		country.weekly_output_value_history.append(reference_output_value)


func advance_week(
	countries: Array,
	items_by_id: Dictionary,
	item_order: Array[StringName]
) -> void:
	for country: Resource in countries:
		ensure_allocations(country, items_by_id, item_order)
		country.reset_weekly_stats(item_order)
	_produce_goods(countries, items_by_id, item_order)
	_run_trade(countries, items_by_id, item_order)
	_consume_and_update_economies(countries, items_by_id, item_order)


func update_ai_production(
	countries: Array,
	player_country_id: int,
	items_by_id: Dictionary,
	item_order: Array[StringName]
) -> void:
	for country: Resource in countries:
		if country.id == player_country_id:
			continue
		update_ai_country_production(country, items_by_id, item_order)


func update_ai_country_production(
	country: Resource,
	items_by_id: Dictionary,
	item_order: Array[StringName]
) -> void:
	country.production_allocations.clear()
	ensure_allocations(country, items_by_id, item_order)


func ensure_allocations(
	country: Resource,
	items_by_id: Dictionary,
	item_order: Array[StringName]
) -> void:
	var capacity: int = country.get_effective_consumer_factories()
	while country.get_allocated_consumer_factories() > capacity:
		var remove_item := _most_overstocked_allocated_item(country, items_by_id)
		if remove_item.is_empty():
			break
		var count := int(country.production_allocations.get(remove_item, 0)) - 1
		if count <= 0:
			country.production_allocations.erase(remove_item)
		else:
			country.production_allocations[remove_item] = count
	while country.get_allocated_consumer_factories() < capacity:
		var add_item := _best_production_item(country, items_by_id, item_order)
		if add_item.is_empty():
			break
		country.production_allocations[add_item] = int(country.production_allocations.get(add_item, 0)) + 1


func calculate_demand(country: Resource, item: ItemClass) -> float:
	if item.civilian_kind == ItemClass.CivilianKind.RESOURCE:
		return 0.0
	var demand: float = float(country.demand_index) * item.demand_per_index
	if item.civilian_kind == ItemClass.CivilianKind.LUXURY:
		demand *= country.standard_of_living / 10.0
		demand *= 1.0 - country.consumption_tax_rate * 0.5
	return maxf(demand, 0.0)


func get_trade_dollar_capacity(country: Resource) -> float:
	if country == null:
		return 0.0
	return float(country.get_trade_factories()) * trade_dollars_per_factory


func _produce_goods(countries: Array, items_by_id: Dictionary, item_order: Array[StringName]) -> void:
	for country: Resource in countries:
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


func _run_trade(countries: Array, items_by_id: Dictionary, item_order: Array[StringName]) -> void:
	var countries_by_id := {}
	var working_inventory := {}
	var working_trade_dollars := {}
	var requests: Array = []
	for country: Resource in countries:
		countries_by_id[country.id] = country
		working_inventory[country.id] = country.inventory.duplicate(true)
		var trade_dollar_capacity := get_trade_dollar_capacity(country)
		working_trade_dollars[country.id] = trade_dollar_capacity
		country.weekly_stats.trade_dollars_generated = trade_dollar_capacity
		var candidates := _trade_candidates(country, working_inventory[country.id], items_by_id, item_order)
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
		var buyer: Resource = countries_by_id.get(int(request.buyer_id))
		for candidate: Dictionary in request.candidates:
			var item_id := StringName(str(candidate.item_id))
			var item: ItemClass = items_by_id[item_id]
			var seller: Resource = _find_trade_seller_working(buyer, item, countries, working_inventory)
			if seller == null:
				continue
			var seller_stock: Dictionary = working_inventory[seller.id]
			var buyer_stock: Dictionary = working_inventory[buyer.id]
			var surplus := float(seller_stock.get(item_id, 0.0)) - _target_inventory(seller, item)
			var quantity := minf(item.trade_batch_size, maxf(surplus, 0.0))
			var seller_price := float(seller.prices.get(item_id, item.base_price))
			var unit_cost := seller_price * 1.1
			quantity = minf(
				quantity,
				float(working_trade_dollars[buyer.id]) / maxf(unit_cost, 0.001)
			)
			if quantity < 0.01:
				continue
			var transaction_cost := quantity * unit_cost
			buyer_stock[item_id] = float(buyer_stock.get(item_id, 0.0)) + quantity
			seller_stock[item_id] = float(seller_stock.get(item_id, 0.0)) - quantity
			working_inventory[buyer.id] = buyer_stock
			working_inventory[seller.id] = seller_stock
			working_trade_dollars[buyer.id] = maxf(
				float(working_trade_dollars[buyer.id]) - transaction_cost,
				0.0
			)
			transactions.append({
				"buyer": buyer,
				"seller": seller,
				"item_id": item_id,
				"quantity": quantity,
				"unit_cost": unit_cost,
			})
			break
	for country: Resource in countries:
		country.inventory = working_inventory[country.id]
	for transaction: Dictionary in transactions:
		var buyer_stats: Dictionary = transaction.buyer.weekly_stats[transaction.item_id]
		buyer_stats.imported = float(buyer_stats.imported) + float(transaction.quantity)
		var import_value := float(transaction.quantity) * float(transaction.unit_cost)
		buyer_stats.import_value = float(buyer_stats.import_value) + import_value
		transaction.buyer.weekly_stats[transaction.item_id] = buyer_stats
		transaction.buyer.weekly_stats.import_value = (
			float(transaction.buyer.weekly_stats.import_value) + import_value
		)
		transaction.buyer.weekly_stats.trade_dollars_spent = (
			float(transaction.buyer.weekly_stats.trade_dollars_spent) + import_value
		)
		var seller_stats: Dictionary = transaction.seller.weekly_stats[transaction.item_id]
		seller_stats.exported = float(seller_stats.exported) + float(transaction.quantity)
		transaction.seller.weekly_stats[transaction.item_id] = seller_stats


func _trade_candidates(
	buyer: Resource,
	stock: Dictionary,
	items_by_id: Dictionary,
	item_order: Array[StringName]
) -> Array:
	var candidates: Array = []
	for item_id: StringName in item_order:
		var item: ItemClass = items_by_id[item_id]
		var target := _target_inventory(buyer, item)
		var amount := float(stock.get(item_id, 0.0))
		if amount + 0.001 < target:
			candidates.append({"item_id": item_id, "price": _target_price(buyer, item, amount)})
	candidates.sort_custom(_sort_trade_candidates)
	return candidates


func _find_trade_seller_working(
	buyer: Resource,
	item: ItemClass,
	countries: Array,
	working_inventory: Dictionary
) -> Resource:
	var result: Resource
	var best_price := INF
	for seller: Resource in countries:
		if seller == buyer:
			continue
		var seller_stock: Dictionary = working_inventory[seller.id]
		var surplus := float(seller_stock.get(item.id, 0.0)) - _target_inventory(seller, item)
		var price := float(seller.prices.get(item.id, item.base_price))
		if surplus >= 0.01 and (
			price < best_price
			or (is_equal_approx(price, best_price) and (result == null or seller.id < result.id))
		):
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


func _consume_and_update_economies(
	countries: Array,
	items_by_id: Dictionary,
	item_order: Array[StringName]
) -> void:
	for country: Resource in countries:
		var essential_requested := 0.0
		var essential_consumed := 0.0
		var luxury_requested := 0.0
		var luxury_consumed := 0.0
		var affordability_weight := 0.0
		var affordability_total := 0.0
		var consumption_value := 0.0
		for item_id: StringName in item_order:
			var item: ItemClass = items_by_id[item_id]
			var demand := calculate_demand(country, item)
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
				consumption_value += consumed * float(country.prices[item_id])

		var essential_fulfillment := essential_consumed / maxf(essential_requested, 0.001)
		var luxury_fulfillment := luxury_consumed / maxf(luxury_requested, 0.001)
		var affordability := affordability_total / maxf(affordability_weight, 0.001)
		var tax_burden: float = 1.0 - float(country.consumption_tax_rate) * 0.5
		var target_sol: float = 10.0 * (
			0.60 * clampf(essential_fulfillment, 0.0, 1.0)
			+ 0.25 * clampf(affordability, 0.0, 1.0)
			+ 0.15 * clampf(luxury_fulfillment, 0.0, 1.0)
		) * tax_burden
		country.standard_of_living = lerpf(country.standard_of_living, target_sol, 0.25)

		var domestic_production_value := 0.0
		for item_id: StringName in item_order:
			var item: ItemClass = items_by_id[item_id]
			var stats: Dictionary = country.weekly_stats[item_id]
			domestic_production_value += (
				float(stats.produced) * float(country.prices.get(item_id, item.base_price))
			)
		country.weekly_output_value_history.append(maxf(domestic_production_value, 0.0))
		while country.weekly_output_value_history.size() > gdp_long_window_weeks:
			country.weekly_output_value_history.pop_front()
		var short_term_output := _history_average(
			country.weekly_output_value_history,
			gdp_short_window_weeks
		)
		var long_term_output := _history_average(
			country.weekly_output_value_history,
			gdp_long_window_weeks
		)
		var annual_gdp_growth := _annual_gdp_growth(short_term_output, long_term_output)
		var weekly_gdp_factor := pow(1.0 + annual_gdp_growth, 1.0 / WEEKS_PER_YEAR)
		country.real_gdp *= weekly_gdp_factor

		var factory_tax_value := (
			float(country.get_allocated_consumer_factories()) * civilian_factory_tax_value
		)
		var consumption_tax_revenue := maxf(
			(consumption_value + factory_tax_value)
			* float(country.consumption_tax_rate)
			* consumption_tax_alpha,
			0.0
		)
		var property_tax_revenue := maxf(
			float(country.standard_of_living)
			* float(country.real_gdp)
			* float(country.property_tax_rate)
			* property_tax_alpha
			/ WEEKS_PER_YEAR,
			0.0
		)
		var tax_revenue := consumption_tax_revenue + property_tax_revenue
		country.treasury += tax_revenue
		country.weekly_stats.domestic_production_value = domestic_production_value
		country.weekly_stats.short_term_output_value = short_term_output
		country.weekly_stats.long_term_output_value = long_term_output
		country.weekly_stats.annual_gdp_growth_rate = annual_gdp_growth
		country.weekly_stats.consumption_value = consumption_value
		country.weekly_stats.consumption_tax_revenue = consumption_tax_revenue
		country.weekly_stats.property_tax_revenue = property_tax_revenue
		country.weekly_stats.tax_revenue = tax_revenue


func _configured_output_value(
	country: Resource,
	items_by_id: Dictionary,
	item_order: Array[StringName]
) -> float:
	var output_value := 0.0
	for item_id: StringName in item_order:
		var factories := int(country.production_allocations.get(item_id, 0))
		if factories <= 0:
			continue
		var item: ItemClass = items_by_id[item_id]
		output_value += factories * item.production_per_factory * item.base_price
	return maxf(output_value, 0.0)


func _history_average(history: Array[float], requested_weeks: int) -> float:
	var sample_count := mini(requested_weeks, history.size())
	if sample_count <= 0:
		return 0.0
	var total := 0.0
	for index: int in range(history.size() - sample_count, history.size()):
		total += history[index]
	return total / float(sample_count)


func _annual_gdp_growth(short_term_output: float, long_term_output: float) -> float:
	if long_term_output <= OUTPUT_EPSILON:
		return gdp_max_annual_change if short_term_output > OUTPUT_EPSILON else -gdp_max_annual_change
	var output_ratio := maxf(short_term_output / long_term_output, 0.0)
	return clampf(
		pow(output_ratio, gdp_output_elasticity) - 1.0,
		-gdp_max_annual_change,
		gdp_max_annual_change
	)


func _target_inventory(country: Resource, item: ItemClass) -> float:
	if item.civilian_kind == ItemClass.CivilianKind.RESOURCE:
		return 40.0
	return calculate_demand(country, item) * 2.0


func _target_price(country: Resource, item: ItemClass, stock: float) -> float:
	var target := _target_inventory(country, item)
	var scarcity := clampf((target - stock) / maxf(target, 1.0), -1.0, 1.0)
	return clampf(item.base_price * (1.0 + 1.5 * scarcity), item.minimum_price, item.maximum_price)


func _most_overstocked_allocated_item(country: Resource, items_by_id: Dictionary) -> StringName:
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


func _best_production_item(
	country: Resource,
	items_by_id: Dictionary,
	item_order: Array[StringName]
) -> StringName:
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
