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
	quit(0)
