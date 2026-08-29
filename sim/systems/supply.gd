class_name Supply extends RefCounted

## 인프라의 역수를 비용으로 쓰는 다중 소스 다익스트라 (§8).
## 현재 프로빈스 그래프는 육지만 가지므로 해상 진입은 M8 해군 통제 계층이 담당한다.

const BASE_COST := 10.0
const SUPPLY_RANGE := 100.0
const SUPPLY_EXPONENT := 1.8
const MIN_SUPPLY := 0.05
const CITY_SOURCE_BASE_COST := 28.0
## §8.2 는 적 영토를 통과 불가로 뒀지만, 그러면 침공군은 국경을 넘는 순간
## 보급 0.05 로 전투력이 2% 가 되어 공격이 물리적으로 불가능해진다.
## 대신 아주 비싸게 통과시킨다 — 1~2칸 침투는 버티고, 깊이 들어가면 굶는다.
const ENEMY_STEP_MULT := 3.5
## 제해권을 쥔 바다는 건널 수 있다. 육로 한 칸보다 비싸지만 대륙을 잇는다.
const SEA_STEP_COST := 40.0
## 제해권을 쥔 해역끼리 잇는 비용. 근해는 싸고 원정은 해역 수만큼 비싸진다.
const SEA_LINK_COST := 12.0
const CITY_INFRA_DISCOUNT := 3.0
const EPS := 0.000001


static func recompute_if_dirty(world: WorldState) -> void:
	for n in world.nations:
		if not n.is_alive:
			continue
		if not n.supply_dirty and not n.at_war:
			continue
		n.supply_field = compute_supply_field(world, n)
		n.supply_dirty = false
		for pid in n.provinces:
			world.provinces[pid].supply = n.supply_field[pid]


static func compute_supply_field(world: WorldState, n: Nation) -> PackedFloat32Array:
	var count := world.provinces.size()
	# 해역도 다익스트라 노드다. id 는 count 만큼 밀어 인코딩한다.
	var costs: Array[float] = []
	costs.resize(count + world.sea_zones.size())
	costs.fill(INF)
	var heap: Array[Vector2] = []

	if n.capital >= 0 and n.capital < count and _can_enter(world.provinces[n.capital], n):
		_add_source(costs, heap, n.capital, 0.0)
	for pid in n.provinces:
		var p: Province = world.provinces[pid]
		if not p.has_city or not _can_enter(p, n):
			continue
		var source_cost := maxf(0.0, CITY_SOURCE_BASE_COST - p.infra * CITY_INFRA_DISCOUNT)
		_add_source(costs, heap, pid, source_cost)

	while not heap.is_empty():
		var item := _heap_pop(heap)
		var cost := item.x
		var node := int(item.y)
		if cost > costs[node] + EPS:
			continue
		if node >= count:
			_expand_zone(world, n, world.sea_zones[node - count], cost, costs, heap)
			continue
		var pid := node
		# 승선은 내 항구에서만 한다. 제해권을 쥔 해역으로 나가는 비용.
		if _can_enter(world.provinces[pid], n):
			for zone_id: int in world.provinces[pid].sea_zone_ids:
				if not n.naval_control_zones.has(zone_id):
					continue
				_add_source(costs, heap, count + zone_id,
					cost + SEA_STEP_COST / maxf(n.sea_supply_mult, 0.1))
		for neighbor_id: int in world.provinces[pid].land_neighbors:
			var next: Province = world.provinces[neighbor_id]
			var step := step_cost(world, next, n)
			if step < 0.0:
				continue
			var next_cost := cost + step
			if next_cost + EPS >= costs[neighbor_id]:
				continue
			costs[neighbor_id] = next_cost
			_heap_push(heap, Vector2(next_cost, neighbor_id))

	var field := PackedFloat32Array()
	field.resize(count)
	field.fill(MIN_SUPPLY)
	for pid in range(count):
		if not is_inf(costs[pid]):
			field[pid] = supply_from_cost(costs[pid], n.supply_range_mult)
	return field


## 제해권을 쥔 해역은 인접 해역으로 이어지고, 그 해역 연안에는 하선한다.
static func _expand_zone(world: WorldState, n: Nation, zone: SeaZone, cost: float,
		costs: Array[float], heap: Array[Vector2]) -> void:
	var count := world.provinces.size()
	for nb: int in zone.neighbors:
		if not n.naval_control_zones.has(nb):
			continue
		_add_source(costs, heap, count + nb, cost + SEA_LINK_COST)
	for landing: int in zone.coast_provinces:
		if not _can_enter(world.provinces[landing], n) \
				and not _is_hostile(world, world.provinces[landing], n):
			continue
		_add_source(costs, heap, landing, cost)


static func step_cost(world: WorldState, p: Province, n: Nation) -> float:
	var cost := BASE_COST
	if _can_enter(p, n):
		cost /= 1.0 + p.infra * 0.85          # 내 도로망은 거의 공짜로 지난다
	elif _is_hostile(world, p, n):
		cost *= ENEMY_STEP_MULT               # 적 도로는 나를 위해 깔린 게 아니다
	else:
		return -1.0                           # 중립국 영토는 통과 불가
	cost *= p.terrain_supply_mult
	cost *= 1.0 + p.unrest * 1.2
	return cost


static func _is_hostile(world: WorldState, p: Province, n: Nation) -> bool:
	var holder := p.controller()
	return holder >= 0 and Diplomacy.are_at_war(world, n.id, holder)


static func supply_from_cost(cost: float, range_mult: float) -> float:
	var effective_range := SUPPLY_RANGE * maxf(range_mult, 0.01)
	return clampf(1.0 - pow(cost / effective_range, SUPPLY_EXPONENT), MIN_SUPPLY, 1.0)


## 점령당한 땅은 원 소유국의 보급선에서 끊긴다 — 이것이 포위망을 만든다.
static func _can_enter(p: Province, n: Nation) -> bool:
	if p.occupied_by_nation >= 0:
		return p.occupied_by_nation == n.id
	return p.owner_nation == n.id


static func _add_source(costs: Array[float], heap: Array[Vector2], pid: int,
		cost: float) -> void:
	if cost + EPS >= costs[pid]:
		return
	costs[pid] = cost
	_heap_push(heap, Vector2(cost, pid))


static func _heap_push(heap: Array[Vector2], item: Vector2) -> void:
	heap.append(item)
	var idx := heap.size() - 1
	while idx > 0:
		var parent := int((idx - 1) / 2)
		if not _less(item, heap[parent]):
			break
		heap[idx] = heap[parent]
		idx = parent
	heap[idx] = item


static func _heap_pop(heap: Array[Vector2]) -> Vector2:
	var root := heap[0]
	var last: Vector2 = heap.pop_back()
	if heap.is_empty():
		return root
	var idx := 0
	while true:
		var left := idx * 2 + 1
		if left >= heap.size():
			break
		var right := left + 1
		var child := left
		if right < heap.size() and _less(heap[right], heap[left]):
			child = right
		if not _less(heap[child], last):
			break
		heap[idx] = heap[child]
		idx = child
	heap[idx] = last
	return root


static func _less(a: Vector2, b: Vector2) -> bool:
	return a.x < b.x or (a.x == b.x and a.y < b.y)
