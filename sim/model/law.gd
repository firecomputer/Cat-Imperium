class_name Law extends Resource

## 법률은 코드가 아니라 데이터(.tres)다. 법률 추가 시 시뮬 코드를 건드리지 않는다.
## 모든 법률은 최소 1개 이상의 스탯을 깎는다 — 순수 이득 법률이 하나라도 있으면 다양성이 죽는다.

@export var id: String = ""
@export var category: String = ""
@export var severity: float = 0.0        # -1.0(관대) ~ +1.0(가혹)
@export var modifiers: Dictionary = {}

## 곱셈 계열: 중립값 1.0, 저장값은 증분 (0.06 → ×1.06)
const MULTIPLICATIVE := ["productivity", "borrowing_capacity", "admin_cost"]

## 덧셈 계열: 중립값 0.0
const ADDITIVE := ["tax_rate", "inflation_pressure", "education", "healthcare",
	"unrest", "manpower", "army_morale", "trade", "merit"]

## AI 평가 전용 힌트. 시뮬 스탯이 아니다 (§6.4).
const AI_HINTS := ["immediate_income", "stability", "long_term_growth"]

const CATEGORIES := ["tax", "occupation", "currency", "conscription",
	"status", "trade", "education", "health"]


func modifier(key: String) -> float:
	return modifiers.get(key, 0.0)
