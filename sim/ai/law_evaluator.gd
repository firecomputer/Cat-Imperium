class_name LawEvaluator extends RefCounted

## 가혹함을 확률로 강제하지 않는다. 재정난이 단기 수익 법률의 효용을 스스로 끌어올린다 (§6.4).


## 3단계 방어선(§7.1)의 진행도. 한도를 소진할수록, 돈을 찍을수록 근시안이 된다.
static func desperation(n: Nation) -> float:
	var used := n.debt / maxf(Credit.credit_limit(n), 1.0)
	var printing := float(n.printing_streak) / float(Credit.DEFAULT_PRINTING_STREAK)
	return clampf(maxf(used, printing), 0.0, 1.0)


## 점령법의 불만 비용은 이문화 영토에만 발생한다 (Unrest.drift 의 occ 항).
## 이 노출을 모르면 immediate_income 배율이 desperation 0.12 만 넘어도 약탈을
## 무조건 이기게 만들어, 실측에서 큰 나라 37개 중 35개가 약탈을 들고 스스로
## 갈라졌다. 정복할수록 점령 정책이 비싸져야 제국이 땅을 소화할 수 있다.
const OCCUPATION_EXPOSURE_W := 8.0


static func evaluate(n: Nation, law: Law) -> float:
	var d := desperation(n)
	var score := 0.0
	# 점령법의 효과는 전부 미통합 정복지에서만 나온다 (Economy.occupation_extraction,
	# Unrest 의 점령 항, EmpireSystem 의 통합 배율 — 셋 다 Province.occupation_base).
	# 그 밑변을 곱하지 않으면 정복지가 없는 나라까지 점령법이 손익을 갖는다.
	# 셋 중 income 만 깎으면 반대로 기울어진다: 약탈은 수익을 잃고 감점만 남는데
	# 자치는 비용만 잃고 stability +0.5 를 그대로 챙겨, 온 세계가 자치로 쏠린다
	# (실측 프로빈스 5개 이상 201개국 중 약탈 0). 세 힌트를 같은 밑변으로 줄인다.
	var scale := occupation_yield_share(n) if law.category == "occupation" else 1.0
	score += law.modifier("immediate_income") * scale * (1.0 + d * 4.0)
	score += law.modifier("stability") * scale * (1.0 - d * 0.8)
	score += law.modifier("long_term_growth") * scale * (1.0 - d)
	score += culture_bias_for_law(n, law)
	if law.category == "occupation":
		score -= law.severity * n.foreign_exposure * OCCUPATION_EXPOSURE_W
	return score


## 점령 수취가 걸리는 GDP 비율. 이 값이 0 이면 점령법은 순수 비용이다.
static func occupation_yield_share(n: Nation) -> float:
	return clampf(n.occupation_gdp / maxf(n.gdp, 1.0), 0.0, 1.0)


## 문화 설정을 법률 선호로 번역하는 통로. 같은 재정 상태라도 품종마다 다른 법을 고른다.
static func culture_bias_for_law(n: Nation, law: Law) -> float:
	var b := 0.0
	# 가혹함 자체에 대한 성향
	b += law.severity * (n.culture_bias("greed") * 0.6 + n.culture_bias("aggression") * 0.4 - 0.5) * 1.4
	# 안정 / 장기성장에 두는 가중치
	b += law.modifier("stability") * (n.culture_bias("cohesion") - 0.5) * 0.9
	b += law.modifier("long_term_growth") * (n.culture_bias("development") - 0.4) * 1.0
	# 분야별 성향
	b += law.modifier("education") * (n.culture_bias("curiosity") - 0.4) * 1.2
	b += law.modifier("healthcare") * (n.culture_bias("fertility") - 0.4) * 1.2
	b += law.modifier("trade") * (n.culture_bias("maritime") - 0.4) * 1.2
	b += law.modifier("manpower") * (n.culture_bias("aggression") - 0.4) * 1.2
	# 결속이 높으면 불만을 감당할 수 있다고 본다
	b += law.modifier("unrest") * (n.culture_bias("cohesion") - 0.5) * 2.0
	# 재정 신중함이 낮을수록 화폐 남발을 덜 꺼린다
	b += law.modifier("inflation_pressure") * (0.5 - n.culture_bias("fiscal_prudence")) * 4.0
	return b
