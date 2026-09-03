extends SceneTree

## M9.2 해역·승선·제해권 회귀 테스트.
##
##   godot4 --headless --path . --script res://tools/test_naval.gd


func _initialize() -> void:
	_test_sea_is_split_into_zones()
	_test_zone_tiles_are_connected()
	_test_coastal_provinces_know_their_zones()
	_test_zone_split_is_deterministic()
	_test_embark_takes_a_turn()
	_test_multi_zone_expedition_reaches_island()
	_test_broken_expedition_route_sinks_the_convoy()
	_test_losing_control_sinks_the_convoy()
	_test_no_control_means_no_crossing()
	_test_expedition_supply_costs_more_than_the_near_sea()
	print("naval tests: PASS")
	quit(0)


# ---------------------------------------------------------------- 해역 생성

func _test_sea_is_split_into_zones() -> void:
	var world := WorldState.create(1, MapSource.Kind.NOISE)
	assert(world.sea_zones.size() >= 80 and world.sea_zones.size() <= 160,
		"바다는 100여 개 해역으로 쪼개진다 (실측 %d)" % world.sea_zones.size())
	var biggest := 0
	for z in world.sea_zones:
		biggest = maxi(biggest, z.tiles.size())
	assert(biggest <= int(SeaSplitter.TARGET_MAX * 1.5),
		"고아 흡수가 한 해역만 부풀리지 않는다 (최대 %d)" % biggest)
	for tile in range(world.land.size()):
		if world.land[tile] == 0:
			assert(world.tile_zone[tile] >= 0, "모든 바다 타일은 해역을 갖는다")
		else:
			assert(world.tile_zone[tile] == -1, "육지는 해역이 아니다")


func _test_zone_tiles_are_connected() -> void:
	var world := WorldState.create(2, MapSource.Kind.NOISE)
	var nbr := MapSource.neighbor_cache(world.map_width, world.map_height)
	for z in world.sea_zones:
		var members := {}
		for t: int in z.tiles:
			members[t] = true
		var seen := {z.tiles[0]: true}
		var stack: Array[int] = [z.tiles[0]]
		while not stack.is_empty():
			var cur: int = stack.pop_back()
			for n: int in nbr[cur]:
				if members.has(n) and not seen.has(n):
					seen[n] = true
					stack.append(n)
		assert(seen.size() == z.tiles.size(),
			"해역 %d 의 타일은 한 덩어리다" % z.id)


func _test_coastal_provinces_know_their_zones() -> void:
	var world := WorldState.create(3, MapSource.Kind.NOISE)
	for p in world.provinces:
		if not p.is_coastal:
			continue
		assert(not p.sea_zone_ids.is_empty(), "연안 프로빈스는 해역에 접한다")
		for zone_id: int in p.sea_zone_ids:
			assert(p.id in world.sea_zones[zone_id].coast_provinces,
				"해역도 자기 연안 프로빈스를 안다")


func _test_zone_split_is_deterministic() -> void:
	var a := WorldState.create(7, MapSource.Kind.NOISE)
	var b := WorldState.create(7, MapSource.Kind.NOISE)
	assert(a.tile_zone == b.tile_zone, "같은 시드는 같은 해역을 만든다")


# ---------------------------------------------------------------- 승선·상륙

func _test_embark_takes_a_turn() -> void:
	var world := _strait_world()
	var n: Nation = world.nations[0]
	n.naval_control_zones[0] = true
	var army: Army = world.armies[0]

	WarAI.plan(world)
	assert(army.at_sea_zone == 0 and army.province_id == -1,
		"제해권이 있으면 바다로 나선다")
	assert(army.landing_target == 2, "목적지는 승선할 때 정해진다")
	assert(not world.armies_at(0).has(army.id), "승선한 부대는 프로빈스 색인에 없다")

	var morale_before := army.morale
	WarAI.plan(world)
	assert(army.at_sea_zone == -1 and army.province_id == 2, "다음 턴에 상륙한다")
	assert(army.morale < morale_before, "상륙은 사기를 깎는다")
	assert(world.armies_at(2).has(army.id), "상륙한 부대는 색인에 돌아온다")


func _test_multi_zone_expedition_reaches_island() -> void:
	var world := _expedition_world()
	var n: Nation = world.nations[0]
	n.naval_control_zones[0] = true
	n.naval_control_zones[1] = true
	var army: Army = world.armies[0]
	assert(1 in WarAI._fronts(world, n), "다중 해역 너머 적 섬도 전선으로 잡는다")
	assert(is_equal_approx(WarAI._hops(world, n, 0, 1), 3.0),
		"승선·해역 이동·상륙은 각각 한 홉이다")

	WarAI.plan(world)
	assert(army.at_sea_zone == 0 and army.province_id == -1,
		"이어진 제해권이 있으면 첫 해역으로 승선한다")
	assert(army.landing_target == 1, "승선할 때 원정 목적지를 고정한다")

	WarAI.plan(world)
	assert(army.at_sea_zone == 1 and army.province_id == -1,
		"원정군은 한 턴에 통제 해역 하나를 전진한다")
	WarAI.plan(world)
	assert(army.at_sea_zone == -1 and army.province_id == 1,
		"마지막 통제 해역에서 적 섬에 상륙한다")


func _test_broken_expedition_route_sinks_the_convoy() -> void:
	var world := _expedition_world()
	var n: Nation = world.nations[0]
	n.naval_control_zones[0] = true
	n.naval_control_zones[1] = true
	var army: Army = world.armies[0]
	WarAI.plan(world)
	assert(army.at_sea_zone == 0, "먼저 원정 항로에 승선한다")

	n.naval_control_zones.erase(1)
	WarAI.plan(world)
	assert(not army.is_alive and army.troops == 0,
		"상륙 전에 통제 해역 사슬이 끊기면 수송선단이 격침된다")


func _test_losing_control_sinks_the_convoy() -> void:
	var world := _strait_world()
	var n: Nation = world.nations[0]
	n.naval_control_zones[0] = true
	var army: Army = world.armies[0]
	WarAI.plan(world)
	assert(army.at_sea_zone == 0, "먼저 승선한다")

	n.naval_control_zones.clear()             # 바다를 뺏겼다
	WarAI.plan(world)
	assert(not army.is_alive and army.troops == 0,
		"제해권을 잃은 수송선단은 전멸한다 (§12.4)")
	var sunk := false
	for e in world.events:
		if e["kind"] == "convoy_sunk":
			sunk = true
	assert(sunk, "격침은 기록에 남는다")


func _test_no_control_means_no_crossing() -> void:
	var world := _strait_world()
	var army: Army = world.armies[0]
	WarAI.plan(world)
	assert(army.at_sea_zone == -1 and army.province_id == 0,
		"제해권이 없으면 배를 타지 않는다")


# ---------------------------------------------------------------- 해상 보급

func _test_expedition_supply_costs_more_than_the_near_sea() -> void:
	var world := _chain_world()
	var n: Nation = world.nations[0]
	n.naval_control_zones[0] = true
	n.naval_control_zones[1] = true
	var field := Supply.compute_supply_field(world, n)
	assert(field[1] > field[2], "해역 두 칸 건너 원정은 근해보다 보급이 나쁘다")
	assert(field[2] > Supply.MIN_SUPPLY, "이어진 제해권은 원정 보급을 성립시킨다")


# ---------------------------------------------------------------- 픽스처

## 본토(0·1)와 해협 건너 내 섬(2). 섬은 적에게 점령당해 되찾아야 할 전선이다.
## 육로가 없으므로 상륙 말고는 갈 길이 없다.
func _strait_world() -> WorldState:
	var world := WorldState.new()
	world.rng_pool = RngPool.new(111)
	var mine := Nation.new()
	mine.id = 0
	mine.capital = 0
	var foe := Nation.new()
	foe.id = 1
	foe.capital = 3
	world.nations.append(mine)
	world.nations.append(foe)

	for i in range(4):
		var p := Province.new()
		p.id = i
		p.infra = 3.0
		p.population = 1000.0
		world.provinces.append(p)
	for pid in [0, 1, 2]:
		world.provinces[pid].owner_nation = 0
		world.provinces[pid].sea_zone_ids = PackedInt32Array([0])
		mine.provinces.append(pid)
	world.provinces[0].land_neighbors = [1]
	world.provinces[1].land_neighbors = [0]
	world.provinces[2].is_island = true
	world.provinces[2].occupied_by_nation = 1     # 되찾아야 할 땅 = 전선
	world.provinces[3].owner_nation = 1
	foe.provinces.append(3)

	var zone := SeaZone.new()
	zone.id = 0
	zone.coast_provinces = PackedInt32Array([0, 1, 2])
	world.sea_zones.append(zone)

	Diplomacy.declare_war(world, mine, foe, "test")
	Military.create_army(world, mine, 0, 500)
	world.rebuild_army_index()
	return world


## 본토(0) — 해역 0 — 해역 1 — 적 섬(1). 양쪽 프로빈스가 같은 해역을 공유하지 않는다.
func _expedition_world() -> WorldState:
	var world := WorldState.new()
	world.rng_pool = RngPool.new(113)
	for i in range(2):
		var n := Nation.new()
		n.id = i
		n.capital = i
		world.nations.append(n)
		var p := Province.new()
		p.id = i
		p.owner_nation = i
		p.population = 1000.0
		p.infra = 3.0
		p.is_island = i == 1
		p.sea_zone_ids = PackedInt32Array([i])
		world.provinces.append(p)
		n.provinces.append(i)

	for i in range(2):
		var zone := SeaZone.new()
		zone.id = i
		zone.neighbors = PackedInt32Array([1 - i])
		zone.coast_provinces = PackedInt32Array([i])
		world.sea_zones.append(zone)

	Diplomacy.declare_war(world, world.nations[0], world.nations[1], "test")
	Military.create_army(world, world.nations[0], 0, 500)
	world.rebuild_army_index()
	return world


## 본토(0) — 해역 0 — 섬(1) — 해역 1 — 먼 섬(2).
func _chain_world() -> WorldState:
	var world := WorldState.new()
	world.rng_pool = RngPool.new(112)
	var n := Nation.new()
	n.id = 0
	n.capital = 0
	world.nations.append(n)
	for i in range(3):
		var p := Province.new()
		p.id = i
		p.owner_nation = 0
		p.infra = 3.0
		world.provinces.append(p)
		n.provinces.append(i)
	world.provinces[0].sea_zone_ids = PackedInt32Array([0])
	world.provinces[1].sea_zone_ids = PackedInt32Array([0, 1])
	world.provinces[2].sea_zone_ids = PackedInt32Array([1])

	for i in range(2):
		var zone := SeaZone.new()
		zone.id = i
		world.sea_zones.append(zone)
	world.sea_zones[0].coast_provinces = PackedInt32Array([0, 1])
	world.sea_zones[0].neighbors = PackedInt32Array([1])
	world.sea_zones[1].coast_provinces = PackedInt32Array([1, 2])
	world.sea_zones[1].neighbors = PackedInt32Array([0])
	return world
