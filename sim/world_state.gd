class_name WorldState extends RefCounted

const EmpireSystem = preload("res://sim/systems/empire_system.gd")

## 전체 상태 컨테이너. Node 를 상속하지 않는다 — 헤드리스 배치·단위 테스트·직렬화를 위해.

var world_seed: int = 0
var turn: int = 0
var rng_pool: RngPool

var land: PackedByteArray
var elevation: PackedFloat32Array
var features: PackedInt32Array
var sea_basin: PackedInt32Array
## 해역 분할 (M9.2). 타일 → 해역 id, 육지는 -1.
var sea_zones: Array[SeaZone] = []
var tile_zone: PackedInt32Array

var provinces: Array[Province] = []
var nations: Array[Nation] = []
var characters: Array[Character] = []
var armies: Array[Army] = []
var fleets: Array[Fleet] = []
var wars: Array[War] = []

## M9 플레이어 투자 상태. 월드 상태와 함께 움직여 행동 로그 기반 재현이 가능하다.
var portfolio: PlayerPortfolio

var map_attempts: int = 0

## 해역 id → 그 바다에 해안을 가진 국가 id 집합. 매 턴 1회만 만든다.
var zone_coast_nations: Dictionary = {}
var zone_coast_turn: int = -1
## 프로빈스 id → 그 자리에 있는 살아있는 군대 id. 교전 판정이 전 군대를 훑지 않게 한다.
var armies_by_province: Dictionary = {}


## 해군 판단이 매 국가마다 전 프로빈스를 훑지 않도록 턴당 한 번 캐시한다.
func refresh_zone_coasts() -> void:
	if zone_coast_turn == turn:
		return
	zone_coast_turn = turn
	zone_coast_nations.clear()
	for p in provinces:
		var holder := p.controller()
		if holder < 0:
			continue
		for z: int in p.sea_zone_ids:
			if not zone_coast_nations.has(z):
				zone_coast_nations[z] = {}
			zone_coast_nations[z][holder] = true

## 뷰가 없는 단계라 EventBus(오토로드 Node) 대신 순수 배열에 쌓는다. M9 에서 flush 대상.
var events: Array[Dictionary] = []


## 지형 → 프로빈스 → 국가 → 초기값 순으로 세계를 만든다.
static func create(world_seed: int) -> WorldState:
	var w := WorldState.new()
	w.world_seed = world_seed
	w.rng_pool = RngPool.new(world_seed)
	w.portfolio = PlayerPortfolio.new()

	var map := MapGenerator.generate(world_seed)
	w.land = map["land"]
	w.elevation = map["elevation"]
	w.map_attempts = map["attempts"]

	var nbr := MapGenerator.neighbor_cache()
	var tagged := FeatureTagger.tag(w.land, nbr)
	w.features = tagged["features"]
	w.sea_basin = tagged["sea_basin"]

	# 프로빈스가 어느 해역에 접했는지를 알아야 하므로 바다부터 쪼갠다.
	var sea := SeaSplitter.split(w.land, w.sea_basin, w.features,
		w.rng_pool.get_rng("sea_split"))
	w.sea_zones = sea["zones"]
	w.tile_zone = sea["tile_zone"]
	tagged["sea_zone"] = w.tile_zone

	w.provinces = ProvinceSplitter.split(w.land, w.elevation, tagged,
		w.rng_pool.get_rng("province_split"))
	w.nations = NationPlacer.place(w.provinces, w.rng_pool.get_rng("nation_placer"))
	NationPlacer.assign_names(w.nations, w.rng_pool.get_rng("nation_names"))

	# 프로빈스는 건국 시 지배국의 문화를 갖는다. 정복해도 이 값은 남아
	# 문화 거리가 정복지 불만의 항구적 원천이 된다 (§10).
	for n in w.nations:
		for pid in n.provinces:
			w.provinces[pid].culture = n.culture

	for p in w.provinces:
		for z: int in p.sea_zone_ids:
			w.sea_zones[z].coast_provinces.append(p.id)

	LawSystem.adopt_initial(w)

	var seed_rng := w.rng_pool.get_rng("province_seed")
	for p in w.provinces:
		Economy.seed_province(p, seed_rng)

	Economy.aggregate(w)
	for n in w.nations:
		n.real_gdp = n.nominal_gdp
		n.prev_real_gdp = n.nominal_gdp
		n.money_supply = n.nominal_gdp
		n.prev_money_supply = n.money_supply
	CharacterSystem.initialize(w)
	AdvisorEffects.apply(w)
	EmpireSystem.initialize(w)
	Supply.recompute_if_dirty(w)
	return w


func rebuild_army_index() -> void:
	armies_by_province.clear()
	for army in armies:
		if not army.is_alive or army.province_id < 0:
			continue
		if not armies_by_province.has(army.province_id):
			armies_by_province[army.province_id] = ([] as Array[int])
		armies_by_province[army.province_id].append(army.id)


func armies_at(pid: int) -> Array:
	return armies_by_province.get(pid, [])


func move_army_index(army_id: int, from_pid: int, to_pid: int) -> void:
	remove_army_index(army_id, from_pid)
	add_army_index(army_id, to_pid)


## 승선한 군대는 어느 프로빈스에도 없다 — 교전·공성 판정이 자동으로 건너뛴다.
func remove_army_index(army_id: int, pid: int) -> void:
	if armies_by_province.has(pid):
		armies_by_province[pid].erase(army_id)


func add_army_index(army_id: int, pid: int) -> void:
	if pid < 0:
		return
	if not armies_by_province.has(pid):
		armies_by_province[pid] = ([] as Array[int])
	armies_by_province[pid].append(army_id)


func log_event(kind: String, data: Dictionary) -> void:
	data["turn"] = turn
	data["kind"] = kind
	events.append(data)


func world_population() -> float:
	var t := 0.0
	for p in provinces:
		t += p.population
	return t


func world_gdp() -> float:
	var t := 0.0
	for p in provinces:
		t += p.gdp
	return t
