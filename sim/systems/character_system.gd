class_name CharacterSystem extends RefCounted

## 인물 생성·사망·등용. 모든 난수는 RngPool 의 characters 스트림만 사용한다.

const INITIAL_CHARACTERS_PER_NATION := 12
## 정상상태 인물 풀 = 배출률 × 수명이다. 두 상수는 반드시 함께 움직인다.
## 국가 인구 약 46,000 기준 턴당 0.128명 × 수명 145턴 = 풀 약 18.5명 —
## 고문석 7 + 장군 4 + 후보 여유를 채운다. 900000 은 실제 인구 규모를 위해
## 쓰인 값이라 이 시뮬에서는 턴당 0.05명, 턴 120에 국가당 생존 3.2명이었다.
const POPULATION_PER_CHARACTER := 360000.0
## 수명 90 + 건강(0~100) × 1.0 → 90~190. 공공의료(healthcare +0.5)가 곱해져
## 최대 204턴이 된다. 300턴 관전에서 한 고문이 제국의 전성기를 통째로
## 떠받칠 수 있어야 설계서 §13.4 의 "한 사람의 죽음" 이 무게를 갖는다.
const LIFESPAN_BASE := 90.0
const LIFESPAN_HEALTH := 1.00
const LIFESPAN_DEVIATION := 12.0
const NAME_DIR := "res://data/names"
const NAME_FILES := {
	Culture.Kind.SIAMESE: "siamese.json",
	Culture.Kind.RAGDOLL: "ragdoll.json",
	Culture.Kind.CHEESE_TABBY: "cheese_tabby.json",
	Culture.Kind.RUSSIAN_BLUE: "russian_blue.json",
	Culture.Kind.KOREAN_SHORTHAIR: "korean_shorthair.json",
}

static var _name_sets: Dictionary = {}


## 경제 초기값과 최초 법률이 정해진 뒤 호출한다.
static func initialize(world: WorldState) -> void:
	if not world.characters.is_empty():
		return
	var rng := world.rng_pool.get_rng("characters")
	for n in world.nations:
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
	var dev := 16.0 - edu * 3.0
	c.intelligence = _roll(rng, mean + edu * 8.0, dev)
	c.charisma = _roll(rng, mean, dev + 4.0)
	c.creativity = _roll(rng, mean + edu * 5.0, dev + 5.0)
	c.health = _roll(rng, 50.0 + p.gdp_pc / 90.0, 15.0)
	c.ambition = _roll(rng, 50.0, 20.0) / 100.0
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
