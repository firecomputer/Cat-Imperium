extends SceneTree

## 재정난이 깊어질수록 AI 가 스스로 가혹해지는지 확인한다 (§6.4).
## 실제 국고 압박은 credit.gd(M5) 가 만들므로, 여기서는 신용한도 소진률을 직접 주입한다.
##
##   godot --headless --script res://tools/test_laws.gd


func _initialize() -> void:
	var pool := LawSystem.laws_by_category()
	var rng := RandomNumberGenerator.new()
	rng.seed = 1

	print("%-14s %-8s %s" % ["culture", "desp", "채택 법률"])
	for kind in range(Culture.Kind.size()):
		var previous_severity := -INF
		for desp in [0.0, 0.5, 1.0]:
			var n := Nation.new()
			n.culture = kind
			n.culture_params = Culture.roll(kind, rng)
			n.gdp = 1000.0
			n.debt = desp * Credit.credit_limit(n)
			var picked: Array[String] = []
			var severity := 0.0
			for cat in Law.CATEGORIES:
				var best: Law = null
				var best_score := -INF
				for law: Law in pool[cat]:
					var s := LawEvaluator.evaluate(n, law)
					if s > best_score:
						best_score = s
						best = law
				picked.append(best.id)
				severity += best.severity
			print("%-14s %-8.1f %.2f  %s" % [Culture.NAMES[kind], desp,
				severity / Law.CATEGORIES.size(), ", ".join(picked)])
			var average := severity / Law.CATEGORIES.size()
			assert(average >= previous_severity,
				"재정난이 깊어졌는데 법률 묶음이 더 온건해지면 안 된다: %s" % Culture.NAMES[kind])
			previous_severity = average

	_test_cheese_tabby_is_unstable_but_not_doomed()
	print("law tests: PASS")
	quit(0)


func _test_cheese_tabby_is_unstable_but_not_doomed() -> void:
	var n := _representative_nation(Culture.Kind.CHEESE_TABBY)
	var domestic := _capital_drift(n)
	var stable := _capital_drift(_representative_nation(Culture.Kind.KOREAN_SHORTHAIR))
	assert(domestic > stable and domestic < 0.005,
		"치즈 태비는 안정 문화보다 불안정하되 본토가 확정 붕괴해서는 안 된다: "
		+ "치즈 %.4f, 안정 %.4f" % [domestic, stable])

	var before := Unrest.domestic_law_unrest(n)
	n.set_law("occupation", load("res://data/laws/occupation_autonomy.tres"))
	var after := Unrest.domestic_law_unrest(n)
	assert(is_equal_approx(before, after),
		"점령법의 불만은 본토 법률 합계가 아니라 정복지 점령 항에서만 작동해야 한다")


func _representative_nation(kind: Culture.Kind) -> Nation:
	var n := Nation.new()
	n.culture = kind
	n.culture_params = Culture.PRESETS[kind].duplicate()
	n.gdp = 1000.0
	LawSystem.adopt_for(n)
	return n


func _capital_drift(n: Nation) -> float:
	var p := Province.new()
	p.culture = n.culture
	p.integration = 1.0
	p.distance_from_capital = 0.0
	return Unrest.drift(p, n)
