extends SceneTree


func _initialize() -> void:
	var file := FileAccess.open("res://data/province_map.json", FileAccess.READ)
	if file == null:
		_fail("Cannot open province JSON")
		return
	var database: Variant = JSON.parse_string(file.get_as_text())
	if typeof(database) != TYPE_DICTIONARY:
		_fail("Cannot parse province JSON")
		return
	var map_info: Dictionary = database.get("map", {})
	var texture: Texture2D = load(str(map_info.get("image", ""))) as Texture2D
	if texture == null:
		_fail("Cannot load imported province bitmap")
		return
	var image := texture.get_image()
	image.convert(Image.FORMAT_RGB8)
	for province: Dictionary in database.get("provinces", []):
		var pixel: Array = province.get("label_pixel", [])
		var expected: Array = province.get("color", [])
		var expected_rgb := [int(expected[0]), int(expected[1]), int(expected[2])]
		var color := image.get_pixel(int(pixel[0]), int(pixel[1]))
		var actual := [
			clampi(roundi(color.r * 255.0), 0, 255),
			clampi(roundi(color.g * 255.0), 0, 255),
			clampi(roundi(color.b * 255.0), 0, 255),
		]
		if actual != expected_rgb:
			_fail(
				"Imported bitmap color mismatch at province %d: expected %s, got %s"
				% [int(province.get("id", 0)), expected_rgb, actual]
			)
			return
	print(
		"OK: Godot imported %dx%d bitmap and preserved all %d province colors"
		% [image.get_width(), image.get_height(), database.get("provinces", []).size()]
	)
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
