extends SceneTree

## M5 신용 회귀 테스트.
##
##   godot4 --headless --path . --script res://tools/test_credit.gd

const EPS := 0.01


func _initialize() -> void:
	_test_interest_uses_cash_before_new_debt()
	_test_unpaid_interest_is_borrowed()
	_test_planned_investment_debt_persists()
	_test_reserve_does_not_repay_debt_during_deficit()
	_test_printing_after_credit_exhaustion()
	_test_printing_threshold_triggers_default()
	_test_default_blocks_credit_and_forces_austerity()
	_test_infra_credit_is_controlled()
	_test_default_caps_debt_to_gdp()
	_test_military_penalty_recovers_on_surplus()
	_test_default_memory_decays()
	print("credit tests: PASS")
	quit(0)


func _nation() -> Nation:
	var n := Nation.new()
	n.id = 0
	n.gdp = 1000.0
	n.nominal_gdp = n.gdp
	n.real_gdp = n.gdp
	n.money_supply = n.gdp
	n.prev_money_supply = n.money_supply
	n.culture_params = {
		"development": 0.8,
		"fiscal_prudence": 0.0,
	}
	return n


func _world(n: Nation) -> WorldState:
	var world := WorldState.new()
	world.nations = [n]
	return world


func _test_interest_uses_cash_before_new_debt() -> void:
	var n := _nation()
	n.debt = 100.0
	n.income = 20.0
	var world := _world(n)
	var expected_interest := n.debt * Credit.interest_rate_for(Credit.credit_rating(n))
	Credit.tick_nation(world, n)
	assert(is_equal_approx(n.debt, 100.0), "지급 가능한 이자를 원금에 자본화하면 안 된다")
	assert(absf(n.treasury - (20.0 - expected_interest)) < EPS,
		"이자는 당기 현금흐름에서 빠져야 한다")


func _test_unpaid_interest_is_borrowed() -> void:
	var n := _nation()
	n.debt = 100.0
	var world := _world(n)
	var expected_interest := n.debt * Credit.interest_rate_for(Credit.credit_rating(n))
	Credit.tick_nation(world, n)
	assert(absf(n.debt - (100.0 + expected_interest)) < EPS,
		"현금으로 못 낸 이자만 신규 차입이어야 한다")
	assert(is_zero_approx(n.treasury))


func _test_planned_investment_debt_persists() -> void:
	var n := _nation()
	n.culture_params["fiscal_prudence"] = 1.0
	n.treasury = 100.0
	n.income = 150.0
	n.expenses = 200.0                   # 경상비 150 + 차입 건설비 50
	n.planned_borrowing = 50.0
	Credit.tick_nation(_world(n), n)
	assert(absf(n.debt - 50.0) < EPS, "건설 국채를 발행한 턴에 즉시 되갚으면 안 된다")
	assert(absf(n.treasury - 100.0) < EPS)


func _test_reserve_does_not_repay_debt_during_deficit() -> void:
	var n := _nation()
	n.culture_params["fiscal_prudence"] = 1.0
	n.debt = 100.0
	n.treasury = 1000.0
	n.expenses = 10.0
	Credit.tick_nation(_world(n), n)
	assert(absf(n.debt - 100.0) < EPS,
		"당기 적자인데 과거 예비금으로 부채까지 상환하면 붕괴 나선이 끊긴다")
	assert(n.treasury < 1000.0)


func _test_printing_after_credit_exhaustion() -> void:
	var n := _nation()
	n.bankruptcy_timer = 2                 # 파산 중에는 신용한도 0
	n.debt = 100.0
	n.expenses = 10.0
	var world := _world(n)
	Credit.tick_nation(world, n)
	assert(absf(n.money_supply - 1010.0) < EPS)
	# 유예 중에도 발행은 일어나지만 카운터는 얼린다. 세면 25턴을 찍은 나라가
	# streak 26 으로 유예를 빠져나와 첫 턴에 재파산한다.
	assert(n.printing_streak == 0, "파산 유예 중에는 printing_streak 이 오르지 않는다")
	assert(absf(n.debt - 100.0) < EPS, "채무조정 기간에는 이자 지급도 유예한다")
	assert(is_zero_approx(n.interest_expense))


func _test_printing_threshold_triggers_default() -> void:
	var n := _nation()
	n.debt = 10000.0                     # 신용한도를 이미 초과
	n.expenses = 10.0
	n.printing_streak = Credit.DEFAULT_PRINTING_STREAK
	var world := _world(n)
	Credit.tick_nation(world, n)
	assert(n.default_history == 1)
	assert(n.bankruptcy_timer == Credit.BANKRUPTCY_TURNS,
		"파산이 발생한 틱에 타이머를 먼저 줄이면 안 된다")
	assert(world.events[-1]["kind"] == "national_default")


func _test_default_blocks_credit_and_forces_austerity() -> void:
	var n := _nation()
	var world := _world(n)
	Credit.trigger_default(world, n)
	assert(n.bankruptcy_timer == Credit.BANKRUPTCY_TURNS)
	assert(is_zero_approx(Credit.credit_limit(n)))
	var plan := BudgetAI.infra_plan(n, 10.0)
	assert(is_zero_approx(plan["budget"]))
	assert(is_zero_approx(plan["borrowing"]))


func _test_infra_credit_is_controlled() -> void:
	var n := _nation()
	n.income = 200.0
	n.treasury = 100.0
	var plan := BudgetAI.infra_plan(n, 100.0)
	var target_debt := Credit.credit_limit(n) * BudgetAI.infra_credit_target(n)
	assert(plan["borrowing"] > 0.0, "개발 성향 국가는 상환 가능한 범위에서 건설 차입을 해야 한다")
	assert(plan["borrowing"] <= target_debt - n.debt + EPS)
	assert(plan["borrowing"] <= n.gdp * BudgetAI.CREDIT_PACE_GDP + EPS)

	n.income = 50.0                       # 유지비조차 못 내면 건설 차입 금지
	plan = BudgetAI.infra_plan(n, 100.0)
	assert(is_zero_approx(plan["borrowing"]))


## 탕감만으로는 회생이 안 된다 — 실측 재파산 시점의 debt/gdp 는 21.6 이었다 (M10 §4.2).
func _test_default_caps_debt_to_gdp() -> void:
	var n := _nation()
	n.debt = n.gdp * 20.0
	var world := _world(n)
	Credit.trigger_default(world, n)
	assert(n.debt <= n.gdp * Credit.DEBT_ANCHOR * Credit.DEFAULT_DEBT_CEILING + EPS,
		"파산 후 부채는 GDP 배수 상한에 묶인다 (debt/gdp %.1f)" % (n.debt / n.gdp))


## 파산 군사 페널티는 영구 ×0.5 였다. 흑자를 내는 동안 풀린다 (M10 §4.3).
func _test_military_penalty_recovers_on_surplus() -> void:
	var n := _nation()
	n.bankruptcy_military_mult = 0.5
	n.income = 100.0
	n.expenses = 10.0
	var world := _world(n)
	for i in range(60):
		Credit.tick_nation(world, n)
	assert(n.bankruptcy_military_mult > 0.9,
		"흑자를 유지하면 군사 페널티가 회복된다 (%.2f)" % n.bankruptcy_military_mult)


## 신용 기억은 감쇠한다 — default_history 는 통계용 카운터로만 남는다 (M10 §4.4).
func _test_default_memory_decays() -> void:
	var n := _nation()
	var world := _world(n)
	Credit.trigger_default(world, n)
	assert(n.default_history == 1 and n.default_memory > 0.9)
	n.bankruptcy_timer = 0
	n.income = 100.0
	n.expenses = 10.0
	var before := n.default_memory
	for i in range(100):
		Credit.tick_nation(world, n)
	assert(n.default_memory < before * 0.6,
		"파산 기억은 시간에 따라 감쇠한다 (%.2f -> %.2f)" % [before, n.default_memory])
	assert(n.default_history == 1, "통계용 카운터는 그대로 남는다")
