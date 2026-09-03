class_name Culture extends RefCounted

## 문화는 스킨이 아니라 AI 성향 파라미터 프리셋이다.
## 국가 생성 시 각 값에 ±노이즈를 주어 같은 품종이라도 판마다 다른 나라가 나온다.

enum Kind {
	SIAMESE, RAGDOLL, CHEESE_TABBY, RUSSIAN_BLUE, KOREAN_SHORTHAIR,
	BRITISH_SHORTHAIR, NORWEGIAN_FOREST, EGYPTIAN_MAU, PERSIAN, BENGAL,
	TURKISH_ANGORA, ABYSSINIAN,
}

const NAMES := {
	Kind.SIAMESE: "샴",
	Kind.RAGDOLL: "랙돌",
	Kind.CHEESE_TABBY: "치즈 태비",
	Kind.RUSSIAN_BLUE: "러시안블루",
	Kind.KOREAN_SHORTHAIR: "코리안숏헤어",
	Kind.BRITISH_SHORTHAIR: "브리티시숏헤어",
	Kind.NORWEGIAN_FOREST: "노르웨이숲",
	Kind.EGYPTIAN_MAU: "이집션마우",
	Kind.PERSIAN: "페르시안",
	Kind.BENGAL: "벵갈",
	Kind.TURKISH_ANGORA: "터키시앙고라",
	Kind.ABYSSINIAN: "아비시니안",
}

## 파라미터 0.0~1.0
## assimilation 은 M13.7-a 신설 축이다 — 정복지를 녹이는 문화와 누르는 문화를
## 가른다. 높으면 이문화 프로빈스의 불만이 빨리 가라앉고 행정 부하도 덜 지지만,
## 그 대가를 매 턴 동화 행정비로 낸다 (Economy.assimilation_upkeep, §5.5).
const PRESETS := {
	# 귀족제·외교·첩보. 전쟁보다 속국화
	Kind.SIAMESE: {
		"aggression": 0.35, "curiosity": 0.60, "cohesion": 0.65, "greed": 0.55,
		"fertility": 0.45, "fiscal_prudence": 0.70, "development": 0.60, "maritime": 0.50,
		"assimilation": 0.45,
	},
	# 평화·문화·인구폭발. 군사 최약체
	Kind.RAGDOLL: {
		"aggression": 0.10, "curiosity": 0.55, "cohesion": 0.75, "greed": 0.20,
		"fertility": 0.90, "fiscal_prudence": 0.60, "development": 0.85, "maritime": 0.35,
		"assimilation": 0.70,
	},
	# 무모함·확장·약탈. 내정 엉망
	Kind.CHEESE_TABBY: {
		"aggression": 0.90, "curiosity": 0.35, "cohesion": 0.30, "greed": 0.85,
		"fertility": 0.60, "fiscal_prudence": 0.15, "development": 0.20, "maritime": 0.45,
		"assimilation": 0.15,
	},
	# 폐쇄·기술·요새화
	Kind.RUSSIAN_BLUE: {
		"aggression": 0.40, "curiosity": 0.90, "cohesion": 0.70, "greed": 0.30,
		"fertility": 0.35, "fiscal_prudence": 0.75, "development": 0.75, "maritime": 0.20,
		"assimilation": 0.30,
	},
	# 적응·모방·생존력. 어떤 시대든 중위권
	Kind.KOREAN_SHORTHAIR: {
		"aggression": 0.50, "curiosity": 0.60, "cohesion": 0.60, "greed": 0.50,
		"fertility": 0.60, "fiscal_prudence": 0.50, "development": 0.50, "maritime": 0.60,
		"assimilation": 0.65,
	},
	# 해양·상업·식민. 월경지로 먹고 살고 해상로가 끊기면 무너진다
	Kind.BRITISH_SHORTHAIR: {
		"aggression": 0.45, "curiosity": 0.65, "cohesion": 0.55, "greed": 0.65,
		"fertility": 0.25, "fiscal_prudence": 0.85, "development": 0.65, "maritime": 0.95,
		"assimilation": 0.30,
	},
	# 약탈 원정·저인구·해양. 초반 폭발 후 정체
	Kind.NORWEGIAN_FOREST: {
		"aggression": 0.85, "curiosity": 0.40, "cohesion": 0.45, "greed": 0.75,
		"fertility": 0.25, "fiscal_prudence": 0.35, "development": 0.30, "maritime": 0.85,
		"assimilation": 0.05,
	},
	# 신정·행정·보수. 재미없고 안 죽는다
	Kind.EGYPTIAN_MAU: {
		"aggression": 0.20, "curiosity": 0.45, "cohesion": 0.95, "greed": 0.35,
		"fertility": 0.55, "fiscal_prudence": 0.80, "development": 0.55, "maritime": 0.30,
		"assimilation": 0.55,
	},
	# 사치·궁정·부패. 화려하고 늘 빚
	Kind.PERSIAN: {
		"aggression": 0.45, "curiosity": 0.55, "cohesion": 0.40, "greed": 0.90,
		"fertility": 0.50, "fiscal_prudence": 0.10, "development": 0.30, "maritime": 0.35,
		"assimilation": 0.60,
	},
	# 인구폭발·야심·분열. 최대 시총, 최대 반란 리스크
	Kind.BENGAL: {
		"aggression": 0.70, "curiosity": 0.50, "cohesion": 0.25, "greed": 0.55,
		"fertility": 0.95, "fiscal_prudence": 0.35, "development": 0.45, "maritime": 0.40,
		"assimilation": 0.50,
	},
	# 중개무역·요충 통제. 지리 의존도가 극단적이다
	Kind.TURKISH_ANGORA: {
		"aggression": 0.45, "curiosity": 0.75, "cohesion": 0.50, "greed": 0.75,
		"fertility": 0.45, "fiscal_prudence": 0.65, "development": 0.65, "maritime": 0.75,
		"assimilation": 0.90,
	},
	# 내륙 요새·독립·기동. 성장은 느리나 정복되지 않는다
	Kind.ABYSSINIAN: {
		"aggression": 0.40, "curiosity": 0.30, "cohesion": 0.80, "greed": 0.30,
		"fertility": 0.65, "fiscal_prudence": 0.55, "development": 0.50, "maritime": 0.05,
		"assimilation": 0.25,
	},
}

const NOISE := 0.12

## 지리 원산 (MapSource.REGION_NAMES 인덱스). -1 은 무국적 — 어디서 시작해도 어울린다.
## 노이즈 지도의 프로빈스는 region = -1 이라 앵커가 걸리지 않고 자동으로 무작위 배치가 된다.
const ORIGIN_REGION := {
	Kind.SIAMESE: 7,             # Southeast Asia & Oceania — 인도차이나
	Kind.RAGDOLL: 0,             # North America — 북미 서안
	Kind.CHEESE_TABBY: -1,       # 무국적. 전역 산포
	Kind.RUSSIAN_BLUE: 8,        # North Eurasia
	Kind.KOREAN_SHORTHAIR: 6,    # East Asia — 한반도 일대
	Kind.BRITISH_SHORTHAIR: 2,   # Europe — 서유럽 도서
	Kind.NORWEGIAN_FOREST: 2,    # Europe — 스칸디나비아
	Kind.EGYPTIAN_MAU: 3,        # North Africa & West Asia — 나일
	Kind.PERSIAN: 3,             # North Africa & West Asia — 이란고원
	Kind.BENGAL: 5,              # South Asia
	Kind.TURKISH_ANGORA: 3,      # North Africa & West Asia — 아나톨리아
	Kind.ABYSSINIAN: 4,          # Sub-Saharan Africa — 동아프리카 고지
}

## 등장 빈도 티어 (§M13.7-a). 12종을 균등 배분하면 문화당 국가가 3개뿐이라
## 생존율 지표가 동전던지기가 된다. 티어 배정 자체를 시드로 흔들어, 이번 판의
## 주력 문화가 다음 판에는 희소가 되게 한다 — 지도를 고정한 대가를 여기서 갚는다.
enum Tier { MAJOR, COMMON, RARE }
const TIER_SIZES := [4, 5, 3]
const TIER_WEIGHT := [7.0, 3.0, 1.0]
## 희소 문화가 아예 안 나오는 판의 비율. "이번 판엔 벵갈이 없네" 가 관전 포인트다.
const RARE_ABSENT_CHANCE := 0.35


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


## 이번 판의 문화별 국가 정원. 합은 정확히 nation_count 다.
static func roll_quota(nation_count: int, rng: RandomNumberGenerator) -> PackedInt32Array:
	var order: Array[int] = []
	for k in range(Kind.size()):
		order.append(k)
	for i in range(order.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var swap := order[i]
		order[i] = order[j]
		order[j] = swap

	var weights := PackedFloat32Array()
	weights.resize(Kind.size())
	var idx := 0
	for tier in range(TIER_SIZES.size()):
		for c in range(int(TIER_SIZES[tier])):
			if idx >= order.size():
				break
			var kind: int = order[idx]
			idx += 1
			var w: float = TIER_WEIGHT[tier]
			if tier == Tier.RARE and rng.randf() < RARE_ABSENT_CHANCE:
				w = 0.0
			weights[kind] = w
	return _apportion(weights, nation_count)


## 최대잔여법. 반올림으로 정원이 남거나 모자라면 잔여가 큰 문화부터 준다 —
## 동률은 문화 id 로 못박아 Dictionary 순회 순서에 의존하지 않는다 (§15).
static func _apportion(weights: PackedFloat32Array, total: int) -> PackedInt32Array:
	var quota := PackedInt32Array()
	quota.resize(weights.size())
	var sum := 0.0
	for w in weights:
		sum += w
	if sum <= 0.0:
		quota[0] = total
		return quota
	var assigned := 0
	var remainders: Array = []
	for k in range(weights.size()):
		var exact := float(weights[k]) / sum * float(total)
		quota[k] = int(floor(exact))
		assigned += quota[k]
		remainders.append({"kind": k, "rest": exact - floor(exact)})
	remainders.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if float(a["rest"]) == float(b["rest"]):
			return int(a["kind"]) < int(b["kind"])
		return float(a["rest"]) > float(b["rest"]))
	var i := 0
	while assigned < total and not remainders.is_empty():
		var kind: int = int(remainders[i % remainders.size()]["kind"])
		if float(weights[kind]) > 0.0:
			quota[kind] += 1
			assigned += 1
		i += 1
		if i > remainders.size() * (total + 1):
			break
	return quota
