class_name Character extends RefCounted

## 인물은 생성 순간 이름·능력치·사망 턴이 모두 확정되는 결정론적 데이터다.

enum Role { NONE, POLITICAL, TECH, ECONOMIC, MILITARY, NAVAL, GENERAL }

const ADVISOR_ROLES: Array[int] = [Role.POLITICAL, Role.TECH, Role.ECONOMIC,
	Role.MILITARY, Role.NAVAL]
const SLOTS := {
	Role.POLITICAL: 3,
	Role.TECH: 1,
	Role.ECONOMIC: 1,
	Role.MILITARY: 1,
	Role.NAVAL: 1,
}
const ROLE_NAMES := {
	Role.NONE: "후보자",
	Role.POLITICAL: "정치 고문",
	Role.TECH: "기술 고문",
	Role.ECONOMIC: "경제 고문",
	Role.MILITARY: "군사 고문",
	Role.NAVAL: "해군 고문",
	Role.GENERAL: "장군",
}

var id: int = -1
var nation_id: int = -1
var name: String = ""
var family_name: String = ""
var given_name: String = ""
var culture: int = Culture.Kind.KOREAN_SHORTHAIR
var birth_turn: int = 0
var death_turn: int = 0
var is_alive: bool = true

# 4대 능력치 (0~100)
var intelligence: float = 0.0
var charisma: float = 0.0
var health: float = 0.0
var creativity: float = 0.0

var role: int = Role.NONE
var loyalty: float = 0.5
var ambition: float = 0.0
## 매파 성향 (0~1). 정치 고문석에 앉으면 국가의 개전 성향이 된다 — 같은 위협을
## 기회로 읽고, 같은 전력차에서 더 밀어붙인다. 0.5 가 중립이다.
var hawkish: float = 0.5
## 강제 진압 선호 (0~1). 정치 고문석에 앉으면 국가의 진압 의지가 된다 — 낮으면
## 분리주의가 높은 땅을 군대로 누르지 않고 방치한다. 0.5 가 중립이다.
var suppression_bias: float = 0.5
var noble_birth: float = 0.0
var home_province: int = -1
var education_at_birth: float = 0.0
var rebellion_requested: bool = false


func score_for(target_role: int) -> float:
	match target_role:
		Role.POLITICAL:
			return charisma * 0.70 + intelligence * 0.30
		Role.TECH:
			return creativity * 0.65 + intelligence * 0.35
		Role.ECONOMIC:
			return intelligence * 0.75 + creativity * 0.25
		Role.MILITARY:
			return intelligence * 0.45 + charisma * 0.35 + health * 0.20
		Role.NAVAL:
			return intelligence * 0.40 + creativity * 0.35 + health * 0.25
		Role.GENERAL:
			return charisma * 0.40 + health * 0.35 + intelligence * 0.25
	return 0.0


func best_role() -> int:
	var best := Role.POLITICAL
	var best_score := score_for(best)
	for candidate in [Role.TECH, Role.ECONOMIC, Role.MILITARY, Role.NAVAL, Role.GENERAL]:
		var candidate_score := score_for(candidate)
		if candidate_score > best_score:
			best = candidate
			best_score = candidate_score
	return best


## M7 군대가 인물을 장군으로 임명할 때 그대로 적용할 파생치 (§13.5).
func general_effects() -> Dictionary:
	return {
		"power_mult": 1.0 + charisma / 100.0 * 0.45,
		"attrition_res": health / 100.0 * 0.40,
		"supply_bonus": intelligence / 100.0 * 0.25,
		"ambush_chance": creativity / 100.0 * 0.20,
	}


static func is_advisor_role(target_role: int) -> bool:
	return target_role in ADVISOR_ROLES


static func role_name(target_role: int) -> String:
	return ROLE_NAMES.get(target_role, "알 수 없음")
