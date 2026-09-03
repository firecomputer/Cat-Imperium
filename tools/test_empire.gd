extends SceneTree

## 대제국 형성·속국·행정 수명 주기 회귀 테스트.
##   godot4 --headless --path . --script res://tools/test_empire.gd

const EmpireSystem = preload("res://sim/systems/empire_system.gd")


func _initialize() -> void:
	_test_subjugation_waits_for_its_goal()
	_test_vassal_tribute_and_relationship_invariants()
	_test_vassals_join_by_loyalty()
	_test_annexation_starts_integration_with_grace()
	_test_overextension_targets_the_periphery()
	_test_low_loyalty_starts_independence_war()
	_test_defeated_independence_restores_vassalage()
	_test_overlord_death_releases_vassals()
	_test_subjugating_an_overlord_transfers_its_realm()
	_test_realm_share_includes_vassals()
	_test_settled_province_assimilates()
	_test_title_follows_realm_size()
	_test_title_demotion_needs_a_real_fall()
	_test_vassal_title_stays_under_its_overlord()
	print("empire tests: PASS")
	quit(0)


func _test_subjugation_waits_for_its_goal() -> void:
	var world := _two_nations()
	var war := Diplomacy.declare_war(world, world.nations[0], world.nations[1],
		"test", War.Goal.SUBJUGATION)
	war.start_turn = -Peace.MIN_WAR_TURNS
	world.provinces[1].occupied_by_nation = 0   # 종전 자격 (SETTLE_CONSUMED_RATIO)
	war.warscore = Peace.SUBJUGATION_SCORE - 1.0
	Peace._consider_peace(world, war)
	assert(war.is_active and world.nations[1].overlord < 0,
		"속국화 전쟁은 자기 목표 점수 전에는 종전하지 않는다")
	war.warscore = Peace.SUBJUGATION_SCORE
	Peace._consider_peace(world, war)
	assert(not war.is_active and world.nations[1].overlord == 0,
		"속국화 목표 점수에 도달하면 실제 종속 관계가 생긴다")


func _test_vassal_tribute_and_relationship_invariants() -> void:
	var world := _two_nations()
	var overlord: Nation = world.nations[0]
	var vassal: Nation = world.nations[1]
	overlord.allies = [vassal.id]
	vassal.allies = [overlord.id]
	assert(EmpireSystem.vassalize(world, overlord, vassal), "독립 소국은 속국화할 수 있다")
	assert(vassal.overlord == overlord.id and overlord.vassals == [vassal.id],
		"속국 관계는 양쪽에 한 번만 기록된다")
	assert(vassal.allies.is_empty() and not overlord.allies.has(vassal.id),
		"속국의 기존 독립 동맹은 해소된다")
	overlord.income = 100.0
	vassal.income = 50.0
	# 공납은 충성도에 비례한다 — 실효 공납 = 소득 × TRIBUTE_SHARE × (0.4 ~ 1.0).
	# 충성도를 안 물리면 억지로 붙인 속국이 자발적 속국과 똑같이 낸다.
	var expected := 50.0 * EmpireSystem.TRIBUTE_SHARE \
		* (0.4 + vassal.vassal_loyalty * EmpireSystem.TRIBUTE_LOYALTY_SPAN)
	EmpireSystem.collect_tribute(world)
	assert(expected > 0.0, "공납이 0 이면 이 검사는 아무것도 보지 않는다")
	assert(is_equal_approx(vassal.income, 50.0 - expected)
		and is_equal_approx(overlord.income, 100.0 + expected),
		"속국 세수의 일부가 충성도에 비례해 종주국으로 이전된다")


func _test_vassals_join_by_loyalty() -> void:
	var world := _three_nations()
	var overlord: Nation = world.nations[0]
	var vassal: Nation = world.nations[1]
	var enemy: Nation = world.nations[2]
	EmpireSystem.vassalize(world, overlord, vassal)
	var defensive := Diplomacy.declare_war(world, enemy, overlord, "test")
	EmpireSystem.call_vassals_to_war(world, defensive, overlord, -1, false)
	assert(defensive.side_of(vassal.id) == -1, "속국은 충성도와 무관하게 방어전에 참전한다")
	Diplomacy.end_war(world, defensive, "test")

	var offensive := Diplomacy.declare_war(world, overlord, enemy, "test")
	vassal.vassal_loyalty = EmpireSystem.OFFENSIVE_JOIN_LOYALTY - 0.01
	EmpireSystem.call_vassals_to_war(world, offensive, overlord, 1, true)
	assert(offensive.side_of(vassal.id) == 0, "저충성 속국은 공격전 참전을 거부한다")
	vassal.vassal_loyalty = EmpireSystem.OFFENSIVE_JOIN_LOYALTY
	EmpireSystem.call_vassals_to_war(world, offensive, overlord, 1, true)
	assert(offensive.side_of(vassal.id) == 1, "충성도 60% 이상 속국은 공격전에 참전한다")


func _test_annexation_starts_integration_with_grace() -> void:
	var world := _three_nations()
	var winner: Nation = world.nations[0]
	var loser: Nation = world.nations[1]
	var p: Province = world.provinces[1]
	var before := p.unrest
	Peace.annex(world, p, loser, winner, [] as Array[int])
	assert(is_equal_approx(p.integration, 0.0), "새 할양지는 미통합 상태에서 시작한다")
	assert(p.rebellion_grace_turns == Peace.CEDED_GRACE_TURNS,
		"새 할양지는 안정화 유예를 받는다")
	assert(is_equal_approx(p.unrest - before, Peace.CEDED_UNREST),
		"즉시 불만은 완화된 할양 충격만 적용된다")
	p.supply = 1.0
	p.unrest = 0.0
	EmpireSystem.tick(world)
	assert(p.integration > 0.0, "보급되고 안정된 할양지는 매 턴 통합된다")


func _test_overextension_targets_the_periphery() -> void:
	var world := _two_nations()
	var n: Nation = world.nations[0]
	var core: Province = world.provinces[0]
	var frontier := Province.new()
	frontier.integration = 0.0
	frontier.is_exclave = true
	n.overextension = 1.0
	assert(EmpireSystem.unrest_pressure(frontier, n) > EmpireSystem.unrest_pressure(core, n),
		"행정 초과 불만은 완전 통합 핵심지보다 미통합 월경지에 집중된다")


func _test_low_loyalty_starts_independence_war() -> void:
	var world := _two_nations()
	var overlord: Nation = world.nations[0]
	var vassal: Nation = world.nations[1]
	EmpireSystem.vassalize(world, overlord, vassal)
	overlord.imperial_authority = 0.0
	vassal.vassal_loyalty = 0.0
	EmpireSystem.tick(world)
	assert(vassal.overlord == -1, "충성도가 무너지면 먼저 종속 관계에서 이탈한다")
	var war := Diplomacy.war_between(world, vassal.id, overlord.id)
	assert(war != null and war.goal == War.Goal.INDEPENDENCE,
		"이탈은 즉시 독립전쟁으로 이어진다")


func _test_defeated_independence_restores_vassalage() -> void:
	var world := _two_nations()
	var former_vassal: Nation = world.nations[1]
	var overlord: Nation = world.nations[0]
	var war := Diplomacy.declare_war(world, former_vassal, overlord,
		"independence", War.Goal.INDEPENDENCE)
	war.start_turn = -Peace.MIN_WAR_TURNS
	# 패자의 35점 항복 의사만으로 승자의 독립전쟁 진압을 끊지 않는다.
	# 방어측 승리도 일반 정복과 같은 결정적 우세에서 끝난다.
	war.warscore = -Peace.CONQUEST_SETTLE_SCORE
	# 진 쪽은 공격자인 former_vassal 이다 — 그 국토가 갈려야 협상이 열린다.
	world.provinces[1].occupied_by_nation = 0
	Peace._consider_peace(world, war)
	assert(not war.is_active and former_vassal.overlord == overlord.id,
		"독립전쟁에서 패하면 종속 관계가 복구된다")


func _test_overlord_death_releases_vassals() -> void:
	var world := _two_nations()
	EmpireSystem.vassalize(world, world.nations[0], world.nations[1])
	EmpireSystem.on_nation_death(world, world.nations[0])
	assert(world.nations[1].overlord == -1 and world.nations[0].vassals.is_empty(),
		"종주국이 사라지면 모든 속국은 독립한다")


func _test_subjugating_an_overlord_transfers_its_realm() -> void:
	var world := _three_nations()
	var conqueror: Nation = world.nations[0]
	var old_overlord: Nation = world.nations[1]
	var inherited: Nation = world.nations[2]
	EmpireSystem.vassalize(world, old_overlord, inherited)
	assert(EmpireSystem.vassalize(world, conqueror, old_overlord),
		"속국을 거느린 종주국도 복속할 수 있다")
	assert(old_overlord.overlord == conqueror.id and inherited.overlord == conqueror.id,
		"패자의 기존 속국은 새 승자의 직속 속국으로 승계된다")
	assert(conqueror.vassals == [old_overlord.id, inherited.id],
		"제국권 승계 뒤에도 속국은 한 단계로만 유지된다")


func _test_realm_share_includes_vassals() -> void:
	var world := _two_nations()
	var direct := EmpireSystem.realm_share(world, world.nations[0])
	EmpireSystem.vassalize(world, world.nations[0], world.nations[1])
	var realm := EmpireSystem.realm_share(world, world.nations[0])
	assert(realm > direct and is_equal_approx(realm, 1.0),
		"제국권 점유율에는 속국 영토 가치가 전부 포함된다")
	assert(is_equal_approx(EmpireSystem.realm_share(world, world.nations[1]), realm),
		"속국을 선택해도 같은 제국권 점유율을 본다")


func _two_nations() -> WorldState:
	return _world(2)


func _three_nations() -> WorldState:
	return _world(3)


# ---------------------------------------------------------------- 국명 칭호

## 칭호는 지금 규모가 정한다. 예전에는 세계 생성 때 평평한 목록에서 하나를 뽑고
## 평생 그대로였다 — 한 칸짜리 나라와 대제국이 똑같이 "공국" 이었다.
func _test_title_follows_realm_size() -> void:
	var world := _titled_world(40)
	var n: Nation = world.nations[0]
	assert(n.title_tier == NationPlacer.Tier.CITY, "한 칸짜리 나라는 도시국가다")
	assert(n.name.begins_with(n.stem), "국명은 어간으로 시작한다")
	var before := n.name

	_annex(world, 1, 0)                          # 2칸 — 평균 위, 아직 왕국
	world.turn = NationPlacer.TIER_MIN_HOLD_TURNS
	NationPlacer.tick_titles(world)
	assert(n.title_tier == NationPlacer.Tier.KINGDOM,
		"평균을 웃도는 크기는 왕국이다: %d" % n.title_tier)

	for pid in range(2, 6):                      # 6칸 = 세계의 15%, 제국 문턱을 넘는다
		_annex(world, pid, 0)
	world.turn = NationPlacer.TIER_MIN_HOLD_TURNS * 2
	NationPlacer.tick_titles(world)
	assert(n.title_tier == NationPlacer.Tier.EMPIRE, "제국 크기면 제국으로 개칭된다")
	assert(n.name != before, "이름이 실제로 바뀌어야 한다")
	assert(n.name.begins_with(n.stem), "어간은 남는다 — 같은 나라임이 읽혀야 한다")


## 국경 한 칸이 오갈 때마다 왕국↔제국 개칭이 기록을 도배하면 안 된다.
func _test_title_demotion_needs_a_real_fall() -> void:
	var world := _titled_world(40)
	var n: Nation = world.nations[0]
	for pid in range(1, 6):
		_annex(world, pid, 0)
	world.turn = NationPlacer.TIER_MIN_HOLD_TURNS
	NationPlacer.tick_titles(world)
	assert(n.title_tier == NationPlacer.Tier.EMPIRE)

	_annex(world, 4, 4)                          # 6칸 → 4칸. 승격 문턱 바로 아래다
	_annex(world, 5, 5)
	world.turn = NationPlacer.TIER_MIN_HOLD_TURNS * 2
	NationPlacer.tick_titles(world)
	assert(n.title_tier == NationPlacer.Tier.EMPIRE,
		"문턱을 살짝 밑돈 것으로는 강등되지 않는다")

	for pid in range(2, 4):                      # 4칸 → 2칸. 이건 진짜 몰락이다
		_annex(world, pid, pid)
	world.turn = NationPlacer.TIER_MIN_HOLD_TURNS * 3
	NationPlacer.tick_titles(world)
	assert(n.title_tier < NationPlacer.Tier.EMPIRE, "실제로 무너지면 강등된다")


## 속국은 종주국의 진영 크기를 물려받지 않고, 종주국과 같은 칭호도 쓰지 않는다.
## 예전에는 realm_province_count 가 realm_root 를 타서 1칸짜리 속국까지 제국이 됐다
## (실측: 917 프로빈스 판에서 제국 문턱 38칸인데 제국 칭호가 31개).
func _test_vassal_title_stays_under_its_overlord() -> void:
	var world := _titled_world(40)
	var overlord: Nation = world.nations[0]
	var vassal: Nation = world.nations[1]
	for pid in range(2, 8):                      # 종주국 6칸, 속국 8칸 — 둘 다 제국 크기
		_annex(world, pid, 0 if pid < 6 else 1)
	for pid in range(8, 14):
		_annex(world, pid, 1)
	assert(NationPlacer.tier_of(world, vassal) == NationPlacer.Tier.EMPIRE,
		"독립국일 때는 자기 크기대로 제국이다")

	assert(EmpireSystem.vassalize(world, overlord, vassal, false), "복속 성립")
	world.turn = NationPlacer.TIER_MIN_HOLD_TURNS
	NationPlacer.tick_titles(world)
	assert(overlord.title_tier == NationPlacer.Tier.EMPIRE,
		"종주국은 진영 전체로 재서 제국이다")
	assert(vassal.title_tier < overlord.title_tier,
		"속국은 종주국보다 낮은 칭호를 쓴다: %d vs %d" % [
			vassal.title_tier, overlord.title_tier])


## 프로빈스 하나를 다른 나라로 옮긴다.
func _annex(world: WorldState, pid: int, to_nation: int) -> void:
	var p: Province = world.provinces[pid]
	world.nations[p.owner_nation].provinces.erase(pid)
	p.owner_nation = to_nation
	if pid not in world.nations[to_nation].provinces:
		world.nations[to_nation].provinces.append(pid)


func _titled_world(count: int) -> WorldState:
	var world := _world(count)
	world.initial_nation_count = count            # 제국 문턱이 이 값을 읽는다
	NationPlacer.assign_names(world, world.rng_pool.get_rng("nation_names"))
	return world


func _world(count: int) -> WorldState:
	var world := WorldState.new()
	world.rng_pool = RngPool.new(101)
	for i in range(count):
		var n := Nation.new()
		n.id = i
		n.name = "N%d" % i
		n.capital = i
		n.culture = Culture.Kind.KOREAN_SHORTHAIR
		n.culture_params = Culture.PRESETS[n.culture].duplicate()
		n.provinces = [i]
		world.nations.append(n)
		var p := Province.new()
		p.id = i
		p.owner_nation = i
		p.culture = n.culture
		p.population = 10000.0
		p.gdp = 1000000.0
		p.gdp_pc = 100.0
		p.infra = 2.0
		p.land_neighbors = []
		world.provinces.append(p)
	for i in range(count):
		for j in range(count):
			if i != j:
				world.provinces[i].land_neighbors.append(j)
	EmpireSystem.initialize(world)
	world.rebuild_army_index()
	return world


## p.culture 는 어디서도 바뀌지 않아 대제국이 문화 경계에서 갈라졌다 (M10 §6.3).
func _test_settled_province_assimilates() -> void:
	var world := _world(2)
	var n: Nation = world.nations[0]
	var p: Province = world.provinces[1]
	n.provinces.append(p.id)
	world.nations[1].provinces.erase(p.id)
	p.owner_nation = n.id
	p.culture = Culture.Kind.CHEESE_TABBY
	p.integration = 1.0
	p.unrest = 0.0
	for i in range(200):
		p.unrest = 0.0
		EmpireSystem.tick(world)
		if p.culture == n.culture:
			break
	assert(p.culture == n.culture, "완전 통합 상태가 이어지면 문화가 동화한다")

	# 불만이 높으면 진행이 되돌아간다 — 끝나는 타이머가 아니다.
	var q: Province = world.provinces[0]
	q.culture = Culture.Kind.RAGDOLL
	q.integration = 1.0
	q.assimilation = 0.5
	# 0.70 이상은 _tick_integration 이 통째로 건너뛴다. 그 아래에서 동화만 되돌린다.
	q.unrest = 0.5
	EmpireSystem.tick(world)
	assert(q.assimilation < 0.5, "불만이 높으면 동화는 되돌아간다")
