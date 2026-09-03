extends SceneTree

## M13.7-a 문화 12종 회귀 테스트. 파라미터가 뭉치지 않는지, assimilation 이
## 실제로 소비되는지(유령값 금지), 티어 정원이 규격을 지키는지 본다.
##   godot4 --headless --path . --script res://tools/test_culture.gd

## 기존 5종의 최소 상호 거리(샴-코리안숏헤어 0.222)를 하한으로 쓴다 — 신설 7종이
## 이보다 가까우면 "이름만 다른 문화" 다.
const MIN_CULTURE_DISTANCE := 0.22
const PARAM_KEYS := ["aggression", "curiosity", "cohesion", "greed", "fertility",
	"fiscal_prudence", "development", "maritime", "assimilation"]


func _initialize() -> void:
	_test_presets_are_complete()
	_test_cultures_do_not_cluster()
	_test_every_culture_has_names()
	_test_quota_matches_nation_count()
	_test_rare_tier_sometimes_absent()
	_test_assimilation_is_consumed()
	_test_anchor_places_cultures_at_their_origin()
	print("culture tests: PASS")
	quit(0)


func _test_presets_are_complete() -> void:
	assert(Culture.Kind.size() == 12, "문화는 12종이다: %d" % Culture.Kind.size())
	for kind in range(Culture.Kind.size()):
		assert(Culture.NAMES.has(kind), "문화 이름 누락: %d" % kind)
		assert(Culture.ORIGIN_REGION.has(kind), "지리 원산 누락: %d" % kind)
		var preset: Dictionary = Culture.PRESETS[kind]
		assert(preset.size() == PARAM_KEYS.size(),
			"%s 파라미터 개수 불일치: %d" % [Culture.NAMES[kind], preset.size()])
		for key in PARAM_KEYS:
			assert(preset.has(key), "%s 에 %s 없음" % [Culture.NAMES[kind], key])
			var v: float = preset[key]
			assert(v >= 0.0 and v <= 1.0, "%s.%s 범위 이탈: %f" % [Culture.NAMES[kind], key, v])


func _test_cultures_do_not_cluster() -> void:
	var worst := 1.0
	var pair := ""
	for a in range(Culture.Kind.size()):
		for b in range(a + 1, Culture.Kind.size()):
			var d := Culture.distance(a, b)
			if d < worst:
				worst = d
				pair = "%s-%s" % [Culture.NAMES[a], Culture.NAMES[b]]
	assert(worst >= MIN_CULTURE_DISTANCE,
		"문화 파라미터가 뭉쳤다: %s 거리 %.3f" % [pair, worst])


func _test_every_culture_has_names() -> void:
	for kind in range(Culture.Kind.size()):
		var data := CharacterSystem.name_data(kind)
		for key in ["family", "given", "nation_stems"]:
			var pool: Array = data.get(key, [])
			assert(pool.size() >= 5, "%s 의 %s 풀이 너무 작다: %d"
				% [Culture.NAMES[kind], key, pool.size()])
		# 티어가 하나라도 비면 그 크기의 나라는 이름을 못 받는다.
		for tier in range(NationPlacer.TIER_KEYS.size()):
			var titles := NationPlacer.tier_titles(data, tier)
			assert(titles.size() >= 2, "%s 의 %s 칭호가 없다"
				% [Culture.NAMES[kind], NationPlacer.TIER_KEYS[tier]])


func _test_quota_matches_nation_count() -> void:
	var rng := RandomNumberGenerator.new()
	for seed_value in range(40):
		rng.seed = seed_value
		for count in [40, 115]:
			var quota := Culture.roll_quota(count, rng)
			var total := 0
			for q in quota:
				assert(q >= 0, "음수 정원")
				total += q
			assert(total == count, "정원 합이 국가 수와 다르다: %d != %d" % [total, count])


func _test_rare_tier_sometimes_absent() -> void:
	var rng := RandomNumberGenerator.new()
	var runs := 200
	var absent_runs := 0
	for seed_value in range(runs):
		rng.seed = seed_value
		var quota := Culture.roll_quota(40, rng)
		for q in quota:
			if q == 0:
				absent_runs += 1
				break
	var rate := float(absent_runs) / float(runs)
	# 판마다 "이번엔 없는 문화" 가 있어야 하고, 매번 절반이 사라지면 죽은 콘텐츠다.
	assert(rate >= 0.20 and rate <= 0.95,
		"미등장 문화가 있는 런의 비율이 대역을 벗어남: %.2f" % rate)


## 신설 파라미터가 실제 코드 경로를 지나는지 — 세 곳 전부 확인한다 (§M11.3 유령값 금지).
func _test_assimilation_is_consumed() -> void:
	var world := WorldState.create(7, MapSource.Kind.NOISE)
	var n: Nation = world.nations[0]
	var p: Province = world.provinces[n.provinces[0]]
	p.culture = Culture.Kind.CHEESE_TABBY if n.culture != Culture.Kind.CHEESE_TABBY \
		else Culture.Kind.RAGDOLL
	p.integration = 0.5
	assert(p.culture_distance(n.culture) > 0.0, "테스트 전제: 이문화 프로빈스")

	n.culture_params["assimilation"] = 0.0
	var lax_drift := Unrest.drift(p, n)
	var lax_upkeep := Economy.infra_upkeep(p, n)
	EmpireSystem._recompute_administration(world, n)
	var lax_load := n.admin_load

	n.culture_params["assimilation"] = 1.0
	var eager_drift := Unrest.drift(p, n)
	var eager_upkeep := Economy.infra_upkeep(p, n)
	EmpireSystem._recompute_administration(world, n)
	var eager_load := n.admin_load

	assert(eager_drift < lax_drift, "동화 성향이 이문화 불만을 줄이지 않는다")
	assert(eager_load < lax_load, "동화 성향이 이문화 행정 부하를 줄이지 않는다")
	assert(eager_upkeep > lax_upkeep, "동화의 대가(행정비)가 재정에 걸리지 않는다")


## 앵커가 걸리면 그 지역 원산 문화의 비중이 무작위 배치보다 확실히 높아야 한다.
func _test_anchor_places_cultures_at_their_origin() -> void:
	var world := WorldState.create(3, MapSource.Kind.EARTH)
	var matched := 0
	var regional := 0
	for n in world.nations:
		var region: int = world.provinces[n.capital].region
		if region < 0:
			continue
		regional += 1
		if int(Culture.ORIGIN_REGION[n.culture]) == region:
			matched += 1
	assert(regional > 0, "지구 지도 수도에 지역 라벨이 없다")
	var rate := float(matched) / float(regional)
	# 12종 중 원산이 겹치는 지역이 있어 무작위 기대값은 대략 0.1 안팎이다.
	assert(rate > 0.20, "지리 원산 앵커가 작동하지 않는다: %.2f" % rate)
