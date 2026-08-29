class_name BudgetAI extends RefCounted

## 인프라와 군대에 얼마를 쓸지, 그중 얼마를 국채로 조달할지 정한다.
## 부채 상환은 credit.tick() 의 흑자 분기가 맡는다.

const SHARE_MIN := 0.10
const SHARE_MAX := 0.90
const DESPERATION_BRAKE := 0.8
const CREDIT_TARGET_MIN := 0.75
const CREDIT_TARGET_MAX := 0.98
const CREDIT_PACE_GDP := 0.021             # 한 턴 신규 건설 차입 상한
const MIN_INVESTMENT_RATING := 0.55

const MILITARY_SHARE_BASE := 0.012         # GDP 대비 최소 군사비 (§9.4)
const MILITARY_SHARE_SPAN := 0.05          # 호전성이 끌어올리는 폭
const MILITARY_WAR_MULT := 1.5
const MILITARY_REVOLT_MULT := 1.25        # 반란 진압은 총력전이 아니다
const MILITARY_SHARE_MAX := 0.09
const MILITARY_BANKRUPTCY_MULT := 0.5


## 전시 배율 2.0 · 상한 12%% 로는 대외전쟁 한 번이 나라를 파산시켜
## M5 기준(첫 파산 100~250턴)이 46턴으로 무너졌다. 전쟁은 아파야 하지만
## 즉사시켜서는 안 된다.
## 군사비를 GDP 비율로 묶는다. 절대액이 아니므로 군비 확장은 성장을 잠식하고,
## 재정난이 오면 desperation 이 병력을 스스로 깎는다 (§9.4).
static func military_share(n: Nation) -> float:
	var share := MILITARY_SHARE_BASE + n.culture_bias("aggression") * MILITARY_SHARE_SPAN
	if n.at_foreign_war:
		share *= MILITARY_WAR_MULT
	elif n.at_war:
		share *= MILITARY_REVOLT_MULT
	if n.bankruptcy_timer > 0:
		share *= MILITARY_BANKRUPTCY_MULT
	share *= 1.0 - LawEvaluator.desperation(n) * DESPERATION_BRAKE
	return clampf(share, 0.0, MILITARY_SHARE_MAX)


## 예비비를 남기고 남은 돈의 일부와 제한된 투자 차입만 건설에 쓴다.
## 인내심(development)이 높을수록 많이 짓고, 신중함(fiscal_prudence)이 높을수록 예비비를 크게 잡는다.
## 유지비조차 못 내는 국가는 새 건설 차입을 할 수 없다. 이자 부담은
## desperation으로 투자 속도를 낮추지만, 과잉 투자 위험까지 제거하지는 않는다.
static func infra_plan(n: Nation, upkeep_total: float) -> Dictionary:
	if n.bankruptcy_timer > 0:
		return {"budget": 0.0, "borrowing": 0.0}  # 파산 직후 강제 긴축

	var interest_due := n.debt * Credit.interest_rate(n)
	var primary_surplus := n.income - upkeep_total
	var recurring_surplus := primary_surplus - interest_due
	var cash := n.treasury + recurring_surplus
	var reserve := upkeep_total * (1.0 + n.culture_bias("fiscal_prudence") * 3.0)
	var spare := maxf(cash - reserve, 0.0)
	var share := clampf(0.25 + n.culture_bias("development") * 0.6, SHARE_MIN, SHARE_MAX)
	share *= (1.0 - LawEvaluator.desperation(n) * DESPERATION_BRAKE)
	var cash_budget := spare * share

	var borrowing := 0.0
	if primary_surplus > 0.0 and n.credit_rating >= MIN_INVESTMENT_RATING:
		var limit := Credit.credit_limit(n)
		var target_debt := limit * infra_credit_target(n)
		var target_room := maxf(target_debt - n.debt, 0.0)
		var pace := n.gdp * CREDIT_PACE_GDP * (0.25 + n.culture_bias("development") * 0.75)
		pace *= 1.0 - LawEvaluator.desperation(n) * DESPERATION_BRAKE
		borrowing = minf(target_room, pace)

	return {"budget": cash_budget + borrowing, "borrowing": borrowing}


## 개발 성향은 목표를 높이고 재정 신중함은 낮춘다. 신용한도 전체를 건설에 쓰지는 않는다.
static func infra_credit_target(n: Nation) -> float:
	return clampf(0.82 + n.culture_bias("development") * 0.25 \
		- n.culture_bias("fiscal_prudence") * 0.12, CREDIT_TARGET_MIN, CREDIT_TARGET_MAX)
