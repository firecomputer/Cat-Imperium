class_name Army
extends Resource

@export var equipment: Dictionary[StringName, int] = {}
@export var total_personnel: int = 0:
	set(value):
		total_personnel = maxi(value, 0)


func set_equipment_count(item_id: StringName, count: int) -> void:
	if item_id.is_empty():
		return
	if count <= 0:
		equipment.erase(item_id)
	else:
		equipment[item_id] = count


func get_equipment_count(item_id: StringName) -> int:
	return int(equipment.get(item_id, 0))
