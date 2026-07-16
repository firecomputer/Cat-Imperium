class_name Army
extends Resource

enum SupplyPriority {
	LOW,
	NORMAL,
	HIGH,
}

@export var id: StringName
@export var display_name: String
@export var owner_country_id: int = 0
@export var equipment: Dictionary[StringName, int] = {}
@export var equipment_targets: Dictionary[StringName, int] = {}
@export var total_personnel: int = 0:
	set(value):
		total_personnel = maxi(value, 0)
@export var target_personnel: int = 0:
	set(value):
		target_personnel = maxi(value, 0)
@export var supply_priority: SupplyPriority = SupplyPriority.NORMAL
@export var assigned_front_id: StringName


func set_equipment_count(item_id: StringName, count: int) -> void:
	if item_id.is_empty():
		return
	if count <= 0:
		equipment.erase(item_id)
	else:
		equipment[item_id] = count


func get_equipment_count(item_id: StringName) -> int:
	return int(equipment.get(item_id, 0))


func set_equipment_target(item_id: StringName, count: int) -> void:
	if item_id.is_empty():
		return
	if count <= 0:
		equipment_targets.erase(item_id)
	else:
		equipment_targets[item_id] = count


func get_equipment_target(item_id: StringName) -> int:
	return int(equipment_targets.get(item_id, 0))


func to_save_data() -> Dictionary:
	return {
		"id": str(id),
		"display_name": display_name,
		"owner_country_id": owner_country_id,
		"equipment": _stringify_keys(equipment),
		"equipment_targets": _stringify_keys(equipment_targets),
		"total_personnel": total_personnel,
		"target_personnel": target_personnel,
		"supply_priority": int(supply_priority),
		"assigned_front_id": str(assigned_front_id),
	}


func apply_save_data(data: Dictionary) -> void:
	id = StringName(str(data.get("id", "")))
	display_name = str(data.get("display_name", id))
	owner_country_id = int(data.get("owner_country_id", 0))
	total_personnel = int(data.get("total_personnel", 0))
	target_personnel = int(data.get("target_personnel", total_personnel))
	supply_priority = clampi(int(data.get("supply_priority", SupplyPriority.NORMAL)), SupplyPriority.LOW, SupplyPriority.HIGH) as SupplyPriority
	assigned_front_id = StringName(str(data.get("assigned_front_id", "")))
	equipment = _item_dictionary(data.get("equipment", {}))
	equipment_targets = _item_dictionary(data.get("equipment_targets", {}))


func _stringify_keys(source: Dictionary) -> Dictionary:
	var result := {}
	for key: Variant in source:
		result[str(key)] = int(source[key])
	return result


func _item_dictionary(source: Dictionary) -> Dictionary[StringName, int]:
	var result: Dictionary[StringName, int] = {}
	for key: String in source:
		result[StringName(key)] = maxi(int(source[key]), 0)
	return result
