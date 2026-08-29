class_name Inflation extends RefCounted

## 즉시 계산값이 아니라 누적 상태값. lerp 로 관성을 줘야 투자 게임이 성립한다.

const LERP_RATE := 0.35
const FLOOR := -0.5      # 디플레 스파이럴로 실질 GDP 가 발산하는 것을 막는다


static func tick(world: WorldState) -> void:
	for n in world.nations:
		if not n.is_alive:
			continue
		tick_nation(n)


static func tick_nation(n: Nation) -> void:
	var money_growth := n.money_supply / maxf(n.prev_money_supply, 1.0)
	var output_growth := n.real_gdp / maxf(n.prev_real_gdp, 1.0)
	var target := (money_growth / maxf(output_growth, 0.0001)) - 1.0

	target += n.law_modifier("inflation_pressure")
	target *= (1.0 - n.inflation_damping)

	n.inflation = lerpf(n.inflation, target, LERP_RATE)
	n.inflation = maxf(n.inflation, FLOOR)

	n.prev_real_gdp = n.real_gdp
	n.prev_money_supply = n.money_supply
	n.real_gdp = n.nominal_gdp / (1.0 + n.inflation)
