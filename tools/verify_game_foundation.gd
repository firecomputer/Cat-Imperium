extends SceneTree

const ArmyClass = preload("res://scripts/army.gd")
const CountryClass = preload("res://scripts/country.gd")
const ItemClass = preload("res://scripts/item.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var database := _load_database()
	if database.is_empty():
		return
	var korea_record: Dictionary
	for record: Dictionary in database.get("countries", []):
		if str(record.get("code", "")) == "KOR":
			korea_record = record
			break
	if not _check(not korea_record.is_empty(), "KOR record is missing"):
		return

	var country = CountryClass.new()
	country.load_map_record(korea_record)
	if not _check(country.id == 25, "Unexpected KOR country ID"):
		return
	if not _check(is_equal_approx(country.real_gdp, 1646739.0), "KOR map GDP was not used as the starting real GDP"):
		return
	if not _check(country.population == 51709098, "Unexpected KOR population"):
		return
	if not _check(country.owned_province_ids.size() == 25, "Unexpected KOR province count"):
		return
	if not _check(country.army != null and country.army.total_personnel == 0, "Country army was not initialized"):
		return
	country.standard_of_living = 15.0
	if not _check(country.standard_of_living == 10.0, "Living standard was not clamped"):
		return

	var army = ArmyClass.new()
	army.total_personnel = -1
	army.set_equipment_count(&"infantry_equipment", 120)
	if not _check(army.total_personnel == 0, "Army personnel accepted a negative value"):
		return
	if not _check(army.get_equipment_count(&"infantry_equipment") == 120, "Army equipment count was not stored"):
		return
	army.set_equipment_count(&"infantry_equipment", 0)
	if not _check(army.get_equipment_count(&"infantry_equipment") == 0, "Zero equipment count was not removed"):
		return

	var item = ItemClass.new()
	item.id = &"destroyer"
	item.category = ItemClass.Category.SHIP
	item.base_price = -10.0
	item.reliability = 120.0
	if not _check(item.uses_reliability(), "Ship item does not use reliability"):
		return
	if not _check(item.base_price == 0.0 and item.reliability == 100.0, "Item numeric ranges were not enforced"):
		return

	var game_state := root.get_node_or_null("GameState")
	if not _check(game_state != null and game_state.is_initialized, "GameState did not initialize"):
		return
	if not _check(game_state.sample_country != null and game_state.sample_country.code == &"KOR", "GameState sample country is invalid"):
		return

	var main_scene := load("res://Main.tscn") as PackedScene
	var main := main_scene.instantiate()
	root.add_child(main)
	await process_frame
	var camera: Camera2D = main.get_node("MapCamera")
	var viewport_size := root.get_viewport().get_visible_rect().size
	var expected_minimum_zoom := maxf(viewport_size.x / 4096.0, viewport_size.y / 2048.0)
	if not _check(is_equal_approx(camera.zoom.x, expected_minimum_zoom), "Initial zoom does not fill the viewport"):
		return

	camera.zoom = Vector2.ONE
	camera.position = Vector2(-1000.0, -1000.0)
	main.call("_clamp_camera_position")
	var visible_half_size := viewport_size * 0.5
	if not _check(camera.position.is_equal_approx(visible_half_size), "Camera escaped the top-left map boundary"):
		return

	camera.position = Vector2(2048.0, 1024.0)
	var cursor := viewport_size * 0.5 + Vector2(100.0, 50.0)
	var world_before := camera.position + (cursor - viewport_size * 0.5) / camera.zoom.x
	main.call("_zoom_at_screen_position", 2.0, cursor)
	var world_after := camera.position + (cursor - viewport_size * 0.5) / camera.zoom.x
	if not _check(world_before.is_equal_approx(world_after), "Cursor-centered zoom did not preserve the target point"):
		return

	var wheel_event := InputEventMouseButton.new()
	wheel_event.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel_event.pressed = true
	wheel_event.position = viewport_size * 0.5
	var zoom_before_wheel := camera.zoom.x
	main.call("_unhandled_input", wheel_event)
	if not _check(camera.zoom.x > zoom_before_wheel, "Mouse wheel input did not zoom in"):
		return

	camera.zoom = Vector2.ONE * 2.0
	camera.position = Vector2(2048.0, 1024.0)
	var position_before_move := camera.position
	main.call("_move_camera", Vector2.RIGHT, 0.1)
	if not _check(camera.position.x > position_before_move.x, "WASD input did not move the camera"):
		return

	var first_province: Dictionary = database.get("provinces", [])[0]
	var label_pixel: Array = first_province.get("label_pixel", [])
	var label_world := Vector2(float(label_pixel[0]) + 0.5, float(label_pixel[1]) + 0.5)
	camera.zoom = Vector2.ONE * 4.0
	camera.position = label_world
	main.call("_clamp_camera_position")
	var label_screen := viewport_size * 0.5 + (label_world - camera.position) * camera.zoom.x
	main.call("_select_at_screen_position", label_screen)
	if not _check(main.selected_province_id == 1, "Province selection was not stored"):
		return
	var map_material := main.get_node("ProvinceMap").material as ShaderMaterial
	if not _check(bool(map_material.get_shader_parameter("has_selection")), "Province selection was not sent to the shader"):
		return
	var korea = game_state.get_country_by_code(&"KOR")
	var korean_province_id: int = korea.owned_province_ids[0]
	var displayed_korean_color: Color = main.call("_display_color_for_province", korean_province_id)
	if not _check(
		int(main.call("_display_controller_id", korean_province_id)) == korea.id
		and displayed_korean_color.is_equal_approx(korea.leader_color)
		and map_material.get_shader_parameter("political_palette") is Texture2D,
		"Political map did not display Korea's actual province control and country color"
	):
		return
	var north_korea = game_state.get_country_by_code(&"PRK")
	var war_result: Dictionary = game_state.declare_war(korea.id, north_korea.id)
	if not _check(war_result.ok, "Political-map front test could not declare war"):
		return
	var war: Dictionary = game_state.get_war(StringName(str(war_result.war_id)))
	var front_id := StringName(str(war.get("front_ids", [""])[0]))
	var front: Dictionary = game_state.get_front(front_id)
	var front_province_id := int(front.get("country_a_provinces", [0])[0])
	if not _check(
		front_province_id > 0
		and bool(main.call("_is_front_province", front_province_id))
		and map_material.get_shader_parameter("front_palette") is Texture2D,
		"Actual KOR-PRK border did not reach the visible front overlay"
	):
		return
	var captured_province_id := int(front.get("country_b_provinces", [0])[0])
	var captured_state: Dictionary = game_state.province_states[captured_province_id]
	captured_state.controller_country_id = korea.id
	game_state.province_states[captured_province_id] = captured_state
	game_state.province_control_changed.emit(captured_province_id, north_korea.id, korea.id)
	var captured_display_color: Color = main.call("_display_color_for_province", captured_province_id)
	if not _check(
		int(main.call("_display_controller_id", captured_province_id)) == korea.id
		and captured_display_color.is_equal_approx(korea.leader_color),
		"A province-control change did not recolor the political map"
	):
		return
	main.call("_set_selected_province", 0)
	if not _check(main.selected_province_id == 0, "Water selection did not clear the province"):
		return
	if not _check(not bool(map_material.get_shader_parameter("has_selection")), "Cleared selection remained active in the shader"):
		return

	print("OK: game data models, political ownership colors, visible fronts, camera, zoom, and selection verified")
	quit(0)


func _load_database() -> Dictionary:
	var file := FileAccess.open("res://data/province_map.json", FileAccess.READ)
	if file == null:
		_fail("Cannot open province database")
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("Cannot parse province database")
		return {}
	return parsed


func _check(condition: bool, message: String) -> bool:
	if condition:
		return true
	_fail(message)
	return false


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
