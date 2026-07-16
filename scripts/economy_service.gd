extends RefCounted

const ItemClass = preload("res://scripts/item.gd")

const WEEKS_PER_YEAR := 52.0
const REAL_GDP_HISTORY_WEEKS := 12

var civilian_factory_tax_value := 100.0
var consumption_tax_alpha := 0.1
var property_tax_alpha := 0.01


func configure(tax_parameters: Dictionary) -> void:
	civilian_factory_tax_value = maxf(
		float(tax_parameters.get("civilian_factory_tax_value", 100.0)),
		0.0
	)
	consumption_tax_alpha = maxf(float(tax_parameters.get("consumption_tax_alpha", 0.1)), 0.0)
	property_tax_alpha = maxf(float(tax_parameters.get("property_tax_alpha", 0.01)), 0.0)


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
	var working_treasury := {}
	var requests: Array = []
	for country: Resource in countries:
		countries_by_id[country.id] = country
		working_inventory[country.id] = country.inventory.duplicate(true)
		working_treasury[country.id] = country.treasury
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
			quantity = minf(quantity, float(working_treasury[buyer.id]) / maxf(unit_cost, 0.001))
			if quantity < 0.01:
				continue
			buyer_stock[item_id] = float(buyer_stock.get(item_id, 0.0)) + quantity
			seller_stock[item_id] = float(seller_stock.get(item_id, 0.0)) - quantity
			working_inventory[buyer.id] = buyer_stock
			working_inventory[seller.id] = seller_stock
			working_treasury[buyer.id] = float(working_treasury[buyer.id]) - quantity * unit_cost
			working_treasury[seller.id] = float(working_treasury[seller.id]) + quantity * seller_price
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
		country.treasury = float(working_treasury[country.id])
	for transaction: Dictionary in transactions:
		var buyer_stats: Dictionary = transaction.buyer.weekly_stats[transaction.item_id]
		buyer_stats.imported = float(buyer_stats.imported) + float(transaction.quantity)
		var import_value := float(transaction.quantity) * float(transaction.unit_cost)
		buyer_stats.import_value = float(buyer_stats.import_value) + import_value
		transaction.buyer.weekly_stats[transaction.item_id] = buyer_stats
		transaction.buyer.weekly_stats.import_value = (
			float(transaction.buyer.weekly_stats.import_value) + import_value
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
			if item.civilian_kind == ItemClass.CivilianKind.RESOURCE:
				continue
			var stats: Dictionary = country.weekly_stats[item_id]
			domestic_production_value += (
				float(stats.produced) * float(country.prices.get(item_id, item.base_price))
			)
		var weekly_real_gdp := maxf(
			float(country.standard_of_living) * 0.1 * domestic_production_value,
			0.0
		)
		country.weekly_real_gdp_history.append(weekly_real_gdp)
		while country.weekly_real_gdp_history.size() > REAL_GDP_HISTORY_WEEKS:
			country.weekly_real_gdp_history.pop_front()
		var rolling_gdp_total := 0.0
		for weekly_value: float in country.weekly_real_gdp_history:
			rolling_gdp_total += weekly_value
		country.real_gdp = (
			rolling_gdp_total / maxf(float(country.weekly_real_gdp_history.size()), 1.0)
			* WEEKS_PER_YEAR
		)

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
		country.weekly_stats.weekly_real_gdp = weekly_real_gdp
		country.weekly_stats.consumption_value = consumption_value
		country.weekly_stats.consumption_tax_revenue = consumption_tax_revenue
		country.weekly_stats.property_tax_revenue = property_tax_revenue
		country.weekly_stats.tax_revenue = tax_revenue


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
