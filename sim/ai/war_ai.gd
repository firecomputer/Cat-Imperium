class_name WarAI extends RefCounted

## 군대 편성·이동·공성 판단 (설계서에 절이 없어 여기서 규격을 정한다).
##
## 원칙 세 가지:
##   1. 전선은 여럿이다 — 적과 접한 자국 프로빈스마다 군대를 하나씩 보낸다.
##   2. 전투는 한 턴에 끝나지 않는다 — 매 턴 12%씩 깎이고 사기가 무너져야 물러난다.
##   3. 방어 측이 유리하다 — 지형·요새·주둔이 수비에 곱해진다. 공격은 비싸야 한다.

## 야전군 상한은 국토 크기가 정한다 (M14 §2). 고정 4 는 소국과 대제국에 같은
## 편성 폭을 줬고, 병력 총량이 GDP 에 비례하므로 큰 나라가 전선마다 더 두꺼운
## 군대를 세우는 일방적 이점이 됐다. 이제 영토가 늘면 관리 단위가 흩어진다.
const ARMY_CAP_PER_PROVINCE := 4
const ARMY_CAP_MIN := 2
const ARMY_CAP_MAX := 8
const MIN_ARMY_TROOPS := 200              # 이보다 작게는 쪼개지 않는다
const RETREAT_MORALE := 0.35
const RETREAT_TROOP_RATIO := 0.35         # 최대 병력 대비 이 아래면 퇴각
const RECOVER_MORALE := 0.65              # 이 사기를 되찾기 전에는 전선에 돌아가지 않는다
const STARVE_SUPPLY := 0.15               # 이 아래로 굶으면 목표를 버리고 물러난다
const LANDING_MORALE := 0.85              # 상륙 직후 사기 배율. 바다를 건너는 건 공짜가 아니다
## 바다 한 칸은 승선 1턴 + 상륙 1턴이다. 경로 비교에서 육로 두 칸과 같은 값을 쓴다.
const SEA_HOPS := 2.0
## 적 야전군이 서 있는 전선을 홉 환산으로 이만큼 당겨온다. 빈 적지를 밟는 것보다
## 적 부대를 잡는 것이 먼저다 — 이게 없으면 양쪽 군대가 서로를 지나쳐 영토만
## 맞바꾼다 (실측: 내 땅에 앉은 적군의 83% 가 아무도 안 붙은 채 공성했다).
const ENEMY_ARMY_PRIORITY := 3.0
## 이미 다른 아군이 맡은 전선에 붙는 비용. 빈 땅은 사실상 금지(각자 다른 전선),
## 적 부대가 있는 곳은 싸게 매겨 협격을 허용한다.
const DUP_FRONT_PENALTY := 100.0
const DUP_STACK_PENALTY := 2.0
## 전선 진입 문턱. 이만한 전력이 안 되면 적 칸에 발을 들이지 않고 앞에서 기다린다.
## 턴이 이산이라 한 번 붙으면 이동도 공성도 그 자리에서 멈춘다 — 지는 나라가
## 매 턴 소부대를 뽑아 던지면 사단 하나가 몇 턴씩 묶였다 (실측: 교전 군대-턴의
## 39% 가 "압도적 우세인데 소부대에 묶임", 45% 가 절망적 열세의 돌격이었다).
const ENGAGE_MIN_POWER_RATIO := 0.6
## 같은 칸에서 벌어지는 교전은 이동보다 먼저 해결한다. 아주 작은 잔병은 대군의
## 행군까지 묶지 못하게 하되, 이 값은 공성 진행 여부에는 사용하지 않는다.
const PIN_MIN_TROOP_RATIO := 0.25

const TERRAIN_DEFENSE := {
	Province.Terrain.PLAIN: 1.0,
	Province.Terrain.HILL: 1.2,
	Province.Terrain.MOUNTAIN: 1.45,
}
const INFRA_DEFENSE := 0.04               # 인프라 1 당 방어력 +4% (요새 대용)
const CITY_DEFENSE := 1.25

const SIEGE_BASE := 30.0                  # 진행도 100 에서 점령 성립
const SIEGE_INFRA_RESIST := 0.35
const SIEGE_CITY_RESIST := 2.0
const SIEGE_TROOP_NORM := 0.01            # 인구의 1% 병력이면 표준 속도
const SIEGE_UNREST_HELP := 0.6            # 불만이 높은 땅은 빨리 넘어온다

# ---------------------------------------------------------------- 치안 주둔 (M8.5 §2)
## 이 값 미만은 평시 주둔 후보에서 제외한다. unrest 가 가장 큰 비중을 차지해야 한다.
const GARRISON_NEED_MIN := 0.35
const GARRISON_NEED_EXCLAVE := 0.15
const GARRISON_NEED_DISTANCE := 0.025
const GARRISON_NEED_DISTANCE_CAP := 0.20
const GARRISON_NEED_CITY := 0.15
## 치안에 묶을 수 있는 전체 병력의 상한. 주둔군은 무료 안정도 버프가 아니라
## 군사력의 기회비용이다 — 전쟁이 나면 대부분 전선으로 빠져나간다.
const GARRISON_ARMY_SHARE_PEACE := 0.25
const GARRISON_ARMY_SHARE_WAR := 0.08
## 야전군 상한(army_cap)과 별개다. 치안 분견대는 전선에 서지 않는다.
const GARRISON_MAX_DETACHMENTS := 6
## 분견대 최소 크기. MIN_ARMY_TROOPS(200) 는 야전군 분할 기준이라 여기 쓰면
## 중앙값 국가(총병력 139)는 분견대를 하나도 못 만든다. 부분 주둔도 허용해야
## 한다 — 하한이 20 이면 치안 목표가 있는 국가-턴의 76% 가 예산 부족으로 탈락했다.
const GARRISON_MIN_TROOPS := 5

# ---------------------------------------------------------------- 진압 의지 (M14 §5)
## 분리주의가 내각의 진압 의지를 넘어선 만큼이 정치적 마찰이 된다.
const GARRISON_RELUCTANCE := 0.5
const FRONT_RELUCTANCE := 4.0


## 국토가 클수록 전선을 더 많이 벌릴 수 있지만, 선형이 아니다.
static func army_cap(n: Nation) -> int:
	return clampi(n.provinces.size() / ARMY_CAP_PER_PROVINCE, ARMY_CAP_MIN, ARMY_CAP_MAX)


## 진압을 꺼리는 정도. 0 이면 망설임 없이 군대를 보낸다.
static func suppression_reluctance(p: Province, n: Nation) -> float:
	return maxf(p.separatism - n.suppression_will, 0.0)


static func plan(world: WorldState) -> void:
	world.rebuild_army_index()
	var occupied := _occupied_index(world)
	for n in world.nations:
		if not n.is_alive:
			continue
		# §2.7 전선 → 치안 예산 → 주둔 순. 치안 때문에 전선이 붕괴하면 안 된다.
		_resolve_landings(world, n)
		var fronts := _fronts(world, n, occupied)
		_organize(world, n, fronts.size())
		_assign_targets(world, n, fronts)
		_garrison(world, n)
		_move(world, n)


## 점령지 색인 (점령국 id -> 프로빈스). 국가마다 전 프로빈스를 훑으면
## 턴당 O(국가 × 프로빈스) 가 되므로 턴에 한 번만 만든다.
static func _occupied_index(world: WorldState) -> Dictionary:
	var out := {}
	for p in world.provinces:
		if p.occupied_by_nation < 0:
			continue
		if not out.has(p.occupied_by_nation):
			out[p.occupied_by_nation] = [] as Array[int]
		out[p.occupied_by_nation].append(p.id)
	return out


## 방어 배율. 프로빈스를 지배 중인 쪽에만 붙는다.
static func defense_mult(p: Province) -> float:
	var m: float = TERRAIN_DEFENSE[p.terrain]
	m *= 1.0 + p.infra * INFRA_DEFENSE
	if p.has_city:
		m *= CITY_DEFENSE
	return m


# ---------------------------------------------------------------- 편성

## 전선 = 지금 칠 수 있는 적 프로빈스. 내 영토에 인접한 적지와,
## 빼앗겨서 되찾아야 할 내 땅이 전부 여기 들어간다.
## 점령지도 내 땅처럼 전선을 뻗는다. 소유 프로빈스에서만 전선을 그리면 국경
## 한 줄을 먹은 뒤 그 너머가 목표에서 사라지고, 야전군은 갈 곳이 없어 수도로
## 돌아간다 — 그 사이 적이 새 군대를 뽑아 걸어 들어와 도로 가져갔다 (실측:
## 점령지에 인접한 적지의 54.8% 가 전선으로 잡히지 않았다).
static func _fronts(world: WorldState, n: Nation,
		occupied: Dictionary = {}) -> Array[int]:
	var out: Array[int] = []
	if not n.at_war:
		return out
	var seen := {}
	var held: Array = n.provinces
	var mine: Array = occupied.get(n.id, [])
	if mine.is_empty() and occupied.is_empty():
		mine = _occupied_index(world).get(n.id, [])
	if not mine.is_empty():
		held = n.provinces.duplicate()
		held.append_array(mine)
	for pid: int in held:
		var p: Province = world.provinces[pid]
		if p.owner_nation == n.id and p.occupied_by_nation >= 0 and not seen.has(pid):
			seen[pid] = true
			out.append(pid)                      # 빼앗긴 내 땅부터 되찾는다
			continue
		if p.controller() != n.id:
			continue
		# 내 땅에 들어와 앉은 적 야전군도 전선이다. 공성이 100 에 닿기 전에는
		# occupied_by_nation 이 비어 있어 예전 규칙으로는 목표가 되지 못했고,
		# 야전군은 침입자를 지나쳐 빈 적지로 행군했다.
		if not seen.has(pid) and _hostile_army_at(world, n.id, pid):
			seen[pid] = true
			out.append(pid)
		for nb: int in p.land_neighbors:
			var q: Province = world.provinces[nb]
			var holder := q.controller()
			if holder < 0 or holder == n.id or seen.has(nb):
				continue
			if Diplomacy.are_at_war(world, n.id, holder):
				seen[nb] = true
				out.append(nb)
		# 제해권을 쥔 바다 건너 적지도 전선이다. 이게 없으면 육로가 닿지 않는
		# 섬 반란은 진압군이 목표로 삼지도 못해 100% 독립한다 (M8.5 §2.1).
		for zone_id: int in p.sea_zone_ids:
			if not n.naval_control_zones.has(zone_id):
				continue
			for landing: int in world.sea_zones[zone_id].coast_provinces:
				var target: Province = world.provinces[landing]
				var owner := target.controller()
				if owner < 0 or owner == n.id or seen.has(landing):
					continue
				if Diplomacy.are_at_war(world, n.id, owner):
					seen[landing] = true
					out.append(landing)
	# 적진 깊숙이 들어간 아군 옆의 적 야전군. 본토에 접한 칸만 전선으로 세우면
	# 국경에서 밀려난 적은 한 칸 물러나는 것만으로 추격을 벗어난다 — 회복해서
	# 다시 나오는 일이 반복되어 전쟁이 소모전으로만 끝난다.
	for a in _field_armies(world, n):
		if a.province_id < 0:
			continue
		for nb: int in world.provinces[a.province_id].land_neighbors:
			if seen.has(nb) or not _passable(world, n, nb):
				continue
			if _hostile_army_at(world, n.id, nb):
				seen[nb] = true
				out.append(nb)
	out.sort()                                    # 결정론 (§15)
	return out


## 전선 수만큼 야전군을 쪼갠다. 전선이 사라지면 다시 합친다.
## 요충지를 눌러 앉는 일은 M8.5 부터 _garrison() 의 치안 분견대가 맡는다.
static func _organize(world: WorldState, n: Nation, front_count: int) -> void:
	var alive := _field_armies(world, n)
	var total := 0
	for a in alive:
		total += a.troops
	if total <= 0:
		return
	var want := clampi(maxi(front_count, 1), 1, army_cap(n))
	want = mini(want, maxi(total / MIN_ARMY_TROOPS, 1))

	while alive.size() > want:
		_merge_smallest(world, alive)
	while alive.size() < want:
		# 편성은 한 턴에 하나씩이다 (M14 §3). 예산은 Military.plan_spending 이
		# 지지도에 비례해 적립한다 — 지지도 0 인 나라는 5턴에 한 번만 쪼갠다.
		# 병합에는 비용을 물리지 않는다. 전선이 사라진 군대는 언제든 합쳐야 한다.
		if n.spawn_credit < 1.0:
			break
		var biggest := _biggest(alive)
		if biggest.troops < MIN_ARMY_TROOPS * 2:
			break
		var split := biggest.troops / 2
		biggest.troops -= split
		var fresh := Military.create_army(world, n, biggest.province_id, split)
		fresh.morale = biggest.morale
		fresh.tech_level = biggest.tech_level
		alive.append(fresh)
		n.spawn_credit -= 1.0

	# 같은 프로빈스에 겹친 군대는 합친다. 잘게 쪼개진 군대는 각개격파당한다.
	var by_province := {}
	for a in _field_armies(world, n):
		if by_province.has(a.province_id):
			_absorb(world, by_province[a.province_id], a)
		else:
			by_province[a.province_id] = a


static func _assign_targets(world: WorldState, n: Nation, fronts: Array[int]) -> void:
	var armies := _field_armies(world, n)
	armies.sort_custom(func(a: Army, b: Army) -> bool: return a.id < b.id)
	if fronts.is_empty():
		for a in armies:
			# 점령지를 비우면 적이 새로 뽑은 군대로 걸어 들어와 도로 가져간다.
			# 칠 곳이 없으면 지금 쥔 땅에 그대로 선다.
			a.target_province = a.province_id if _holds_ground(world, n, a) \
				else n.capital
		return

	var taken := {}
	for a in armies:
		# 굶는 군대는 목표를 버린다. 보급 없는 진격은 그 자리에서 녹는 것뿐이다.
		if a.supply_ratio < STARVE_SUPPLY and not _has_hostile(world, a):
			a.retreating = true
		if a.retreating:
			a.target_province = n.capital       # 후방에서 재편할 때까지 전선에 안 간다
			continue
		# 포위 중이면 끝까지 앉아 있는다. 목표를 갈아타면 공성이 영원히 안 끝난다.
		if _is_besieging(world, a):
			a.target_province = a.province_id
			taken[a.province_id] = int(taken.get(a.province_id, 0)) + 1
			continue
		var best := -1
		var best_cost := INF
		for f in fronts:
			var cost := _hops(world, n, a.province_id, f)
			cost += suppression_reluctance(world.provinces[f], n) * FRONT_RELUCTANCE
			var manned := _hostile_army_at(world, n.id, f)
			if manned:
				cost -= ENEMY_ARMY_PRIORITY
			if taken.has(f):
				# 빈 전선은 나눠 맡고, 적 부대가 선 전선에는 겹쳐 붙는다.
				cost += (DUP_STACK_PENALTY * int(taken[f])) if manned \
					else DUP_FRONT_PENALTY
			if cost < best_cost:
				best_cost = cost
				best = f
		a.target_province = best if best >= 0 else n.capital
		taken[a.target_province] = int(taken.get(a.target_province, 0)) + 1


## 지금 서 있는 칸을 이 나라가 쥐고 있는가 (자국 영토든 점령지든).
static func _holds_ground(world: WorldState, n: Nation, army: Army) -> bool:
	if army.province_id < 0:
		return false
	return world.provinces[army.province_id].controller() == n.id


## 치안 수요 (§2.3). unrest 가 지배항이고 나머지는 이미 설계된 위험 특성이다.
static func garrison_need(p: Province, n: Nation) -> float:
	var score := p.unrest
	score += GARRISON_NEED_EXCLAVE if p.is_exclave else 0.0
	score += minf(p.distance_from_capital * GARRISON_NEED_DISTANCE, GARRISON_NEED_DISTANCE_CAP)
	score += GARRISON_NEED_CITY if p.has_city else 0.0
	# 비둘기 내각은 분리주의가 끓는 땅을 눌러 앉히기를 꺼린다. GARRISON_NEED_MIN
	# 아래로 떨어지면 후보에서 아예 빠져 그 땅은 주둔 없이 방치된다.
	score -= suppression_reluctance(p, n) * GARRISON_RELUCTANCE
	return maxf(score, 0.0)


## 위험한 순으로 자른 주둔 후보. 동점은 unrest, 그 다음 id 로 깬다 (§15).
static func garrison_targets(world: WorldState, n: Nation) -> Array[int]:
	var scored: Array = []
	for pid in n.provinces:
		var p: Province = world.provinces[pid]
		if p.controller() != n.id:
			continue
		var need := garrison_need(p, n)
		if need < GARRISON_NEED_MIN:
			continue
		scored.append({"pid": pid, "need": need, "unrest": p.unrest})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(a["need"], b["need"]):
			return a["need"] > b["need"]
		if not is_equal_approx(a["unrest"], b["unrest"]):
			return a["unrest"] > b["unrest"]
		return int(a["pid"]) < int(b["pid"]))
	var out: Array[int] = []
	for e: Dictionary in scored:
		if out.size() >= GARRISON_MAX_DETACHMENTS:
			break
		out.append(int(e["pid"]))
	return out


## 평시 치안 주둔 (§2). §10 의 garrison_ratio 항은 군대를 전선에만 두면 죽은 값이다.
## 분견대는 새로 뽑는 병력이 아니라 기존 병력에서 떼어낸다 — 그래야 군사비가
## 늘지 않고 "치안 = 전선 병력의 기회비용"이 성립한다.
static func _garrison(world: WorldState, n: Nation) -> void:
	var reach := _reachable(world, n, n.capital)
	var targets := garrison_targets(world, n)
	var rank := {}
	for i in range(targets.size()):
		rank[targets[i]] = i

	# 더 이상 위험하지 않은 곳의 분견대는 야전군으로 돌려보낸다.
	var held: Array[Army] = []
	for a in _alive_armies(world, n):
		if a.garrison_province < 0:
			continue
		if rank.has(a.garrison_province):
			held.append(a)
		else:
			a.garrison_province = -1
	# 오래된 분견대부터 예산을 준다. 매 턴 바뀌는 위험 순위로 정렬하면 순위가
	# 한 칸 흔들릴 때마다 해산·재편성이 반복되어 분견대가 목적지에 영영 못 간다
	# (실측: 배정 62% 중 도착 9%). 이미 배치된 부대의 자리를 지켜준다.
	held.sort_custom(func(x: Army, y: Army) -> bool: return x.id < y.id)

	var budget := int(Military.total_troops(world, n) \
		* (GARRISON_ARMY_SHARE_WAR if n.at_war else GARRISON_ARMY_SHARE_PEACE))
	var spent := 0
	var covered := {}
	for a in held:
		var over := covered.has(a.garrison_province) or spent + a.troops > budget
		# 육로가 닿지 않는 곳의 분견대는 풀어줘도 전선에 못 간다. 야전군으로
		# 되돌리면 편성에만 잡히는 유령 병력이 되므로 자리를 지키게 둔다.
		if over and reach.has(a.province_id):
			a.garrison_province = -1        # 예산 초과분은 우선순위 낮은 쪽부터 해제
			continue
		spent += a.troops
		covered[a.garrison_province] = true

	for pid in targets:
		if covered.has(pid):
			continue
		var want := mini(int(Unrest.required_garrison(world.provinces[pid])), budget - spent)
		if want < GARRISON_MIN_TROOPS:
			break
		var src := _garrison_source(world, n, pid, want, reach)
		if src == null:
			continue
		# 육로가 닿지 않는 자국 영토(섬·월경지)에는 현지 주둔으로 바로 세운다.
		# 행군시키면 분견대가 영영 도착하지 못한 채 치안 예산만 묶는다 (실측 도착률 9%).
		# 이 세계 반란의 75%가 섬에서 나고 소유국이 그 바다 제해권을 쥔 비율은 1% 라,
		# 행군만 허용하면 치안 자체가 성립하지 않는다. 전시·교전 중에는 금지해
		# 포위된 거점에 병력이 순간이동하는 우회로가 되지 않게 한다.
		var direct := not reach.has(pid)
		if direct and not _can_post_directly(world, n, pid):
			continue
		src.troops -= want
		var det := Military.create_army(world, n, pid if direct else src.province_id, want)
		det.morale = src.morale
		det.tech_level = src.tech_level
		det.garrison_province = pid
		spent += want
		covered[pid] = true

	for a in _alive_armies(world, n):
		if a.garrison_province >= 0:
			a.target_province = a.garrison_province
			a.retreating = false


## 현지 주둔을 허용할 조건. 평시의 온전한 자국 영토에만 허용한다.
static func _can_post_directly(world: WorldState, n: Nation, pid: int) -> bool:
	if n.at_war:
		return false
	var p: Province = world.provinces[pid]
	if p.controller() != n.id or p.siege_by_nation >= 0:
		return false
	for other_id: int in world.armies_at(pid):
		var other: Army = world.armies[other_id]
		if other.is_alive and other.nation_id != n.id:
			return false
	return true


## 분견대를 떼어낼 야전군. 이미 그 자리에 있는 부대를 먼저 쓰고, 없으면 가장 큰
## 부대에서 뗀다. 야전군을 껍데기로 만들지 않는다 (MIN_ARMY_TROOPS 보장).
static func _garrison_source(world: WorldState, n: Nation, pid: int, want: int,
		reach: Dictionary) -> Army:
	var best: Army = null
	for a in _field_armies(world, n):
		# 야전군 하나에서 절반 넘게 떼지 않는다. 국가 단위 상한은 치안 예산이 잡는다.
		if a.troops - want < want or not reach.has(a.province_id):
			continue
		if best == null or _better_source(a, best, pid):
			best = a
	return best


static func _better_source(a: Army, b: Army, pid: int) -> bool:
	var here_a := a.province_id == pid
	var here_b := b.province_id == pid
	if here_a != here_b:
		return here_a
	if a.troops != b.troops:
		return a.troops > b.troops
	return a.id < b.id


# ---------------------------------------------------------------- 이동

static func _move(world: WorldState, n: Nation) -> void:
	for a in _alive_armies(world, n):
		if a.retreating and a.morale >= RECOVER_MORALE \
				and a.troops >= int(a.peak_troops * 0.6):
			a.retreating = false
		if a.province_id == a.target_province or a.target_province < 0:
			continue
		if _pinned_by_hostile(world, a):
			# 이길 수 없는 싸움에서는 빠진다. 이산 턴에서는 한 번 붙으면 이동도
			# 공성도 그 자리에서 멈추므로, 열세 부대가 버티면 제 병력만 갈리면서
			# 적을 묶어 두는 소모품이 된다 (실측: 압도적 우세군이 중앙값 14명짜리
			# 부대에 붙잡힌 것이 교전 군대-턴의 37%).
			if a.garrison_province < 0 and _outgunned(world, a):
				_withdraw(world, n, a)
			continue                          # 교전 중에는 이동하지 않는다
		var step := _next_step(world, n, a.province_id, a.target_province)
		if step >= 0 and not _can_engage(world, a, step):
			continue                          # 전력이 모일 때까지 전선 앞에서 기다린다
		if step >= 0 and _is_sea_step(world, a.province_id, step):
			_embark(world, n, a, step)
			continue
		if step < 0:
			# 진격로가 뒤에서 갈라져 나가 길이 끊긴 경우. 굶고 있으면 억류된다 —
			# 갇힌 군대를 그대로 두면 영원히 녹지 않는 좀비가 된다.
			if a.supply_ratio < STARVE_SUPPLY and not _has_passable_neighbor(world, n, a):
				_intern(world, a)
			continue
		world.move_army_index(a.id, a.province_id, step)
		a.province_id = step


## 전력이 모일 때까지 뒤로 뺀다. 적이 없고 내가 쥔 인접 칸 중 수도에 가까운
## 쪽으로 한 칸 물러난다. 갈 곳이 없으면 그 자리에서 싸운다.
static func _withdraw(world: WorldState, n: Nation, army: Army) -> void:
	var best := -1
	var best_cost := INF
	for nb: int in world.provinces[army.province_id].land_neighbors:
		if world.provinces[nb].controller() != n.id:
			continue
		if _hostile_army_at(world, n.id, nb):
			continue
		var cost := _hops(world, n, nb, n.capital)
		if cost < best_cost:
			best_cost = cost
			best = nb
	if best < 0:
		return
	world.move_army_index(army.id, army.province_id, best)
	army.province_id = best
	world.log_event("army_withdrew", {
		"nation": n.id,
		"army": army.id,
		"to": best,
		"troops": army.troops,
	})


## 승선. 한 턴을 바다에서 보내고 다음 턴에 내린다 — 그 사이 제해권을 잃으면 격침이다.
## 이 한 턴이 "제해권을 쥐어야 바다를 건넌다"를 관전에서 읽히게 만든다 (§12.4).
static func _embark(world: WorldState, n: Nation, army: Army, target: int) -> void:
	var zone := _crossing_zone(world, n, army.province_id, target)
	if zone < 0:
		return                                # 제해권을 잃었으면 그 자리에 선다
	world.remove_army_index(army.id, army.province_id)
	world.log_event("embarked", {
		"nation": n.id,
		"army": army.id,
		"from": army.province_id,
		"to": target,
		"zone": zone,
		"troops": army.troops,
		"garrison": army.garrison_province >= 0,
	})
	army.at_sea_zone = zone
	army.landing_target = target
	army.province_id = -1


## 양쪽 연안이 공유하는 해역 중 내가 제해권을 쥔 것. 동점은 id 가 낮은 쪽 (§15).
static func _crossing_zone(world: WorldState, n: Nation, from: int, to: int) -> int:
	var shared: Array[int] = []
	for zone_id: int in world.provinces[from].sea_zone_ids:
		if not n.naval_control_zones.has(zone_id):
			continue
		if zone_id in world.provinces[to].sea_zone_ids:
			shared.append(zone_id)
	if shared.is_empty():
		return -1
	shared.sort()
	return shared[0]


## 바다에 떠 있는 부대를 먼저 처리한다. 아직 그 바다를 쥐고 있으면 내리고,
## 뺏겼으면 수송선단째 가라앉는다.
static func _resolve_landings(world: WorldState, n: Nation) -> void:
	for army_id in n.armies:
		var a: Army = world.armies[army_id]
		if not a.is_alive or a.at_sea_zone < 0:
			continue
		var zone := a.at_sea_zone
		if not n.naval_control_zones.has(zone):
			_sink(world, a, zone)
			continue
		a.province_id = a.landing_target
		a.at_sea_zone = -1
		a.landing_target = -1
		a.morale = maxf(Military.MORALE_FLOOR, a.morale * LANDING_MORALE)
		world.add_army_index(a.id, a.province_id)
		world.log_event("amphibious_landing", {
			"nation": n.id,
			"army": a.id,
			"to": a.province_id,
			"zone": zone,
			"troops": a.troops,
			"garrison": a.garrison_province >= 0,
		})


## 제해권을 잃은 바다 위의 수송선단. 설계서 §12.4 "제해권 상실 시 전멸"의 실물이다.
static func _sink(world: WorldState, army: Army, zone: int) -> void:
	world.log_event("convoy_sunk", {
		"nation": army.nation_id,
		"army": army.id,
		"zone": zone,
		"to": army.landing_target,
		"troops": army.troops,
	})
	army.at_sea_zone = -1
	army.landing_target = -1
	Military.destroy_army(world, army, "convoy_sunk")


## 자국·점령지·교전국 영토를 통과할 수 있다. 중립국 영토는 못 지나간다.
static func _passable(world: WorldState, n: Nation, pid: int) -> bool:
	var p: Province = world.provinces[pid]
	var holder := p.controller()
	if holder < 0 or holder == n.id:
		return true
	return Diplomacy.are_at_war(world, n.id, holder)


static func _next_step(world: WorldState, n: Nation, from: int, to: int) -> int:
	var prev := _bfs(world, n, from, to)
	if not prev.has(to):
		return -1
	var cur := to
	while int(prev[cur]) != from:
		cur = int(prev[cur])
	return cur


static func _hops(world: WorldState, n: Nation, from: int, to: int) -> float:
	if from == to:
		return 0.0
	var prev := _bfs(world, n, from, to)
	if not prev.has(to):
		return INF
	var steps := 0.0
	var cur := to
	while cur != from:
		var back := int(prev[cur])
		steps += SEA_HOPS if _is_sea_step(world, back, cur) else 1.0
		cur = back
	return steps


## 이 나라 군대가 실제로 걸어갈 수 있는 프로빈스 집합. 목표마다 BFS 를 돌리면
## 국가·턴당 수십 번이 되므로 턴당 한 번만 만든다.
static func _reachable(world: WorldState, n: Nation, from: int) -> Dictionary:
	var seen := {}
	if from < 0:
		return seen
	seen[from] = true
	var queue: Array[int] = [from]
	var head := 0
	while head < queue.size():
		var cur: int = queue[head]
		head += 1
		for nb: int in _neighbors(world, n, cur):
			if seen.has(nb) or not _passable(world, n, nb):
				continue
			seen[nb] = true
			queue.append(nb)
	return seen


static func _bfs(world: WorldState, n: Nation, from: int, to: int) -> Dictionary:
	var prev := {}
	var queue: Array[int] = [from]
	var head := 0
	var seen := {from: true}
	while head < queue.size():
		var cur: int = queue[head]
		head += 1
		if cur == to:
			break
		for nb: int in _neighbors(world, n, cur):
			if seen.has(nb) or not _passable(world, n, nb):
				continue
			seen[nb] = true
			prev[nb] = cur
			queue.append(nb)
	return prev


## 육상 인접 + 제해권을 쥔 **같은 해역**의 연안. 해역은 지도의 한 조각이라
## 상륙이 근해 도하가 된다 — 예전처럼 지구 반대편으로 1홉 순간이동하지 않는다.
static func _neighbors(world: WorldState, n: Nation, pid: int) -> Array[int]:
	var p: Province = world.provinces[pid]
	var out: Array[int] = []
	out.append_array(p.land_neighbors)
	if p.controller() != n.id:
		return out                                # 발판이 없으면 배를 탈 수 없다
	for zone_id: int in p.sea_zone_ids:
		if not n.naval_control_zones.has(zone_id):
			continue
		for landing: int in world.sea_zones[zone_id].coast_provinces:
			if landing != pid:
				out.append(landing)
	return out


static func _is_sea_step(world: WorldState, from: int, to: int) -> bool:
	return not world.provinces[from].land_neighbors.has(to)


# ---------------------------------------------------------------- 유틸

## 승선 중인 부대는 어느 프로빈스에도 없으므로 이동·주둔 판정에서 빠진다.
static func _alive_armies(world: WorldState, n: Nation) -> Array[Army]:
	var out: Array[Army] = []
	for army_id in n.armies:
		var a: Army = world.armies[army_id]
		if a.is_alive and a.at_sea_zone < 0:
			out.append(a)
	return out


## 치안 분견대를 뺀 야전군. 편성·전선 배치는 이쪽만 본다.
## 승선 중인 부대도 뺀다 — 목표 재배정에 끌려들어가면 바다 위에서 목적지가 바뀐다.
static func _field_armies(world: WorldState, n: Nation) -> Array[Army]:
	var out: Array[Army] = []
	for army_id in n.armies:
		var a: Army = world.armies[army_id]
		if a.is_alive and a.garrison_province < 0 and a.at_sea_zone < 0:
			out.append(a)
	return out


static func _has_passable_neighbor(world: WorldState, n: Nation, army: Army) -> bool:
	for nb: int in _neighbors(world, n, army.province_id):
		if _passable(world, n, nb):
			return true
	return false


static func _intern(world: WorldState, army: Army) -> void:
	world.log_event("army_interned", {
		"nation": army.nation_id,
		"army": army.id,
		"province": army.province_id,
		"troops": army.troops,
	})
	Military.destroy_army(world, army, "interned")


static func _is_besieging(world: WorldState, army: Army) -> bool:
	if army.province_id < 0:
		return false
	var p: Province = world.provinces[army.province_id]
	var holder := p.controller()
	if holder < 0 or holder == army.nation_id:
		return false
	if not Diplomacy.are_at_war(world, army.nation_id, holder):
		return false
	return true


## 다음 칸에 발을 들일 만한 전력인가. 방어 배율은 그 칸을 지배하는 쪽에 붙는다.
static func _can_engage(world: WorldState, army: Army, pid: int) -> bool:
	var p: Province = world.provinces[pid]
	var enemy := 0.0
	for other_id: int in world.armies_at(pid):
		var other: Army = world.armies[other_id]
		if not other.is_alive:
			continue
		if not Diplomacy.are_at_war(world, army.nation_id, other.nation_id):
			continue
		var mult := defense_mult(p) if p.controller() == other.nation_id else 1.0
		enemy += Military.combat_power(world, other) * mult
	if enemy <= 0.0:
		return true
	return Military.combat_power(world, army) >= enemy * ENGAGE_MIN_POWER_RATIO


## 지금 서 있는 칸에서 이길 가망이 없는가.
static func _outgunned(world: WorldState, army: Army) -> bool:
	return not _can_engage(world, army, army.province_id)


static func _has_hostile(world: WorldState, army: Army) -> bool:
	return _hostile_army_at(world, army.nation_id, army.province_id)


## 이 부대를 그 자리에 묶어 둘 만한 적이 있는가. 존재만 보면 5명짜리 부대가
## 사단 하나의 행군을 무한정 멈춘다. 그 아래는 스쳐 지나갈 수 있는 잔병이다.
static func _pinned_by_hostile(world: WorldState, army: Army) -> bool:
	var enemy := 0
	for other_id: int in world.armies_at(army.province_id):
		var other: Army = world.armies[other_id]
		if not other.is_alive:
			continue
		if Diplomacy.are_at_war(world, army.nation_id, other.nation_id):
			enemy += other.troops
	return enemy > 0 and enemy >= int(army.troops * PIN_MIN_TROOP_RATIO)


static func _hostile_army_at(world: WorldState, nation_id: int, pid: int) -> bool:
	for other_id: int in world.armies_at(pid):
		var other: Army = world.armies[other_id]
		if not other.is_alive:
			continue
		if Diplomacy.are_at_war(world, nation_id, other.nation_id):
			return true
	return false


static func _biggest(armies: Array[Army]) -> Army:
	var best: Army = armies[0]
	for a in armies:
		if a.troops > best.troops or (a.troops == best.troops and a.id < best.id):
			best = a
	return best


static func _merge_smallest(world: WorldState, armies: Array[Army]) -> void:
	var small: Army = armies[0]
	for a in armies:
		if a.troops < small.troops or (a.troops == small.troops and a.id < small.id):
			small = a
	armies.erase(small)
	_absorb(world, _biggest(armies), small)


## 병력·사기·장비 품질을 인원 가중 평균으로 흡수한다.
static func _absorb(world: WorldState, keep: Army, gone: Army) -> void:
	var total := keep.troops + gone.troops
	if total > 0:
		keep.morale = (keep.morale * keep.troops + gone.morale * gone.troops) / float(total)
		keep.tech_level = (keep.tech_level * keep.troops \
			+ gone.tech_level * gone.troops) / float(total)
	keep.troops = total
	keep.peak_troops = maxi(keep.peak_troops, keep.troops)
	gone.troops = 0
	gone.is_alive = false
	Military.release_general(world, gone)
