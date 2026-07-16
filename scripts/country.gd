class_name Country
extends Resource

const ArmyClass = preload("res://scripts/army.gd")

@export var id: int
@export var code: StringName
@export var display_name: String
@export var real_gdp: float = 0.0:
	set(value):
		real_gdp = maxf(value, 0.0)
@export var owned_province_ids: Array[int] = []
@export var civilian_factories: int = 0:
	set(value):
		civilian_factories = maxi(value, 0)
@export var military_factories: int = 0:
	set(value):
		military_factories = maxi(value, 0)
@export var dockyards: int = 0:
	set(value):
		dockyards = maxi(value, 0)
@export var population: int = 0:
	set(value):
		population = maxi(value, 0)
@export var army: ArmyClass = ArmyClass.new()
@export var controlled_province_ids: Array[int] = []
@export var available_manpower: int = 0:
	set(value):
		available_manpower = maxi(value, 0)
@export_range(0.0, 10.0, 0.1) var standard_of_living: float = 0.0:
	set(value):
		standard_of_living = clampf(value, 0.0, 10.0)
@export var demand_index: float = 1.0:
	set(value):
		demand_index = maxf(value, 0.0)
@export var treasury: float = 0.0:
	set(value):
		treasury = maxf(value, 0.0)
@export_range(0.0, 0.5, 0.01) var consumption_tax_rate: float = 0.2:
	set(value):
		consumption_tax_rate = clampf(value, 0.0, 0.5)
@export_range(0.0, 0.5, 0.01) var property_tax_rate: float = 0.2:
	set(value):
		property_tax_rate = clampf(value, 0.0, 0.5)
@export_range(0, 100, 1) var consumer_ratio: int = 40:
	set(value):
		consumer_ratio = clampi(value, 0, 100)
@export var leader_id: StringName
@export var leader_name: String
@export var leader_trait: String
@export var leader_color: Color = Color.WHITE
@export var leader_portrait: String

var inventory: Dictionary = {}
var prices: Dictionary = {}
var production_allocations: Dictionary = {}
var weekly_stats: Dictionary = {}
var weekly_real_gdp_history: Array[float] = []
var province_buildings: Dictionary = {}
var construction_projects: Array = []
var military_stockpile: Dictionary = {}
var military_production_lines: Array = []
var armies_by_id: Dictionary = {}
var is_surrendered := false


func load_map_record(record: Dictionary) -> void:
	id = int(record.get("id", 0))
	code = StringName(str(record.get("code", "")))
	var localized_name := str(record.get("name_ko", ""))
	display_name = localized_name if not localized_name.is_empty() else str(record.get("name", ""))
	real_gdp = 0.0
	weekly_real_gdp_history.clear()
	population = roundi(float(record.get("population_estimate", 0.0)))
	owned_province_ids.clear()
	for province_id: Variant in record.get("province_ids", []):
		owned_province_ids.append(int(province_id))
	controlled_province_ids = owned_province_ids.duplicate()
	army = ArmyClass.new()
	armies_by_id.clear()


func apply_scenario_preset(preset: Dictionary) -> void:
	demand_index = float(preset.get("demand_index", 1.0))
	treasury = float(preset.get("treasury", 0.0))
	consumption_tax_rate = float(preset.get("consumption_tax_rate", 0.2))
	property_tax_rate = float(preset.get("property_tax_rate", 0.2))
	consumer_ratio = int(preset.get("consumer_ratio", 40))
	standard_of_living = float(preset.get("standard_of_living", 6.0))
	civilian_factories = int(preset.get("civilian_factories", 0))
	military_factories = int(preset.get("military_factories", 0))
	dockyards = int(preset.get("dockyards", 0))
	var leader: Dictionary = preset.get("leader", {})
	leader_id = StringName(str(leader.get("id", "")))
	leader_name = str(leader.get("name", ""))
	leader_trait = str(leader.get("trait", ""))
	leader_color = Color.from_string(str(leader.get("color", "#ffffff")), Color.WHITE)
	leader_portrait = str(leader.get("portrait", ""))
	production_allocations.clear()
	for item_id: String in preset.get("production_allocations", {}):
		production_allocations[StringName(item_id)] = int(preset.production_allocations[item_id])


func get_active_construction_count() -> int:
	var result := 0
	for project: Dictionary in construction_projects:
		if not bool(project.get("paused", false)):
			result += 1
	return result


func controls_province(province_id: int) -> bool:
	return province_id in controlled_province_ids


func get_effective_consumer_factories() -> int:
	return mini(
		floori(float(civilian_factories * consumer_ratio) / 100.0),
		maxi(civilian_factories - get_active_construction_count(), 0)
	)


func get_allocated_consumer_factories() -> int:
	var total := 0
	for count: Variant in production_allocations.values():
		total += maxi(int(count), 0)
	return total


func get_trade_factories() -> int:
	return maxi(
		civilian_factories - get_effective_consumer_factories() - get_active_construction_count(),
		0
	)


func reset_weekly_stats(item_ids: Array[StringName]) -> void:
	weekly_stats = {
		"domestic_production_value": 0.0,
		"weekly_real_gdp": 0.0,
		"import_value": 0.0,
		"consumption_value": 0.0,
		"consumption_tax_revenue": 0.0,
		"property_tax_revenue": 0.0,
		"tax_revenue": 0.0,
	}
	for item_id: StringName in item_ids:
		weekly_stats[item_id] = {
			"produced": 0.0,
			"demand": 0.0,
			"consumed": 0.0,
			"imported": 0.0,
			"import_value": 0.0,
			"exported": 0.0,
		}


func to_save_data() -> Dictionary:
	return {
		"id": id,
		"treasury": treasury,
		"real_gdp": real_gdp,
		"weekly_real_gdp_history": weekly_real_gdp_history.duplicate(),
		"consumption_tax_rate": consumption_tax_rate,
		"property_tax_rate": property_tax_rate,
		"standard_of_living": standard_of_living,
		"consumer_ratio": consumer_ratio,
		"civilian_factories": civilian_factories,
		"military_factories": military_factories,
		"dockyards": dockyards,
		"inventory": _stringify_keys(inventory),
		"prices": _stringify_keys(prices),
		"production_allocations": _stringify_keys(production_allocations),
		"province_buildings": _stringify_keys(province_buildings),
		"construction_projects": construction_projects.duplicate(true),
		"controlled_province_ids": controlled_province_ids.duplicate(),
		"available_manpower": available_manpower,
		"military_stockpile": _stringify_keys(military_stockpile),
		"military_production_lines": military_production_lines.duplicate(true),
		"armies": _armies_to_save_data(),
		"is_surrendered": is_surrendered,
	}


func apply_save_data(data: Dictionary) -> void:
	treasury = float(data.get("treasury", treasury))
	real_gdp = float(data.get("real_gdp", real_gdp))
	weekly_real_gdp_history.clear()
	var saved_gdp_history: Variant = data.get("weekly_real_gdp_history", [])
	if typeof(saved_gdp_history) == TYPE_ARRAY and not saved_gdp_history.is_empty():
		for weekly_value: Variant in saved_gdp_history:
			weekly_real_gdp_history.append(maxf(float(weekly_value), 0.0))
	elif real_gdp > 0.0:
		var legacy_weekly_gdp := real_gdp / 52.0
		for _week: int in 12:
			weekly_real_gdp_history.append(legacy_weekly_gdp)
	consumption_tax_rate = float(data.get("consumption_tax_rate", consumption_tax_rate))
	property_tax_rate = float(data.get("property_tax_rate", property_tax_rate))
	standard_of_living = float(data.get("standard_of_living", standard_of_living))
	consumer_ratio = int(data.get("consumer_ratio", consumer_ratio))
	civilian_factories = int(data.get("civilian_factories", civilian_factories))
	military_factories = int(data.get("military_factories", military_factories))
	dockyards = int(data.get("dockyards", dockyards))
	inventory = _item_key_dictionary(data.get("inventory", {}), true)
	prices = _item_key_dictionary(data.get("prices", {}), true)
	production_allocations = _item_key_dictionary(data.get("production_allocations", {}), false)
	province_buildings.clear()
	for province_id: String in data.get("province_buildings", {}):
		province_buildings[int(province_id)] = data.province_buildings[province_id]
	construction_projects = data.get("construction_projects", []).duplicate(true)
	controlled_province_ids.clear()
	for province_id: Variant in data.get("controlled_province_ids", owned_province_ids):
		controlled_province_ids.append(int(province_id))
	available_manpower = int(data.get("available_manpower", 0))
	military_stockpile = _item_key_dictionary(data.get("military_stockpile", {}), false)
	military_production_lines = data.get("military_production_lines", []).duplicate(true)
	armies_by_id.clear()
	for army_data: Dictionary in data.get("armies", []):
		var loaded_army: ArmyClass = ArmyClass.new()
		loaded_army.apply_save_data(army_data)
		if not loaded_army.id.is_empty():
			armies_by_id[loaded_army.id] = loaded_army
	army = armies_by_id.values()[0] if not armies_by_id.is_empty() else ArmyClass.new()
	is_surrendered = bool(data.get("is_surrendered", false))


func _stringify_keys(source: Dictionary) -> Dictionary:
	var result := {}
	for key: Variant in source:
		result[str(key)] = source[key]
	return result


func _item_key_dictionary(source: Dictionary, use_float: bool) -> Dictionary:
	var result := {}
	for key: String in source:
		result[StringName(key)] = float(source[key]) if use_float else int(source[key])
	return result


func _armies_to_save_data() -> Array:
	var result: Array = []
	var army_ids: Array = armies_by_id.keys()
	army_ids.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
	for army_id: Variant in army_ids:
		result.append(armies_by_id[army_id].to_save_data())
	return result
