extends SceneTree

## M9 시장·포트폴리오 회귀 테스트.
##
##   godot4 --headless --path . --script res://tools/test_market.gd

const EPS := 0.01


func _initialize() -> void:
	_test_design_prices()
	_test_buy_and_sell()
	_test_buy_rejects_insufficient_cash()
	_test_dividends_follow_asset_state()
	_test_dead_character_becomes_worthless()
	_test_history_records_after_tick()
	_test_full_world_integration()
	print("market tests: PASS")
	quit(0)


func _test_design_prices() -> void:
	var world := _world()
	var n: Nation = world.nations[0]
	n.credit_rating = 0.8
	n.inflation = 0.25
	assert(absf(Market.bond_price(n) - 60.0) < EPS)
	var p: Province = world.provinces[0]
	p.gdp = 1000000.0
	p.unrest = 0.5
	p.supply = 0.8
	assert(absf(Market.province_share_price(p) - 520.0) < EPS)
	assert(Market.character_stake_price(world.characters[0], 0) > 0.0)


func _test_buy_and_sell() -> void:
	var world := _world()
	var unit_price := Market.price(world, Market.AssetKind.BOND, 0)
	var cash_before := world.portfolio.cash
	assert(Market.buy(world, Market.AssetKind.BOND, 0, 3))
	assert(world.portfolio.quantity(Market.AssetKind.BOND, 0) == 3)
	assert(absf(world.portfolio.cash - (cash_before - unit_price * 3.0)) < EPS)
	assert(Market.sell(world, Market.AssetKind.BOND, 0, 2))
	assert(world.portfolio.quantity(Market.AssetKind.BOND, 0) == 1)
	assert(world.portfolio.trade_count == 2)
	assert(world.portfolio.action_log.size() == 2)
	assert(world.events[-1]["side"] == "sell")


func _test_buy_rejects_insufficient_cash() -> void:
	var world := _world()
	world.portfolio.cash = 1.0
	assert(not Market.buy(world, Market.AssetKind.BOND, 0, 1))
	assert(world.portfolio.bond_holdings.is_empty())


func _test_dividends_follow_asset_state() -> void:
	var world := _world()
	world.portfolio.set_quantity(Market.AssetKind.BOND, 0, 1)
	world.portfolio.set_quantity(Market.AssetKind.PROVINCE, 0, 1)
	world.portfolio.set_quantity(Market.AssetKind.CHARACTER, 0, 1)
	var before := world.portfolio.cash
	Market.tick(world)
	assert(world.portfolio.cash > before, "세 자산의 배당이 현금에 들어와야 한다")
	var paid := world.portfolio.cash - before
	assert(absf(world.portfolio.total_dividends - paid) < EPS)

	world.nations[0].bankruptcy_timer = 2
	world.provinces[0].gdp = 0.0
	world.characters[0].role = Character.Role.NONE
	before = world.portfolio.cash
	Market.tick(world)
	assert(absf(world.portfolio.cash - before) < EPS,
		"파산 국채·무배당 지역·무보직 인물은 배당을 주면 안 된다")


func _test_dead_character_becomes_worthless() -> void:
	var world := _world()
	world.portfolio.set_quantity(Market.AssetKind.CHARACTER, 0, 2)
	world.characters[0].is_alive = false
	assert(is_zero_approx(Market.price(world, Market.AssetKind.CHARACTER, 0)))
	assert(Market.sell(world, Market.AssetKind.CHARACTER, 0, 2),
		"가치 0인 자산도 포트폴리오에서 정리할 수 있어야 한다")
	assert(world.portfolio.character_holdings.is_empty())


func _test_history_records_after_tick() -> void:
	var world := _world()
	Market.tick(world)
	assert(world.portfolio.history_turns == [1])
	assert(world.portfolio.cash_history.size() == 1)
	assert(world.portfolio.net_worth_history.size() == 1)
	assert(absf(world.portfolio.net_worth_history[0] - Market.net_worth(world)) < EPS)


func _test_full_world_integration() -> void:
	var world := WorldState.create(7)
	var nation_id := 0
	var province_id: int = world.nations[nation_id].capital
	var character_id: int = world.nations[nation_id].characters[0]
	assert(Market.buy(world, Market.AssetKind.BOND, nation_id, 1))
	assert(Market.buy(world, Market.AssetKind.PROVINCE, province_id, 1))
	assert(Market.buy(world, Market.AssetKind.CHARACTER, character_id, 1))
	SimClock.run(world, 20)
	assert(world.portfolio.net_worth_history.size() == 20)
	assert(is_finite(Market.net_worth(world)) and Market.net_worth(world) >= 0.0,
		"실제 시뮬 속에서도 포트폴리오 가치가 유한해야 한다")


func _world() -> WorldState:
	var world := WorldState.new()
	world.portfolio = PlayerPortfolio.new()

	var n := Nation.new()
	n.id = 0
	n.is_alive = true
	n.credit_rating = 1.0
	n.gdp = 1000000.0
	n.population = 1000.0
	n.culture_params = {"fiscal_prudence": 0.5}
	world.nations = [n]

	var p := Province.new()
	p.id = 0
	p.owner_nation = 0
	p.gdp = 1000000.0
	p.gdp_pc = 500.0
	p.infra = 2.0
	p.supply = 1.0
	world.provinces = [p]
	n.provinces = [0]

	var c := Character.new()
	c.id = 0
	c.nation_id = 0
	c.is_alive = true
	c.death_turn = 60
	c.intelligence = 70.0
	c.charisma = 60.0
	c.health = 50.0
	c.creativity = 80.0
	c.role = Character.Role.TECH
	world.characters = [c]
	n.characters = [0]
	return world
