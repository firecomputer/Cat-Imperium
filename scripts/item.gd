class_name Item
extends Resource

enum Category {
	CIVILIAN,
	MILITARY,
	SHIP,
}

enum CivilianKind {
	ESSENTIAL,
	RESOURCE,
	LUXURY,
}

@export var id: StringName
@export var display_name: String
@export var category: Category = Category.CIVILIAN
@export var civilian_kind: CivilianKind = CivilianKind.ESSENTIAL
@export var base_price: float = 0.0:
	set(value):
		base_price = maxf(value, 0.0)
@export var maximum_price: float = 0.0:
	set(value):
		maximum_price = maxf(value, 0.0)
@export var minimum_price: float = 0.0:
	set(value):
		minimum_price = maxf(value, 0.0)
@export var production_cost: float = 0.0:
	set(value):
		production_cost = maxf(value, 0.0)
@export var production_per_factory: float = 10.0:
	set(value):
		production_per_factory = maxf(value, 0.0)
@export var trade_batch_size: float = 10.0:
	set(value):
		trade_batch_size = maxf(value, 0.0)
@export var demand_per_index: float = 0.0:
	set(value):
		demand_per_index = maxf(value, 0.0)
@export var standard_of_living_weight: float = 1.0:
	set(value):
		standard_of_living_weight = maxf(value, 0.0)
@export_range(0.0, 100.0, 0.1) var reliability: float = 100.0:
	set(value):
		reliability = clampf(value, 0.0, 100.0)
@export var equipment_group: StringName
@export var combat_value: float = 0.0:
	set(value):
		combat_value = maxf(value, 0.0)
@export var input_materials: Dictionary = {}


func uses_reliability() -> bool:
	return category == Category.MILITARY or category == Category.SHIP


func load_catalog_record(record: Dictionary) -> void:
	id = StringName(str(record.get("id", "")))
	display_name = str(record.get("display_name", id))
	match str(record.get("category", "civilian")):
		"military":
			category = Category.MILITARY
		"ship":
			category = Category.SHIP
		_:
			category = Category.CIVILIAN
	match str(record.get("kind", "essential")):
		"resource":
			civilian_kind = CivilianKind.RESOURCE
		"luxury":
			civilian_kind = CivilianKind.LUXURY
		_:
			civilian_kind = CivilianKind.ESSENTIAL
	base_price = float(record.get("base_price", 0.0))
	production_cost = float(record.get("production_cost", 0.0))
	minimum_price = float(record.get("minimum_price", base_price * 0.5))
	maximum_price = float(record.get("maximum_price", base_price * 3.0))
	production_per_factory = float(record.get("production_per_factory", 10.0))
	trade_batch_size = float(record.get("trade_batch_size", 10.0))
	demand_per_index = float(record.get("demand_per_index", 0.0))
	standard_of_living_weight = float(record.get("standard_of_living_weight", 1.0))
	reliability = float(record.get("reliability", 100.0))
	equipment_group = StringName(str(record.get("equipment_group", "")))
	combat_value = float(record.get("combat_value", 0.0))
	input_materials.clear()
	for material_id: String in record.get("input_materials", {}):
		input_materials[StringName(material_id)] = maxf(float(record.input_materials[material_id]), 0.0)
