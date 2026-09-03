class_name NoiseMapSource extends MapSource

## M1~M12 절차 생성기의 고정 어댑터. 회귀·재현성 기준선으로만 사용한다.

const W := MapGenerator.W
const H := MapGenerator.H
const TOTAL := MapGenerator.TOTAL
const LAND_TARGET := MapGenerator.LAND_TARGET


static func generate(world_seed: int) -> Dictionary:
	return _decorate(MapGenerator.generate(world_seed))


static func generate_once(world_seed: int) -> Dictionary:
	return _decorate(MapGenerator.generate_once(world_seed))


static func _decorate(result: Dictionary) -> Dictionary:
	result["source"] = "noise"
	result["source_kind"] = MapSource.Kind.NOISE
	result["width"] = W
	result["height"] = H
	result["granularity"] = 1.0
	var forced := PackedByteArray()
	forced.resize(TOTAL)
	forced.fill(MapSource.NO_FORCED_FEATURE)
	result["forced_features"] = forced
	result["regions"] = PackedByteArray()
	result["longitude"] = PackedFloat32Array()
	result["latitude"] = PackedFloat32Array()
	result["land_coverage"] = PackedByteArray()
	return result
