class_name CharacterSystem extends RefCounted

## 인물 생성·사망·등용. 모든 난수는 RngPool 의 characters 스트림만 사용한다.

const INITIAL_CHARACTERS_PER_NATION := 12
## 정상상태 인물 풀 = 배출률 × 수명이다. 두 상수는 반드시 함께 움직인다.
## 국가 인구 약 46,000 기준 턴당 0.128명 × 수명 145턴 = 풀 약 18.5명 —
## 고문석 7 + 장군 4 + 후보 여유를 채운다. 900000 은 실제 인구 규모를 위해
## 쓰인 값이라 이 시뮬에서는 턴당 0.05명, 턴 120에 국가당 생존 3.2명이었다.
## 수명 115 로 늘리면서 배출률은 그대로 둔다. 430000 으로 함께 올려 정상상태 풀을
## 맞춰 봤더니 (풀 15.7, 충원율 85%) 초반 100턴의 과도기가 얇아져 첫 파산이
## 104 → 88.9턴으로 밀렸다 — 고문석이 비면 tax_efficiency 가 0.7 바닥에 붙는다.
## 정상상태 풀이 약 22명으로 커지는 대신 건국기 재정을 지킨다.
const POPULATION_PER_CHARACTER := 360000.0
## 수명 115 + 건강(0~100) × 1.0 → 115~215. 공공의료가 곱해져 최대 247턴.
## 뛰어난 고문이 오래 앉아 있어야 인재 편차(talent_bias)가 국력 차이로 쌓인다 —
## 수명이 짧으면 좋은 인물이 나와도 다음 세대에 평균으로 돌아간다.
const LIFESPAN_BASE := 115.0
const LIFESPAN_HEALTH := 1.00
const LIFESPAN_DEVIATION := 12.0
## 인재 기질의 표준편차. 국가마다 한 번 뽑아 능력치 평균에 그대로 더한다.
## ±1σ 면 평균 10점 차이 — 고문 한 자리에서 army_modifier 약 3.5%p 차이가 나고
## 일곱 자리에 걸쳐 누적된다.
const TALENT_NATION_SIGMA := 10.0
## 개인 편차. 16 에서 올린다. 꼬리가 두꺼워야 "이 나라에 이번 세대 명장이 났다" 가
## 생긴다 — 편차가 좁으면 모든 나라의 최고 고문 점수가 같아진다.
const ABILITY_DEVIATION := 20.0
## 매파 성향의 분포. 평균 0.45 는 중립(0.5)보다 조금 낮게 둬서 개전이 세계 전체로
## 번지지 않게 한다 — 전역 다이얼은 이미 실패했다 (WAR_POWER_EDGE 전역 인하 실험).
const HAWKISH_MEAN := 0.45
const HAWKISH_DEVIATION := 0.22
## 강제 진압 선호. 매파 성향과 상관시키지 않는다 — 묶으면 매파 내각이 자동으로
## 진압파가 되어 두 축이 하나로 무너진다.
const SUPPRESSION_MEAN := 0.5
const SUPPRESSION_DEVIATION := 0.22
const NAME_DIR := "res://data/names"
const NAME_FILES := {
	Culture.Kind.SIAMESE: "siamese.json",
	Culture.Kind.RAGDOLL: "ragdoll.json",
	Culture.Kind.CHEESE_TABBY: "cheese_tabby.json",
	Culture.Kind.RUSSIAN_BLUE: "russian_blue.json",
	Culture.Kind.KOREAN_SHORTHAIR: "korean_shorthair.json",
	Culture.Kind.BRITISH_SHORTHAIR: "british_shorthair.json",
	Culture.Kind.NORWEGIAN_FOREST: "norwegian_forest.json",
	Culture.Kind.EGYPTIAN_MAU: "egyptian_mau.json",
	Culture.Kind.PERSIAN: "persian.json",
	Culture.Kind.BENGAL: "bengal.json",
	Culture.Kind.TURKISH_ANGORA: "turkish_angora.json",
	Culture.Kind.ABYSSINIAN: "abyssinian.json",
}

static var _name_sets: Dictionary = {}


## 경제 초기값과 최초 법률이 정해진 뒤 호출한다.
static func initialize(world: WorldState) -> void:
	if not world.characters.is_empty():
		return
	var rng := world.rng_pool.get_rng("characters")
	for n in world.nations:
		# 인재 기질은 국가당 한 번만 뽑는다. 이후 태어나는 모든 인물이 이 편차를
		# 물려받아, 세대가 바뀌어도 "인재가 나는 나라" 가 유지된다.
		n.talent_bias = rng.randfn(0.0, TALENT_NATION_SIGMA)
		for i in range(INITIAL_CHARACTERS_PER_NATION):
			var p := _weighted_home(world, n, rng)
			spawn_character(world, n, p, world.turn, rng, _founder_age(i))
		appoint_vacancies(world, n)


## 건국 12명이 전부 birth_turn 0 이면 한 세대가 통째로 같은 구간에서 죽어
## 세계의 고문석이 동시에 빈다. 인덱스로 나이를 흩는다 — 난수를 뽑으면
## 이후 모든 시스템의 characters 스트림이 밀린다 (§15).
static func _founder_age(index: int) -> int:
	return int(LIFESPAN_BASE * float(index) / float(INITIAL_CHARACTERS_PER_NATION + 1))


static func tick(world: WorldState) -> void:
	_process_deaths(world)
	var rng := world.rng_pool.get_rng("characters")
	for n in world.nations:
		if not n.is_alive:
			continue
		_spawn_for_nation(world, n, rng)
		appoint_vacancies(world, n)
		_tick_loyalty(world, n)


## 생성 시점에 이름·능력치·사망 턴을 모두 확정한다.
## age_offset 은 이미 살아온 턴 수다. 건국 세대를 분산시키는 데만 쓴다 —
## 난수를 하나도 더 뽑지 않고 나이를 주기 위한 인자다 (§15 결정론).
static func spawn_character(world: WorldState, n: Nation, p: Province, turn: int,
		rng: RandomNumberGenerator, age_offset: int = 0) -> Character:
	var c := Character.new()
	c.id = world.characters.size()
	c.nation_id = n.id
	c.culture = n.culture
	c.birth_turn = turn - age_offset
	c.home_province = p.id

	var parts := generate_name_parts(n.culture, rng)
	c.family_name = parts["family"]
	c.given_name = parts["given"]
	c.name = parts["full"]

	var edu := n.law_modifier("education")
	var mean := 45.0 + edu * 22.0 + p.infra * 1.6 + (5.0 if p.has_city else 0.0)
	mean += n.talent_bias
	var dev := ABILITY_DEVIATION - edu * 3.0
	c.intelligence = _roll(rng, mean + edu * 8.0, dev)
	c.charisma = _roll(rng, mean, dev + 4.0)
	c.creativity = _roll(rng, mean + edu * 5.0, dev + 5.0)
	c.health = _roll(rng, 50.0 + p.gdp_pc / 90.0, 15.0)
	c.ambition = _roll(rng, 50.0, 20.0) / 100.0
	# 야심가는 전쟁을 부추기는 쪽으로 기운다. 성향 자체는 독립적으로 뽑는다 —
	# 야심만으로 정하면 충성도(0.75 - ambition×0.4)와 완전히 묶여 버린다.
	c.hawkish = clampf(rng.randfn(HAWKISH_MEAN, HAWKISH_DEVIATION) + (c.ambition - 0.5) * 0.30,
		0.0, 1.0)
	c.suppression_bias = clampf(
		rng.randfn(SUPPRESSION_MEAN, SUPPRESSION_DEVIATION), 0.0, 1.0)
	c.noble_birth = clampf(rng.randfn(0.5, 0.25), 0.0, 1.0)
	c.loyalty = clampf(0.75 - c.ambition * 0.4 + edu * 0.1, 0.05, 1.0)
	c.education_at_birth = edu

	var lifespan := LIFESPAN_BASE + c.health * LIFESPAN_HEALTH
	lifespan *= 1.0 + n.law_modifier("healthcare") * 0.15
	lifespan += rng.randfn(0.0, LIFESPAN_DEVIATION)
	c.death_turn = maxi(turn + 4, turn + int(maxf(lifespan, 18.0)) - age_offset)

	world.characters.append(c)
	n.characters.append(c.id)
	world.log_event("character_born", {
		"nation": n.id,
		"character": c.id,
		"name": c.name,
		"culture": c.culture,
		"home": c.home_province,
		"death_turn": c.death_turn,
		"education": edu,
	})
	return c


## 국명 생성기 등 다른 시스템이 같은 캐시를 쓰도록 열어 둔다.
static func name_data(culture: int) -> Dictionary:
	return _name_set(culture)


static func generate_name(culture: int, rng: RandomNumberGenerator) -> String:
	return generate_name_parts(culture, rng)["full"]


static func generate_name_parts(culture: int, rng: RandomNumberGenerator) -> Dictionary:
	var data := _name_set(culture)
	var families: Array = data["family"]
	var given_names: Array = data["given"]
	var family: String = families[rng.randi_range(0, families.size() - 1)]
	var given: String = given_names[rng.randi_range(0, given_names.size() - 1)]
	var separator: String = data.get("separator", " ")
	var full := family + separator + given
	if data.get("order", "given_family") == "given_family":
		full = given + separator + family
	return {"family": family, "given": given, "full": full}


static func appoint_vacancies(world: WorldState, n: Nation) -> void:
	var merit := clampf(n.law_modifier("merit"), -1.0, 1.0)
	for role in Character.ADVISOR_ROLES:
		var missing: int = int(Character.SLOTS[role]) - _role_count(world, n, role)
		for i in range(missing):
			var best := _best_candidate(world, n, role, merit)
			if best == null:
				break
			best.role = role
			world.log_event("advisor_appointed", {
				"nation": n.id,
				"character": best.id,
				"name": best.name,
				"role": role,
				"score": best.score_for(role),
			})


static func _process_deaths(world: WorldState) -> void:
	for c in world.characters:
		if not c.is_alive or c.death_turn > world.turn:
			continue
		var old_role := c.role
		c.is_alive = false
		c.role = Character.Role.NONE
		world.log_event("character_died", {
			"nation": c.nation_id,
			"character": c.id,
			"name": c.name,
			"role": old_role,
		})


static func _spawn_for_nation(world: WorldState, n: Nation,
		rng: RandomNumberGenerator) -> void:
	if n.provinces.is_empty():
		return
	var rate := n.population / POPULATION_PER_CHARACTER
	rate *= 1.0 + n.law_modifier("education") * 0.6
	rate *= 1.0 + _city_count(world, n) * 0.08
	rate = maxf(rate, 0.0)
	var count := int(floor(rate))
	if rng.randf() < rate - count:
		count += 1
	for i in range(count):
		spawn_character(world, n, _weighted_home(world, n, rng), world.turn, rng)


static func _weighted_home(world: WorldState, n: Nation,
		rng: RandomNumberGenerator) -> Province:
	var order := n.provinces.duplicate()
	order.sort()
	var total := 0.0
	for pid in order:
		total += maxf(world.provinces[pid].population, 0.0)
	if total <= 0.0:
		var fallback: int = n.capital if n.capital >= 0 else int(order[0])
		return world.provinces[fallback]
	var pick := rng.randf() * total
	for pid in order:
		pick -= maxf(world.provinces[pid].population, 0.0)
		if pick <= 0.0:
			return world.provinces[pid]
	return world.provinces[order[-1]]


static func _best_candidate(world: WorldState, n: Nation, role: int,
		merit: float) -> Character:
	var best: Character = null
	var best_score := -INF
	var ability_weight := lerpf(0.4, 1.0, (merit + 1.0) / 2.0)
	for cid in n.characters:
		var c: Character = world.characters[cid]
		if not c.is_alive or c.role != Character.Role.NONE:
			continue
		var score := c.score_for(role) * ability_weight + c.noble_birth * (1.0 - merit) * 30.0
		if score > best_score or (is_equal_approx(score, best_score) and (best == null or c.id < best.id)):
			best_score = score
			best = c
	return best


static func _role_count(world: WorldState, n: Nation, role: int) -> int:
	var count := 0
	for cid in n.characters:
		var c: Character = world.characters[cid]
		if c.is_alive and c.role == role:
			count += 1
	return count


static func _city_count(world: WorldState, n: Nation) -> int:
	var count := 0
	for pid in n.provinces:
		if world.provinces[pid].has_city:
			count += 1
	return count


static func _tick_loyalty(world: WorldState, n: Nation) -> void:
	for cid in n.characters:
		var c: Character = world.characters[cid]
		if not c.is_alive:
			continue
		if c.role == Character.Role.NONE and c.score_for(Character.Role.MILITARY) > 75.0:
			c.loyalty -= c.ambition * 0.02
		if n.inflation > 0.2 or n.bankruptcy_timer > 0:
			c.loyalty -= 0.03
		c.loyalty = clampf(c.loyalty, 0.0, 1.0)
		if c.role == Character.Role.GENERAL and c.loyalty < 0.15 \
				and not c.rebellion_requested:
			c.rebellion_requested = true
			# M8의 반란 생성기가 이 이벤트를 소비해 해당 장군을 지도자로 삼는다.
			world.log_event("rebellion_requested", {
				"nation": n.id,
				"character": c.id,
				"name": c.name,
				"loyalty": c.loyalty,
				"home": c.home_province,
			})


static func _roll(rng: RandomNumberGenerator, mean: float, deviation: float) -> float:
	return clampf(rng.randfn(mean, deviation), 0.0, 100.0)


static func _name_set(culture: int) -> Dictionary:
	if _name_sets.has(culture):
		return _name_sets[culture]
	var path: String = NAME_DIR + "/" + NAME_FILES[culture]
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	assert(parsed is Dictionary, "이름 데이터 JSON 오류: %s" % path)
	assert(parsed.get("family", []).size() > 0 and parsed.get("given", []).size() > 0,
		"이름 데이터가 비어 있음: %s" % path)
	_name_sets[culture] = parsed
	return parsed
