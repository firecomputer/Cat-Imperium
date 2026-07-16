extends RefCounted

const BUILDING_CIVILIAN := &"civilian_factory"
const BUILDING_MILITARY := &"military_factory"
const BUILDING_DOCKYARD := &"dockyard"


func initialize(countries: Array, province_states: Dictionary) -> void:
	province_states.clear()
	for country: Resource in countries:
		country.controlled_province_ids = country.owned_province_ids.duplicate()
		country.controlled_province_ids.sort()
		country.province_buildings.clear()
		for province_id: int in country.owned_province_ids:
			province_states[province_id] = {
				"owner_country_id": country.id,
				"controller_country_id": country.id,
			}
		_distribute_buildings(country, BUILDING_CIVILIAN, country.civilian_factories, false)
		_distribute_buildings(country, BUILDING_MILITARY, country.military_factories, false)
		_distribute_buildings(country, BUILDING_DOCKYARD, country.dockyards, true)
		recalculate_country_factories(country)
		refresh_construction_capacity(country)


func capture_province(
	province_id: int,
	new_controller: Resource,
	countries_by_id: Dictionary,
	province_states: Dictionary
) -> Dictionary:
	var state: Dictionary = province_states.get(province_id, {})
	if state.is_empty() or new_controller == null:
		return _result(false, "프로빈스 또는 새 지배국을 찾을 수 없습니다.")
	var old_controller_id := int(state.get("controller_country_id", 0))
	if old_controller_id == new_controller.id:
		return _result(false, "이미 해당 국가가 지배하고 있습니다.")
	var old_controller: Resource = countries_by_id.get(old_controller_id)
	if old_controller == null:
		return _result(false, "기존 지배국을 찾을 수 없습니다.")
	old_controller.controlled_province_ids.erase(province_id)
	if province_id not in new_controller.controlled_province_ids:
		new_controller.controlled_province_ids.append(province_id)
		new_controller.controlled_province_ids.sort()
	var buildings: Dictionary = old_controller.province_buildings.get(province_id, {}).duplicate(true)
	old_controller.province_buildings.erase(province_id)
	if not buildings.is_empty():
		new_controller.province_buildings[province_id] = buildings
	_cancel_project_at(old_controller, province_id)
	state.controller_country_id = new_controller.id
	province_states[province_id] = state
	recalculate_country_factories(old_controller)
	recalculate_country_factories(new_controller)
	refresh_construction_capacity(old_controller)
	refresh_construction_capacity(new_controller)
	return {
		"ok": true,
		"message": "",
		"province_id": province_id,
		"old_controller_id": old_controller_id,
		"new_controller_id": new_controller.id,
	}


func recalculate_country_factories(country: Resource) -> void:
	var civilian := 0
	var military := 0
	var dockyards := 0
	for province_id: Variant in country.province_buildings:
		var buildings: Dictionary = country.province_buildings[province_id]
		civilian += maxi(int(buildings.get(BUILDING_CIVILIAN, buildings.get(str(BUILDING_CIVILIAN), 0))), 0)
		military += maxi(int(buildings.get(BUILDING_MILITARY, buildings.get(str(BUILDING_MILITARY), 0))), 0)
		dockyards += maxi(int(buildings.get(BUILDING_DOCKYARD, buildings.get(str(BUILDING_DOCKYARD), 0))), 0)
	country.civilian_factories = civilian
	country.military_factories = military
	country.dockyards = dockyards


func refresh_construction_capacity(country: Resource) -> void:
	var projects: Array = country.construction_projects
	projects.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("province_id", 0)) < int(b.get("province_id", 0))
	)
	var active_capacity: int = int(country.civilian_factories)
	for index: int in projects.size():
		projects[index].paused = index >= active_capacity


func get_controller_id(province_states: Dictionary, province_id: int) -> int:
	return int(province_states.get(province_id, {}).get("controller_country_id", 0))


func get_owner_id(province_states: Dictionary, province_id: int) -> int:
	return int(province_states.get(province_id, {}).get("owner_country_id", 0))


func to_save_data(province_states: Dictionary) -> Dictionary:
	var result := {}
	var province_ids: Array = province_states.keys()
	province_ids.sort()
	for province_id: Variant in province_ids:
		result[str(province_id)] = int(province_states[province_id].get("controller_country_id", 0))
	return result


func apply_control_data(
	data: Dictionary,
	countries_by_id: Dictionary,
	province_states: Dictionary
) -> void:
	for country: Resource in countries_by_id.values():
		country.controlled_province_ids.clear()
	for province_key: String in data:
		var province_id := int(province_key)
		if not province_states.has(province_id):
			continue
		var controller_id := int(data[province_key])
		var controller: Resource = countries_by_id.get(controller_id)
		if controller == null:
			continue
		province_states[province_id].controller_country_id = controller_id
		controller.controlled_province_ids.append(province_id)
	for country: Resource in countries_by_id.values():
		country.controlled_province_ids.sort()
		recalculate_country_factories(country)
		refresh_construction_capacity(country)


func _distribute_buildings(country: Resource, building_type: StringName, count: int, coastal_only: bool) -> void:
	if count <= 0:
		return
	var eligible: Array[int] = []
	for province_id: int in country.owned_province_ids:
		if coastal_only and not bool(ProvinceMapDB.get_province(province_id).get("water_border", false)):
			continue
		eligible.append(province_id)
	eligible.sort()
	if eligible.is_empty():
		return
	for index: int in count:
		var province_id := eligible[index % eligible.size()]
		var buildings: Dictionary = country.province_buildings.get(province_id, {})
		buildings[building_type] = int(buildings.get(building_type, 0)) + 1
		country.province_buildings[province_id] = buildings


func _cancel_project_at(country: Resource, province_id: int) -> void:
	for index: int in range(country.construction_projects.size() - 1, -1, -1):
		if int(country.construction_projects[index].get("province_id", 0)) == province_id:
			country.construction_projects.remove_at(index)


func _result(ok: bool, message: String = "") -> Dictionary:
	return {"ok": ok, "message": message}
