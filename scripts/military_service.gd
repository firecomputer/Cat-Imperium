extends RefCounted

const ArmyClass = preload("res://scripts/army.gd")

const LINE_START_EFFICIENCY := 0.5
const LINE_EFFICIENCY_GAIN := 0.05


func initialize_country(country: Resource, preset: Dictionary, equipment_by_id: Dictionary) -> void:
	country.available_manpower = int(preset.get("available_manpower", 0))
	country.military_stockpile.clear()
	for item_id: String in preset.get("stockpile", {}):
		var key := StringName(item_id)
		if equipment_by_id.has(key):
			country.military_stockpile[key] = maxi(int(preset.stockpile[item_id]), 0)
	country.military_production_lines.clear()
	for record: Dictionary in preset.get("production_lines", []):
		var item_id := StringName(str(record.get("item_id", "")))
		var line_id := StringName(str(record.get("id", "")))
		if line_id.is_empty() or not equipment_by_id.has(item_id):
			continue
		country.military_production_lines.append({
			"id": str(line_id),
			"item_id": str(item_id),
			"assigned_factories": maxi(int(record.get("assigned_factories", 0)), 0),
			"efficiency": clampf(float(record.get("efficiency", LINE_START_EFFICIENCY)), LINE_START_EFFICIENCY, 1.0),
			"progress": maxf(float(record.get("progress", 0.0)), 0.0),
		})
	country.armies_by_id.clear()
	for record: Dictionary in preset.get("armies", []):
		var army: ArmyClass = ArmyClass.new()
		army.id = StringName(str(record.get("id", "")))
		if army.id.is_empty():
			continue
		army.display_name = str(record.get("name", army.id))
		army.owner_country_id = country.id
		army.total_personnel = maxi(int(record.get("personnel", 0)), 0)
		army.target_personnel = maxi(int(record.get("target_personnel", army.total_personnel)), army.total_personnel)
		for item_id: String in record.get("equipment_targets", {}):
			var key := StringName(item_id)
			if equipment_by_id.has(key):
				army.set_equipment_target(key, int(record.equipment_targets[item_id]))
		country.armies_by_id[army.id] = army
	country.army = country.armies_by_id.values()[0] if not country.armies_by_id.is_empty() else ArmyClass.new()
	reinforce_country(country, equipment_by_id)


func set_production_line(
	country: Resource,
	line_id: StringName,
	item_id: StringName,
	assigned_factories: int,
	equipment_by_id: Dictionary
) -> Dictionary:
	if country == null or line_id.is_empty():
		return _result(false, "국가 또는 생산선 ID가 올바르지 않습니다.")
	if assigned_factories < 0:
		return _result(false, "군수공장 수는 음수가 될 수 없습니다.")
	if assigned_factories > 0 and not equipment_by_id.has(item_id):
		return _result(false, "알 수 없는 군사 장비입니다.")
	var existing_index := _line_index(country.military_production_lines, line_id)
	var existing_count := 0
	if existing_index >= 0:
		existing_count = int(country.military_production_lines[existing_index].get("assigned_factories", 0))
	var requested_total := _requested_factory_total(country.military_production_lines) - existing_count + assigned_factories
	if requested_total > country.military_factories:
		return _result(false, "군수공장 배정 한도를 초과합니다.")
	if assigned_factories == 0:
		if existing_index >= 0:
			country.military_production_lines.remove_at(existing_index)
		return _result(true)
	if existing_index < 0:
		country.military_production_lines.append({
			"id": str(line_id),
			"item_id": str(item_id),
			"assigned_factories": assigned_factories,
			"efficiency": LINE_START_EFFICIENCY,
			"progress": 0.0,
		})
	else:
		var line: Dictionary = country.military_production_lines[existing_index]
		if str(line.get("item_id", "")) != str(item_id):
			line.item_id = str(item_id)
			line.efficiency = LINE_START_EFFICIENCY
			line.progress = 0.0
		line.assigned_factories = assigned_factories
		country.military_production_lines[existing_index] = line
	_sort_lines(country.military_production_lines)
	return _result(true)


func create_army(country: Resource, army_id: StringName, display_name: String, target_personnel: int) -> Dictionary:
	if country == null or army_id.is_empty() or country.armies_by_id.has(army_id):
		return _result(false, "부대 ID가 없거나 중복되었습니다.")
	if target_personnel <= 0:
		return _result(false, "목표 인력은 1명 이상이어야 합니다.")
	var army: ArmyClass = ArmyClass.new()
	army.id = army_id
	army.display_name = display_name if not display_name.is_empty() else str(army_id)
	army.owner_country_id = country.id
	army.target_personnel = target_personnel
	country.armies_by_id[army_id] = army
	if country.armies_by_id.size() == 1:
		country.army = army
	return _result(true)


func disband_army(country: Resource, army_id: StringName) -> Dictionary:
	if country == null or not country.armies_by_id.has(army_id):
		return _result(false, "부대를 찾을 수 없습니다.")
	var army: ArmyClass = country.armies_by_id[army_id]
	country.available_manpower += army.total_personnel
	for item_id: Variant in army.equipment:
		country.military_stockpile[item_id] = int(country.military_stockpile.get(item_id, 0)) + int(army.equipment[item_id])
	country.armies_by_id.erase(army_id)
	country.army = country.armies_by_id.values()[0] if not country.armies_by_id.is_empty() else ArmyClass.new()
	return _result(true)


func set_army_personnel_target(country: Resource, army_id: StringName, target: int) -> Dictionary:
	var army: ArmyClass = country.armies_by_id.get(army_id) if country != null else null
	if army == null or target < army.total_personnel:
		return _result(false, "목표 인력은 현재 인력 이상이어야 합니다.")
	army.target_personnel = target
	return _result(true)


func set_army_equipment_target(
	country: Resource,
	army_id: StringName,
	item_id: StringName,
	count: int,
	equipment_by_id: Dictionary
) -> Dictionary:
	var army: ArmyClass = country.armies_by_id.get(army_id) if country != null else null
	if army == null or not equipment_by_id.has(item_id) or count < 0:
		return _result(false, "부대, 장비 또는 목표 수량이 올바르지 않습니다.")
	if not _target_within_cap(army, item_id, count, equipment_by_id):
		return _result(false, "부대 장비 상한을 초과합니다.")
	army.set_equipment_target(item_id, count)
	return _result(true)


func set_supply_priority(country: Resource, army_id: StringName, priority: int) -> Dictionary:
	var army: ArmyClass = country.armies_by_id.get(army_id) if country != null else null
	if army == null or priority < ArmyClass.SupplyPriority.LOW or priority > ArmyClass.SupplyPriority.HIGH:
		return _result(false, "부대 또는 보급 우선순위가 올바르지 않습니다.")
	army.supply_priority = priority
	return _result(true)


func advance_production(countries: Array, equipment_by_id: Dictionary) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	for country: Resource in countries:
		if country.is_surrendered:
			continue
		_sort_lines(country.military_production_lines)
		var factories_remaining: int = int(country.military_factories)
		for line: Dictionary in country.military_production_lines:
			var item_id := StringName(str(line.get("item_id", "")))
			var item: Resource = equipment_by_id.get(item_id)
			if item == null:
				continue
			var effective_factories: int = mini(maxi(int(line.get("assigned_factories", 0)), 0), factories_remaining)
			factories_remaining -= effective_factories
			if effective_factories <= 0:
				continue
			var efficiency := clampf(float(line.get("efficiency", LINE_START_EFFICIENCY)), LINE_START_EFFICIENCY, 1.0)
			var potential: float = maxf(float(line.get("progress", 0.0)), 0.0) + effective_factories * float(item.production_per_factory) * efficiency
			var material_cap := floori(potential)
			for material_id: Variant in item.input_materials:
				var amount_per_unit := float(item.input_materials[material_id])
				if amount_per_unit > 0.0:
					material_cap = mini(material_cap, floori(float(country.inventory.get(material_id, 0.0)) / amount_per_unit))
			var produced := mini(floori(potential), maxi(material_cap, 0))
			if produced > 0:
				for material_id: Variant in item.input_materials:
					country.inventory[material_id] = maxf(
						float(country.inventory.get(material_id, 0.0)) - float(item.input_materials[material_id]) * produced,
						0.0
					)
				country.military_stockpile[item_id] = int(country.military_stockpile.get(item_id, 0)) + produced
				events.append({"country_id": country.id, "item_id": str(item_id), "produced": produced})
			line.progress = potential - floorf(potential) if produced == floori(potential) else 0.0
			if produced > 0:
				line.efficiency = minf(efficiency + LINE_EFFICIENCY_GAIN, 1.0)
	return events


func reinforce_country(country: Resource, equipment_by_id: Dictionary) -> void:
	var armies: Array = country.armies_by_id.values()
	armies.sort_custom(func(a: Resource, b: Resource) -> bool:
		if int(a.supply_priority) != int(b.supply_priority):
			return int(a.supply_priority) > int(b.supply_priority)
		return str(a.id) < str(b.id)
	)
	for army: ArmyClass in armies:
		var personnel_needed := maxi(army.target_personnel - army.total_personnel, 0)
		var personnel_added := mini(personnel_needed, country.available_manpower)
		army.total_personnel += personnel_added
		country.available_manpower -= personnel_added
		var item_ids: Array = army.equipment_targets.keys()
		item_ids.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
		for item_id: StringName in item_ids:
			if not equipment_by_id.has(item_id):
				continue
			var needed := maxi(army.get_equipment_target(item_id) - army.get_equipment_count(item_id), 0)
			var issued := mini(needed, int(country.military_stockpile.get(item_id, 0)))
			if issued <= 0:
				continue
			army.set_equipment_count(item_id, army.get_equipment_count(item_id) + issued)
			country.military_stockpile[item_id] = int(country.military_stockpile.get(item_id, 0)) - issued


func reinforce_countries(countries: Array, equipment_by_id: Dictionary) -> void:
	for country: Resource in countries:
		if not country.is_surrendered:
			reinforce_country(country, equipment_by_id)


func update_ai_production(country: Resource, equipment_by_id: Dictionary) -> void:
	if country == null or country.military_factories <= 0:
		return
	var desired: Array[StringName] = [&"infantry_equipment", &"supply_equipment", &"tank", &"fighter"]
	var remaining: int = int(country.military_factories)
	for index: int in desired.size():
		if remaining <= 0 or not equipment_by_id.has(desired[index]):
			break
		var factories := 1
		if index == 0:
			factories = maxi(1, ceili(country.military_factories * 0.5))
		factories = mini(factories, remaining)
		set_production_line(country, StringName("%s-ai-%03d" % [country.code, index + 1]), desired[index], factories, equipment_by_id)
		remaining -= factories


func _target_within_cap(army: ArmyClass, item_id: StringName, count: int, equipment_by_id: Dictionary) -> bool:
	var item: Resource = equipment_by_id[item_id]
	var personnel_cap := maxi(army.target_personnel, army.total_personnel)
	match str(item.equipment_group):
		"armor":
			var armor_total := count
			for existing_id: Variant in army.equipment_targets:
				if existing_id == item_id:
					continue
				var existing_item: Resource = equipment_by_id.get(existing_id)
				if existing_item != null and str(existing_item.equipment_group) == "armor":
					armor_total += int(army.equipment_targets[existing_id])
			return armor_total <= floori(personnel_cap * 0.5)
		"aircraft":
			return false
		_:
			return count <= personnel_cap


func _requested_factory_total(lines: Array) -> int:
	var result := 0
	for line: Dictionary in lines:
		result += maxi(int(line.get("assigned_factories", 0)), 0)
	return result


func _line_index(lines: Array, line_id: StringName) -> int:
	for index: int in lines.size():
		if str(lines[index].get("id", "")) == str(line_id):
			return index
	return -1


func _sort_lines(lines: Array) -> void:
	lines.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))


func _result(ok: bool, message: String = "") -> Dictionary:
	return {"ok": ok, "message": message}
