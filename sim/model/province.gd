class_name Province extends RefCounted

## 모든 시스템의 작동 단위. 타일이 아니라 프로빈스로 계산한다 (15000 → ~294, 50배 절약).

var id: int = -1
var tiles: PackedInt32Array = PackedInt32Array()
var owner_nation: int = -1
var occupied_by_nation: int = -1       # M8 점령 전에는 -1

# 핵심 3수치
var infra: float = 0.0           # 0~10
var population: float = 0.0
var gdp: float = 0.0
var gdp_pc: float = 0.0

# 파생 상태
var unrest: float = 0.0          # 0~1
var supply: float = 1.0          # 0~1
var has_city: bool = false
var is_exclave: bool = false
var is_island: bool = false
var culture: int = -1
var admin_cost_mult: float = 1.0
## 제국 통합도. 건국 영토는 완전 통합, 새 할양지는 0 에서 행정·문화적으로 편입된다.
var integration: float = 1.0
## 완전 통합 상태를 유지한 누적치. 1.0 에서 문화가 소유국 문화로 바뀐다 (§6.3).
var assimilation: float = 0.0
var pending_migration: float = 0.0
var pop_density_ratio: float = 1.0
var is_being_pillaged: bool = false

# M8 전쟁. 점령은 즉시가 아니라 공성 진행도가 100 을 넘어야 성립한다.
var siege_progress: float = 0.0
var siege_by_nation: int = -1
var garrison_ratio: float = 0.0        # 주둔 병력 / 필요 치안 병력, unrest.gd 가 매 턴 갱신
## M8.5 재통합 직후 유예. 0 보다 크면 새 반란이 터지지 않는다 — 불만 누적 자체는 계속된다.
var rebellion_grace_turns: int = 0

# 생성 시 1회 캐시 (불변)
var land_neighbors: Array = []               # 인접 프로빈스 id
var sea_zone_ids: PackedInt32Array = PackedInt32Array()
var terrain: int = Terrain.PLAIN
var terrain_mult: float = 1.0                # 생산성 배율
var terrain_supply_mult: float = 1.0         # 보급 비용 배율
var terrain_cost_mult: float = 1.0           # 건설비 배율
var is_coastal: bool = false
var has_river: bool = false
var centroid: Vector2 = Vector2.ZERO
var distance_from_capital: float = 0.0

## 고도 순위로 분류한다 (지형 생성의 순위 선택과 같은 철학 — 노이즈 파라미터에 흔들리지 않는다).
enum Terrain { PLAIN, HILL, MOUNTAIN }

const TERRAIN_MULTS := {
	Terrain.PLAIN: {"prod": 1.0, "supply": 1.0, "cost": 1.0},
	Terrain.HILL: {"prod": 0.9, "supply": 1.25, "cost": 1.15},
	Terrain.MOUNTAIN: {"prod": 0.7, "supply": 1.8, "cost": 1.5},
}


func set_terrain(t: int) -> void:
	terrain = t
	var m: Dictionary = TERRAIN_MULTS[t]
	terrain_mult = m["prod"]
	terrain_supply_mult = m["supply"]
	terrain_cost_mult = m["cost"]


func size() -> int:
	return tiles.size()


## 문화 거리. 정복지가 불만을 품는 이유이자 동화의 어려움이다 (§10).
func culture_distance(other: int) -> float:
	return Culture.distance(culture, other)


func controller() -> int:
	return occupied_by_nation if occupied_by_nation >= 0 else owner_nation
