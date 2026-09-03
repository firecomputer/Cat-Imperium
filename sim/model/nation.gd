class_name Nation extends RefCounted

var id: int = -1
## 관전 화면 식별용 국명. 시뮬 계산에는 쓰이지 않는다.
## 어간(stem)과 칭호(title)의 합성이다 — 통짜 문자열로 들고 있으면 나라가
## 제국이 되어도 "공국" 이 그대로 남는다 (NationPlacer.retitle).
var name: String = ""
var stem: String = ""
## NationPlacer.Tier. 규모가 정하고 반란국은 Tier.REBEL 에 머문다.
var title_tier: int = 0
var title_tier_turn: int = -999           # 마지막 개칭 턴. 잦은 승격·강등을 막는다
var culture: int = Culture.Kind.KOREAN_SHORTHAIR
var culture_params: Dictionary = {}
var capital: int = -1                     # 프로빈스 id
var start_region: int = -1                # M13 건국 수도의 고정 지리 라벨
var provinces: Array[int] = []
var characters: Array[int] = []           # WorldState.characters 인덱스
var armies: Array[int] = []               # WorldState.armies 인덱스

# 집계값 (economy 가 매 턴 갱신)
var population: float = 0.0
var gdp: float = 0.0                      # = nominal_gdp
var nominal_gdp: float = 0.0
var real_gdp: float = 0.0
var prev_real_gdp: float = 0.0
var infra_mean: float = 0.0               # 인구 가중 평균 (§4.7 익스플로잇 방지)
var controlled_gdp: float = 0.0           # 점령당하지 않은 땅의 GDP. 세수는 여기서만 나온다
## 점령법이 물리는 GDP (Province.occupation_base 가중). Economy 의 수취와
## LawEvaluator 의 immediate_income 이 같은 이 값을 읽는다 — AI 가 보는 수익과
## 실제로 들어오는 수익이 어긋나면 법 선택이 시뮬과 무관해진다.
var occupation_gdp: float = 0.0
var manpower: float = -1.0                # 남은 동원 인력. -1 은 미초기화
## 0~1. 대규모 전투 손실은 장교단·보급조직·동원망까지 무너뜨린다. 병력을 다시
## 모아도 이 값이 회복되기 전에는 같은 전투력을 즉시 낼 수 없다.
var military_readiness: float = 1.0

# 재정 / 통화
var treasury: float = 0.0
var money_supply: float = 0.0
var prev_money_supply: float = 0.0
var inflation: float = 0.0
var inflation_damping: float = 0.0        # 경제 고문 효과 (M6)
var upkeep_paid_ratio: float = 1.0
var infra_cost_mult: float = 1.0          # 기술 고문 효과 (M6)
var tax_efficiency: float = 1.0           # 경제 고문 효과 (M6)

# 신용 · 부채 (§7). economy 가 income/expenses 를 기록하고 credit 가 정산한다.
var debt: float = 0.0
var credit_rating: float = 1.0
var default_history: int = 0
var default_memory: float = 0.0           # 신용도에 반영되는 파산 기억. 매 턴 감쇠한다
var printing_streak: int = 0
var bankruptcy_timer: int = 0
var consecutive_surplus_turns: int = 0
var income: float = 0.0
var expenses: float = 0.0
var interest_expense: float = 0.0
var planned_borrowing: float = 0.0       # 이번 턴 인프라 투자용 선제 차입
var avg_unrest: float = 0.0               # 인구 가중 평균

# 고문 효과. AdvisorEffects 가 매 턴 재계산한다.
var law_change_speed: float = 1.0
var law_review_progress: float = 0.0
var law_review_count: int = 0
var unrest_suppression: float = 0.0
var diplo_bonus: float = 0.0
var tech_rate: float = 1.0
var prestige: float = 0.0                 # M8 외교
var credit_bonus: float = 0.0
var bankruptcy_military_mult: float = 1.0
var military_modifier: float = 1.0
var army_modifier: float = 1.0
var supply_range_mult: float = 1.0
## 0~1. 내각이 전쟁을 정치적으로 지탱하는 힘 (정치 고문 + 군사 고문). 같은 사상자에
## 지지도를 덜 잃고 같은 승전에 더 얻는다 — 인물이 강한 쪽이 소모전을 오래 버틴다.
var war_resolve: float = 0.0
var navy_modifier: float = 1.0
var sea_supply_mult: float = 1.0

# 보급. 해역 제해권은 M9.2 해군 시스템이 채운다.
var supply_field: PackedFloat32Array = PackedFloat32Array()
var supply_dirty: bool = true
var at_war: bool = false
var at_foreign_war: bool = false          # 반란 진압이 아닌 대외전쟁 여부
var naval_control_zones: Dictionary = {}

# M8 외교 (§11). 상대 국가 id → 값. 단일 수치 금지, 3축을 따로 둔다.
var opinion: Dictionary = {}              # -100 ~ +100, 과거 행동의 누적
var threat: Dictionary = {}               # 0 ~ 1, 상대 전력 × 국경 접촉 × 팽창 속도
var interest: Dictionary = {}             # 0 ~ 1, 무역 의존 + 공통의 적
var allies: Array[int] = []               # 방어동맹
var alliance_expiry: Dictionary = {}      # nation_id → 갱신 심사 턴 (§11.4)
var truces: Dictionary = {}               # nation_id → 휴전 만료 턴
var wars: Array[int] = []                 # WorldState.wars 인덱스
## 0~1. 전쟁을 계속할 정치적 여력. 사상자가 깎고 승전이 올리며 평시에 천천히 회복한다.
## 전쟁 피로의 반대 방향 표현이자 동원·편성 속도의 원천이다 (M14 §4).
var war_support: float = 0.7
## war_support 가 1.0 인 채로 평화가 이어진 턴 수. 오래 쌓이면 개전 문턱을 무시한다.
var peace_streak_turns: int = 0
## 이번 턴에 야전군을 새로 편성할 수 있는 몫. 1.0 을 넘겨 비축되지 않는다 (M14 §3).
var spawn_credit: float = 1.0
var prev_province_count: int = 0
var expansion_rate: float = 0.0           # 최근 영토 증가율 (threat 계산용)
var last_war_turn: int = -999             # 연속 선전포고 방지
var claims: Array[int] = []               # 실지회복 명분이 붙은 프로빈스 id
var fleets: Array[int] = []               # WorldState.fleets 인덱스

# 국가의 생사와 종속. 반란군도 국가로 스폰된다 (§10).
var is_alive: bool = true
var is_rebel: bool = false
var rebel_origin: int = -1                # 어느 나라에서 떨어져 나왔는지
var overlord: int = -1                    # 속국이면 종주국 id (§12.2)
var vassals: Array[int] = []
var vassal_loyalty: float = 1.0           # 독립국은 1, 강제 속국은 낮은 값에서 시작
var vassal_since_turn: int = -1

# 제국 수명 주기. EmpireSystem 이 매 턴 갱신하고 불만·외교·UI 가 읽는다.
var imperial_authority: float = 0.5
var admin_load: float = 0.0
var admin_capacity: float = 1.0
var overextension: float = 0.0
## 점령법이 실제로 물리는 땅의 비율 (이문화 프로빈스 / 전체). EmpireSystem 이 갱신하고
## LawEvaluator 가 점령법의 비용을 매길 때 읽는다.
var foreign_exposure: float = 0.0
var authority_band: int = 1               # 0 위기 / 1 보통 / 2 강성, 사건 중복 방지

## 인재 기질. 세계 생성 때 국가마다 한 번 뽑는 능력치 평균 편차다 (§인재 편차).
## 모든 나라의 인물 풀이 똑같으면 아무도 전력 우세를 못 만들어 개전 게이트가
## 열리지 않는다 — 표적 평가의 94%가 t_power 에서 죽던 원인 중 하나다.
var talent_bias: float = 0.0
## 재직 중인 정치 고문들의 매파 성향 평균 (0~1, 중립 0.5). AdvisorEffects 가 갱신하고
## Diplomacy 의 개전 판정이 읽는다.
var war_hawk: float = 0.5
## 재직 중인 정치 고문들의 강제 진압 선호 평균 (0~1, 중립 0.5). 낮은 내각은
## 분리주의가 끓는 땅에 군대를 보내기를 꺼린다 (M14 §5).
var suppression_will: float = 0.5

var laws: Dictionary = {}                 # category → Law
## law_modifier 결과 캐시. 값은 국가 단위 상수인데 호출은 프로빈스마다 일어난다 —
## 917 프로빈스 지도에서 이 8개 카테고리 순회가 tick_infra 시간의 큰 몫이었다.
## laws 를 직접 대입하면 캐시가 상하므로 반드시 set_law() 로 쓴다.
var _law_cache: Dictionary = {}


## 법률 채택의 유일한 입구. 여기서만 캐시가 비워진다.
func set_law(category: String, law: Law) -> void:
	laws[category] = law
	_law_cache.clear()


## 채택 법률들의 합성치. 곱셈 계열은 중립 1.0, 덧셈 계열은 중립 0.0.
func law_modifier(key: String) -> float:
	if _law_cache.has(key):
		return _law_cache[key]
	var multiplicative := key in Law.MULTIPLICATIVE
	var v := 1.0 if multiplicative else 0.0
	for cat in Law.CATEGORIES:              # Dictionary 순회 순서에 의존 금지 (§15)
		var law: Law = laws.get(cat)
		if law == null:
			continue
		var m := law.modifier(key)
		if multiplicative:
			v *= (1.0 + m)
		else:
			v += m
	_law_cache[key] = v
	return v


## 점령 법률의 가혹함. §10 불만 공식이 쓰는 값이다.
func occupation_law_severity() -> float:
	var law: Law = laws.get("occupation")
	return 0.0 if law == null else law.severity


func culture_bias(key: String) -> float:
	return culture_params.get(key, 0.5)
