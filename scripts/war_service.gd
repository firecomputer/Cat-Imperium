extends RefCounted

const ArmyClass = preload("res://scripts/army.gd")

const DEFENDER_BONUS := 1.10
const MIN_CAPTURE_RATIO := 1.10

var wars_by_id: Dictionary = {}
var fronts_by_id: Dictionary = {}
var next_war_number := 1
var next_front_number := 1


func reset() -> void:
	wars_by_id.clear()
	fronts_by_id.clear()
	next_war_number = 1
	next_front_number = 1


func declare_war(
	attacker: Resource,
	defender: Resource,
	countries_by_id: Dictionary,
	province_states: Dictionary
) -> Dictionary:
	if attacker == null or defender == null or attacker.id == defender.id:
		return _result(false, "선전포고 대상이 올바르지 않습니다.")
	if attacker.is_surrendered or defender.is_surrendered:
		return _result(false, "항복한 국가는 전쟁을 시작할 수 없습니다.")
	for war: Dictionary in wars_by_id.values():
		if not bool(war.get("active", false)):
			continue
		var pair := [int(war.attacker_country_id), int(war.defender_country_id)]
		if attacker.id in pair and defender.id in pair:
			return _result(false, "이미 두 국가가 전쟁 중입니다.")
	var war_id := StringName("war-%03d" % next_war_number)
	next_war_number += 1
	wars_by_id[war_id] = {
		"id": str(war_id),
		"attacker_country_id": attacker.id,
		"defender_country_id": defender.id,
		"preparation_turns_remaining": 1,
		"active": true,
		"surrendered_country_id": 0,
		"front_ids": [],
	}
	recalculate_fronts(countries_by_id, province_states)
	return {"ok": true, "message": "", "war_id": war_id}


func assign_army_to_front(country: Resource, army_id: StringName, front_id: StringName) -> Dictionary:
	var army: ArmyClass = country.armies_by_id.get(army_id) if country != null else null
	var front: Dictionary = fronts_by_id.get(front_id, {})
	if army == null or front.is_empty():
		return _result(false, "부대 또는 전선을 찾을 수 없습니다.")
	if country.id not in [int(front.country_a_id), int(front.country_b_id)]:
		return _result(false, "해당 국가가 참여한 전선이 아닙니다.")
	army.assigned_front_id = front_id
	return _result(true)


func set_offensive_target(
	country: Resource,
	front_id: StringName,
	province_id: int,
	province_states: Dictionary
) -> Dictionary:
	var front: Dictionary = fronts_by_id.get(front_id, {})
	if country == null or front.is_empty() or country.id not in [int(front.country_a_id), int(front.country_b_id)]:
		return _result(false, "국가 또는 전선이 올바르지 않습니다.")
	var targets: Dictionary = front.get("targets", {})
	if province_id <= 0:
		targets.erase(str(country.id))
		front.targets = targets
		return _result(true)
	var enemy_id := _enemy_country_id(front, country.id)
	if int(province_states.get(province_id, {}).get("controller_country_id", 0)) != enemy_id:
		return _result(false, "공세 목표는 현재 적국이 지배하는 프로빈스여야 합니다.")
	if _path_to_target(front, country.id, province_id, province_states).is_empty():
		return _result(false, "현재 전선에서 육로로 도달할 수 없는 목표입니다.")
	targets[str(country.id)] = province_id
	front.targets = targets
	return _result(true)


func allocate_aircraft(
	country: Resource,
	front_id: StringName,
	item_id: StringName,
	count: int,
	equipment_by_id: Dictionary
) -> Dictionary:
	var front: Dictionary = fronts_by_id.get(front_id, {})
	var item: Resource = equipment_by_id.get(item_id)
	if country == null or front.is_empty() or item == null or str(item.equipment_group) != "aircraft" or count < 0:
		return _result(false, "항공 지원 요청이 올바르지 않습니다.")
	if country.id not in [int(front.country_a_id), int(front.country_b_id)]:
		return _result(false, "해당 국가가 참여한 전선이 아닙니다.")
	var reserved_elsewhere := 0
	for other_front_id: Variant in fronts_by_id:
		if str(other_front_id) == str(front_id):
			continue
		reserved_elsewhere += _air_count(fronts_by_id[other_front_id], country.id, item_id)
	if reserved_elsewhere + count > int(country.military_stockpile.get(item_id, 0)):
		return _result(false, "가용 항공기 재고를 초과합니다.")
	var allocations: Dictionary = front.get("air_allocations", {})
	var country_allocations: Dictionary = allocations.get(str(country.id), {})
	if count == 0:
		country_allocations.erase(str(item_id))
	else:
		country_allocations[str(item_id)] = count
	allocations[str(country.id)] = country_allocations
	front.air_allocations = allocations
	return _result(true)


func recalculate_fronts(countries_by_id: Dictionary, province_states: Dictionary) -> void:
	var active_war_ids: Array = wars_by_id.keys()
	active_war_ids.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
	var retained_front_ids := {}
	for war_id: Variant in active_war_ids:
		var war: Dictionary = wars_by_id[war_id]
		if not bool(war.get("active", false)):
			continue
		var country_a_id := int(war.attacker_country_id)
		var country_b_id := int(war.defender_country_id)
		var components := _front_components(country_a_id, country_b_id, province_states)
		var old_ids: Array = war.get("front_ids", []).duplicate()
		old_ids.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
		var used_old := {}
		var new_ids: Array = []
		for component: Dictionary in components:
			var matched_id := _best_matching_front(old_ids, used_old, component)
			var front: Dictionary
			if matched_id.is_empty():
				matched_id = StringName("front-%03d" % next_front_number)
				next_front_number += 1
				front = {
					"id": str(matched_id),
					"war_id": str(war_id),
					"country_a_id": country_a_id,
					"country_b_id": country_b_id,
					"targets": {},
					"air_allocations": {},
				}
			else:
				front = fronts_by_id[matched_id]
				used_old[matched_id] = true
			front.country_a_provinces = component.country_a_provinces
			front.country_b_provinces = component.country_b_provinces
			fronts_by_id[matched_id] = front
			retained_front_ids[matched_id] = true
			new_ids.append(str(matched_id))
		war.front_ids = new_ids
		wars_by_id[war_id] = war
	var removed_ids: Array = []
	for front_id: Variant in fronts_by_id:
		if not retained_front_ids.has(front_id):
			removed_ids.append(front_id)
	for front_id: Variant in removed_ids:
		fronts_by_id.erase(front_id)
	for country: Resource in countries_by_id.values():
		for army: ArmyClass in country.armies_by_id.values():
			if not army.assigned_front_id.is_empty() and not fronts_by_id.has(army.assigned_front_id):
				army.assigned_front_id = &""


func advance_wars(
	countries_by_id: Dictionary,
	province_states: Dictionary,
	equipment_by_id: Dictionary,
	territory_service: RefCounted
) -> Dictionary:
	var combat_reports: Array[Dictionary] = []
	var captures: Array[Dictionary] = []
	var surrenders: Array[Dictionary] = []
	recalculate_fronts(countries_by_id, province_states)
	var war_ids: Array = wars_by_id.keys()
	war_ids.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
	for war_id: Variant in war_ids:
		var war: Dictionary = wars_by_id[war_id]
		if not bool(war.get("active", false)):
			continue
		if int(war.get("preparation_turns_remaining", 0)) > 0:
			war.preparation_turns_remaining = int(war.preparation_turns_remaining) - 1
			wars_by_id[war_id] = war
			continue
		var front_ids: Array = war.get("front_ids", []).duplicate()
		front_ids.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
		for front_id_value: Variant in front_ids:
			var front_id := StringName(str(front_id_value))
			if not fronts_by_id.has(front_id):
				continue
			var front: Dictionary = fronts_by_id[front_id]
			var report := _resolve_front(front, countries_by_id, province_states, equipment_by_id, territory_service)
			if not report.is_empty():
				combat_reports.append(report)
				captures.append_array(report.get("captures", []))
		recalculate_fronts(countries_by_id, province_states)
		var surrendered_id := _surrendered_side(war, province_states)
		if surrendered_id > 0:
			var surrendered_country: Resource = countries_by_id.get(surrendered_id)
			if surrendered_country != null:
				surrendered_country.is_surrendered = true
			war.active = false
			war.surrendered_country_id = surrendered_id
			wars_by_id[war_id] = war
			surrenders.append({"war_id": str(war_id), "country_id": surrendered_id})
			_close_war_fronts(war, countries_by_id)
	return {"combat_reports": combat_reports, "captures": captures, "surrenders": surrenders}


func update_ai(countries_by_id: Dictionary, player_country_id: int, province_states: Dictionary, equipment_by_id: Dictionary) -> void:
	var war_ids: Array = wars_by_id.keys()
	war_ids.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
	for war_id: Variant in war_ids:
		var war: Dictionary = wars_by_id[war_id]
		if not bool(war.get("active", false)):
			continue
		for country_id: int in [int(war.attacker_country_id), int(war.defender_country_id)]:
			if country_id == player_country_id:
				continue
			var country: Resource = countries_by_id.get(country_id)
			if country == null or country.is_surrendered:
				continue
			var front_ids: Array = war.get("front_ids", []).duplicate()
			front_ids.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
			if front_ids.is_empty():
				continue
			var armies: Array = country.armies_by_id.values()
			armies.sort_custom(func(a: Resource, b: Resource) -> bool: return str(a.id) < str(b.id))
			for index: int in armies.size():
				armies[index].assigned_front_id = StringName(str(front_ids[index % front_ids.size()]))
			for front_id_value: Variant in front_ids:
				var front_id := StringName(str(front_id_value))
				var target := _best_ai_target(fronts_by_id[front_id], country_id, province_states, countries_by_id)
				if target > 0:
					set_offensive_target(country, front_id, target, province_states)
			var aircraft_ids: Array = equipment_by_id.keys()
			aircraft_ids.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
			for item_id: StringName in aircraft_ids:
				var item: Resource = equipment_by_id[item_id]
				if str(item.equipment_group) != "aircraft":
					continue
				var per_front := int(country.military_stockpile.get(item_id, 0)) / front_ids.size()
				for front_id_value: Variant in front_ids:
					allocate_aircraft(country, StringName(str(front_id_value)), item_id, per_front, equipment_by_id)


func to_save_data() -> Dictionary:
	var wars: Array = []
	var war_ids: Array = wars_by_id.keys()
	war_ids.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
	for war_id: Variant in war_ids:
		wars.append(wars_by_id[war_id].duplicate(true))
	var fronts: Array = []
	var front_ids: Array = fronts_by_id.keys()
	front_ids.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
	for front_id: Variant in front_ids:
		fronts.append(fronts_by_id[front_id].duplicate(true))
	return {
		"wars": wars,
		"fronts": fronts,
		"next_war_number": next_war_number,
		"next_front_number": next_front_number,
	}


func apply_save_data(data: Dictionary) -> void:
	reset()
	for war: Dictionary in data.get("wars", []):
		var war_id := StringName(str(war.get("id", "")))
		if not war_id.is_empty():
			wars_by_id[war_id] = war.duplicate(true)
	for front: Dictionary in data.get("fronts", []):
		var front_id := StringName(str(front.get("id", "")))
		if not front_id.is_empty():
			fronts_by_id[front_id] = front.duplicate(true)
	next_war_number = maxi(int(data.get("next_war_number", 1)), 1)
	next_front_number = maxi(int(data.get("next_front_number", 1)), 1)


func _resolve_front(
	front: Dictionary,
	countries_by_id: Dictionary,
	province_states: Dictionary,
	equipment_by_id: Dictionary,
	territory_service: RefCounted
) -> Dictionary:
	var country_a: Resource = countries_by_id.get(int(front.country_a_id))
	var country_b: Resource = countries_by_id.get(int(front.country_b_id))
	if country_a == null or country_b == null:
		return {}
	var armies_a := _front_armies(country_a, StringName(str(front.id)))
	var armies_b := _front_armies(country_b, StringName(str(front.id)))
	var power_a := _combat_power(armies_a, front, country_a.id, equipment_by_id, false)
	var power_b := _combat_power(armies_b, front, country_b.id, equipment_by_id, false)
	var defensive_power_a := power_a * DEFENDER_BONUS
	var defensive_power_b := power_b * DEFENDER_BONUS
	var losses_a := _personnel_losses(armies_a, power_a, power_b, equipment_by_id)
	var losses_b := _personnel_losses(armies_b, power_b, power_a, equipment_by_id)
	_apply_personnel_and_equipment_losses(armies_a, losses_a, equipment_by_id)
	_apply_personnel_and_equipment_losses(armies_b, losses_b, equipment_by_id)
	_apply_air_losses(country_a, country_b, front, equipment_by_id)
	var targets: Dictionary = front.get("targets", {})
	var has_a_target := targets.has(str(country_a.id))
	var has_b_target := targets.has(str(country_b.id))
	var advancing_country: Resource
	var defending_country: Resource
	var ratio := 0.0
	if has_a_target and (not has_b_target or power_a >= power_b):
		advancing_country = country_a
		defending_country = country_b
		ratio = power_a / maxf(defensive_power_b, 1.0)
	elif has_b_target:
		advancing_country = country_b
		defending_country = country_a
		ratio = power_b / maxf(defensive_power_a, 1.0)
	var captures: Array[Dictionary] = []
	if advancing_country != null and ratio >= MIN_CAPTURE_RATIO:
		var capture_count := 1
		if ratio >= 2.0:
			capture_count = 3
		elif ratio >= 1.5:
			capture_count = 2
		var target := int(targets.get(str(advancing_country.id), 0))
		var path := _path_to_target(front, advancing_country.id, target, province_states)
		for index: int in mini(capture_count, path.size()):
			var province_id := int(path[index])
			var result: Dictionary = territory_service.capture_province(province_id, advancing_country, countries_by_id, province_states)
			if result.ok:
				captures.append(result)
		if int(province_states.get(target, {}).get("controller_country_id", 0)) == advancing_country.id:
			targets.erase(str(advancing_country.id))
			front.targets = targets
	return {
		"front_id": str(front.id),
		"country_a_id": country_a.id,
		"country_b_id": country_b.id,
		"power_a": power_a,
		"power_b": power_b,
		"losses_a": losses_a,
		"losses_b": losses_b,
		"captures": captures,
	}


func _combat_power(
	armies: Array,
	front: Dictionary,
	country_id: int,
	equipment_by_id: Dictionary,
	defending: bool
) -> float:
	var total := 0.0
	for army: ArmyClass in armies:
		if army.total_personnel <= 0:
			continue
		var equipment_ratio := _equipment_fulfillment(army, equipment_by_id)
		var supply_ratio := _group_fulfillment(army, "supply", equipment_by_id)
		var equipment_factor := 0.25 + 0.75 * equipment_ratio
		var supply_factor := 0.5 + 0.5 * supply_ratio
		total += army.total_personnel * equipment_factor * supply_factor
	var enemy_id := _enemy_country_id(front, country_id)
	var friendly_air := _air_power(front, country_id, equipment_by_id)
	var enemy_air := _air_power(front, enemy_id, equipment_by_id)
	var air_balance := (friendly_air - enemy_air) / maxf(friendly_air + enemy_air, 1.0)
	total *= 1.0 + clampf(air_balance * 0.25, -0.25, 0.25)
	return total * (DEFENDER_BONUS if defending else 1.0)


func _personnel_losses(armies: Array, own_power: float, enemy_power: float, equipment_by_id: Dictionary) -> int:
	var personnel := 0
	var weighted_medical := 0.0
	for army: ArmyClass in armies:
		personnel += army.total_personnel
		weighted_medical += army.total_personnel * _group_fulfillment(army, "medical", equipment_by_id)
	if personnel <= 0 or enemy_power <= 0.0:
		return 0
	var medical_ratio := weighted_medical / personnel
	var loss_rate := clampf(0.01 * enemy_power / maxf(own_power, 1.0), 0.005, 0.05)
	loss_rate *= 1.0 - 0.25 * medical_ratio
	return mini(roundi(personnel * loss_rate), personnel)


func _apply_personnel_and_equipment_losses(armies: Array, total_losses: int, equipment_by_id: Dictionary) -> void:
	var total_personnel := 0
	for army: ArmyClass in armies:
		total_personnel += army.total_personnel
	var remaining_losses := total_losses
	for index: int in armies.size():
		var army: ArmyClass = armies[index]
		var before := army.total_personnel
		var losses := remaining_losses if index == armies.size() - 1 else roundi(total_losses * float(before) / maxf(total_personnel, 1.0))
		losses = mini(losses, before)
		remaining_losses -= losses
		army.total_personnel -= losses
		if before <= 0 or losses <= 0:
			continue
		var equipment_ids: Array = army.equipment.keys()
		for item_id: StringName in equipment_ids:
			var item: Resource = equipment_by_id.get(item_id)
			var reliability_factor := 1.0
			if item != null:
				reliability_factor = 2.0 - float(item.reliability) / 100.0
			var equipment_loss := ceili(army.get_equipment_count(item_id) * float(losses) / before * reliability_factor)
			army.set_equipment_count(item_id, army.get_equipment_count(item_id) - equipment_loss)


func _apply_air_losses(country_a: Resource, country_b: Resource, front: Dictionary, equipment_by_id: Dictionary) -> void:
	for pair: Array in [[country_a, country_b], [country_b, country_a]]:
		var country: Resource = pair[0]
		var enemy: Resource = pair[1]
		var own_power := _air_power(front, country.id, equipment_by_id)
		var enemy_power := _air_power(front, enemy.id, equipment_by_id)
		if own_power <= 0.0 or enemy_power <= 0.0:
			continue
		var allocations: Dictionary = front.get("air_allocations", {}).get(str(country.id), {})
		for item_key: String in allocations.keys():
			var item_id := StringName(item_key)
			var item: Resource = equipment_by_id.get(item_id)
			if item == null:
				continue
			var count := int(allocations[item_key])
			var loss_rate := clampf(0.01 * enemy_power / maxf(own_power, 1.0), 0.005, 0.05)
			loss_rate *= 2.0 - float(item.reliability) / 100.0
			var losses := mini(ceili(count * loss_rate), count)
			allocations[item_key] = count - losses
			country.military_stockpile[item_id] = maxi(int(country.military_stockpile.get(item_id, 0)) - losses, 0)


func _equipment_fulfillment(army: ArmyClass, equipment_by_id: Dictionary) -> float:
	var actual_value := 0.0
	var target_value := 0.0
	for item_id: Variant in army.equipment_targets:
		var item: Resource = equipment_by_id.get(item_id)
		if item == null or str(item.equipment_group) == "medical" or str(item.equipment_group) == "supply":
			continue
		var target := maxi(int(army.equipment_targets[item_id]), 0)
		target_value += target * float(item.combat_value)
		actual_value += mini(army.get_equipment_count(item_id), target) * float(item.combat_value)
	return 1.0 if target_value <= 0.0 else clampf(actual_value / target_value, 0.0, 1.0)


func _group_fulfillment(army: ArmyClass, group: String, equipment_by_id: Dictionary) -> float:
	var actual := 0
	var target := 0
	for item_id: Variant in army.equipment_targets:
		var item: Resource = equipment_by_id.get(item_id)
		if item != null and str(item.equipment_group) == group:
			target += int(army.equipment_targets[item_id])
			actual += mini(army.get_equipment_count(item_id), int(army.equipment_targets[item_id]))
	return 1.0 if target <= 0 else clampf(float(actual) / target, 0.0, 1.0)


func _air_power(front: Dictionary, country_id: int, equipment_by_id: Dictionary) -> float:
	var result := 0.0
	var allocations: Dictionary = front.get("air_allocations", {}).get(str(country_id), {})
	for item_key: String in allocations:
		var item: Resource = equipment_by_id.get(StringName(item_key))
		if item != null:
			result += int(allocations[item_key]) * float(item.combat_value)
	return result


func _air_count(front: Dictionary, country_id: int, item_id: StringName) -> int:
	return int(front.get("air_allocations", {}).get(str(country_id), {}).get(str(item_id), 0))


func _front_armies(country: Resource, front_id: StringName) -> Array:
	var result: Array = []
	for army: ArmyClass in country.armies_by_id.values():
		if army.assigned_front_id == front_id:
			result.append(army)
	result.sort_custom(func(a: Resource, b: Resource) -> bool: return str(a.id) < str(b.id))
	return result


func _front_components(country_a_id: int, country_b_id: int, province_states: Dictionary) -> Array:
	var border := {}
	for province_id: Variant in province_states:
		var controller_id := int(province_states[province_id].get("controller_country_id", 0))
		if controller_id not in [country_a_id, country_b_id]:
			continue
		var enemy_id := country_b_id if controller_id == country_a_id else country_a_id
		for neighbor_id: Variant in ProvinceMapDB.get_province(int(province_id)).get("neighbors", []):
			if int(province_states.get(int(neighbor_id), {}).get("controller_country_id", 0)) == enemy_id:
				border[int(province_id)] = true
				border[int(neighbor_id)] = true
	var unvisited: Array = border.keys()
	unvisited.sort()
	var unvisited_set := border.duplicate()
	var result: Array = []
	while not unvisited_set.is_empty():
		var start := 0
		for candidate: Variant in unvisited:
			if unvisited_set.has(candidate):
				start = int(candidate)
				break
		var queue: Array[int] = [start]
		unvisited_set.erase(start)
		var a_provinces: Array[int] = []
		var b_provinces: Array[int] = []
		while not queue.is_empty():
			var current: int = int(queue.pop_front())
			var controller_id := int(province_states[current].controller_country_id)
			if controller_id == country_a_id:
				a_provinces.append(current)
			else:
				b_provinces.append(current)
			var neighbors: Array = ProvinceMapDB.get_province(current).get("neighbors", []).duplicate()
			neighbors.sort()
			for neighbor_id: Variant in neighbors:
				var neighbor := int(neighbor_id)
				if unvisited_set.has(neighbor):
					unvisited_set.erase(neighbor)
					queue.append(neighbor)
		a_provinces.sort()
		b_provinces.sort()
		if not a_provinces.is_empty() and not b_provinces.is_empty():
			result.append({"country_a_provinces": a_provinces, "country_b_provinces": b_provinces})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_min := mini(int(a.country_a_provinces[0]), int(a.country_b_provinces[0]))
		var b_min := mini(int(b.country_a_provinces[0]), int(b.country_b_provinces[0]))
		return a_min < b_min
	)
	return result


func _best_matching_front(old_ids: Array, used_old: Dictionary, component: Dictionary) -> StringName:
	var component_set := {}
	for province_id: int in component.country_a_provinces:
		component_set[province_id] = true
	for province_id: int in component.country_b_provinces:
		component_set[province_id] = true
	var best_id := StringName()
	var best_overlap := 0
	for old_id_value: Variant in old_ids:
		var old_id := StringName(str(old_id_value))
		if used_old.has(old_id) or not fronts_by_id.has(old_id):
			continue
		var old: Dictionary = fronts_by_id[old_id]
		var overlap := 0
		for province_id: Variant in old.get("country_a_provinces", []):
			if component_set.has(int(province_id)):
				overlap += 1
		for province_id: Variant in old.get("country_b_provinces", []):
			if component_set.has(int(province_id)):
				overlap += 1
		if overlap > best_overlap:
			best_overlap = overlap
			best_id = old_id
	return best_id


func _path_to_target(front: Dictionary, country_id: int, target: int, province_states: Dictionary) -> Array[int]:
	var enemy_id := _enemy_country_id(front, country_id)
	if enemy_id <= 0 or int(province_states.get(target, {}).get("controller_country_id", 0)) != enemy_id:
		return []
	var starts: Array = front.country_b_provinces if country_id == int(front.country_a_id) else front.country_a_provinces
	var queue: Array[int] = []
	var previous := {}
	for start_value: Variant in starts:
		var start := int(start_value)
		if int(province_states.get(start, {}).get("controller_country_id", 0)) == enemy_id:
			queue.append(start)
			previous[start] = 0
	queue.sort()
	while not queue.is_empty():
		var current: int = int(queue.pop_front())
		if current == target:
			break
		var neighbors: Array = ProvinceMapDB.get_province(current).get("neighbors", []).duplicate()
		neighbors.sort()
		for neighbor_value: Variant in neighbors:
			var neighbor := int(neighbor_value)
			if previous.has(neighbor):
				continue
			if int(province_states.get(neighbor, {}).get("controller_country_id", 0)) != enemy_id:
				continue
			previous[neighbor] = current
			queue.append(neighbor)
	if not previous.has(target):
		return []
	var reversed_path: Array[int] = []
	var cursor := target
	while cursor != 0:
		reversed_path.append(cursor)
		cursor = int(previous[cursor])
	reversed_path.reverse()
	return reversed_path


func _best_ai_target(front: Dictionary, country_id: int, province_states: Dictionary, countries_by_id: Dictionary) -> int:
	var enemy_id := _enemy_country_id(front, country_id)
	var enemy: Resource = countries_by_id.get(enemy_id)
	if enemy == null:
		return 0
	var best_id := 0
	var best_building_score := -1
	for province_id: int in enemy.controlled_province_ids:
		if _path_to_target(front, country_id, province_id, province_states).is_empty():
			continue
		var buildings: Dictionary = enemy.province_buildings.get(province_id, {})
		var score := 0
		for count: Variant in buildings.values():
			score += int(count)
		if score > best_building_score or (score == best_building_score and (best_id == 0 or province_id < best_id)):
			best_building_score = score
			best_id = province_id
	return best_id


func _enemy_country_id(front: Dictionary, country_id: int) -> int:
	if country_id == int(front.country_a_id):
		return int(front.country_b_id)
	if country_id == int(front.country_b_id):
		return int(front.country_a_id)
	return 0


func _surrendered_side(war: Dictionary, province_states: Dictionary) -> int:
	for country_id: int in [int(war.attacker_country_id), int(war.defender_country_id)]:
		var has_controlled_home := false
		for province_id: Variant in province_states:
			var state: Dictionary = province_states[province_id]
			if int(state.owner_country_id) == country_id and int(state.controller_country_id) == country_id:
				has_controlled_home = true
				break
		if not has_controlled_home:
			return country_id
	return 0


func _close_war_fronts(war: Dictionary, countries_by_id: Dictionary) -> void:
	for front_id_value: Variant in war.get("front_ids", []):
		fronts_by_id.erase(StringName(str(front_id_value)))
	for country_id: int in [int(war.attacker_country_id), int(war.defender_country_id)]:
		var country: Resource = countries_by_id.get(country_id)
		if country == null:
			continue
		for army: ArmyClass in country.armies_by_id.values():
			army.assigned_front_id = &""


func _result(ok: bool, message: String = "") -> Dictionary:
	return {"ok": ok, "message": message}
