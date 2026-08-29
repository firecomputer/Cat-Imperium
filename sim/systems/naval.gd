class_name Naval extends RefCounted

## 해군과 제해권. 설계서에 해군 절이 없어 여기서 규격을 정한다.
##
## 추상화: 함대는 프로빈스가 아니라 해역(SeaZone)에 존재하고, 그 안에서만 싸운다.
## 해역 그래프 위를 한 턴에 한 칸 움직이므로 "어느 바다를 누가 쥐고 있는가"가
## 국지적이고 다툴 수 있는 값이 된다 — 그래야 해상 보급(§8)과 상륙(§12.3)이 성립한다.
##
## M9.2 이전에는 바다 전체가 분지 1개라 제해권이 세계 1등 해군의 독식이거나
## 무주공산이었다 (실측: 섬 소유국이 자기 앞바다를 쥔 비율 1%).

const SHIP_COST_GDP_PC := 9.0             # 함선 1척 유지비 = 1인당 GDP × 이 값
const BUILD_COST_MULT := 2.5              # 신규 건조비 = 유지비 × 이 값
const SHARE_BASE := 0.004                 # GDP 대비 최소 해군비
const SHARE_MARITIME := 0.020             # 해양성 문화가 끌어올리는 폭
const SHARE_WAR_MULT := 1.6
const CHANGE_RATE := 0.10                 # 한 턴 함선 증감 상한
const BATTLE_ATTRITION := 0.15
const MORALE_SHOCK := 1.5
const MORALE_FLOOR := 0.1
const CONTROL_MARGIN := 1.15              # 통제권을 쥐려면 2위보다 이만큼 앞서야 한다
const STRAIT_MARGIN := 1.35               # 해협은 병목이라 더 확실히 앞서야 넘어온다
const MAX_FLEETS := 3                     # 국가당 함대 상한
const MOVE_STEPS := 1                     # 한 턴에 움직이는 해역 칸수


static func ship_cost(n: Nation) -> float:
	return n.gdp / maxf(n.population, 1.0) * SHIP_COST_GDP_PC


static func navy_share(n: Nation) -> float:
	var share := SHARE_BASE + n.culture_bias("maritime") * SHARE_MARITIME
	if n.at_foreign_war:
		share *= SHARE_WAR_MULT
	if n.bankruptcy_timer > 0:
		share *= 0.5
	share *= 1.0 - LawEvaluator.desperation(n) * BudgetAI.DESPERATION_BRAKE
	return maxf(share, 0.0)


static func target_ships(n: Nation) -> int:
	var cost := ship_cost(n)
	if cost <= 0.0:
		return 0
	return int(n.gdp * navy_share(n) / cost)


static func total_ships(world: WorldState, n: Nation) -> int:
	var total := 0
	for fid in n.fleets:
		var f: Fleet = world.fleets[fid]
		if f.is_alive:
			total += f.ships
	return total


## 건조·해체를 처리하고 이번 턴 해군비를 돌려준다. economy 4단계에서 호출된다.
static func plan_spending(world: WorldState, n: Nation) -> float:
	var homes := home_zones(world, n)
	if homes.is_empty():
		_scuttle(world, n)
		return 0.0

	var current := total_ships(world, n)
	var target := target_ships(n)
	var limit := int(maxf(float(maxi(current, target)) * CHANGE_RATE, 1.0))
	var next_total := clampi(target, current - limit, current + limit)
	var built := maxi(next_total - current, 0)
	_apply_strength(world, n, homes, next_total)
	return next_total * ship_cost(n) + built * ship_cost(n) * BUILD_COST_MULT


## 자국 연안에 접한 해역. 여기서만 함대를 띄운다.
static func home_zones(world: WorldState, n: Nation) -> Array[int]:
	var seen := {}
	for pid in n.provinces:
		var p: Province = world.provinces[pid]
		if p.controller() != n.id:
			continue
		for z: int in p.sea_zone_ids:
			seen[z] = true
	var out: Array[int] = []
	for z in seen:
		out.append(int(z))
	out.sort()                                    # 결정론 (§15)
	return out


## 함선 총량을 함대들에 나눈다. 함대는 위치를 갖는 실체라 매 턴 순간이동시키지
## 않는다 — 배치는 _move_fleets 가 한 칸씩 옮겨서 만든다.
static func _apply_strength(world: WorldState, n: Nation, homes: Array[int],
		total: int) -> void:
	if total <= 0:
		_scuttle(world, n)
		return
	var fleets := alive_fleets(world, n)
	var want := clampi(_contested_zones(world, n, homes, _fleet_zones(world)).size(),
		1, MAX_FLEETS)
	want = mini(want, total)                      # 0척짜리 함대는 만들지 않는다
	while fleets.size() < want:
		fleets.append(_create_fleet(world, n, homes[0], 0))
	while fleets.size() > want:
		var extra: Fleet = fleets.pop_back()
		extra.ships = 0
		extra.is_alive = false

	var per := total / fleets.size()
	var rest := total % fleets.size()
	for i in range(fleets.size()):
		var f: Fleet = fleets[i]
		f.ships = per + (1 if i < rest else 0)
		f.is_alive = f.ships > 0


static func alive_fleets(world: WorldState, n: Nation) -> Array[Fleet]:
	var out: Array[Fleet] = []
	for fid in n.fleets:
		var f: Fleet = world.fleets[fid]
		if f.is_alive:
			out.append(f)
	out.sort_custom(func(a: Fleet, b: Fleet) -> bool: return a.id < b.id)
	return out


static func _contested_zones(world: WorldState, n: Nation, zones: Array[int],
		fleet_zones: Dictionary) -> Array[int]:
	var out: Array[int] = []
	for z in zones:
		if _is_contested(world, n, z, fleet_zones):
			out.append(z)
	return out


## 해역 → 그 바다에 함대를 띄운 국가들. 이걸 미리 만들지 않으면 판정마다
## 전 함대를 훑어 국가 × 해역 × 함대 = 십수만 번이 된다 (실측 4.8ms/턴).
static func _fleet_zones(world: WorldState) -> Dictionary:
	var out := {}
	for f in world.fleets:
		if not f.is_alive or f.ships <= 0:
			continue
		if not out.has(f.zone_id):
			out[f.zone_id] = {}
		out[f.zone_id][f.nation_id] = true
	return out


static func _is_contested(world: WorldState, n: Nation, zone: int,
		fleet_zones: Dictionary) -> bool:
	for other in fleet_zones.get(zone, {}):
		if int(other) != n.id and Diplomacy.are_at_war(world, n.id, int(other)):
			return true
	# 적 해안이 이 바다에 접해 있으면 앞으로 다툴 바다다.
	world.refresh_zone_coasts()
	for holder in world.zone_coast_nations.get(zone, {}):
		if int(holder) != n.id and Diplomacy.are_at_war(world, n.id, int(holder)):
			return true
	return false


## 죽은 함대를 먼저 되살린다. 300턴 관전에서 함대 배열이 무한히 자라지 않게 한다.
static func _create_fleet(world: WorldState, n: Nation, zone: int, ships: int) -> Fleet:
	for fid in n.fleets:
		var dead: Fleet = world.fleets[fid]
		if dead.is_alive:
			continue
		dead.zone_id = zone
		dead.target_zone = zone
		dead.ships = ships
		dead.morale = 1.0
		dead.is_alive = true
		return dead
	var f := Fleet.new()
	f.id = world.fleets.size()
	f.nation_id = n.id
	f.zone_id = zone
	f.target_zone = zone
	f.ships = ships
	f.is_alive = ships > 0
	world.fleets.append(f)
	n.fleets.append(f.id)
	return f


static func _scuttle(world: WorldState, n: Nation) -> void:
	for fid in n.fleets:
		var f: Fleet = world.fleets[fid]
		f.ships = 0
		f.is_alive = false


# ---------------------------------------------------------------- 이동

static func _move_fleets(world: WorldState) -> void:
	var fleet_zones := _fleet_zones(world)
	var cache := {}                               # 같은 해역에서 출발하는 함대는 경로를 나눠 쓴다
	for n in world.nations:
		if not n.is_alive:
			continue
		var homes := home_zones(world, n)
		if homes.is_empty():
			continue
		for f in alive_fleets(world, n):
			var paths := _cached_paths(world, cache, f.zone_id)
			f.target_zone = _pick_target(world, n, homes, paths, fleet_zones)
			for i in range(MOVE_STEPS):
				if f.zone_id == f.target_zone:
					break
				var step := _first_step(paths, f.target_zone)
				if step < 0:
					break
				f.zone_id = step
				if i + 1 < MOVE_STEPS:
					paths = _cached_paths(world, cache, f.zone_id)


## 다툴 바다를 먼저, 그중 가장 가까운 곳으로. 없으면 가장 가까운 모항.
static func _pick_target(world: WorldState, n: Nation, homes: Array[int],
		paths: Array, fleet_zones: Dictionary) -> int:
	var distance: PackedInt32Array = paths[0]
	var best := -1
	var best_key := Vector2i(2, 1 << 30)
	for z in homes:
		if z >= distance.size() or distance[z] < 0:
			continue
		var priority := 0 if _is_contested(world, n, z, fleet_zones) else 1
		var key := Vector2i(priority, distance[z])
		if key.x < best_key.x or (key.x == best_key.x and key.y < best_key.y):
			best_key = key
			best = z
	return best if best >= 0 else homes[0]


static func _cached_paths(world: WorldState, cache: Dictionary, from_zone: int) -> Array:
	if not cache.has(from_zone):
		cache[from_zone] = _zone_paths(world, from_zone)
	return cache[from_zone]


## 해역 그래프 BFS. [거리, 첫 걸음] 두 배열, 못 가는 해역은 -1.
## 딕셔너리로 담으면 해역마다 배열을 하나씩 새로 만들어 그것만으로 밀리초가 든다.
static func _zone_paths(world: WorldState, from_zone: int) -> Array:
	var count := world.sea_zones.size()
	var distance := PackedInt32Array()
	var first := PackedInt32Array()
	distance.resize(count)
	distance.fill(-1)
	first.resize(count)
	first.fill(-1)
	if from_zone < 0 or from_zone >= count:
		return [distance, first]
	distance[from_zone] = 0
	first[from_zone] = from_zone
	var queue: Array[int] = [from_zone]
	var head := 0
	while head < queue.size():
		var cur: int = queue[head]
		head += 1
		for nb: int in world.sea_zones[cur].neighbors:
			if distance[nb] >= 0:
				continue
			distance[nb] = distance[cur] + 1
			first[nb] = nb if cur == from_zone else first[cur]
			queue.append(nb)
	return [distance, first]


static func _first_step(paths: Array, target: int) -> int:
	var first: PackedInt32Array = paths[1]
	if target < 0 or target >= first.size():
		return -1
	return first[target]


# ---------------------------------------------------------------- 틱

static func tick(world: WorldState) -> void:
	_move_fleets(world)
	_resolve_zone_battles(world)
	refresh_control(world)


static func strength(world: WorldState, f: Fleet) -> float:
	var n: Nation = world.nations[f.nation_id]
	return f.ships * f.morale * n.navy_modifier * n.military_modifier


static func _resolve_zone_battles(world: WorldState) -> void:
	var by_zone := {}
	for f in world.fleets:
		if not f.is_alive:
			continue
		if not by_zone.has(f.zone_id):
			by_zone[f.zone_id] = ([] as Array[Fleet])
		by_zone[f.zone_id].append(f)
	var zones: Array = by_zone.keys()
	zones.sort()
	for z in zones:
		_battle_in_zone(world, by_zone[z])


static func _battle_in_zone(world: WorldState, fleets: Array[Fleet]) -> void:
	if fleets.size() < 2:
		return
	fleets.sort_custom(func(a: Fleet, b: Fleet) -> bool:
		if a.ships == b.ships:
			return a.id < b.id
		return a.ships > b.ships)
	var lead: Fleet = fleets[0]
	var foe: Fleet = null
	for other in fleets:
		if other.nation_id != lead.nation_id \
				and Diplomacy.are_at_war(world, lead.nation_id, other.nation_id):
			foe = other
			break
	if foe == null:
		return

	var pa := strength(world, lead)
	var pb := strength(world, foe)
	if pa + pb <= 0.0:
		return
	var ratio := pa / (pa + pb)
	var loss_foe := mini(maxi(1, int(foe.ships * ratio * BATTLE_ATTRITION)), foe.ships)
	var loss_lead := mini(maxi(1, int(lead.ships * (1.0 - ratio) * BATTLE_ATTRITION)),
		lead.ships)
	_apply(lead, loss_lead)
	_apply(foe, loss_foe)
	world.log_event("naval_battle", {
		"nation": lead.nation_id,
		"enemy": foe.nation_id,
		"zone": lead.zone_id,
		"losses_a": loss_lead,
		"losses_b": loss_foe,
	})


static func _apply(f: Fleet, losses: int) -> void:
	var before := maxi(f.ships, 1)
	f.ships -= losses
	f.morale = maxf(MORALE_FLOOR, f.morale - float(losses) / float(before) * MORALE_SHOCK)
	f.is_alive = f.ships > 0


## 각 해역에서 2위보다 확실히 앞선 나라만 제해권을 갖는다. 동률과 빈 바다는 무주공산이다.
static func refresh_control(world: WorldState) -> void:
	var previous := {}
	for n in world.nations:
		for z in n.naval_control_zones:
			previous[int(z)] = n.id
		n.naval_control_zones.clear()

	var best := {}
	var second := {}
	var owner := {}
	for f in world.fleets:
		if not f.is_alive:
			continue
		var s := strength(world, f)
		var z := f.zone_id
		if s > float(best.get(z, 0.0)):
			second[z] = best.get(z, 0.0)
			best[z] = s
			owner[z] = f.nation_id
		elif s > float(second.get(z, 0.0)):
			second[z] = s

	var zones: Array = owner.keys()
	zones.sort()                                  # 결정론 (§15)
	for z in zones:
		var zone_id := int(z)
		var margin := CONTROL_MARGIN
		if zone_id >= 0 and zone_id < world.sea_zones.size() \
				and world.sea_zones[zone_id].is_strait:
			margin = STRAIT_MARGIN
		if float(best[z]) >= float(second.get(z, 0.0)) * margin:
			world.nations[int(owner[z])].naval_control_zones[zone_id] = true

	_log_control_changes(world, previous)


## 전시에만 기록한다. 평시 제해권 교체까지 흘리면 기록이 그것만으로 가득 찬다.
static func _log_control_changes(world: WorldState, previous: Dictionary) -> void:
	var current := {}
	for n in world.nations:
		for z in n.naval_control_zones:
			current[int(z)] = n.id
	var zones := {}
	for z in previous:
		zones[z] = true
	for z in current:
		zones[z] = true
	var keys: Array = zones.keys()
	keys.sort()
	for z in keys:
		var before := int(previous.get(z, -1))
		var after := int(current.get(z, -1))
		if before == after:
			continue
		if not _at_war(world, before) and not _at_war(world, after):
			continue
		world.log_event("naval_control_changed", {
			"zone": int(z),
			"nation": after,
			"lost": before,
		})


static func _at_war(world: WorldState, nation_id: int) -> bool:
	return nation_id >= 0 and world.nations[nation_id].at_war
