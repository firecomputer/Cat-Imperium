class_name Province extends RefCounted

## 모든 시스템의 작동 단위. 타일이 아니라 프로빈스로 계산한다 (15000 → ~294, 50배 절약).

var id: int = -1
var tiles: PackedInt32Array = PackedInt32Array()
var owner_nation: int = -1
var occupied_by_nation: int = -1       # M8 점령 전에는 -1

# 핵심 3수치
var infra: float = 0.0           # 0~10
## 지리가 정하는 인프라 상한. 전역 상수 하나였을 때는 모든 프로빈스가 결국 같은
## 앵커로 수렴해 시간이 편차를 지웠다 (PHASE2 §6.6 · §M13.9). 하드캡은 아니다 —
## 넘겨 짓는 비용이 지수로 오를 뿐이라 역전 경로는 남는다 (Economy.infra_build_cost).
var infra_cap: float = 10.0
var population: float = 0.0
var gdp: float = 0.0
var gdp_pc: float = 0.0
## 직전 생산 틱이 수렴 목표로 삼은 앵커. Economy 가 쓰고 계측이 읽는다 — 파이프라인
## 5단계의 앵커를 턴이 끝난 뒤 재계산하면 11단계의 불만 증가가 섞여 들어와,
## 정상적인 수렴이 앵커 초과로 잡힌다 (M11 §M3).
var anchor_gdp_pc: float = 0.0

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
## 0~1. integration 이 행정적 편입이라면 이쪽은 폭력으로 눌린 기억이다. 자국 땅에서
## 벌어진 교전과 반란 진압이 쌓고, 불만 상승률을 키우며 통합을 정체시킨다.
## 진압이 다음 진압을 비싸게 만드는 유일한 경로다 (M14 §1).
var separatism: float = 0.0
## 이번 턴에 진압이 있었는가. Military 가 세우고 Unrest.tick_province 가 읽고 내린다 —
## 진압한 턴에도 감쇠가 함께 돌면 작은 교전은 순증이 0 이 된다.
var suppressed_this_turn: bool = false
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
## M13 고정 지리 좌표. 노이즈 회귀 지도에서는 region=-1, 좌표는 0이다.
var region: int = -1
var longitude: float = 0.0
var latitude: float = 0.0
var distance_from_capital: float = 0.0

## 고도 순위로 분류한다 (지형 생성의 순위 선택과 같은 철학 — 노이즈 파라미터에 흔들리지 않는다).
enum Terrain { PLAIN, HILL, MOUNTAIN }

const TERRAIN_MULTS := {
	Terrain.PLAIN: {"prod": 1.0, "supply": 1.0, "cost": 1.0, "cap": 2.6},
	Terrain.HILL: {"prod": 0.9, "supply": 1.25, "cost": 1.15, "cap": 0.4},
	Terrain.MOUNTAIN: {"prod": 0.7, "supply": 1.8, "cost": 1.5, "cap": -1.0},
}

## infra_cap 의 재료. 전부 프로빈스마다 다른 값이고 그 값을 지리가 준다 (§5.1).
const INFRA_CAP_BASE := 3.0
const INFRA_CAP_COAST := 2.2
const INFRA_CAP_JITTER := 0.9
const INFRA_CAP_MIN := 2.0
const INFRA_CAP_MAX := 10.0


func set_terrain(t: int) -> void:
	terrain = t
	var m: Dictionary = TERRAIN_MULTS[t]
	terrain_mult = m["prod"]
	terrain_supply_mult = m["supply"]
	terrain_cost_mult = m["cost"]


## 지형·해안이 상한의 뼈대를 주고 jitter 가 같은 등급 안의 동률을 깬다 —
## 동률이 남으면 평지·해안만 있는 나라는 다시 평평해진다.
func assign_infra_cap(jitter: float) -> void:
	var cap: float = INFRA_CAP_BASE + float(TERRAIN_MULTS[terrain]["cap"]) + jitter
	if is_coastal:
		cap += INFRA_CAP_COAST
	infra_cap = clampf(cap, INFRA_CAP_MIN, INFRA_CAP_MAX)


func size() -> int:
	return tiles.size()


## 문화 거리. 정복지가 불만을 품는 이유이자 동화의 어려움이다 (§10).
func culture_distance(other: int) -> float:
	return Culture.distance(culture, other)


func controller() -> int:
	return occupied_by_nation if occupied_by_nation >= 0 else owner_nation


## 점령 정책이 실제로 물리는 몫. 수취(Economy)와 불만(Unrest)이 같은 밑변에서
## 나오게 하는 한 곳이다 — 약탈로 돈이 나오는 땅이 정확히 반란이 나는 땅이다.
## 통합이 끝나면 둘 다 함께 0 이 된다. 그래서 온건 통치는 "언젠가 점령 비용이
## 사라지는" 경로이고 약탈은 그 경로를 스스로 막는 선택이 된다.
func occupation_base(owner_culture: int) -> float:
	if culture_distance(owner_culture) <= 0.0 and occupied_by_nation < 0:
		return 0.0
	return maxf(1.0 - integration, 0.0)
