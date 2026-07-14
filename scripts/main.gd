extends Node2D

signal province_selected(province_id: int)
signal province_selection_cleared

const MOVE_SPEED_SCREEN_PIXELS := 800.0
const ZOOM_STEP := 1.2
const MAX_ZOOM := 4.0

@onready var map_sprite: Sprite2D = %ProvinceMap
@onready var camera: Camera2D = %MapCamera

var selected_province_id := 0
var _map_size := Vector2.ZERO
var _minimum_zoom := 1.0
var _map_material: ShaderMaterial


func _ready() -> void:
	_map_size = map_sprite.texture.get_size()
	map_sprite.position = _map_size * 0.5
	_map_material = map_sprite.material as ShaderMaterial
	get_viewport().size_changed.connect(_on_viewport_size_changed)
	_update_camera_for_viewport(true)


func _process(delta: float) -> void:
	var direction := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W))
	)
	_move_camera(direction, delta)


func _move_camera(direction: Vector2, delta: float) -> void:
	if direction.length_squared() > 1.0:
		direction = direction.normalized()
	if direction.is_zero_approx():
		return
	camera.position += direction * MOVE_SPEED_SCREEN_PIXELS * delta / camera.zoom.x
	_clamp_camera_position()


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or not event.pressed:
		return
	var mouse_event := event as InputEventMouseButton
	match mouse_event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			_zoom_at_screen_position(camera.zoom.x * ZOOM_STEP, mouse_event.position)
		MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at_screen_position(camera.zoom.x / ZOOM_STEP, mouse_event.position)
		MOUSE_BUTTON_LEFT:
			_select_at_screen_position(mouse_event.position)
		_:
			return
	get_viewport().set_input_as_handled()


func _on_viewport_size_changed() -> void:
	_update_camera_for_viewport(false)


func _update_camera_for_viewport(reset_view: bool) -> void:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0 or _map_size.is_zero_approx():
		return
	_minimum_zoom = maxf(viewport_size.x / _map_size.x, viewport_size.y / _map_size.y)
	if reset_view:
		camera.zoom = Vector2.ONE * _minimum_zoom
		camera.position = _map_size * 0.5
	else:
		var adjusted_zoom := clampf(camera.zoom.x, _minimum_zoom, maxf(MAX_ZOOM, _minimum_zoom))
		camera.zoom = Vector2.ONE * adjusted_zoom
	_clamp_camera_position()


func _zoom_at_screen_position(requested_zoom: float, screen_position: Vector2) -> void:
	var old_zoom := camera.zoom.x
	var new_zoom := clampf(requested_zoom, _minimum_zoom, maxf(MAX_ZOOM, _minimum_zoom))
	if is_equal_approx(old_zoom, new_zoom):
		return
	var screen_offset := screen_position - get_viewport_rect().size * 0.5
	var world_under_cursor := camera.position + screen_offset / old_zoom
	camera.zoom = Vector2.ONE * new_zoom
	camera.position = world_under_cursor - screen_offset / new_zoom
	_clamp_camera_position()


func _clamp_camera_position() -> void:
	var visible_half_size := get_viewport_rect().size * 0.5 / camera.zoom.x
	camera.position = Vector2(
		_clamp_axis(camera.position.x, visible_half_size.x, _map_size.x),
		_clamp_axis(camera.position.y, visible_half_size.y, _map_size.y)
	)


func _clamp_axis(value: float, visible_half_size: float, map_extent: float) -> float:
	if visible_half_size * 2.0 >= map_extent:
		return map_extent * 0.5
	return clampf(value, visible_half_size, map_extent - visible_half_size)


func _select_at_screen_position(screen_position: Vector2) -> void:
	var world_position := (
		camera.position
		+ (screen_position - get_viewport_rect().size * 0.5) / camera.zoom.x
	)
	var map_local_position := map_sprite.to_local(world_position) + _map_size * 0.5
	var pixel := Vector2i(floori(map_local_position.x), floori(map_local_position.y))
	_set_selected_province(ProvinceMapDB.province_id_at_pixel(pixel))


func _set_selected_province(province_id: int) -> void:
	if province_id <= 0:
		if selected_province_id == 0:
			return
		selected_province_id = 0
		_map_material.set_shader_parameter("has_selection", false)
		province_selection_cleared.emit()
		return
	var province := ProvinceMapDB.get_province(province_id)
	var rgb: Array = province.get("color", [])
	if rgb.size() != 3:
		return
	selected_province_id = province_id
	_map_material.set_shader_parameter(
		"selected_source_color",
		Color8(int(rgb[0]), int(rgb[1]), int(rgb[2]))
	)
	_map_material.set_shader_parameter("has_selection", true)
	province_selected.emit(province_id)
