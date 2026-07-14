class_name Country
extends Resource

const ArmyClass = preload("res://scripts/army.gd")

@export var id: int
@export var code: StringName
@export var display_name: String
@export var gdp: float = 0.0:
	set(value):
		gdp = maxf(value, 0.0)
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
@export_range(0.0, 10.0, 0.1) var standard_of_living: float = 0.0:
	set(value):
		standard_of_living = clampf(value, 0.0, 10.0)
@export var demand_index: float = 1.0:
	set(value):
		demand_index = maxf(value, 0.0)
@export var treasury: float = 0.0:
	set(value):
		treasury = maxf(value, 0.0)
@export_range(0.0, 0.5, 0.01) var tax_rate: float = 0.2:
	set(value):
		tax_rate = clampf(value, 0.0, 0.5)
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
var province_buildings: Dictionary = {}
var construction_projects: Array = []


func load_map_record(record: Dictionary) -> void:
	id = int(record.get("id", 0))
	code = StringName(str(record.get("code", "")))
	var localized_name := str(record.get("name_ko", ""))
	display_name = localized_name if not localized_name.is_empty() else str(record.get("name", ""))
	gdp = float(record.get("gdp_million_usd", 0.0))
	population = roundi(float(record.get("population_estimate", 0.0)))
	owned_province_ids.clear()
	for province_id: Variant in record.get("province_ids", []):
		owned_province_ids.append(int(province_id))
	army = ArmyClass.new()


func apply_scenario_preset(preset: Dictionary) -> void:
	demand_index = float(preset.get("demand_index", 1.0))
	treasury = float(preset.get("treasury", 0.0))
	tax_rate = float(preset.get("tax_rate", 0.2))
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
	return construction_projects.size()


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
	weekly_stats = {"tax_revenue": 0.0}
	for item_id: StringName in item_ids:
		weekly_stats[item_id] = {
			"produced": 0.0,
			"demand": 0.0,
			"consumed": 0.0,
			"imported": 0.0,
			"exported": 0.0,
		}


func to_save_data() -> Dictionary:
	return {
		"id": id,
		"treasury": treasury,
		"tax_rate": tax_rate,
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
	}


func apply_save_data(data: Dictionary) -> void:
	treasury = float(data.get("treasury", treasury))
	tax_rate = float(data.get("tax_rate", tax_rate))
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
