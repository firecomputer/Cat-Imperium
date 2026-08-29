class_name Market extends RefCounted

## M9 최소 투자 시장. 별도 가격 발견 시뮬레이션을 만들지 않고 이미 계산된
## 경제·신용·불만·보급·인물 수치를 가격 신호로 변환한다 (§14).

enum AssetKind { BOND, PROVINCE, CHARACTER }

const BOND_FACE_VALUE := 100.0
const PROVINCE_DIVIDEND_RATE := 0.005
const CHARACTER_ROLE_DIVIDEND_RATE := 0.02


static func bond_price(n: Nation) -> float:
	if not n.is_alive:
		return 0.0
	return BOND_FACE_VALUE * n.credit_rating \
		* (1.0 - clampf(n.inflation, 0.0, 0.9))


static func province_share_price(p: Province) -> float:
	return maxf(p.gdp, 0.0) / 1000.0 \
		* (1.0 - clampf(p.unrest, 0.0, 1.0) * 0.7) \
		* clampf(p.supply, 0.0, 1.0)


static func character_stake_price(c: Character, turn: int) -> float:
	if not c.is_alive:
		return 0.0
	var remaining := clampf(float(c.death_turn - turn) / 30.0, 0.0, 1.0)
	return c.score_for(c.best_role()) * remaining * 0.5


static func growth_headroom(p: Province) -> float:
	var anchor := Economy.gdp_pc_anchor(p.infra)
	if anchor <= 0.0:
		return 0.0
	return (anchor - p.gdp_pc) / anchor


static func price(world: WorldState, kind: int, asset_id: int) -> float:
	match kind:
		AssetKind.BOND:
			if asset_id >= 0 and asset_id < world.nations.size():
				return bond_price(world.nations[asset_id])
		AssetKind.PROVINCE:
			if asset_id >= 0 and asset_id < world.provinces.size():
				return province_share_price(world.provinces[asset_id])
		AssetKind.CHARACTER:
			if asset_id >= 0 and asset_id < world.characters.size():
				return character_stake_price(world.characters[asset_id], world.turn)
	return 0.0


static func buy(world: WorldState, kind: int, asset_id: int, units: int) -> bool:
	if world.portfolio == null or units <= 0 or not _tradable(world, kind, asset_id):
		return false
	var unit_price := price(world, kind, asset_id)
	var total := unit_price * units
	if unit_price <= 0.0 or world.portfolio.cash + 0.0001 < total:
		return false
	world.portfolio.cash -= total
	var before := world.portfolio.quantity(kind, asset_id)
	world.portfolio.set_quantity(kind, asset_id, before + units)
	world.portfolio.trade_count += 1
	_log_trade(world, "buy", kind, asset_id, units, unit_price)
	return true


static func sell(world: WorldState, kind: int, asset_id: int, units: int) -> bool:
	if world.portfolio == null or units <= 0:
		return false
	var before := world.portfolio.quantity(kind, asset_id)
	if before < units:
		return false
	var unit_price := price(world, kind, asset_id)
	world.portfolio.cash += unit_price * units
	world.portfolio.set_quantity(kind, asset_id, before - units)
	world.portfolio.total_sale_proceeds += unit_price * units
	world.portfolio.trade_count += 1
	_log_trade(world, "sell", kind, asset_id, units, unit_price)
	return true


## 파이프라인 14단계. 국채는 신용 위험에 비례한 이자, 프로빈스는 지역 경제
## 배당, 인물 후원은 실제 보직을 얻은 동안만 수익을 준다.
static func tick(world: WorldState) -> void:
	if world.portfolio == null:
		return
	var payout := _bond_dividends(world) + _province_dividends(world) \
		+ _character_dividends(world)
	if payout > 0.0:
		world.portfolio.cash += payout
		world.portfolio.total_dividends += payout
		world.log_event("market_dividend", {"amount": payout})
	_record_history(world)


static func net_worth(world: WorldState) -> float:
	if world.portfolio == null:
		return 0.0
	var total := world.portfolio.cash
	for kind in [AssetKind.BOND, AssetKind.PROVINCE, AssetKind.CHARACTER]:
		var book := world.portfolio.holdings(kind)
		var ids: Array = book.keys()
		ids.sort()
		for asset_id in ids:
			total += int(book[asset_id]) * price(world, kind, int(asset_id))
	return total


static func _tradable(world: WorldState, kind: int, asset_id: int) -> bool:
	match kind:
		AssetKind.BOND:
			return asset_id >= 0 and asset_id < world.nations.size() \
				and world.nations[asset_id].is_alive
		AssetKind.PROVINCE:
			return asset_id >= 0 and asset_id < world.provinces.size()
		AssetKind.CHARACTER:
			return asset_id >= 0 and asset_id < world.characters.size() \
				and world.characters[asset_id].is_alive
	return false


static func _bond_dividends(world: WorldState) -> float:
	var payout := 0.0
	var ids: Array = world.portfolio.bond_holdings.keys()
	ids.sort()
	for nation_id in ids:
		var id := int(nation_id)
		if id < 0 or id >= world.nations.size():
			continue
		var n: Nation = world.nations[id]
		if not n.is_alive or n.bankruptcy_timer > 0:
			continue
		# 부실채권이 액면 100 기준 이자를 매 턴 지급하면 가격 5짜리 채권이 한 턴에
		# 27을 뱉는 무위험 차익이 된다. 현재 시장가 기준 수익률로 지급한다.
		payout += int(world.portfolio.bond_holdings[nation_id]) \
			* bond_price(n) * Credit.interest_rate(n)
	return payout


static func _province_dividends(world: WorldState) -> float:
	var payout := 0.0
	var ids: Array = world.portfolio.province_holdings.keys()
	ids.sort()
	for province_id in ids:
		var id := int(province_id)
		if id < 0 or id >= world.provinces.size():
			continue
		payout += int(world.portfolio.province_holdings[province_id]) \
			* province_share_price(world.provinces[id]) * PROVINCE_DIVIDEND_RATE
	return payout


static func _character_dividends(world: WorldState) -> float:
	var payout := 0.0
	var ids: Array = world.portfolio.character_holdings.keys()
	ids.sort()
	for character_id in ids:
		var id := int(character_id)
		if id < 0 or id >= world.characters.size():
			continue
		var c: Character = world.characters[id]
		if not c.is_alive or c.role == Character.Role.NONE:
			continue
		payout += int(world.portfolio.character_holdings[character_id]) \
			* c.score_for(c.role) * CHARACTER_ROLE_DIVIDEND_RATE
	return payout


static func _record_history(world: WorldState) -> void:
	world.portfolio.history_turns.append(world.turn + 1)
	world.portfolio.cash_history.append(world.portfolio.cash)
	world.portfolio.net_worth_history.append(net_worth(world))


static func _log_trade(world: WorldState, side: String, kind: int, asset_id: int,
		units: int, unit_price: float) -> void:
	var action := {
		"turn": world.turn,
		"side": side,
		"asset_kind": kind,
		"asset": asset_id,
		"units": units,
		"price": unit_price,
	}
	world.portfolio.action_log.append(action.duplicate())
	world.log_event("market_trade", action)
