extends RefCounted


func build_snapshot(countries: Array, metadata: Dictionary) -> Dictionary:
	var country_data: Array = []
	for country: Resource in countries:
		country_data.append(country.to_save_data())
	return {
		"schema_version": int(metadata.schema_version),
		"scenario_id": str(metadata.scenario_id),
		"turn": int(metadata.turn),
		"elapsed_days": int(metadata.elapsed_days),
		"start_date": str(metadata.start_date),
		"player_country_id": int(metadata.player_country_id),
		"countries": country_data,
		"province_control": metadata.get("province_control", {}).duplicate(true),
		"war_state": metadata.get("war_state", {}).duplicate(true),
	}


func migrate_v1(data: Dictionary, default_snapshot: Dictionary, legacy_scenario_id: String) -> Dictionary:
	if int(data.get("schema_version", -1)) != 1:
		return {"ok": true, "message": "", "data": data}
	if str(data.get("scenario_id", "")) != legacy_scenario_id:
		return _result(false, "지원하지 않는 이전 시나리오 저장 파일입니다.")
	var migrated := default_snapshot.duplicate(true)
	migrated.turn = int(data.get("turn", -1))
	migrated.elapsed_days = int(data.get("elapsed_days", -1))
	migrated.start_date = str(data.get("start_date", migrated.start_date))
	var default_by_id := {}
	for country_data: Dictionary in migrated.get("countries", []):
		default_by_id[int(country_data.get("id", 0))] = country_data
	for legacy_country: Dictionary in data.get("countries", []):
		var country_id := int(legacy_country.get("id", 0))
		if not default_by_id.has(country_id):
			return _result(false, "이전 저장 파일에 알 수 없는 국가가 있습니다.")
		var target: Dictionary = default_by_id[country_id]
		for key: String in [
			"treasury", "standard_of_living", "consumer_ratio",
			"civilian_factories", "military_factories", "dockyards", "inventory",
			"prices", "production_allocations", "construction_projects"
		]:
			if legacy_country.has(key):
				target[key] = legacy_country[key].duplicate(true) if typeof(legacy_country[key]) in [TYPE_DICTIONARY, TYPE_ARRAY] else legacy_country[key]
		var legacy_tax_rate := float(legacy_country.get("tax_rate", target.consumption_tax_rate))
		target.consumption_tax_rate = legacy_tax_rate
		target.property_tax_rate = legacy_tax_rate
		var merged_buildings: Dictionary = target.get("province_buildings", {}).duplicate(true)
		for province_key: String in legacy_country.get("province_buildings", {}):
			var buildings: Dictionary = merged_buildings.get(province_key, {}).duplicate(true)
			for building_key: String in legacy_country.province_buildings[province_key]:
				buildings[building_key] = int(buildings.get(building_key, 0)) + int(legacy_country.province_buildings[province_key][building_key])
			merged_buildings[province_key] = buildings
		target.province_buildings = merged_buildings
		default_by_id[country_id] = target
	var migrated_countries: Array = []
	for country_data: Dictionary in migrated.get("countries", []):
		migrated_countries.append(default_by_id[int(country_data.id)])
	migrated.countries = migrated_countries
	return {"ok": true, "message": "", "data": migrated}


func migrate_v2(data: Dictionary, scenario_id: String) -> Dictionary:
	if int(data.get("schema_version", -1)) != 2:
		return {"ok": true, "message": "", "data": data}
	if str(data.get("scenario_id", "")) != scenario_id:
		return _result(false, "지원하지 않는 이전 시나리오 저장 파일입니다.")
	var migrated := data.duplicate(true)
	migrated.schema_version = 3
	for country_data: Dictionary in migrated.get("countries", []):
		var legacy_tax_rate := float(country_data.get("tax_rate", 0.2))
		country_data.real_gdp = maxf(float(country_data.get("real_gdp", 0.0)), 0.0)
		country_data.consumption_tax_rate = float(
			country_data.get("consumption_tax_rate", legacy_tax_rate)
		)
		country_data.property_tax_rate = float(country_data.get("property_tax_rate", legacy_tax_rate))
		country_data.erase("tax_rate")
	return {"ok": true, "message": "", "data": migrated}


func write_file(path: String, data: Dictionary) -> Dictionary:
	var temporary_path := "%s.tmp" % path
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return _result(false, "저장 파일을 만들 수 없습니다.")
	file.store_string(JSON.stringify(data, "  "))
	file = null
	var target_absolute := ProjectSettings.globalize_path(path)
	var temporary_absolute := ProjectSettings.globalize_path(temporary_path)
	var backup_path := "%s.bak" % path
	var backup_absolute := ProjectSettings.globalize_path(backup_path)
	if FileAccess.file_exists(path):
		if FileAccess.file_exists(backup_path):
			DirAccess.remove_absolute(backup_absolute)
		var backup_error := DirAccess.rename_absolute(target_absolute, backup_absolute)
		if backup_error != OK:
			DirAccess.remove_absolute(temporary_absolute)
			return _result(false, "기존 저장 파일을 보호할 수 없습니다.")
	var rename_error := DirAccess.rename_absolute(temporary_absolute, target_absolute)
	if rename_error != OK:
		if FileAccess.file_exists(backup_path):
			DirAccess.rename_absolute(backup_absolute, target_absolute)
		return _result(false, "임시 저장 파일을 확정할 수 없습니다.")
	if FileAccess.file_exists(backup_path):
		DirAccess.remove_absolute(backup_absolute)
	return _result(true, "게임을 저장했습니다.")


func read_file(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _result(false, "저장 파일이 없습니다.")
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK:
		return _result(false, "저장 파일 형식이 올바르지 않습니다.")
	var parsed: Variant = parser.data
	if typeof(parsed) != TYPE_DICTIONARY:
		return _result(false, "저장 파일 형식이 올바르지 않습니다.")
	return {"ok": true, "message": "", "data": parsed}


func validate(data: Dictionary, context: Dictionary) -> Dictionary:
	if int(data.get("schema_version", -1)) != int(context.schema_version):
		return _result(false, "지원하지 않는 저장 파일 버전입니다.")
	if str(data.get("scenario_id", "")) != str(context.scenario_id):
		return _result(false, "다른 시나리오의 저장 파일입니다.")
	if int(data.get("turn", -1)) < 0 or int(data.get("elapsed_days", -1)) < 0:
		return _result(false, "저장된 턴 정보가 잘못되었습니다.")
	if int(data.get("player_country_id", 0)) != int(context.player_country_id):
		return _result(false, "저장된 플레이어 국가가 올바르지 않습니다.")
	var saved_countries: Array = data.get("countries", [])
	if saved_countries.size() != int(context.expected_country_count):
		return _result(false, "저장된 국가 수가 올바르지 않습니다.")
	var countries_by_id: Dictionary = context.countries_by_id
	var item_order: Array[StringName] = context.item_order
	var items_by_id: Dictionary = context.items_by_id
	var construction_requirements: Dictionary = context.construction_requirements
	var construction_days := int(context.construction_days)
	var equipment_by_id: Dictionary = context.get("equipment_by_id", {})
	var province_states: Dictionary = context.get("province_states", {})
	var active_country_ids: Dictionary = context.get("active_country_ids", {})
	var province_control: Dictionary = data.get("province_control", {})
	if province_control.size() != province_states.size():
		return _result(false, "저장된 프로빈스 지배권 수가 올바르지 않습니다.")
	for province_key: String in province_control:
		var province_id := int(province_key)
		if not province_states.has(province_id) or not active_country_ids.has(int(province_control[province_key])):
			return _result(false, "저장된 프로빈스 지배권이 잘못되었습니다.")
	for country_data: Dictionary in saved_countries:
		var country: Resource = countries_by_id.get(int(country_data.get("id", 0)))
		if country == null:
			return _result(false, "저장 파일에 알 수 없는 국가가 있습니다.")
		if (
			not _is_nonnegative_number(country_data.get("treasury"))
			or not _is_nonnegative_number(country_data.get("real_gdp"))
			or not _is_nonnegative_number(country_data.get("standard_of_living"))
			or float(country_data.get("standard_of_living", 11.0)) > 10.0
			or not _is_nonnegative_number(country_data.get("consumption_tax_rate"))
			or float(country_data.get("consumption_tax_rate", 1.0)) > 0.5
			or not _is_nonnegative_number(country_data.get("property_tax_rate"))
			or float(country_data.get("property_tax_rate", 1.0)) > 0.5
			or int(country_data.get("civilian_factories", -1)) < 0
			or int(country_data.get("military_factories", -1)) < 0
			or int(country_data.get("dockyards", -1)) < 0
			or int(country_data.get("consumer_ratio", -1)) < 0
			or int(country_data.get("consumer_ratio", 101)) > 100
		):
			return _result(false, "저장된 국가 경제 수치가 잘못되었습니다.")
		var gdp_history: Variant = country_data.get("weekly_real_gdp_history", [])
		if typeof(gdp_history) != TYPE_ARRAY or gdp_history.size() > 12:
			return _result(false, "저장된 실질 GDP 이력이 잘못되었습니다.")
		var gdp_history_total := 0.0
		for weekly_value: Variant in gdp_history:
			if not _is_nonnegative_number(weekly_value):
				return _result(false, "저장된 실질 GDP 이력이 잘못되었습니다.")
			gdp_history_total += float(weekly_value)
		if (
			not gdp_history.is_empty()
			and not is_equal_approx(
				float(country_data.real_gdp),
				gdp_history_total / float(gdp_history.size()) * 52.0
			)
		):
			return _result(false, "저장된 실질 GDP와 이력이 일치하지 않습니다.")
		var inventory: Dictionary = country_data.get("inventory", {})
		var prices: Dictionary = country_data.get("prices", {})
		for item_id: StringName in item_order:
			if (
				not inventory.has(str(item_id))
				or not prices.has(str(item_id))
				or not _is_nonnegative_number(inventory.get(str(item_id)))
				or not _is_nonnegative_number(prices.get(str(item_id)))
			):
				return _result(false, "저장된 품목 상태가 잘못되었습니다.")
		var allocations: Dictionary = country_data.get("production_allocations", {})
		var allocation_total := 0
		for item_key: String in allocations:
			if not items_by_id.has(StringName(item_key)) or int(allocations[item_key]) < 0:
				return _result(false, "저장된 생산 배정이 잘못되었습니다.")
			allocation_total += int(allocations[item_key])
		var projects: Array = country_data.get("construction_projects", [])
		var project_provinces := {}
		for project: Variant in projects:
			if typeof(project) != TYPE_DICTIONARY:
				return _result(false, "저장된 건설 정보가 잘못되었습니다.")
			var project_data: Dictionary = project
			var province_id := int(project_data.get("province_id", 0))
			var building_type := StringName(str(project_data.get("building_type", "")))
			if (
				int(province_control.get(str(province_id), 0)) != country.id
				or project_provinces.has(province_id)
				or not construction_requirements.has(building_type)
				or int(project_data.get("remaining_days", 0)) <= 0
				or int(project_data.get("remaining_days", 0)) > construction_days
			):
				return _result(false, "저장된 건설 프로젝트가 잘못되었습니다.")
			project_provinces[province_id] = true
		var active_project_count := 0
		for project: Dictionary in projects:
			if not bool(project.get("paused", false)):
				active_project_count += 1
		var consumer_capacity := mini(
			floori(
				float(int(country_data.get("civilian_factories", 0)) * int(country_data.get("consumer_ratio", 0)))
				/ 100.0
			),
			maxi(int(country_data.get("civilian_factories", 0)) - active_project_count, 0)
		)
		if allocation_total > consumer_capacity:
			return _result(false, "저장된 생산 배정이 소비재 공장 한도를 초과합니다.")
		var province_buildings: Dictionary = country_data.get("province_buildings", {})
		for province_key: String in province_buildings:
			var province_id := int(province_key)
			if (
				int(province_control.get(str(province_id), 0)) != country.id
				or typeof(province_buildings[province_key]) != TYPE_DICTIONARY
			):
				return _result(false, "저장된 프로빈스 건물 정보가 잘못되었습니다.")
			for building_key: String in province_buildings[province_key]:
				if (
					not construction_requirements.has(StringName(building_key))
					or int(province_buildings[province_key][building_key]) < 0
				):
					return _result(false, "저장된 프로빈스 건물 수가 잘못되었습니다.")
		if int(country_data.get("available_manpower", -1)) < 0:
			return _result(false, "저장된 가용 인력이 잘못되었습니다.")
		var military_stockpile: Dictionary = country_data.get("military_stockpile", {})
		for equipment_key: String in military_stockpile:
			if not equipment_by_id.has(StringName(equipment_key)) or int(military_stockpile[equipment_key]) < 0:
				return _result(false, "저장된 군사 장비 재고가 잘못되었습니다.")
		var line_ids := {}
		for line: Dictionary in country_data.get("military_production_lines", []):
			var line_id := str(line.get("id", ""))
			var equipment_id := StringName(str(line.get("item_id", "")))
			if (
				line_id.is_empty()
				or line_ids.has(line_id)
				or not equipment_by_id.has(equipment_id)
				or int(line.get("assigned_factories", -1)) < 0
				or not _is_nonnegative_number(line.get("efficiency"))
				or float(line.get("efficiency", 0.0)) < 0.5
				or float(line.get("efficiency", 2.0)) > 1.0
				or not _is_nonnegative_number(line.get("progress"))
			):
				return _result(false, "저장된 군수 생산선이 잘못되었습니다.")
			line_ids[line_id] = true
		var army_ids := {}
		for army_data: Dictionary in country_data.get("armies", []):
			var army_id := str(army_data.get("id", ""))
			if (
				army_id.is_empty()
				or army_ids.has(army_id)
				or int(army_data.get("owner_country_id", 0)) != country.id
				or int(army_data.get("total_personnel", -1)) < 0
				or int(army_data.get("target_personnel", -1)) < int(army_data.get("total_personnel", 0))
				or int(army_data.get("supply_priority", -1)) < 0
				or int(army_data.get("supply_priority", 3)) > 2
			):
				return _result(false, "저장된 부대 정보가 잘못되었습니다.")
			army_ids[army_id] = true
			for collection_key: String in ["equipment", "equipment_targets"]:
				var collection: Dictionary = army_data.get(collection_key, {})
				for equipment_key: String in collection:
					if not equipment_by_id.has(StringName(equipment_key)) or int(collection[equipment_key]) < 0:
						return _result(false, "저장된 부대 장비 정보가 잘못되었습니다.")
			if not _army_equipment_within_caps(army_data, equipment_by_id):
				return _result(false, "저장된 부대 장비 상한이 잘못되었습니다.")
	var war_validation := _validate_war_state(
		data.get("war_state", {}),
		active_country_ids,
		province_states,
		province_control,
		saved_countries,
		equipment_by_id
	)
	if not war_validation.ok:
		return war_validation
	return _result(true)


func apply_countries(data: Dictionary, countries_by_id: Dictionary) -> void:
	for country_data: Dictionary in data.get("countries", []):
		var country: Resource = countries_by_id.get(int(country_data.get("id", 0)))
		country.apply_save_data(country_data)


func _is_nonnegative_number(value: Variant) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value)) and float(value) >= 0.0


func _validate_war_state(
	data: Dictionary,
	active_country_ids: Dictionary,
	province_states: Dictionary,
	province_control: Dictionary,
	saved_countries: Array,
	equipment_by_id: Dictionary
) -> Dictionary:
	var war_ids := {}
	for war: Dictionary in data.get("wars", []):
		var war_id := str(war.get("id", ""))
		var attacker_id := int(war.get("attacker_country_id", 0))
		var defender_id := int(war.get("defender_country_id", 0))
		if (
			war_id.is_empty()
			or war_ids.has(war_id)
			or attacker_id == defender_id
			or not active_country_ids.has(attacker_id)
			or not active_country_ids.has(defender_id)
			or int(war.get("preparation_turns_remaining", -1)) < 0
		):
			return _result(false, "저장된 전쟁 정보가 잘못되었습니다.")
		war_ids[war_id] = war
	var front_ids := {}
	var air_reserved := {}
	for front: Dictionary in data.get("fronts", []):
		var front_id := str(front.get("id", ""))
		var war_id := str(front.get("war_id", ""))
		if front_id.is_empty() or front_ids.has(front_id) or not war_ids.has(war_id):
			return _result(false, "저장된 전선 정보가 잘못되었습니다.")
		var war: Dictionary = war_ids[war_id]
		var side_ids := [int(war.attacker_country_id), int(war.defender_country_id)]
		if int(front.get("country_a_id", 0)) not in side_ids or int(front.get("country_b_id", 0)) not in side_ids:
			return _result(false, "저장된 전선 참전국이 잘못되었습니다.")
		front_ids[front_id] = front
		for key: String in ["country_a_provinces", "country_b_provinces"]:
			for province_id: Variant in front.get(key, []):
				if not province_states.has(int(province_id)) or not province_control.has(str(int(province_id))):
					return _result(false, "저장된 전선 프로빈스가 잘못되었습니다.")
		for country_key: String in front.get("targets", {}):
			var country_id := int(country_key)
			var target_id := int(front.targets[country_key])
			var enemy_id: int = int(side_ids[1]) if country_id == int(side_ids[0]) else int(side_ids[0])
			if country_id not in side_ids or int(province_control.get(str(target_id), 0)) != enemy_id:
				return _result(false, "저장된 공세 목표가 잘못되었습니다.")
		for country_key: String in front.get("air_allocations", {}):
			var country_id := int(country_key)
			if country_id not in side_ids:
				return _result(false, "저장된 항공 지원국이 잘못되었습니다.")
			for equipment_key: String in front.air_allocations[country_key]:
				var item: Resource = equipment_by_id.get(StringName(equipment_key))
				var count := int(front.air_allocations[country_key][equipment_key])
				if item == null or str(item.equipment_group) != "aircraft" or count < 0:
					return _result(false, "저장된 항공 지원이 잘못되었습니다.")
				var reservation_key := "%d:%s" % [country_id, equipment_key]
				air_reserved[reservation_key] = int(air_reserved.get(reservation_key, 0)) + count
	var saved_by_id := {}
	for country_data: Dictionary in saved_countries:
		saved_by_id[int(country_data.id)] = country_data
	for country_id: Variant in saved_by_id:
		var country_data: Dictionary = saved_by_id[country_id]
		for army_data: Dictionary in country_data.get("armies", []):
			var assigned_front_id := str(army_data.get("assigned_front_id", ""))
			if assigned_front_id.is_empty():
				continue
			if not front_ids.has(assigned_front_id):
				return _result(false, "저장된 부대 전선 배정이 잘못되었습니다.")
			var assigned_front: Dictionary = front_ids[assigned_front_id]
			if int(country_id) not in [int(assigned_front.country_a_id), int(assigned_front.country_b_id)]:
				return _result(false, "저장된 부대가 다른 국가의 전선에 배정되었습니다.")
		for equipment_key: String in country_data.get("military_stockpile", {}):
			var reservation_key := "%d:%s" % [int(country_id), equipment_key]
			if int(air_reserved.get(reservation_key, 0)) > int(country_data.military_stockpile[equipment_key]):
				return _result(false, "저장된 항공 지원이 국가 재고를 초과합니다.")
	return _result(true)


func _army_equipment_within_caps(army_data: Dictionary, equipment_by_id: Dictionary) -> bool:
	var personnel_cap := int(army_data.get("target_personnel", 0))
	for collection_key: String in ["equipment", "equipment_targets"]:
		var collection: Dictionary = army_data.get(collection_key, {})
		var armor_total := 0
		for equipment_key: String in collection:
			var item: Resource = equipment_by_id.get(StringName(equipment_key))
			if item == null:
				return false
			var count := int(collection[equipment_key])
			match str(item.equipment_group):
				"armor":
					armor_total += count
				"aircraft":
					return false
				_:
					if count > personnel_cap:
						return false
		if armor_total > floori(personnel_cap * 0.5):
			return false
	return true


func _result(ok: bool, message: String = "") -> Dictionary:
	return {"ok": ok, "message": message}
