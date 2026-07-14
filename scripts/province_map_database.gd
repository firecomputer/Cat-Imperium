extends Node

signal database_loaded
signal database_failed(message: String)

const DATABASE_PATH := "res://data/province_map.json"

var metadata: Dictionary = {}
var provinces: Array = []
var countries: Array = []
var is_loaded := false

var _province_image: Image
var _province_by_id: Dictionary = {}
var _province_id_by_rgb: Dictionary = {}


func _ready() -> void:
	reload_database()


func reload_database() -> Error:
	is_loaded = false
	_province_by_id.clear()
	_province_id_by_rgb.clear()

	var file := FileAccess.open(DATABASE_PATH, FileAccess.READ)
	if file == null:
		return _fail(FileAccess.get_open_error(), "Cannot open %s" % DATABASE_PATH)
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return _fail(ERR_PARSE_ERROR, "Province JSON root must be an object")

	metadata = parsed
	provinces = metadata.get("provinces", [])
	countries = metadata.get("countries", [])
	for province: Dictionary in provinces:
		var province_id := int(province.get("id", 0))
		var rgb: Array = province.get("color", [])
		if province_id <= 0 or rgb.size() != 3:
			return _fail(ERR_INVALID_DATA, "Invalid province record in JSON")
		_province_by_id[province_id] = province
		_province_id_by_rgb[_rgb_key(int(rgb[0]), int(rgb[1]), int(rgb[2]))] = province_id

	var map_info: Dictionary = metadata.get("map", {})
	var image_path := str(map_info.get("image", ""))
	var texture: Texture2D = load(image_path) as Texture2D
	if texture == null:
		return _fail(ERR_FILE_NOT_FOUND, "Cannot load province bitmap: %s" % image_path)
	_province_image = texture.get_image()
	if _province_image == null or _province_image.is_empty():
		return _fail(ERR_CANT_OPEN, "Province bitmap contains no image data")
	_province_image.convert(Image.FORMAT_RGB8)
	if (
		_province_image.get_width() != int(map_info.get("width", 0))
		or _province_image.get_height() != int(map_info.get("height", 0))
	):
		return _fail(ERR_INVALID_DATA, "Province bitmap dimensions do not match JSON")

	is_loaded = true
	database_loaded.emit()
	return OK


func get_province(province_id: int) -> Dictionary:
	return _province_by_id.get(province_id, {})


func get_country(country_id: int) -> Dictionary:
	if country_id <= 0 or country_id > countries.size():
		return {}
	return countries[country_id - 1]


func province_id_at_pixel(pixel: Vector2i) -> int:
	if not is_loaded:
		return 0
	var width := _province_image.get_width()
	var height := _province_image.get_height()
	var x := pixel.x
	if bool(metadata.get("map", {}).get("wrap_x", false)):
		x = posmod(x, width)
	if x < 0 or x >= width or pixel.y < 0 or pixel.y >= height:
		return 0
	var color := _province_image.get_pixel(x, pixel.y)
	return province_id_from_color(color)


func province_id_at_uv(uv: Vector2) -> int:
	if not is_loaded:
		return 0
	var pixel := Vector2i(
		floori(uv.x * _province_image.get_width()),
		floori(uv.y * _province_image.get_height())
	)
	return province_id_at_pixel(pixel)


func province_id_from_color(color: Color) -> int:
	var key := _rgb_key(
		clampi(roundi(color.r * 255.0), 0, 255),
		clampi(roundi(color.g * 255.0), 0, 255),
		clampi(roundi(color.b * 255.0), 0, 255)
	)
	return int(_province_id_by_rgb.get(key, 0))


func _rgb_key(red: int, green: int, blue: int) -> int:
	return (red << 16) | (green << 8) | blue


func _fail(error: Error, message: String) -> Error:
	push_error(message)
	database_failed.emit(message)
	return error
