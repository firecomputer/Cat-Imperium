class_name NationPlacer extends RefCounted

## 초기 국가 배치. 프로빈스 인접 그래프 위에서 수도 씨앗을 흩고 동시 확장한다.
## (문서에 국가 수/배치 규격이 없어 여기서 정한다)

## 기준 격자(육지 5000타일, granularity 1.0)의 국가 수. 지도가 커져도 이 값을
## 고정하면 국가당 땅이 그만큼 넓어져 건국 시점부터 admin_load 가 capacity 를
## 넘는다 — 지구 지도에서 40국은 국가당 22.9칸(노이즈 7.8칸)이라 37/40 국이
## turn 0 부터 과확장이고, 권위가 개전 문턱 아래로 내려가 제국이 형성되지 않았다.
## 국가 수를 세계 크기에 맞춰 국가당 땅을 기준 격자와 같게 둔다.
const NATION_COUNT := 40
## 육지 CAPITAL_DIST_BASE_TILES 타일 기준의 수도 간 최소 평면 거리.
## 지도가 커지면 국가 수도 함께 늘므로, 간격은 "국가당 육지 타일" 비율로 잡는다.
const CAPITAL_MIN_DIST := 9.0
const CAPITAL_DIST_BASE_TILES := 5000.0
const CAPITAL_TRIES_PER_NATION := 60
## 육로로 못 닿는 땅의 거리 환산 상한. 직선거리를 그대로 쓰면 불만(§10)과
## 건설비(§4.4)가 지도 크기에 비례해 터진다.
const EXCLAVE_DIST_CAP := 12.0
## 국명 중복 회피 재시도 횟수. 문화당 조합은 60가지, 국가는 8개다.
const NAME_TRIES := 12
## 문화가 지리 원산에 얼마나 붙잡히는가 (§M13.6). 1.0 이면 판마다 같은 문화 지도,
## 0.0 이면 러시안블루가 사하라에서 시작한다. 밸런스가 아니라 취향 다이얼이라
## 지표에 영향이 없어야 정상이다.
const CULTURE_ANCHOR_STRENGTH := 0.45


## 세계 크기에 맞춘 국가 수. 프로빈스 수는 시드마다 흔들리므로 육지 타일과
## granularity 로만 정한다 — 같은 지도 소스면 시드와 무관하게 같은 값이다.
## 프로빈스 평균 크기가 granularity 에 비례하므로 국가당 프로빈스 수가 보존된다.
static func nation_count(land_tiles: int, granularity: float) -> int:
	return maxi(4, int(round(NATION_COUNT * float(land_tiles)
		/ CAPITAL_DIST_BASE_TILES / maxf(granularity, 0.01))))


static func place(provinces: Array[Province], rng: RandomNumberGenerator,
		granularity: float = 1.0, culture_rng: RandomNumberGenerator = null) -> Array[Nation]:
	var capitals := _pick_capitals(provinces, rng, granularity)
	var nations: Array[Nation] = []

	var kinds := assign_cultures(provinces, capitals,
		culture_rng if culture_rng != null else rng)

	for i in range(capitals.size()):
		var n := Nation.new()
		n.id = i
		n.culture = kinds[i]
		n.culture_params = Culture.roll(n.culture, rng)
		n.capital = capitals[i]
		n.start_region = provinces[n.capital].region
		n.law_review_progress = float(i % int(LawSystem.REVIEW_INTERVAL))
		nations.append(n)

	_claim(provinces, nations)
	_set_capital_distances(provinces, nations)
	return nations


## 국명 부여. 시뮬 수치에 전혀 쓰이지 않으므로 반드시 별도 RNG 스트림으로 뽑는다 —
## 기존 스트림에서 뽑으면 그 뒤 모든 난수가 밀려 회귀 해시가 깨진다 (§15).
static func assign_names(nations: Array[Nation], rng: RandomNumberGenerator) -> void:
	var taken := {}
	for n in nations:
		n.name = _roll_name(n.culture, taken, rng)


static func _roll_name(culture: int, taken: Dictionary, rng: RandomNumberGenerator) -> String:
	var data := CharacterSystem.name_data(culture)
	var stems: Array = data["nation_stems"]
	var titles: Array = data["nation_titles"]
	var separator: String = data.get("nation_separator", " ")
	var name := ""
	for attempt in range(NAME_TRIES):
		var stem: String = stems[rng.randi_range(0, stems.size() - 1)]
		var title: String = titles[rng.randi_range(0, titles.size() - 1)]
		name = stem + separator + title
		if not taken.has(name):
			break
	# 조합이 다 겹치면 서수를 붙인다. 같은 이름 둘은 관전에서 최악이다.
	if taken.has(name):
		var ordinal := 2
		while taken.has("%s %d세" % [name, ordinal]):
			ordinal += 1
		name = "%s %d세" % [name, ordinal]
	taken[name] = true
	return name


## 반란국 이름은 봉기가 난 지역에서 뽑는다. 새 난수를 쓰면 반란 발생 시점이
## 다른 시스템의 난수열을 밀어 결정론이 깨지므로, 프로빈스 id 로 결정론적으로 고른다 (§15).
static func rebel_name(nations: Array[Nation], culture: int, province_id: int) -> String:
	var data := CharacterSystem.name_data(culture)
	var stems: Array = data["nation_stems"]
	var titles: Array = data["rebel_titles"]
	var separator: String = data.get("nation_separator", " ")
	var taken := {}
	for n in nations:
		taken[n.name] = true

	var title: String = titles[(province_id / stems.size()) % titles.size()]
	var name := ""
	for k in range(stems.size()):
		name = stems[(province_id + k) % stems.size()] + separator + title
		if not taken.has(name):
			return name
	# 그 문화의 조합이 다 쓰였다. 서수를 붙인다 (국명 규칙과 동일).
	var ordinal := 2
	while taken.has("%s %d세" % [name, ordinal]):
		ordinal += 1
	return "%s %d세" % [name, ordinal]


## 문화 배치. 이번 판의 티어 정원(Culture.roll_quota)을 지리 원산에 맞춰 나눠 준다.
## 별도 RNG 스트림을 쓴다 — 수도 선정·문화 파라미터 스트림을 밀면 회귀 기준선이
## 통째로 어긋난다 (§15).
static func assign_cultures(provinces: Array[Province], capitals: Array[int],
		rng: RandomNumberGenerator) -> Array[int]:
	var quota := Culture.roll_quota(capitals.size(), rng)
	var kinds: Array[int] = []
	for pid in capitals:
		var region: int = provinces[pid].region
		var pick := -1
		if rng.randf() < CULTURE_ANCHOR_STRENGTH:
			pick = _anchored_pick(quota, region, rng)
		if pick < 0:
			pick = _quota_pick(quota, rng)
		quota[pick] -= 1
		kinds.append(pick)
	return kinds


## 이 지역이 원산인 문화 중 정원이 남은 것. 없으면 -1 (호출부가 무작위로 넘어간다).
static func _anchored_pick(quota: PackedInt32Array, region: int,
		rng: RandomNumberGenerator) -> int:
	if region < 0:
		return -1
	var candidates: Array[int] = []
	for kind in range(quota.size()):
		if quota[kind] > 0 and int(Culture.ORIGIN_REGION[kind]) == region:
			candidates.append(kind)
	if candidates.is_empty():
		return -1
	return candidates[rng.randi_range(0, candidates.size() - 1)]


## 남은 정원에 비례해 뽑는다. 정원 합이 수도 수와 같으므로 항상 하나는 남아 있다.
static func _quota_pick(quota: PackedInt32Array, rng: RandomNumberGenerator) -> int:
	var total := 0
	for q in quota:
		total += maxi(q, 0)
	if total <= 0:
		return 0
	var roll := rng.randi_range(0, total - 1)
	for kind in range(quota.size()):
		roll -= maxi(quota[kind], 0)
		if roll < 0:
			return kind
	return 0


## 큰 대륙 프로빈스 중에서 서로 떨어진 것들을 수도로 고른다.
static func _pick_capitals(provinces: Array[Province], rng: RandomNumberGenerator,
		granularity: float) -> Array[int]:
	var pool: Array[int] = []
	for p in provinces:
		if not p.is_island:
			pool.append(p.id)
	if pool.is_empty():
		for p in provinces:
			pool.append(p.id)

	var land_tiles := 0
	for p in provinces:
		land_tiles += p.size()
	var want := nation_count(land_tiles, granularity)
	# 국가당 육지 타일이 기준(5000/40)과 같으면 간격도 기준값 그대로다.
	var min_dist := CAPITAL_MIN_DIST * sqrt(float(land_tiles) / float(want)
		/ (CAPITAL_DIST_BASE_TILES / float(NATION_COUNT)))

	var capitals: Array[int] = []
	var tries := want * CAPITAL_TRIES_PER_NATION
	while capitals.size() < want and tries > 0:
		tries -= 1
		var cand: int = pool[rng.randi_range(0, pool.size() - 1)]
		if capitals.has(cand):
			continue
		var ok := true
		for c in capitals:
			if provinces[cand].centroid.distance_to(provinces[c].centroid) < min_dist:
				ok = false
				break
		if ok:
			capitals.append(cand)
	return capitals


## 수도에서 동시 확장. 육로로 못 닿는 섬은 가장 가까운 수도에 붙인다.
static func _claim(provinces: Array[Province], nations: Array[Nation]) -> void:
	var frontier: Array = []
	var head: Array[int] = []
	for n in nations:
		provinces[n.capital].owner_nation = n.id
		n.provinces.append(n.capital)
		frontier.append(provinces[n.capital].land_neighbors.duplicate())
		head.append(0)

	var progressed := true
	while progressed:
		progressed = false
		for i in range(nations.size()):
			var f: Array = frontier[i]
			while head[i] < f.size():
				var pid: int = f[head[i]]
				head[i] += 1
				if provinces[pid].owner_nation != -1:
					continue
				provinces[pid].owner_nation = nations[i].id
				nations[i].provinces.append(pid)
				f.append_array(provinces[pid].land_neighbors)
				progressed = true
				break

	for p in provinces:
		if p.owner_nation != -1:
			continue
		var best := -1
		var best_d := INF
		for n in nations:
			var d: float = p.centroid.distance_to(provinces[n.capital].centroid)
			if d < best_d:
				best_d = d
				best = n.id
		p.owner_nation = best
		nations[best].provinces.append(p.id)


## 수도로부터의 프로빈스 홉 수. 건설비가 이 거리에 비례해 오른다 (§4.4).
static func _set_capital_distances(provinces: Array[Province], nations: Array[Nation]) -> void:
	for n in nations:
		var dist: Dictionary = {n.capital: 0}
		var queue: Array[int] = [n.capital]
		var head := 0
		while head < queue.size():
			var cur: int = queue[head]
			head += 1
			for nb: int in provinces[cur].land_neighbors:
				if provinces[nb].owner_nation != n.id or dist.has(nb):
					continue
				dist[nb] = int(dist[cur]) + 1
				queue.append(nb)
		for pid in n.provinces:
			# 육로로 못 닿는 월경지/섬은 직선 거리로 환산한다
			if dist.has(pid):
				provinces[pid].distance_from_capital = float(dist[pid])
			else:
				provinces[pid].is_exclave = true
				provinces[pid].distance_from_capital = minf(
					provinces[pid].centroid.distance_to(
						provinces[n.capital].centroid) * 0.5, EXCLAVE_DIST_CAP)
