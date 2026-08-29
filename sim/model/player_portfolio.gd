class_name PlayerPortfolio extends RefCounted

## M9 최소 포트폴리오. 시장 충격·호가·유동성은 두지 않고 정수 단위만 거래한다.
## 플레이어 상태를 WorldState 안에 두어 동일 행동 로그로 재현할 수 있게 한다 (§15).

const STARTING_CASH := 25000.0

var cash: float = STARTING_CASH
var bond_holdings: Dictionary = {}       # nation_id -> units
var province_holdings: Dictionary = {}   # province_id -> units
var character_holdings: Dictionary = {}  # character_id -> units

var total_dividends: float = 0.0
var total_sale_proceeds: float = 0.0
var trade_count: int = 0
var action_log: Array[Dictionary] = []

var history_turns: Array[int] = []
var cash_history: Array[float] = []
var net_worth_history: Array[float] = []


func holdings(kind: int) -> Dictionary:
	match kind:
		Market.AssetKind.BOND:
			return bond_holdings
		Market.AssetKind.PROVINCE:
			return province_holdings
		Market.AssetKind.CHARACTER:
			return character_holdings
	return {}


func quantity(kind: int, asset_id: int) -> int:
	return int(holdings(kind).get(asset_id, 0))


func set_quantity(kind: int, asset_id: int, value: int) -> void:
	var book := holdings(kind)
	if value <= 0:
		book.erase(asset_id)
	else:
		book[asset_id] = value
