extends SceneTree

## 지형을 눈으로 확인하기 위한 PNG 덤프. 렌더러보다 먼저 만든다.
##
##   godot --headless --script res://tools/dump_map_png.gd -- --seed 1234 --out res://out/map.png
##
## 옵션: --seed N, --out PATH, --scale N, --once (검증 재시도 없이 1회만 생성)

const TILE_PX_DEFAULT := 6


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var seed_value := int(args.get("seed", 1))
	var out_path: String = args.get("out", "res://out/map_%d.png" % seed_value)
	var scale_px := int(args.get("scale", TILE_PX_DEFAULT))
	var once: bool = args.has("once")

	var result: Dictionary = MapGenerator.generate_once(seed_value) if once else MapGenerator.generate(seed_value)
	var stats: Dictionary = result["stats"]

	print("seed=%d  attempts=%d  valid=%s" % [result["seed"], result["attempts"], result["valid"]])
	print("land=%d  components=%d  largest=%d (%.1f%%)  second=%d" % [
		stats["land_count"], stats["component_count"], stats["largest"],
		stats["largest_frac"] * 100.0, stats["second"]])
	print("checks=%s" % [result["checks"]])

	var err := _render(result, scale_px).save_png(out_path)
	if err != OK:
		push_error("PNG 저장 실패: %s (err %d)" % [out_path, err])
		quit(1)
		return
	print("wrote %s" % ProjectSettings.globalize_path(out_path))
	quit(0)


func _render(result: Dictionary, s: int) -> Image:
	var land: PackedByteArray = result["land"]
	var elevation: PackedFloat32Array = result["elevation"]

	var img_w := int((MapGenerator.W + 1) * s)
	var img_h := int(MapGenerator.H * Hex.SQRT3_2 * s) + s
	var img := Image.create(img_w, img_h, false, Image.FORMAT_RGB8)
	img.fill(Color.BLACK)

	var lo := INF
	var hi := -INF
	for e in elevation:
		lo = minf(lo, e)
		hi = maxf(hi, e)
	var span := maxf(hi - lo, 0.0001)

	for row in range(MapGenerator.H):
		for col in range(MapGenerator.W):
			var idx := row * MapGenerator.W + col
			var t := (elevation[idx] - lo) / span
			var c := _land_color(t) if land[idx] == 1 else _sea_color(t)
			var x0 := int((col + (0.5 if row % 2 == 1 else 0.0)) * s)
			var y0 := int(row * Hex.SQRT3_2 * s)
			for dy in range(s):
				for dx in range(s):
					img.set_pixel(x0 + dx, y0 + dy, c)
	return img


func _land_color(t: float) -> Color:
	return Color(0.22, 0.42, 0.20).lerp(Color(0.80, 0.74, 0.58), clampf((t - 0.5) * 2.0, 0.0, 1.0))


func _sea_color(t: float) -> Color:
	return Color(0.02, 0.06, 0.18).lerp(Color(0.16, 0.38, 0.62), clampf(t * 2.0, 0.0, 1.0))


func _parse_args(argv: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < argv.size():
		var a := argv[i]
		if a.begins_with("--"):
			var key := a.substr(2)
			if i + 1 < argv.size() and not argv[i + 1].begins_with("--"):
				out[key] = argv[i + 1]
				i += 1
			else:
				out[key] = true
		i += 1
	return out
