class_name Army extends RefCounted

## 군대의 순수 상태. 이동·전쟁 목표 결정은 M8 WarAI가 담당한다.

var id: int = -1
var nation_id: int = -1
var province_id: int = -1
var troops: int = 0
var tech_level: float = 1.0
var morale: float = 1.0
var supply_ratio: float = 1.0
var is_alive: bool = true
var peak_troops: int = 0                  # 퇴각 판정 기준
var target_province: int = -1             # WarAI 가 매 턴 갱신
var retreating: bool = false
## M8.5 치안 분견대. >= 0 이면 그 프로빈스에 묶인 주둔군이며 야전 편성에서 제외된다.
var garrison_province: int = -1
## M9.2 승선. >= 0 이면 그 해역에 떠 있고 province_id 는 -1 이다.
## 다음 턴에 landing_target 으로 상륙하며, 그 사이 제해권을 잃으면 격침된다.
var at_sea_zone: int = -1
var landing_target: int = -1

var general_id: int = -1
var power_mult: float = 1.0
var attrition_res: float = 0.0
var supply_bonus: float = 0.0
var ambush_chance: float = 0.0


func apply_general(c: Character) -> void:
	general_id = c.id
	var effects := c.general_effects()
	power_mult = effects["power_mult"]
	attrition_res = effects["attrition_res"]
	supply_bonus = effects["supply_bonus"]
	ambush_chance = effects["ambush_chance"]


func clear_general() -> void:
	general_id = -1
	power_mult = 1.0
	attrition_res = 0.0
	supply_bonus = 0.0
	ambush_chance = 0.0
