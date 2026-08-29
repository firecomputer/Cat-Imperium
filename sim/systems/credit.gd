class_name Credit extends RefCounted

const EmpireSystem = preload("res://sim/systems/empire_system.gd")

## 국고 고갈 → [1] 국채 발행 → [2] 화폐 발행 → [3] 파산 (§7.1).
## 한도는 GDP 에 선형으로 늘지만 행정비·유지비는 초선형으로 는다.
## 그래서 대제국의 붕괴는 지연될 뿐 회피되지 않는다.

const DEBT_ANCHOR := 3.5                 # 신용 한도 / 부채비율 기준이 되는 GDP 배수
const RATE_MIN := 0.02
const RATE_SPAN := 0.28                  # 최대 30%
const RATE_EXP := 2.2

const DEFAULT_INFLATION := 0.60
const DEFAULT_PRINTING_STREAK := 12
const BANKRUPTCY_TURNS := 25
const DEBT_HAIRCUT := 0.35               # 탕감 후 남는 비율
const MILITARY_PENALTY := 0.5
const DEFAULT_UNREST := 0.25
const DEFAULT_INFLATION_SHOCK := 0.15
## 탕감만으로는 회생이 안 된다. 실측 재파산 시점의 debt/gdp 는 21.6 이라
## 65% 탕감 후에도 7.5×GDP 가 남아 최저 신용도 이자가 세수의 17배였다.
## 탕감률은 그대로 두고 상한을 씌운다.
const DEFAULT_DEBT_CEILING := 1.0        # 상한 = DEBT_ANCHOR × GDP × 이 값
## 파산은 사형선고가 아니라 회복 가능한 위기여야 한다. 흑자를 유지하면
## 군사 페널티가 풀리고(0.5 -> 1.0 에 약 42턴) 신용 기억도 감쇠한다.
const MILITARY_RECOVERY := 0.012
const DEFAULT_MEMORY_DECAY := 0.990      # 반감기 약 69턴


## 파산 직후엔 아무도 빌려주지 않는다 (문서에 bankruptcy_timer 효과가 없어 여기서 정의).
static func credit_limit(n: Nation) -> float:
	if n.bankruptcy_timer > 0:
		return 0.0
	return n.gdp * DEBT_ANCHOR \
		* (0.4 + n.credit_rating * 0.6) \
		* (1.0 + n.prestige * 0.25) \
		* n.law_modifier("borrowing_capacity")


static func credit_rating(n: Nation) -> float:
	var r := 1.0
	r -= clampf(n.debt / maxf(n.gdp * DEBT_ANCHOR, 1.0), 0.0, 1.0) * 0.45
	r -= clampf(n.inflation / 0.25, 0.0, 1.0) * 0.25
	r -= n.default_memory * 0.15
	r -= clampf(n.avg_unrest, 0.0, 1.0) * 0.15
	r += clampf(n.consecutive_surplus_turns / 40.0, 0.0, 1.0) * 0.2
	r += n.credit_bonus                                   # M6 경제 고문
	return clampf(r, 0.05, 1.0)


static func interest_rate(n: Nation) -> float:
	return interest_rate_for(n.credit_rating)


static func interest_rate_for(rating: float) -> float:
	return RATE_MIN + pow(1.0 - rating, RATE_EXP) * RATE_SPAN


# ---------------------------------------------------------------- 틱

static func tick(world: WorldState) -> void:
	for n in world.nations:
		if not n.is_alive:
			continue
		tick_nation(world, n)


static func tick_nation(world: WorldState, n: Nation) -> void:
	var was_bankrupt := n.bankruptcy_timer > 0
	# 신용도 산정 전에 감쇠시켜야 같은 턴에 반영된다.
	n.default_memory *= DEFAULT_MEMORY_DECAY
	n.credit_rating = credit_rating(n)
	var debt_at_start := n.debt
	# 파산 타이머는 신규 차입 금지뿐 아니라 채무조정(이자 지급 유예) 기간이다.
	# 신용도 0.05의 약 30% 이자를 즉시 부과하면 35% 탕감 뒤에도 회생이 불가능하다.
	n.interest_expense = 0.0 if was_bankrupt else n.debt * interest_rate(n)

	# 건설용 국채는 먼저 발행해 같은 턴의 건설비와 상계한다. 현금 예비비를
	# 소진한 뒤 사후 차입하는 방식은 AI가 의도한 투자 규모와 달라진다.
	var planned := minf(n.planned_borrowing, maxf(credit_limit(n) - n.debt, 0.0))
	if planned > 0.0:
		n.debt += planned
		n.treasury += planned
	n.planned_borrowing = 0.0

	# 이자는 자동으로 원금에 붙이지 않는다. 현금으로 먼저 지급하고,
	# 부족할 때만 아래의 3단계 방어선으로 신규 차입한다.
	var fiscal_balance := n.income - n.expenses - n.interest_expense
	n.treasury += fiscal_balance
	var deficit_borrowing := 0.0
	var printed := 0.0

	if n.treasury < 0.0:
		n.consecutive_surplus_turns = 0
		var need := -n.treasury
		var room := maxf(credit_limit(n) - n.debt, 0.0)
		n.treasury = 0.0
		deficit_borrowing = minf(need, room)
		n.debt += deficit_borrowing                 # [1] 차입
		need -= deficit_borrowing

		if need > 0.0:
			printed = need
			n.money_supply += printed                 # [2] 화폐 발행
			if n.printing_streak == 0:
				world.log_event("money_printing_started", {
					"nation": n.id,
					"debt": n.debt,
					"gdp": n.gdp,
					"shortfall": printed,
				})
			# 파산 유예 중에도 세면 25턴을 찍은 나라가 streak 26 으로 유예를
			# 빠져나와 첫 턴에 재파산한다 (실측 434건 중 43건). 발행 자체는
			# 계속 일어나므로 로그는 남기고 카운터만 얼린다.
			if n.bankruptcy_timer <= 0:
				n.printing_streak += 1

			var hyper := n.inflation > DEFAULT_INFLATION
			if (hyper or n.printing_streak > DEFAULT_PRINTING_STREAK) and n.bankruptcy_timer <= 0:
				trigger_default(world, n)             # [3] 파산
		else:
			n.printing_streak = 0
	else:
		n.printing_streak = 0
		if fiscal_balance > 0.0:
			n.consecutive_surplus_turns += 1
		else:
			n.consecutive_surplus_turns = 0
		# 파산 군사 페널티는 영구 ×0.5 였다. 흑자를 내는 동안 서서히 푼다.
		if n.bankruptcy_timer <= 0 and n.bankruptcy_military_mult < 1.0 \
				and fiscal_balance > 0.0:
			n.bankruptcy_military_mult = move_toward(n.bankruptcy_military_mult, 1.0,
				MILITARY_RECOVERY)
		# 투자 국채를 발행한 같은 턴에 예비비로 즉시 상환하는 왕복 거래를 막는다.
		if planned <= 0.0 and fiscal_balance > 0.0:
			var repay := minf(fiscal_balance * n.culture_bias("fiscal_prudence"), n.debt)
			n.debt -= repay
			n.treasury -= repay

	if debt_at_start <= 0.0 and n.debt > 0.0:
		world.log_event("credit_started", {
			"nation": n.id,
			"debt": n.debt,
			"gdp": n.gdp,
			"borrowing": planned + deficit_borrowing,
		})

	# 이번 틱에 새로 발생한 파산은 25턴을 온전히 유지한다.
	if was_bankrupt and n.bankruptcy_timer > 0:
		n.bankruptcy_timer -= 1


## 탕감으로 회생 여지를 주되, 위협 인식을 떨어뜨려 주변국이 달려들게 만드는 것이 본래 목적이다.
static func trigger_default(world: WorldState, n: Nation) -> void:
	var cause_streak := n.printing_streak
	EmpireSystem.on_default(world, n)
	n.debt = minf(n.debt * DEBT_HAIRCUT, n.gdp * DEBT_ANCHOR * DEFAULT_DEBT_CEILING)
	n.treasury = 0.0
	n.default_history += 1
	n.default_memory += 1.0
	n.credit_rating = 0.05
	n.bankruptcy_timer = BANKRUPTCY_TURNS
	n.printing_streak = 0                 # 리셋하지 않으면 다음 턴에 즉시 재파산한다
	for other in world.nations:
		if other.id == n.id or not other.is_alive:
			continue
		other.opinion[n.id] = clampf(float(other.opinion.get(n.id, 0.0))
			+ Diplomacy.OPINION_DEFAULT, Diplomacy.OPINION_MIN, Diplomacy.OPINION_MAX)
	n.bankruptcy_military_mult *= MILITARY_PENALTY
	n.military_modifier = n.bankruptcy_military_mult
	for army_id in n.armies:
		var army: Army = world.armies[army_id]
		if army.is_alive:
			army.morale *= MILITARY_PENALTY

	for pid in n.provinces:
		var p: Province = world.provinces[pid]
		p.unrest = minf(1.0, p.unrest + DEFAULT_UNREST)
	n.supply_dirty = true
	n.inflation += DEFAULT_INFLATION_SHOCK

	# TODO M8: 전 세계 opinion -35, 채권국 추가 -30 및 대출액 65% 손실, threat ×0.6 (하이에나)
	world.log_event("national_default", {
		"nation": n.id,
		"culture": n.culture,
		"count": n.default_history,
		"debt": n.debt,
		"gdp": n.gdp,
		"inflation": n.inflation,
		"provinces": n.provinces.size(),
		"printing_streak": cause_streak,
		"income": n.income,
		"expenses": n.expenses,
		"interest": n.interest_expense,
	})
