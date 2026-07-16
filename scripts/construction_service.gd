extends RefCounted

const BUILDING_CIVILIAN := &"civilian_factory"
const BUILDING_MILITARY := &"military_factory"
const BUILDING_DOCKYARD := &"dockyard"
const CONSTRUCTION_DAYS := 100
const REQUIREMENTS := {
	BUILDING_CIVILIAN: {
		"cost": 5000.0,
		"materials": {&"wood": 30.0, &"concrete": 40.0, &"steel": 20.0, &"glass": 10.0},
	},
	BUILDING_MILITARY: {
		"cost": 7500.0,
		"materials": {&"wood": 20.0, &"concrete": 40.0, &"steel": 40.0, &"glass": 10.0},
	},
	BUILDING_DOCKYARD: {
		"cost": 8000.0,
		"materials": {&"wood": 40.0, &"concrete": 30.0, &"steel": 30.0, &"glass": 10.0},
	},
}


func get_requirements(building_type: StringName) -> Dictionary:
	return REQUIREMENTS.get(building_type, {}).duplicate(true)


func start(
	country: Resource,
	player_country_id: int,
	province_id: int,
	building_type: StringName,
	require_player: bool,
	province: Dictionary,
	items_by_id: Dictionary
) -> Dictionary:
	if country == null:
		return _result(false, "국가를 찾을 수 없습니다.")
	if require_player and country.id != player_country_id:
		return _result(false, "플레이어 국가에서만 건설할 수 있습니다.")
	if not REQUIREMENTS.has(building_type):
		return _result(false, "알 수 없는 건물 종류입니다.")
	if not country.controls_province(province_id):
		return _result(false, "해당 국가가 지배하는 프로빈스가 아닙니다.")
	if has_project(country, province_id):
		return _result(false, "이 프로빈스에서는 이미 건설이 진행 중입니다.")
	if country.get_trade_factories() <= 0:
		return _result(false, "건설에 전환할 무역 민간공장이 없습니다.")
	if building_type == BUILDING_DOCKYARD and not bool(province.get("water_border", false)):
		return _result(false, "조선소는 해안 프로빈스에만 건설할 수 있습니다.")
	var requirements: Dictionary = REQUIREMENTS[building_type]
	var cost := float(requirements.cost)
	if country.treasury < cost:
		return _result(false, "국고가 부족합니다.")
	var materials: Dictionary = requirements.materials
	for item_id: Variant in materials:
		if float(country.inventory.get(item_id, 0.0)) < float(materials[item_id]):
			var item: Resource = items_by_id.get(item_id)
			var display_name: String = str(item_id) if item == null else str(item.display_name)
			return _result(false, "%s 재고가 부족합니다." % display_name)
	country.treasury -= cost
	for item_id: Variant in materials:
		country.inventory[item_id] = float(country.inventory.get(item_id, 0.0)) - float(materials[item_id])
	country.construction_projects.append({
		"province_id": province_id,
		"building_type": str(building_type),
		"remaining_days": CONSTRUCTION_DAYS,
		"total_days": CONSTRUCTION_DAYS,
		"paused": false,
	})
	return _result(true, "건설을 시작했습니다.")


func cancel(country: Resource, player_country_id: int, province_id: int) -> Dictionary:
	if country == null or country.id != player_country_id:
		return _result(false, "플레이어 국가의 건설만 취소할 수 있습니다.")
	for index: int in country.construction_projects.size():
		var project: Dictionary = country.construction_projects[index]
		if int(project.get("province_id", 0)) == province_id:
			country.construction_projects.remove_at(index)
			return _result(true, "건설을 취소했습니다. 이미 사용한 비용과 자재는 환불되지 않습니다.")
	return _result(false, "취소할 건설이 없습니다.")


func has_project(country: Resource, province_id: int) -> bool:
	for project: Dictionary in country.construction_projects:
		if int(project.get("province_id", 0)) == province_id:
			return true
	return false


func advance_week(countries: Array, turn_days: int) -> Array[Dictionary]:
	var completed: Array[Dictionary] = []
	for country: Resource in countries:
		var active_projects: Array = []
		for project: Dictionary in country.construction_projects:
			if bool(project.get("paused", false)):
				active_projects.append(project)
				continue
			project.remaining_days = int(project.get("remaining_days", CONSTRUCTION_DAYS)) - turn_days
			if int(project.remaining_days) > 0:
				active_projects.append(project)
				continue
			var province_id := int(project.get("province_id", 0))
			var building_type := StringName(str(project.get("building_type", "")))
			var buildings: Dictionary = country.province_buildings.get(province_id, {})
			buildings[building_type] = int(buildings.get(building_type, 0)) + 1
			country.province_buildings[province_id] = buildings
			match building_type:
				BUILDING_CIVILIAN:
					country.civilian_factories += 1
				BUILDING_MILITARY:
					country.military_factories += 1
				BUILDING_DOCKYARD:
					country.dockyards += 1
			completed.append({"country": country, "province_id": province_id})
		country.construction_projects = active_projects
	return completed


func _result(ok: bool, message: String = "") -> Dictionary:
	return {"ok": ok, "message": message}
