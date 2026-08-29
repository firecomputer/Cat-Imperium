class_name War extends RefCounted

## 전쟁 하나. 다자 참전을 전제로 진영을 배열로 둔다 (§11.2 하이에나 참전, §12).
## warscore 는 공격 진영 기준 -100 ~ +100 이며 peace.gd 가 조항 비용과 비교한다.

enum Goal { CONQUEST, SUBJUGATION, INDEPENDENCE }

var id: int = -1
var attackers: Array[int] = []            # Nation id
var defenders: Array[int] = []
var primary_attacker: int = -1
var primary_defender: int = -1
var start_turn: int = 0
var is_active: bool = true
var goal: int = Goal.CONQUEST
var goal_score: float = 35.0

var warscore: float = 0.0
var battles_won: int = 0                  # 공격 진영 기준
var battles_lost: int = 0
var attacker_losses: float = 0.0
var defender_losses: float = 0.0
var occupied_value_attacker: float = 0.0  # 공격 진영이 점령 중인 적 프로빈스 가치
var occupied_value_defender: float = 0.0

## M8.5 반란전 전용. 반란전은 일반 warscore·강화 경로를 타지 않는다 (§3, §4).
## 모국은 항상 공격 진영이므로 손실은 attacker_losses / defender_losses 를 그대로 읽는다.
var is_rebel_war: bool = false
var parent_nation_id: int = -1
var rebel_nation_id: int = -1
## 반란이 떼어 간 프로빈스 스냅샷. 인접 프로빈스가 합류할 때마다 늘어난다.
var rebel_origin_provinces: PackedInt32Array = PackedInt32Array()
var rebel_capital_province: int = -1
## 0 ~ 100. 반란군이 영토를 지킨 턴만큼 쌓이고, 100 에서 독립이 인정된다 (§5).
var recognition: float = 0.0


static func goal_name(value: int) -> String:
	match value:
		Goal.SUBJUGATION:
			return "속국화"
		Goal.INDEPENDENCE:
			return "독립"
		_:
			return "정복"


func side_of(nation_id: int) -> int:
	if nation_id in attackers:
		return 1
	if nation_id in defenders:
		return -1
	return 0


func is_enemy(a: int, b: int) -> bool:
	var sa := side_of(a)
	var sb := side_of(b)
	return sa != 0 and sb != 0 and sa != sb


func participants() -> Array[int]:
	var out: Array[int] = []
	out.append_array(attackers)
	out.append_array(defenders)
	return out


func enemies_of(nation_id: int) -> Array[int]:
	var side := side_of(nation_id)
	if side == 1:
		return defenders.duplicate()
	if side == -1:
		return attackers.duplicate()
	return []
