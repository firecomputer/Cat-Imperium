extends SceneTree

## M8.5 반란 개편 회귀 테스트 (§14).
##
##   godot4 --headless --path . --script res://tools/test_rebellion.gd


func _initialize() -> void:
	_test_garrison_prefers_unrest()
	_test_garrison_breaks_ties_by_province_id()
	_test_garrison_respects_peace_budget()
	_test_garrison_respects_war_budget()
	_test_garrison_posts_directly_on_unreachable_land()
	_test_territory_score_is_full_when_all_reclaimed()
	_test_capital_recapture_adds_twenty()
	_test_even_losses_are_neutral()
	_test_parent_wins_before_taking_every_province()
	_test_defeat_returns_rebel_held_origin_land()
	_test_defeat_leaves_third_party_land_alone()
	_test_reintegration_caps_unrest_and_grants_grace()
	_test_grace_blocks_respawn_but_not_drift()
	_test_recognition_rises_while_holding_everything()
	_test_recognition_is_slower_at_half_control()
	_test_recognition_stalls_under_parent_pressure()
	_test_recognition_stalls_when_rebels_bleed()
	_test_recognition_falls_when_pushed_out()
	_test_recognition_target_grants_independence()
	_test_war_age_alone_grants_nothing()
	_test_rebel_names_are_unique()
	_test_independence_retitles_the_rebel()
	_test_ghost_rebel_war_is_decided_by_ground()
	_test_integration_relieves_structural_unrest()
	_test_reclaim_lowers_integration()
	print("rebellion tests: PASS")
	quit(0)


# ---------------------------------------------------------------- 주둔 (§2)

func _test_garrison_prefers_unrest() -> void:
	var world := _world(3)
	var n: Nation = world.nations[0]
	world.provinces[1].unrest = 0.1
	world.provinces[2].unrest = 0.8
	var targets := WarAI.garrison_targets(world, n)
	assert(targets[0] == 2, "불만이 높은 프로빈스가 먼저 주둔된다")


func _test_garrison_breaks_ties_by_province_id() -> void:
	var world := _world(3)
	var n: Nation = world.nations[0]
	# distance_from_capital 항까지 같게 맞춰야 순수 동점이 된다.
	for i in range(3):
		world.provinces[i].unrest = 0.6
		world.provinces[i].distance_from_capital = 0.0
	var targets := WarAI.garrison_targets(world, n)
	assert(targets[0] == 0 and targets[1] == 1 and targets[2] == 2,
		"같은 need 에서는 province.id 가 낮은 쪽이 먼저다")


func _test_garrison_respects_peace_budget() -> void:
	var world := _world(6)
	var n: Nation = world.nations[0]
	for i in range(1, 6):
		world.provinces[i].unrest = 0.9
	Military.create_army(world, n, 0, 1000)
	WarAI.plan(world)
	var share := float(_garrison_troops(world, n)) / 1000.0
	assert(share <= WarAI.GARRISON_ARMY_SHARE_PEACE + 0.001,
		"평시 치안 병력은 %.0f%% 를 넘지 않는다 (실제 %.1f%%)"
			% [WarAI.GARRISON_ARMY_SHARE_PEACE * 100.0, share * 100.0])
	assert(share > 0.0, "고불만 프로빈스가 있으면 실제로 주둔한다")


func _test_garrison_respects_war_budget() -> void:
	var world := _world(6)
	var n: Nation = world.nations[0]
	for i in range(1, 6):
		world.provinces[i].unrest = 0.9
	Military.create_army(world, n, 0, 1000)
	n.at_war = true
	WarAI.plan(world)
	var share := float(_garrison_troops(world, n)) / 1000.0
	assert(share <= WarAI.GARRISON_ARMY_SHARE_WAR + 0.001,
		"전쟁 중 치안 병력은 %.0f%% 를 넘지 않는다 (실제 %.1f%%)"
			% [WarAI.GARRISON_ARMY_SHARE_WAR * 100.0, share * 100.0])


## 섬은 행군으로 닿지 않는다. 평시에는 현지 주둔으로 세우고, 전시에는 세우지 않는다.
func _test_garrison_posts_directly_on_unreachable_land() -> void:
	var world := _island_world()
	Military.create_army(world, world.nations[0], 0, 1000)
	WarAI.plan(world)
	var posted := false
	for army in world.armies:
		if army.garrison_province == 2:
			posted = true
			assert(army.province_id == 2, "도달 불가 영토의 분견대는 현지에 배치된다")
	assert(posted, "평시에는 섬에도 주둔한다")

	var at_war := _island_world()
	at_war.nations[0].at_war = true
	Military.create_army(at_war, at_war.nations[0], 0, 1000)
	WarAI.plan(at_war)
	for army in at_war.armies:
		assert(army.garrison_province != 2,
			"전시에는 도달 불가 영토에 병력을 순간이동시키지 않는다")


# ---------------------------------------------------------------- warscore (§3)

func _test_territory_score_is_full_when_all_reclaimed() -> void:
	var world := _rebel_world()
	var war: War = world.wars[0]
	# 원영토를 전부 모국이 되찾은 상태. 수도는 아직 반란군 손에 두어 분리 측정한다.
	_give(world, 3, 0)
	_give(world, 4, 0)
	war.rebel_capital_province = -1
	assert(absf(Peace.rebel_warscore(world, war) - Peace.REBEL_TERRITORY_SCORE) < 0.001,
		"원영토 100%% 탈환이면 territory_score 가 정확히 %.0f 이다"
			% Peace.REBEL_TERRITORY_SCORE)


func _test_capital_recapture_adds_twenty() -> void:
	var world := _rebel_world()
	var war: War = world.wars[0]
	var without := Peace.rebel_warscore(world, war)
	_give(world, 3, 0)                      # 3 번이 반란 수도다
	var with_capital := Peace.rebel_warscore(world, war)
	var territory := Peace.REBEL_TERRITORY_SCORE / 2.0
	assert(absf(with_capital - without - territory - Peace.REBEL_CAPITAL_SCORE) < 0.001,
		"반란 수도 탈환은 %.0f 점을 더한다" % Peace.REBEL_CAPITAL_SCORE)


func _test_even_losses_are_neutral() -> void:
	var world := _rebel_world()
	var war: War = world.wars[0]
	war.attacker_losses = 500.0
	war.defender_losses = 500.0
	assert(absf(Peace.rebel_warscore(world, war)) < 0.001,
		"손실이 같으면 battle_score 는 0 이다")


func _test_parent_wins_before_taking_every_province() -> void:
	var world := _rebel_world(4)            # 원영토 3,4,5,6
	var war: War = world.wars[0]
	_give(world, 3, 0)                      # 수도 포함 3/4 탈환 = 41.25 + 20
	_give(world, 4, 0)
	_give(world, 5, 0)
	war.attacker_losses = 400.0             # 반란군 손실 우위 → +5
	war.defender_losses = 600.0
	var score := Peace.rebel_warscore(world, war)
	assert(score >= Peace.REBEL_PARENT_VICTORY_SCORE,
		"전 영토 점령 없이도 진압 임계를 넘는다 (%.1f)" % score)
	assert(world.nations[1].provinces.size() > 0, "반란국은 아직 땅을 쥐고 있다")

	Peace.tick(world)
	assert(not war.is_active, "임계를 넘으면 반란전이 끝난다")
	assert(world.provinces[6].owner_nation == 0, "남은 원영토도 일괄 반환된다")


# ---------------------------------------------------------------- 재통합 (§4)

func _test_defeat_returns_rebel_held_origin_land() -> void:
	var world := _rebel_world()
	var war: War = world.wars[0]
	Peace._resolve_rebel_defeat(world, war, "suppressed")
	assert(world.provinces[3].owner_nation == 0 and world.provinces[4].owner_nation == 0,
		"반란국이 쥔 원영토는 모국으로 반환된다")
	assert(not world.nations[1].is_alive, "땅을 다 잃은 반란국은 소멸한다")


func _test_defeat_leaves_third_party_land_alone() -> void:
	var world := _rebel_world()
	var war: War = world.wars[0]
	var third := Nation.new()
	third.id = 2
	third.capital = 4
	third.culture = Culture.Kind.KOREAN_SHORTHAIR
	third.culture_params = Culture.PRESETS[third.culture].duplicate()
	world.nations.append(third)
	_give(world, 4, 2)                      # 제3국이 합법적으로 병합한 땅
	Peace._resolve_rebel_defeat(world, war, "suppressed")
	assert(world.provinces[3].owner_nation == 0, "반란국 소유 원영토는 반환된다")
	assert(world.provinces[4].owner_nation == 2, "제3국 소유 원영토는 건드리지 않는다")


func _test_reintegration_caps_unrest_and_grants_grace() -> void:
	var world := _rebel_world()
	var p: Province = world.provinces[3]
	p.unrest = 1.0
	Unrest.reclaim_from_rebel(world, p, world.nations[1], world.nations[0])
	assert(p.unrest <= Unrest.REINTEGRATION_UNREST,
		"재통합 직후 불만은 %.2f 이하다" % Unrest.REINTEGRATION_UNREST)
	assert(p.rebellion_grace_turns == Unrest.REINTEGRATION_GRACE_TURNS,
		"재통합은 유예 턴을 부여한다")


func _test_grace_blocks_respawn_but_not_drift() -> void:
	var world := _world(4)
	var n: Nation = world.nations[0]
	# 유예 대상 프로빈스만 drift 를 양수로 만든다. 인플레처럼 전국 항을 쓰면
	# 본토가 먼저 다 떨어져 나가 "프로빈스 1개는 갈라설 수 없다" 가드에 걸린다.
	var p: Province = world.provinces[3]
	p.distance_from_capital = 10.0
	p.is_exclave = true
	# 구조적 압력은 통합도로 완화된다. 여기서 재봉기하는 것은 막 정복한
	# 미통합 변경지다 — 완전 통합된 본토는 원래 다시 안 터져야 한다.
	p.integration = 0.0
	p.unrest = 0.9
	p.rebellion_grace_turns = Unrest.REINTEGRATION_GRACE_TURNS
	assert(Unrest.drift(p, n) > 0.0 and Unrest.drift(world.provinces[1], n) < 0.0,
		"이 세계에서는 3 번만 불만이 쌓인다")
	for i in range(Unrest.REINTEGRATION_GRACE_TURNS):
		Unrest.tick(world)
		assert(p.owner_nation == n.id,
			"유예 중에는 새 반란이 터지지 않는다 (%d 턴째)" % i)
	assert(p.unrest > 0.9, "유예 중에도 불만 drift 자체는 계속 계산된다")
	# 유예가 풀렸다고 그 턴에 반드시 터지지는 않는다 — 봉기는 REBELLION_CHANCE
	# 확률로만 성립한다. 검사할 것은 "유예가 막던 것이 이제 막지 않는다" 이다.
	var fired := false
	for i in range(60):
		Unrest.tick(world)
		if p.owner_nation != n.id:
			fired = true
			break
	assert(fired, "유예가 끝나면 다시 봉기할 수 있다")


# ---------------------------------------------------------------- recognition (§5)

func _test_recognition_rises_while_holding_everything() -> void:
	var world := _rebel_world()
	var base := Peace.RECOGNITION_CONTROL_GAIN + Peace.RECOGNITION_CAPITAL_GAIN
	var mean := _mean_recognition_gain(world, world.wars[0])
	assert(mean > 0.0, "전 영토와 수도를 지키면 인정도가 오른다")
	assert(absf(mean - base * Peace.RECOGNITION_LUCK_MEAN) < 0.1,
		"평균 증가는 %.2f 에 운 평균 %.2f 를 곱한 값이다 (실측 %.3f)" \
			% [base, Peace.RECOGNITION_LUCK_MEAN, mean])
	assert(mean < base, "운의 평균이 1 미만이라 고정 증가율보다 느리다")


func _test_recognition_is_slower_at_half_control() -> void:
	var full := _rebel_world()
	var half := _rebel_world()
	_give(half, 4, 0)                       # 원영토 절반 상실, 수도는 유지
	var full_mean := _mean_recognition_gain(full, full.wars[0])
	var half_mean := _mean_recognition_gain(half, half.wars[0])
	assert(half_mean > 0.0, "절반만 쥐어도 인정도는 오른다")
	assert(half_mean < full_mean, "다만 전 영토를 지킬 때보다 느리다")


## 모국이 원영토를 물리적으로 누르면 인정도가 느려진다. 예전에는 controller()
## 플립만 셌기 때문에 포위도 주둔도 인정도에 한 푼도 반영되지 않았다.
func _test_recognition_stalls_under_parent_pressure() -> void:
	var world := _rebel_world()
	var war: War = world.wars[0]
	var free_mean := _mean_recognition_gain(world, war)
	Military.create_army(world, world.nations[0], 3, 100)
	var pressed_mean := _mean_recognition_gain(world, war)
	assert(pressed_mean < free_mean,
		"모국 야전군이 올라와 앉으면 인정도 증가가 느려진다 (%.3f → %.3f)" \
			% [free_mean, pressed_mean])


## 모국 군대가 원영토까지 못 가도, 반란군만 갈려 나가고 있으면 독립이 멀어진다.
func _test_recognition_stalls_when_rebels_bleed() -> void:
	var world := _rebel_world()
	var war: War = world.wars[0]
	var even_mean := _mean_recognition_gain(world, war)
	war.attacker_losses = 100.0             # 모국 손실
	war.defender_losses = 900.0             # 반란군이 사상자의 90% 를 부담
	var bleeding_mean := _mean_recognition_gain(world, war)
	assert(bleeding_mean < even_mean,
		"반란군만 갈려 나가면 인정도가 오르지 않는다 (%.3f → %.3f)" \
			% [even_mean, bleeding_mean])


func _test_recognition_falls_when_pushed_out() -> void:
	var world := _rebel_world(5)            # 원영토 3..7
	var war: War = world.wars[0]
	war.recognition = 50.0
	for pid in [3, 4, 5, 6]:                # 1/5 만 남는다 = 20% < 30%
		_give(world, pid, 0)
	war.rebel_capital_province = 7
	Peace._tick_rebel_recognition(world, war)
	assert(war.recognition < 50.0, "영토 30%% 미만이면 인정도가 줄어든다")

	_give(world, 7, 0)                      # 전부 상실
	var before := war.recognition
	Peace._tick_rebel_recognition(world, war)
	assert(before - war.recognition >= Peace.RECOGNITION_LOSING_PENALTY
			+ Peace.RECOGNITION_COLLAPSE_PENALTY - 0.001,
		"완전히 밀려나면 더 빠르게 무너진다")


func _test_recognition_target_grants_independence() -> void:
	var world := _rebel_world()
	var war: War = world.wars[0]
	war.recognition = Peace.REBEL_RECOGNITION_TARGET - 0.5
	Peace.tick(world)
	assert(not war.is_active, "인정도가 목표에 닿으면 독립이 인정된다")
	assert(not world.nations[1].is_rebel, "독립국은 이후 일반 국가로 취급된다")
	assert(world.provinces[3].owner_nation == 1, "독립국은 영토를 지킨다")


func _test_war_age_alone_grants_nothing() -> void:
	var world := _rebel_world()
	var war: War = world.wars[0]
	# 반란군이 원영토를 하나도 못 쥔 채 200턴을 버틴다.
	_give(world, 3, 0)
	_give(world, 4, 0)
	world.turn = war.start_turn + 200
	for i in range(200):
		Peace._tick_rebel_recognition(world, war)
	assert(war.recognition <= 0.0,
		"영토 없이 시간만 버텨서는 인정도가 오르지 않는다 (%.1f)" % war.recognition)


# ---------------------------------------------------------------- 도우미

## 인정도 증가에는 결정론 난수가 얹혀 있다. 한 턴 값이 아니라 평균으로 본다 —
## 한 번의 draw 로 비교하면 두 세계가 서로 다른 난수를 뽑아 결과가 뒤집힌다.
func _mean_recognition_gain(world: WorldState, war: War, ticks: int = 400) -> float:
	var total := 0.0
	for i in range(ticks):
		war.recognition = 0.0
		Peace._tick_rebel_recognition(world, war)
		total += war.recognition
	war.recognition = 0.0
	return total / float(ticks)


func _garrison_troops(world: WorldState, n: Nation) -> int:
	var total := 0
	for army_id in n.armies:
		var a: Army = world.armies[army_id]
		if a.is_alive and a.garrison_province >= 0:
			total += a.troops
	return total


## 프로빈스 소유권을 옮긴다. 테스트에서만 쓰는 최소 이전이다.
func _give(world: WorldState, pid: int, nation_id: int) -> void:
	var p: Province = world.provinces[pid]
	world.nations[p.owner_nation].provinces.erase(pid)
	p.owner_nation = nation_id
	p.occupied_by_nation = -1
	world.nations[nation_id].provinces.append(pid)


## 프로빈스 2 가 육상 인접이 전혀 없는 섬인 세계.
func _island_world() -> WorldState:
	var world := _world(3)
	world.provinces[2].land_neighbors = []
	world.provinces[1].land_neighbors = [0]
	world.provinces[2].unrest = 0.95
	world.provinces[2].is_exclave = true
	return world


## 같은 모국에서 두 번 봉기하면 이름이 겹치면 안 된다 — 지도에서 구분이 안 된다.
func _test_rebel_names_are_unique() -> void:
	var world := _world(5)
	var parent: Nation = world.nations[0]
	parent.name = "한벌 왕국"
	Unrest.spawn_new_rebellion(world, world.provinces[1], parent)
	Unrest.spawn_new_rebellion(world, world.provinces[4], parent)
	var first: Nation = world.nations[1]
	var second: Nation = world.nations[2]
	assert(not first.name.is_empty() and not second.name.is_empty(),
		"반란국도 이름을 갖는다")
	assert(first.name != second.name, "같은 모국의 두 반란국은 이름이 다르다")
	assert(not first.name.contains(parent.name),
		"반란국 이름은 봉기 지역에서 나온다 — 모국 이름을 물려받지 않는다")


## 독립이 인정되면 봉기군이 아니라 나라다. 어간은 남기고 칭호만 바뀐다 —
## 예전에는 300턴이 지나 제국 크기가 되어도 이름이 "봉기군" 이었다.
func _test_independence_retitles_the_rebel() -> void:
	var world := _rebel_world()
	var war: War = world.wars[0]
	var rebel: Nation = world.nations[war.rebel_nation_id]
	var before := rebel.name
	assert(rebel.title_tier == NationPlacer.Tier.REBEL, "반란국은 반란 칭호로 시작한다")
	assert(not rebel.stem.is_empty(), "반란국도 어간을 들고 있어야 개칭할 수 있다")
	war.recognition = Peace.REBEL_RECOGNITION_TARGET - 0.5
	Peace.tick(world)
	assert(not rebel.is_rebel, "인정된 반란국은 더 이상 반란 세력이 아니다")
	assert(rebel.title_tier != NationPlacer.Tier.REBEL, "칭호가 정식 국가로 바뀐다")
	assert(rebel.name != before, "이름이 실제로 바뀌어야 한다")
	assert(rebel.name.begins_with(rebel.stem),
		"어간은 그대로 남아 같은 세력임이 읽혀야 한다")


## 교전도 인정도 진행도 멈춘 반란전은 어느 시계로도 끝나지 않았다 —
## 실측에서 1200턴 판에 1068턴짜리 반란전이 살아 있었다.
func _test_ghost_rebel_war_is_decided_by_ground() -> void:
	var world := _rebel_world(5)
	var war: War = world.wars[0]
	# 반란군이 원영토의 20% 만 쥐면 인정도는 오르지 않는다 — 시계가 멈춘다.
	for pid in range(4, 8):
		_give(world, pid, 0)
	world.turn = Peace.GHOST_WAR_TURNS
	Peace.tick(world)
	assert(not war.is_active, "멈춘 반란전은 원영토를 쥔 쪽으로 결착된다")

	var living := _rebel_world(5)
	living.turn = Peace.GHOST_WAR_TURNS * 3
	Peace.tick(living)
	assert(living.wars[0].is_active, "인정도가 오르는 반란전은 유령이 아니다")
	assert(living.wars[0].last_progress_turn == living.turn,
		"인정도 상승이 진행 턴을 갱신한다")


func _world(count: int) -> WorldState:
	var world := WorldState.new()
	world.rng_pool = RngPool.new(109)
	world.nations.append(_nation(0, 0))
	for i in range(count):
		var p := Province.new()
		p.id = i
		p.owner_nation = 0
		p.culture = Culture.Kind.KOREAN_SHORTHAIR
		p.population = 10000.0
		p.gdp = 1000000.0
		p.infra = 3.0
		p.distance_from_capital = float(i)
		p.centroid = Vector2(float(i), 0.0)
		if i > 0:
			p.land_neighbors.append(i - 1)
		if i < count - 1:
			p.land_neighbors.append(i + 1)
		world.provinces.append(p)
		world.nations[0].provinces.append(i)
	world.nations[0].supply_field.resize(count)
	world.nations[0].supply_field.fill(1.0)
	return world


## 모국 0 (프로빈스 0..2) 과 반란국 1 (프로빈스 3..2+size) 이 반란전 중인 세계.
## 반란 수도는 3 번이다.
func _rebel_world(size: int = 2) -> WorldState:
	var world := _world(3 + size)
	var rebel := _nation(1, 3)
	rebel.is_rebel = true
	rebel.rebel_origin = 0
	# Unrest.spawn_new_rebellion 과 같은 정체성을 준다. 어간이 없으면 개칭이 불가능하다.
	var identity := NationPlacer.rebel_identity(world.nations, rebel.culture, 3)
	rebel.stem = identity["stem"]
	rebel.name = identity["name"]
	rebel.title_tier = NationPlacer.Tier.REBEL
	world.nations.append(rebel)
	var origin := PackedInt32Array()
	for i in range(3, 3 + size):
		_give(world, i, 1)
		origin.append(i)

	var war := Diplomacy.declare_war(world, world.nations[0], rebel, "rebellion")
	war.is_rebel_war = true
	war.parent_nation_id = 0
	war.rebel_nation_id = 1
	war.rebel_origin_provinces = origin
	war.rebel_capital_province = 3
	rebel.supply_field.resize(world.provinces.size())
	rebel.supply_field.fill(1.0)
	world.turn = war.start_turn + Peace.MIN_WAR_TURNS + 1
	return world


func _nation(id: int, capital: int) -> Nation:
	var n := Nation.new()
	n.id = id
	n.capital = capital
	n.culture = Culture.Kind.KOREAN_SHORTHAIR
	n.culture_params = Culture.PRESETS[n.culture].duplicate()
	return n


## drift 에는 감쇠항이 없어 정복지의 문화·거리 압력이 영구 양수였다.
## 통합이 진행되면 구조적 압력이 줄어야 한다 (M10 §6.1).
func _test_integration_relieves_structural_unrest() -> void:
	var world := _world(4)
	var n: Nation = world.nations[0]
	var p: Province = world.provinces[3]
	p.distance_from_capital = 10.0
	p.is_exclave = true
	p.culture = Culture.Kind.CHEESE_TABBY
	p.integration = 0.0
	var raw := Unrest.drift(p, n)
	p.integration = 1.0
	var settled := Unrest.drift(p, n)
	assert(settled < raw, "통합된 땅은 구조적 불만 압력이 낮다 (%.4f -> %.4f)" % [raw, settled])
	assert(raw > 0.0, "미통합 이문화 월경지는 여전히 불만이 쌓인다")


## 진압된 땅이 integration 1.0 인 채로 남으면 반란났던 곳이 가장 조용해진다 (M10 §6.2).
func _test_reclaim_lowers_integration() -> void:
	var world := _world(4)
	var p: Province = world.provinces[2]
	p.integration = 1.0
	Unrest.spawn_rebellion(world, p, world.nations[0])
	var rebel: Nation = world.nations[world.nations.size() - 1]
	Unrest.reclaim_from_rebel(world, p, rebel, world.nations[0])
	assert(p.integration <= Unrest.REINTEGRATION_INTEGRATION,
		"재통합은 부분 통합에서 다시 시작한다 (%.2f)" % p.integration)
