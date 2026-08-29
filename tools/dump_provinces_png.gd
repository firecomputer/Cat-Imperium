extends SceneTree

## 프로빈스 분할 / 지형 특징을 눈으로 확인하는 PNG 덤프.
##
##   godot --headless --script res://tools/dump_provinces_png.gd -- --seed 1 --mode province
##
## 옵션: --seed N, --mode province|feature|terrain, --out PATH, --scale N

const TILE_PX_DEFAULT := 6

const FEATURE_COLORS := {
	FeatureTagger.Feature.INLAND: Color(0.30, 0.45, 0.28),
	FeatureTagger.Feature.COAST: Color(0.85, 0.80, 0.55),
	FeatureTagger.Feature.ISTHMUS: Color(0.90, 0.25, 0.20),
	FeatureTagger.Feature.STRAIT: Color(0.95, 0.85, 0.20),
	FeatureTagger.Feature.ISLAND: Color(0.35, 0.80, 0.55),
}

const TERRAIN_COLORS := {
	Province.Terrain.PLAIN: Color(0.42, 0.62, 0.32),
	Province.Terrain.HILL: Color(0.66, 0.58, 0.32),
	Province.Terrain.MOUNTAIN: Color(0.72, 0.72, 0.74),
}


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var seed_value := int(args.get("seed", 1))
	var mode: String = args.get("mode", "province")
	var scale_px := int(args.get("scale", TILE_PX_DEFAULT))
	var out_path: String = args.get("out", "res://out/%s_%d.png" % [mode, seed_value])

	var map: Dictionary = MapGenerator.generate(seed_value)
	var nbr := MapGenerator.neighbor_cache()
	var tagged := FeatureTagger.tag(map["land"], nbr)
	var rng := RngPool.new(map["seed"]).get_rng("province_split")
	var provinces := ProvinceSplitter.split(map["land"], map["elevation"], tagged, rng)

	var stats := ProvinceStats.summarize(provinces, map["land"], tagged)
	print("seed=%d (attempts=%d)" % [map["seed"], map["attempts"]])
	print("provinces=%d  min=%d  max=%d  mean=%.1f  orphans=%d  islands=%d" % [
		stats["count"], stats["min_size"], stats["max_size"], stats["mean_size"],
		stats["orphan_tiles"], stats["island_provinces"]])
	print("feature counts: %s" % [stats["feature_counts"]])

	var err := _render(map, tagged, provinces, mode, scale_px).save_png(out_path)
	if err != OK:
		push_error("PNG 저장 실패: %s (err %d)" % [out_path, err])
		quit(1)
		return
	print("wrote %s" % ProjectSettings.globalize_path(out_path))
	quit(0)


func _render(map: Dictionary, tagged: Dictionary, provinces: Array[Province],
		mode: String, s: int) -> Image:
	var land: PackedByteArray = map["land"]
	var features: PackedInt32Array = tagged["features"]

	var owner_of := PackedInt32Array()
	owner_of.resize(land.size())
	owner_of.fill(-1)
	for p in provinces:
		for t in p.tiles:
			owner_of[t] = p.id

	var img_w := int((MapGenerator.W + 1) * s)
	var img_h := int(MapGenerator.H * Hex.SQRT3_2 * s) + s
	var img := Image.create(img_w, img_h, false, Image.FORMAT_RGB8)
	img.fill(Color.BLACK)

	for row in range(MapGenerator.H):
		for col in range(MapGenerator.W):
			var idx := row * MapGenerator.W + col
			var c := _tile_color(idx, mode, land, features, owner_of, provinces)
			var x0 := int((col + (0.5 if row % 2 == 1 else 0.0)) * s)
			var y0 := int(row * Hex.SQRT3_2 * s)
			for dy in range(s):
				for dx in range(s):
					img.set_pixel(x0 + dx, y0 + dy, c)
	return img


func _tile_color(idx: int, mode: String, land: PackedByteArray, features: PackedInt32Array,
		owner_of: PackedInt32Array, provinces: Array[Province]) -> Color:
	if land[idx] == 0:
		if mode == "feature" and features[idx] == FeatureTagger.Feature.STRAIT:
			return FEATURE_COLORS[FeatureTagger.Feature.STRAIT]
		return Color(0.06, 0.13, 0.26)
	match mode:
		"feature":
			return FEATURE_COLORS[features[idx]]
		"terrain":
			return TERRAIN_COLORS[provinces[owner_of[idx]].terrain]
		_:
			return _province_color(owner_of[idx])


## 인접 프로빈스가 같은 색으로 붙어 보이지 않도록 id 를 흩뿌린다.
func _province_color(pid: int) -> Color:
	var h := fmod(pid * 0.6180339887, 1.0)
	var s := 0.45 + fmod(pid * 0.311, 0.35)
	var v := 0.55 + fmod(pid * 0.177, 0.40)
	return Color.from_hsv(h, s, v)


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
