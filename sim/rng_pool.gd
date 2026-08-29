class_name RngPool extends RefCounted

## 시스템별 RNG 인스턴스 발급기.
## 전역 randi()/randf() 사용 금지 — 결정론이 깨지면 리플레이·밸런싱이 전부 무너진다.

var world_seed: int = 0

var _pool: Dictionary = {}


func _init(p_world_seed: int) -> void:
	world_seed = p_world_seed


## 같은 (world_seed, system) 조합은 항상 같은 시드를 준다.
func get_rng(system: String) -> RandomNumberGenerator:
	if _pool.has(system):
		return _pool[system]
	var rng := RandomNumberGenerator.new()
	rng.seed = derive_seed(world_seed, system)
	_pool[system] = rng
	return rng


## 같은 시스템을 특정 시점에서 재현 가능하게 다시 굴려야 할 때 사용.
func reset(system: String) -> void:
	_pool.erase(system)


## FNV-1a 64bit. 엔진 String.hash() 구현에 의존하지 않기 위해 직접 계산한다.
static func derive_seed(p_world_seed: int, system: String) -> int:
	var h := -3750763034362895579  # 0xcbf29ce484222325 (FNV offset basis, signed 64bit)
	for b in system.to_utf8_buffer():
		h = (h ^ b) * 0x100000001b3
	h = (h ^ p_world_seed) * 0x100000001b3
	return h
