class_name Unrest extends RefCounted

const EmpireSystem = preload("res://sim/systems/empire_system.gd")

## 불만 누적과 반란 (§10). 반란군은 독립 국가로 스폰되므로 진압에 실패하면
## 영토를 실제로 잃는다 — 제국 분할이 확률이 아니라 시스템 귀결로 일어난다.

const OCCUPATION_W := 0.05
## 법률의 unrest 수정자는 실제 국내 정치 비용이다. 0.15에서는 치즈 태비의 초기
## 법률 묶음이 점령지가 없어도 턴당 +0.033을 만들고, 결속 감쇠(-0.006)를 항상
## 압도해 모든 국가가 1프로빈스까지 확정 붕괴했다. 점령법은 별도 점령 항으로만
## 처리하고 나머지는 0.08로 낮춰 가혹한 국가는 불안정하되 확정 사형은 아니게 한다.
const LAW_UNREST_W := 0.08
const INFLATION_W := 2.0
## §10 은 5% 초과분부터 불만으로 치지만, 이 시뮬의 평시 인플레가 이미 4~5% 다
## (M5 배치 측정값). 그 임계로는 모든 나라가 상시 발동 상태가 되어
## 세계가 통째로 조각난다. 진짜 인플레 위기(화폐 발행)만 잡도록 10% 로 올린다.
const INFLATION_FREE := 0.10
const CULTURE_W := 0.03
## 동화 성향이 이문화 압력을 얼마나 지우는가 (M13.7-a). 0 으로 떨어뜨리지 않는다 —
## 정복지가 완전히 조용해지면 제국의 문화 경계라는 압력원 자체가 사라진다.
const ASSIMILATION_RELIEF := 0.60
## 계수 0.01 · 상한 5 는 거리 항 단독으로 +0.05/턴을 만든다. 반면 감쇠 합계는
## cohesion·suppression·garrison 을 다 더해도 -0.02 수준이라(주둔 병력이 있는
## 프로빈스가 16% 뿐이다) 수도거리 3 이상은 무조건 봉기했다. 국가 반경이 2 로
## 고정되어 정복해도 반경 밖은 되돌아가므로 정복 자체가 무의미해졌다.
## 계수를 낮추고 상한을 풀어, 거리는 확정 사형선고가 아니라 규모에 비례해
## 커지는 압력이 되게 한다 — 큰 제국일수록 주둔·고문에 더 써야 한다.
const DISTANCE_W := 0.004
## 월경지는 직선거리로 환산되므로 상한이 없으면 이 항 하나가 턴당 +0.3 을 넘겨
## 세계를 즉시 붕괴시킨다.
const DISTANCE_CAP := 10.0
const EXCLAVE_W := 0.02
const GARRISON_W := 0.04
const SUPPRESSION_W := 0.05
const COHESION_W := 0.02
## drift 에는 감쇠항이 없어 문화 거리(최대 +0.03/턴)가 영구 양수였다. 그래서
## 정복지는 진압해도 유예가 끝나는 즉시 다시 봉기했다 (실측 50턴 내 재반란 79%).
## p.integration 은 이미 매 턴 갱신되지만 행정부하에만 쓰였다. 구조적 압력
## (문화·거리·월경지)만 통합으로 덜어 준다 — 인플레·점령법은 그대로 둔다.
## 통합된 본토라도 하이퍼인플레에는 흔들려야 §13.4 의 서사가 성립한다.
const INTEGRATION_RELIEF := 0.80

## 필요 치안 병력 = max(GARRISON_MIN_REQUIRED, 인구 × GARRISON_TROOPS_PER_POP).
## garrison_ratio 는 실제 주둔 병력을 이 값으로 나눈 것이다 (M8.5 §2.6).
## 하한이 없으면 인구가 적은 변경 프로빈스는 한 줌 병력으로 ratio 1.0 이 되어
## 주둔이 공짜 안정도가 된다.
## 계획서의 max(500, 인구×0.015) 는 이 시뮬의 규모와 20배 어긋난다 — 실측 중앙값이
## 프로빈스 인구 4145, 국가 총병력 139 이라 프로빈스 하나를 채우는 데 국가 전군의
## 3배가 필요해져 주둔이 아예 성립하지 않았다. 형태는 그대로 두고 배율만 맞춘다.
## 중앙 프로빈스 기준 필요 병력 25 = 평시 치안 예산(총병력 25%)의 약 3/4.
const GARRISON_TROOPS_PER_POP := 0.006
const GARRISON_MIN_REQUIRED := 15.0
## M8.5 재통합. 진압 직후를 불만 0 으로 만들면 정치 문제가 사라지고,
## 그대로 두면 다음 턴에 다시 봉기한다. 낮춘 뒤 유예를 준다 (§4.5).
const REINTEGRATION_UNREST := 0.35
## 전장 탈환은 파이프라인 10단계(Military), 불만은 11단계다. 즉 재통합된 턴에
## 유예가 이미 1 소모된다. §9 의 "진압 후 15턴 내 재반란 0%" 를 실제로 만족하려면
## 16 이어야 한다.
const REINTEGRATION_GRACE_TURNS := 16
## 진압된 땅이 integration 1.0 인 채로 남으면 (반란국이 자기 수도로 삼으며
## 올려놓는다) 6.1 의 완화가 걸려 반란났던 곳이 오히려 가장 조용해진다.
## 부분 통합에서 다시 시작하게 한다 — 유예 16턴 + 0.020/턴 으로 약 28턴.
const REINTEGRATION_INTEGRATION := 0.45
## 반란 규모. 도시 프로빈스는 ×3 (§10).
## 봉기 판정을 시작하는 불만. 예전에는 1.0 에 닿는 즉시 터졌다 — 언제 터질지
## 턴 단위로 계산되던 것이 문제였다.
const REBELLION_FUSE := 0.90
## 불만 1.0 에서의 턴당 봉기 확률. 임계 바로 위(0.90)에서는 0 이고 선형으로 오른다.
const REBELLION_CHANCE := 0.35
const REBEL_TROOP_RATIO := 0.02
const REBEL_CITY_MULT := 3.0
const REBEL_START_UNREST := 0.5

# ---------------------------------------------------------------- 분리주의 (M14 §1)
## 자국 땅에서 벌어진 교전·공성 한 턴치. 진압은 그 자리에서 끝나지만 기억은 남는다.
const SEPARATISM_COMBAT := 0.02
## 반란 진압 성공. 재통합이 불만·통합도를 되돌려 놓는 바로 그 자리에서 물린다 —
## 진압이 공짜였던 것이 "찍어누르면 끝"의 원인이었다.
const SEPARATISM_SUPPRESSION := 0.25
## 불만 상승분에만 걸리는 배율. 감쇠항까지 곱하면 주둔이 오히려 이득이 된다.
const SEPARATISM_UNREST_MULT := 1.2
## 진압이 없는 턴의 망각. 없으면 200턴 배치에서 모든 대국이 확정 붕괴한다.
## 0.25 를 지우는 데 약 125턴 — 진압한 세대가 죽을 만큼의 시간이다.
const SEPARATISM_DECAY := 0.002


static func tick(world: WorldState) -> void:
	refresh_garrisons(world)
	for n in world.nations:
		if not n.is_alive:
			continue
		# 반란이 목록을 바꾸므로 사본을 순회한다.
		for pid in n.provinces.duplicate():
			var p: Province = world.provinces[pid]
			if p.owner_nation != n.id:
				continue
			tick_province(world, p, n)
	# 유예는 프로빈스당 턴당 한 번만 준다. tick_province 안에서 깎으면 반란으로
	# 소유가 바뀐 프로빈스가 같은 턴에 두 번 세어져 유예가 한 턴 짧아진다.
	for p in world.provinces:
		if p.rebellion_grace_turns > 0:
			p.rebellion_grace_turns -= 1
		# 진압이 있었던 턴에는 감쇠하지 않는다. 함께 돌면 작은 교전은 순증이 0 이다.
		if p.suppressed_this_turn:
			p.suppressed_this_turn = false
		else:
			p.separatism = maxf(p.separatism - SEPARATISM_DECAY, 0.0)


## 주둔 병력을 프로빈스 단위로 집계한다. §10 의 garrison_ratio 는 여기서 나온다.
static func refresh_garrisons(world: WorldState) -> void:
	for p in world.provinces:
		p.garrison_ratio = 0.0
	for army in world.armies:
		if not army.is_alive or army.province_id < 0:
			continue
		var p: Province = world.provinces[army.province_id]
		if p.controller() != army.nation_id:
			continue
		p.garrison_ratio += army.troops
	for p in world.provinces:
		if p.garrison_ratio <= 0.0:
			continue
		p.garrison_ratio = clampf(p.garrison_ratio / required_garrison(p), 0.0, 1.0)


## 이 프로빈스를 눌러 앉으려면 몇 명이 필요한가. WarAI 의 치안 배치도 이 값을 쓴다.
static func required_garrison(p: Province) -> float:
	return maxf(GARRISON_MIN_REQUIRED, p.population * GARRISON_TROOPS_PER_POP)


static func drift(p: Province, n: Nation) -> float:
	# §10 은 점령 법률 항을 전 프로빈스에 무조건 더하지만, 그러면 가혹한
	# 점령법을 고른 나라는 본토까지 20여 턴 만에 동시 봉기해 자멸한다.
	# 점령 정책은 정복지 정책이므로 문화가 다른 땅에만 적용한다.
	var d := 0.0
	# 점령 항의 밑변은 수취가 실제로 일어나는 땅과 같다 (Province.occupation_base).
	# 예전에는 이문화 땅이면 통합도와 무관하게 severity 전액이 영구히 걸렸다.
	# 약탈(0.9)의 +0.045/턴 하나가 주둔·진압·결속을 다 더한 감쇠(-0.037)보다 커서
	# 이문화 정복지는 통치 방식과 상관없이 확정 반란이었다 (실측 평균 21턴).
	# 이제 통합이 진행될수록 수취도 불만도 함께 줄어, 온건 통치는 압력이 끝나는
	# 경로가 되고 약탈은 그 경로를 스스로 막은 채 돈을 받는 선택이 된다.
	d += n.occupation_law_severity() * OCCUPATION_W * p.occupation_base(n.culture)
	d += maxf(n.inflation - INFLATION_FREE, 0.0) * INFLATION_W   # 인플레는 최강 불만 요인
	var settled := 1.0 - p.integration * INTEGRATION_RELIEF
	d += p.culture_distance(n.culture) * CULTURE_W * settled \
		* (1.0 - n.culture_bias("assimilation") * ASSIMILATION_RELIEF)
	d += minf(p.distance_from_capital, DISTANCE_CAP) * DISTANCE_W * settled
	d += (EXCLAVE_W if p.is_exclave else 0.0) * settled
	d += EmpireSystem.unrest_pressure(p, n)
	d += domestic_law_unrest(n) * LAW_UNREST_W
	# 분리주의는 압력을 새로 만들지 않고 이미 있는 압력을 키운다. 감쇠항까지
	# 곱하면 주둔·고문이 오히려 더 잘 듣게 되어 방향이 뒤집힌다.
	if d > 0.0:
		d *= 1.0 + p.separatism * SEPARATISM_UNREST_MULT
	d -= p.garrison_ratio * GARRISON_W
	d -= n.unrest_suppression * SUPPRESSION_W
	d -= n.culture_bias("cohesion") * COHESION_W
	return d


## 진압의 유일한 기록 지점. 분리주의를 올리고 통합도를 같은 폭만큼 되돌린다 —
## 군대로 누른 땅은 행정적으로도 그만큼 뒤로 밀린다 (M14 §1).
static func register_suppression(world: WorldState, p: Province, amount: float) -> void:
	if amount <= 0.0:
		return
	var before := p.separatism
	p.separatism = clampf(p.separatism + amount, 0.0, 1.0)
	p.integration = maxf(p.integration - (p.separatism - before), 0.0)
	p.suppressed_this_turn = true
	world.log_event("suppression", {
		"nation": p.owner_nation,
		"province": p.id,
		"separatism": p.separatism,
		"integration": p.integration,
	})


## 점령법의 불만은 위의 occupation_base 항에서 정복지에만 이미 적용된다.
## 전체 law_modifier 합계에 다시 넣으면 약탈 정책이 같은 문화의 본토에도 중복된다.
static func domestic_law_unrest(n: Nation) -> float:
	var total := n.law_modifier("unrest")
	var occupation: Law = n.laws.get("occupation")
	if occupation != null:
		total -= occupation.modifier("unrest")
	return total


static func tick_province(world: WorldState, p: Province, n: Nation) -> void:
	p.unrest = clampf(p.unrest + drift(p, n), 0.0, 1.0)
	# 재통합 유예. 불만 누적은 계속 계산하고 봉기만 막는다 — 유예가 끝났을 때
	# 상황이 나쁘면 다시 위험해져야 한다 (§4.5).
	if p.rebellion_grace_turns > 0:
		p.unrest = minf(p.unrest, 0.99)
		return
	if p.unrest < REBELLION_FUSE:
		return
	# 한 프로빈스짜리 나라에서는 갈라설 땅이 없다. 이 가드가 없으면 반란국이
	# 자기 자신에게서 다시 갈라져 나오며 세계가 무한 분할된다.
	if n.provinces.size() <= 1:
		p.unrest = REBELLION_FUSE - 0.01
		return
	# 임계를 넘었다고 그 턴에 반드시 터지지는 않는다. 언제 터질지 모르는 것이 봉기의
	# 본질이다. 압력이 높을수록 빨리 터지고, 시드가 같으면 같은 턴에 터진다.
	var pressure := (p.unrest - REBELLION_FUSE) / (1.0 - REBELLION_FUSE)
	if world.rng_pool.get_rng("rebellion").randf() > pressure * REBELLION_CHANCE:
		return
	spawn_rebellion(world, p, n)


## 이미 같은 모국에서 갈라져 나와 싸우고 있는 인접 반란국이 있으면 거기 합류한다.
## 없으면 새 반란국을 세운다. 합류가 없으면 반란국은 영원히 1프로빈스라
## 반란전 warscore·recognition 이 둘 다 이진값이 되어 의미를 잃는다.
static func spawn_rebellion(world: WorldState, p: Province, n: Nation) -> void:
	var existing := _adjacent_rebellion(world, p, n)
	if existing != null:
		join_rebellion(world, p, n, existing)
		return
	spawn_new_rebellion(world, p, n)


## 결정론 (§15): 후보가 여럿이면 국가 id 가 낮은 쪽.
static func _adjacent_rebellion(world: WorldState, p: Province, n: Nation) -> Nation:
	var best: Nation = null
	for nb: int in p.land_neighbors:
		var owner := world.provinces[nb].owner_nation
		if owner < 0:
			continue
		var r: Nation = world.nations[owner]
		if not r.is_alive or not r.is_rebel or r.rebel_origin != n.id:
			continue
		if not Diplomacy.are_at_war(world, n.id, r.id):
			continue
		if best == null or r.id < best.id:
			best = r
	return best


static func join_rebellion(world: WorldState, p: Province, n: Nation,
		rebel: Nation) -> void:
	var origin := _origin_snapshot(p, n)
	_transfer_province(world, p, n, rebel)
	p.unrest = REBEL_START_UNREST
	p.integration = 1.0
	_recompute_capital_distances(world, rebel)
	var troops := _raise_rebel_troops(world, p, rebel)
	# 합류한 땅의 생산도 반란국 경제에 들어간다.
	rebel.money_supply += p.gdp
	rebel.prev_money_supply = rebel.money_supply
	rebel.real_gdp += p.gdp
	rebel.prev_real_gdp = rebel.real_gdp

	var war := Diplomacy.war_between(world, n.id, rebel.id)
	if war != null and not war.rebel_origin_provinces.has(p.id):
		war.rebel_origin_provinces.append(p.id)
	_log_rebellion(world, p, n, rebel, origin, true, troops)


## 반란 국가는 프로빈스 문화를 그대로 쓴다 — 왜 갈라섰는지가 곧 정체성이다.
static func spawn_new_rebellion(world: WorldState, p: Province, n: Nation) -> void:
	var rebel := Nation.new()
	rebel.id = world.nations.size()
	rebel.is_rebel = true
	rebel.rebel_origin = n.id
	rebel.culture = p.culture if p.culture >= 0 else n.culture
	rebel.culture_params = Culture.PRESETS[rebel.culture].duplicate()
	rebel.capital = p.id
	# 이름은 봉기 지역에서 나온다. 모국 이름을 물려받으면 같은 나라에서 반란이
	# 두 번 날 때 이름이 겹친다. 모국은 기록 줄에만 남는다.
	rebel.name = NationPlacer.rebel_name(world.nations, rebel.culture, p.id)
	# 부모의 법률을 물려받지 않는다. 가혹한 법에 반발해 갈라선 세력이
	# 같은 법을 그대로 쓰면 자기 땅에서 또 반란이 나는 자기증식이 된다.
	LawSystem.adopt_for(rebel)
	world.nations.append(rebel)

	var origin := _origin_snapshot(p, n)

	_transfer_province(world, p, n, rebel)
	p.unrest = REBEL_START_UNREST
	p.integration = 1.0
	p.distance_from_capital = 0.0
	p.is_exclave = false

	var troops := _raise_rebel_troops(world, p, rebel)

	# 반란군은 이미 봉기에 인력을 다 썼다. 소모를 재모병으로 메울 수 없다.
	rebel.manpower = 0.0
	rebel.money_supply = p.gdp
	rebel.prev_money_supply = rebel.money_supply
	rebel.real_gdp = p.gdp
	rebel.prev_real_gdp = p.gdp

	_log_rebellion(world, p, n, rebel, origin, false, troops)
	# 마지막 영토를 잃고 이미 소멸한 나라는 진압 전쟁을 시작할 수 없다.
	if not n.is_alive:
		return
	var war := Diplomacy.declare_war(world, n, rebel, "rebellion")
	war.is_rebel_war = true
	war.parent_nation_id = n.id
	war.rebel_nation_id = rebel.id
	war.rebel_origin_provinces = PackedInt32Array([p.id])
	war.rebel_capital_province = p.id


## 봉기 원인은 이전(移轉) 전 상태에 있다. 전이가 거리·월경지를 리셋하므로
## 진단용 값은 반드시 그 전에 떠 둔다.
static func _origin_snapshot(p: Province, n: Nation) -> Dictionary:
	return {
		"distance": p.distance_from_capital,
		"exclave": p.is_exclave,
		"drift": drift(p, n),
		"garrison": p.garrison_ratio,
	}


## 반란 규모는 프로빈스 인구에서 나온다. 도시는 ×3 (§10).
static func _raise_rebel_troops(world: WorldState, p: Province, rebel: Nation) -> int:
	var troops := p.population * REBEL_TROOP_RATIO
	if p.has_city:
		troops *= REBEL_CITY_MULT
	Military.create_army(world, rebel, p.id, int(troops))
	return int(troops)


static func _log_rebellion(world: WorldState, p: Province, n: Nation, rebel: Nation,
		origin: Dictionary, joined: bool, troops: int) -> void:
	world.log_event("rebellion", {
		"nation": n.id,
		"rebel": rebel.id,
		"province": p.id,
		"joined": joined,
		"troops": troops,
		"city": p.has_city,
		"exclave": origin["exclave"],
		"island": p.is_island,
		"distance": origin["distance"],
		"drift": origin["drift"],
		"garrison": origin["garrison"],
		"inflation": n.inflation,
		"culture_distance": p.culture_distance(n.culture),
		"from_rebel": n.is_rebel,
		"owner_provinces": n.provinces.size() + 1,
	})


## 진압 성공. 반란국은 협상 없이 땅을 토해낸다.
static func reclaim_from_rebel(world: WorldState, p: Province, rebel: Nation,
		winner: Nation) -> void:
	p.occupied_by_nation = -1
	_transfer_province(world, p, rebel, winner)
	p.unrest = minf(p.unrest, REINTEGRATION_UNREST)
	p.integration = minf(p.integration, REINTEGRATION_INTEGRATION)
	p.rebellion_grace_turns = REINTEGRATION_GRACE_TURNS
	# 재통합이 되돌려 놓은 값 위에 진압의 대가를 얹는다. 순서가 반대면
	# integration 리셋이 분리주의의 통합 삭감을 통째로 지운다.
	register_suppression(world, p, SEPARATISM_SUPPRESSION)
	_recompute_capital_distances(world, winner)
	world.log_event("rebellion_suppressed", {
		"nation": winner.id,
		"rebel": rebel.id,
		"province": p.id,
	})


static func _transfer_province(world: WorldState, p: Province, from: Nation,
		to: Nation) -> void:
	# n.provinces 는 owner_nation 의 파생 색인이므로 집합이어야 한다.
	# Array.erase 는 첫 항목만 지운다 — 중복이 한 번 생기면 영영 남고,
	# Economy._rebalance 가 그 프로빈스를 유출입에 여러 번 세면서 적용은 한 번만
	# 해 인구 보존이 깨진다 (M10 §3.4).
	while from.provinces.has(p.id):
		from.provinces.erase(p.id)
	if not to.provinces.has(p.id):
		to.provinces.append(p.id)
	p.owner_nation = to.id
	p.assimilation = 0.0
	p.occupied_by_nation = -1
	p.siege_progress = 0.0
	p.siege_by_nation = -1
	from.supply_dirty = true
	to.supply_dirty = true
	if from.capital == p.id:
		recompute_capital(world, from)
	if from.provinces.is_empty():
		kill_nation(world, from)


## 수도가 유효하면 거리만 다시 잰다. 잃었을 때만 남은 땅 중 인구 최대 프로빈스로
## 옮긴다. 동점은 id 로 깬다 (§15).
static func recompute_capital(world: WorldState, n: Nation) -> void:
	if n.capital >= 0 and world.provinces[n.capital].owner_nation == n.id:
		_recompute_capital_distances(world, n)
		return
	var best := -1
	var best_pop := -1.0
	for pid in n.provinces:
		var pop: float = world.provinces[pid].population
		if pop > best_pop or (pop == best_pop and pid < best):
			best_pop = pop
			best = pid
	n.capital = best
	if best < 0:
		return
	world.log_event("capital_moved", {"nation": n.id, "province": best})
	_recompute_capital_distances(world, n)


## 국경이 바뀌면 수도 거리도 바뀐다. 건설비(§4.4)와 불만(§10)이 이 값을 쓴다.
static func _recompute_capital_distances(world: WorldState, n: Nation) -> void:
	if n.capital < 0:
		return
	var dist := {n.capital: 0}
	var queue: Array[int] = [n.capital]
	var head := 0
	while head < queue.size():
		var cur: int = queue[head]
		head += 1
		for nb: int in world.provinces[cur].land_neighbors:
			if world.provinces[nb].owner_nation != n.id or dist.has(nb):
				continue
			dist[nb] = int(dist[cur]) + 1
			queue.append(nb)
	for pid in n.provinces:
		var p: Province = world.provinces[pid]
		if dist.has(pid):
			p.distance_from_capital = float(dist[pid])
			p.is_exclave = false
		else:
			p.is_exclave = true
			p.distance_from_capital = minf(p.centroid.distance_to(
				world.provinces[n.capital].centroid) * 0.5, NationPlacer.EXCLAVE_DIST_CAP)


static func kill_nation(world: WorldState, n: Nation) -> void:
	EmpireSystem.on_nation_death(world, n)
	n.is_alive = false
	n.capital = -1
	# 죽은 나라의 점령은 풀린다. 안 풀면 그 땅은 영영 통행·보급 불가가 된다.
	for p in world.provinces:
		if p.occupied_by_nation == n.id:
			p.occupied_by_nation = -1
			world.nations[p.owner_nation].supply_dirty = true
		if p.siege_by_nation == n.id:
			p.siege_by_nation = -1
			p.siege_progress = 0.0
	for army_id in n.armies:
		var army: Army = world.armies[army_id]
		army.is_alive = false
		army.troops = 0
	for war_id in n.wars.duplicate():
		var war: War = world.wars[war_id]
		# 진압 전쟁이 협상이 아니라 전멸로 끝나는 경로. 여기서 안 남기면
		# 반란전 종료 통계에 전멸 건이 통째로 빠진다.
		if war.is_active and war.is_rebel_war:
			Peace.log_rebel_war_end(world, war,
				"annihilated" if war.rebel_nation_id == n.id else "parent_collapsed")
		Diplomacy.end_war(world, war, "annihilated")
	world.log_event("nation_died", {"nation": n.id, "rebel": n.is_rebel})
