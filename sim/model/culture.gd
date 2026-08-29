class_name Culture extends RefCounted

## 문화는 스킨이 아니라 AI 성향 파라미터 프리셋이다.
## 국가 생성 시 각 값에 ±노이즈를 주어 같은 품종이라도 판마다 다른 나라가 나온다.

enum Kind { SIAMESE, RAGDOLL, CHEESE_TABBY, RUSSIAN_BLUE, KOREAN_SHORTHAIR }

const NAMES := {
	Kind.SIAMESE: "샴",
	Kind.RAGDOLL: "랙돌",
	Kind.CHEESE_TABBY: "치즈 태비",
	Kind.RUSSIAN_BLUE: "러시안블루",
	Kind.KOREAN_SHORTHAIR: "코리안숏헤어",
}

## 파라미터 0.0~1.0
const PRESETS := {
	# 귀족제·외교·첩보. 전쟁보다 속국화
	Kind.SIAMESE: {
		"aggression": 0.35, "curiosity": 0.60, "cohesion": 0.65, "greed": 0.55,
		"fertility": 0.45, "fiscal_prudence": 0.70, "development": 0.60, "maritime": 0.50,
	},
	# 평화·문화·인구폭발. 군사 최약체
	Kind.RAGDOLL: {
		"aggression": 0.10, "curiosity": 0.55, "cohesion": 0.75, "greed": 0.20,
		"fertility": 0.90, "fiscal_prudence": 0.60, "development": 0.85, "maritime": 0.35,
	},
	# 무모함·확장·약탈. 내정 엉망
	Kind.CHEESE_TABBY: {
		"aggression": 0.90, "curiosity": 0.35, "cohesion": 0.30, "greed": 0.85,
		"fertility": 0.60, "fiscal_prudence": 0.15, "development": 0.20, "maritime": 0.45,
	},
	# 폐쇄·기술·요새화
	Kind.RUSSIAN_BLUE: {
		"aggression": 0.40, "curiosity": 0.90, "cohesion": 0.70, "greed": 0.30,
		"fertility": 0.35, "fiscal_prudence": 0.75, "development": 0.75, "maritime": 0.20,
	},
	# 적응·모방·생존력. 어떤 시대든 중위권
	Kind.KOREAN_SHORTHAIR: {
		"aggression": 0.50, "curiosity": 0.60, "cohesion": 0.60, "greed": 0.50,
		"fertility": 0.60, "fiscal_prudence": 0.50, "development": 0.50, "maritime": 0.60,
	},
}

const NOISE := 0.12


## 두 문화 사이의 거리 0~1. 성향 벡터의 평균 절대차를 쓴다 —
## 문화를 스킨이 아니라 파라미터 프리셋으로 정의했으므로 거리도 거기서 나와야 한다.
static func distance(a: int, b: int) -> float:
	if a < 0 or b < 0 or a == b:
		return 0.0
	var pa: Dictionary = PRESETS[a]
	var pb: Dictionary = PRESETS[b]
	var keys: Array = pa.keys()
	keys.sort()                             # Dictionary 순회 순서에 의존 금지 (§15)
	var sum := 0.0
	for k in keys:
		sum += absf(float(pa[k]) - float(pb[k]))
	return clampf(sum / float(keys.size()) * 2.0, 0.0, 1.0)


## 프리셋에 ±NOISE 를 섞은 개별 국가용 파라미터.
static func roll(kind: int, rng: RandomNumberGenerator) -> Dictionary:
	var out := {}
	var keys: Array = PRESETS[kind].keys()
	keys.sort()   # Dictionary 순회 순서에 의존 금지 (§15)
	for k in keys:
		out[k] = clampf(PRESETS[kind][k] + rng.randf_range(-NOISE, NOISE), 0.0, 1.0)
	return out
