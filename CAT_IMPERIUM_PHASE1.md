# Cat Imperium — 1차 설계 계획서 (v0.1)

> **이 문서의 목적**: Godot 4.x 기반 관전형 문명 시뮬레이션 게임 "Cat Imperium"의 전체 시스템 설계를 정의한다. 구현자(Claude Code)는 이 문서를 단일 진실 공급원(SSOT)으로 삼아 마일스톤 순서대로 작업한다.

---

## 0. 프로젝트 개요

### 0.1 한 줄 요약
다양한 고양이 문화권의 국가들이 자율적으로 문명을 건설하고 전쟁·외교를 벌이는 세계를 **플레이어는 관전만 하며**, 국가·기업·인물에 **투자하여 수익을 내는** 게임.

### 0.2 핵심 설계 철학

| 원칙 | 의미 |
|---|---|
| **플레이어는 통치하지 않는다** | 직접 조작 불가. 오직 자본으로 세계에 간접 개입한다. |
| **예측 가능하되 확실하지 않다** | 시뮬은 결정론적. 불확실성은 **정보 비대칭**에서만 발생시킨다. |
| **모든 선택에는 대가가 있다** | 순수 이득인 법률/건물/조약은 **하나도 존재해선 안 된다**. |
| **대제국은 반드시 무너진다** | 확률 강제가 아니라 **시스템 상호작용의 자연 귀결**로 붕괴시킨다. |
| **GDP는 폭주할 수 없다** | 인프라가 1인당 GDP의 **하드 상한**을 정의한다. |

### 0.3 붕괴 나선 (게임의 중심 서사)

이 루프가 게임 전체를 관통한다. 모든 시스템은 이 루프에 기여해야 한다.

```
확장 (정복)
   ↓
행정비 초선형 증가 (provinces^1.3) + 인프라 유지비 폭증
   ↓
재정난 → AI의 근시안화(desperation↑) → 가혹한 법률 채택
   ↓
신용 한도 소진 → 화폐 발행 → 인플레이션
   ↓
실질 GDP↓ · 불만↑ · 인프라 감쇠
   ↓
변경/월경지에서 반란 (그곳은 보급이 안 됨)
   ↓
진압 실패 → 진압 비용만 소모 → 재정난 심화 ──┐
   ↓                                          │
파산 → 군사력 -50% + 전 세계 관계 악화        │
   ↓                                          │
threat 인식 하락 → 주변국 동시 참전 (하이에나) │
   ↓                                          │
제국 분할 ────────────────────────────────────┘
```

---

## 1. 기술 스택 및 아키텍처

### 1.1 스택
- **엔진**: Godot 4.3+ / GDScript
- **분석 파이프라인**: Python 3.11+ (pandas, matplotlib) — 배치 시뮬 결과 분석 전용
- **직렬화**: JSON (리플레이/로그), Godot `Resource(.tres)` (밸런스 데이터)

### 1.2 절대 규칙

> ⚠️ **시뮬레이션 코어는 `Node`를 상속하지 않는다.** 전부 `RefCounted` 기반 순수 GDScript로 작성한다.

이유:
1. 헤드리스 배치 실행(밸런싱)이 가능해진다
2. 배속/일시정지가 `tick()` 호출 횟수 조절로 끝난다
3. 뷰 없이 단위 테스트가 가능하다
4. 나중에 GDExtension(C++/Rust)으로 이관하기 쉽다

> ⚠️ **시뮬은 뷰를 절대 참조하지 않는다.** 통신은 `EventBus` 오토로드를 통한 **단방향 시그널**만 허용한다.

> ⚠️ **전역 `randi()` / `randf()` 사용 금지.** 시스템별로 `RandomNumberGenerator` 인스턴스를 소유하고 시드를 명시적으로 주입한다. 결정론이 깨지면 리플레이·버그재현·밸런싱이 전부 무너진다.

### 1.3 디렉토리 구조

```
res://
├── sim/                          # 순수 로직 (Node 금지)
│   ├── world_state.gd            # 전체 상태 컨테이너, 직렬화 가능
│   ├── sim_clock.gd              # tick() 진입점, 시스템 실행 순서 관리
│   ├── rng_pool.gd               # 시스템별 RNG 인스턴스 관리
│   │
│   ├── model/
│   │   ├── tile.gd
│   │   ├── province.gd
│   │   ├── nation.gd
│   │   ├── army.gd
│   │   ├── character.gd
│   │   └── law.gd
│   │
│   ├── worldgen/
│   │   ├── map_generator.gd      # 헥스 지형 생성
│   │   ├── province_splitter.gd  # 프로빈스 분할
│   │   ├── feature_tagger.gd     # 해협/지협/섬 태깅
│   │   └── nation_placer.gd      # 초기 국가 배치
│   │
│   ├── systems/
│   │   ├── economy.gd            # GDP, 인프라, 인구
│   │   ├── credit.gd             # 신용, 부채, 파산
│   │   ├── inflation.gd
│   │   ├── law_system.gd
│   │   ├── supply.gd             # 보급 필드 (다익스트라)
│   │   ├── military.gd           # 결정론적 전투
│   │   ├── diplomacy.gd
│   │   ├── peace.gd              # 평화협상
│   │   ├── unrest.gd             # 불만/반란
│   │   ├── character_system.gd   # 인물 생성/사망/등용
│   │   └── market.gd             # 투자 시장
│   │
│   ├── ai/
│   │   ├── law_evaluator.gd
│   │   ├── budget_ai.gd
│   │   ├── war_ai.gd
│   │   └── culture_bias.gd
│   │
│   └── util/
│       ├── hex.gd                # 헥스 좌표/거리/이웃
│       └── priority_queue.gd
│
├── data/
│   ├── laws/*.tres
│   ├── cultures/*.tres
│   └── names/*.json              # 문화별 인물 이름 풀
│
├── view/                         # Node/Scene 허용 영역
│   ├── map_renderer.tscn
│   ├── hud/
│   └── charts/
│
└── tools/
    ├── batch_sim.gd              # 헤드리스 배치 실행
    ├── dump_map_png.gd           # 지형 시각 확인
    └── analyze.py                # pandas 분석
```

### 1.4 턴 진행 파이프라인

`sim_clock.gd`의 `tick()`은 **반드시 이 순서**로 시스템을 호출한다. 순서가 바뀌면 값이 한 턴씩 밀린다.

```
1.  character_system.tick()      # 사망 처리 → 공석 발생 → 등용
2.  law_system.tick()            # AI 법률 심의/변경
3.  advisor_effects.apply()      # 고문 효과를 국가 스탯에 반영
4.  economy.tick_infra()         # 인프라 건설/감쇠
5.  economy.tick_production()    # GDP 앵커 수렴
6.  economy.tick_migration()     # 인구 이동 (총합 보존 필수)
7.  credit.tick()                # 수입/지출/차입/화폐발행/파산
8.  inflation.tick()             # 통화량 → 인플레 (관성 lerp)
9.  supply.recompute_if_dirty()  # 보급 필드 (전쟁국만)
10. military.tick()              # 전투 해결, 소모
11. unrest.tick()                # 불만 누적, 반란 발생
12. diplomacy.tick()             # opinion/threat 갱신, 선전포고
13. peace.tick()                 # 평화협상 판정
14. market.tick()                # 가격 산정, 배당 지급
15. events.flush()               # EventBus 일괄 방출
```

---

## 2. 세계 생성

### 2.1 지형 생성 (`map_generator.gd`)

#### 상수
```gdscript
const W := 100
const H := 150
const TOTAL := 15000
const LAND_TARGET := 5000        # 정확히 1/3
```

#### 좌표계
- **odd-r 오프셋 헥스** 사용
- 노이즈 샘플링 시 반드시 평면 좌표로 변환:
  ```gdscript
  x = col + (0.5 if row % 2 == 1 else 0.0)
  y = row * 0.8660254            # sqrt(3)/2
  ```
  이 보정을 빼면 지형이 세로로 찌그러진다.

#### 핵심 기법: 임계값이 아닌 **순위(rank) 선택**

```
15000 타일 전부의 고도 계산 → 정렬 → 상위 5000개만 육지
```

임계값 방식(`elev > 0.5`)을 쓰면 육지 개수가 노이즈 파라미터에 따라 흔들려 튜닝이 불가능하다. 순위 선택은 **노이즈를 어떻게 만지든 육지가 항상 정확히 5000개**를 보장한다.

#### 고도장 합성

```
elevation = 대륙마스크           # 큰 덩어리 2개 이상 보장
          + 도메인워프 fBm × 0.45  # 해안선 뒤틀기 (변칙성의 8할)
          + 릿지 노이즈    × 0.25  # 반도/열도 촉수
          + 고주파 노이즈  × 0.12  # 앞바다 섬 부스러기
          - 가장자리 감쇠          # 지도 테두리는 바다
```

**도메인 워프가 핵심이다.** 이것 없이는 옥타브를 아무리 쌓아도 감자 모양 대륙만 나온다.

| 노이즈 | 설정 |
|---|---|
| warp | SIMPLEX_SMOOTH, freq 0.020, octaves 5, lacunarity 2.1, **domain_warp_amplitude 55**, warp_freq 0.012 |
| ridge | SIMPLEX, freq 0.035, FRACTAL_RIDGED, octaves 4 |
| detail | freq 0.11 |

#### 대륙 씨앗 배치
- 대형 씨앗 `randi_range(2,3)`개, 반경 26~40, 상호 최소거리 **42**
- 소형 씨앗(열도/고립섬) 8~14개, 반경 4~11, strength 0.45~0.75
- 마스크 합성은 `sum`이 아니라 **`max`** (씨앗이 겹쳐 뭉치는 것 방지)

#### 후처리 (`_cleanup`)
1. 고립된 1타일 섬의 **70%만** 제거 (30%는 남겨 점섬의 맛 유지)
2. 육지에 둘러싸인 1타일 바다(호수)는 메움
3. 위 과정에서 변동된 개수만큼, **해안 인접 바다 중 고도 높은 순**으로 보충하여 정확히 5000 복원

#### 검증 (`_validate`) — 실패 시 시드 변경 후 재생성 (최대 12회)
```
✓ 컴포넌트 2개 이상
✓ 상위 2개 컴포넌트가 각각 900타일 이상
✓ 최대 컴포넌트가 전체 육지의 70% 이하   # 판게아 방지
✓ 전체 컴포넌트 12개 이상                # 섬 다양성
```

#### 필수 도구
```gdscript
func dump_png(land, path) -> void   # 렌더러 만들기 전에 PNG로 눈 확인
```
**렌더링을 만들기 전에 이 함수부터 만든다.** 순서를 어기면 "지형이 별로네"를 뒤늦게 발견해 시간이 두 배로 든다.

### 2.2 지형 특징 태깅 (`feature_tagger.gd`)

```gdscript
enum Feature { INLAND, COAST, ISTHMUS, STRAIT, ISLAND }
```

| 특징 | 판정 | 게임플레이 효과 |
|---|---|---|
| **STRAIT** | 바다 타일인데 양쪽에 서로 다른 대륙 인접 | 해군 통제권, 교역로 병목 |
| **ISTHMUS** | 육지 관절점(articulation point). 제거 시 컴포넌트 분리 | 최고의 방어 요충지 |
| **ISLAND** | 크기 30 이하 컴포넌트 | 육상 침공 불가, 반란 진압비 폭증 |

> 성능: 지협 판정을 5000타일 전부 검사하면 느리다. **육지 이웃이 2~3개뿐인 타일만** 후보로 필터링한 뒤 플러드필한다.

**바다 컴포넌트에도 `sea_basin_id`를 라벨링한다.** 평화협상의 해상 접근성 판정에 사용된다.

### 2.3 프로빈스 분할 (`province_splitter.gd`)

#### 규격
- 프로빈스 = **1~30 타일**
- 독립된 섬은 **타일 1개여도 독립 프로빈스**
- 게임 시작 시 1회만 분할 (이후 불변)
- 목표 평균 17타일 → 약 **294개 프로빈스**

#### 알고리즘: 제약 있는 성장 (보로노이 아님)

보로노이는 크기 제어가 불가능하다. 다중 소스 BFS 동시 확장을 사용한다.

```
1) 육지를 컴포넌트로 분해
2) 크기 ≤ 30 컴포넌트 → 통째로 1 프로빈스  ← 섬 요구사항 자동 충족
3) 큰 컴포넌트 → 포아송 디스크로 씨앗 배치 → 라운드로빈 확장
   - 각 프로빈스 목표 크기를 randi_range(8, 30)으로 랜덤화
   - 고도차 > 0.18인 방향은 65% 확률로 확장 차단  ← 산맥이 자연 경계
4) 고아 타일은 가장 작은 인접 프로빈스에 흡수
```

**고도차 차단이 중요하다.** 이것이 프로빈스 경계를 지형에 맞춰 그려주어 밋밋한 육각 덩어리를 방지한다.

#### 성능상 의의
> 이 분할로 다익스트라·경제·반란 계산이 전부 **15000 → ~294 단위**로 축소된다. 50배 절약. GDScript로 충분히 실시간이 된다. **모든 시스템은 타일이 아닌 프로빈스 단위로 작동한다.**

#### Province 데이터
```gdscript
class_name Province extends RefCounted

var id: int
var tiles: PackedInt32Array
var owner_nation: int = -1

# 핵심 3수치
var infra: float = 0.0           # 0~10
var population: float = 0.0
var gdp: float = 0.0
var gdp_pc: float = 0.0

# 파생 상태
var unrest: float = 0.0          # 0~1
var supply: float = 1.0          # 0~1
var has_city: bool = false
var is_exclave: bool = false
var is_island: bool = false
var culture: int = -1
var admin_cost_mult: float = 1.0

# 생성 시 1회 캐시 (불변)
var land_neighbors: Array = []
var sea_basin_ids: PackedInt32Array
var terrain_mult: float = 1.0        # 생산성 배율
var terrain_supply_mult: float = 1.0 # 보급 비용 배율
var terrain_cost_mult: float = 1.0   # 건설비 배율
var is_coastal: bool = false
var has_river: bool = false
var centroid: Vector2
var distance_from_capital: float = 0.0
```

#### 초기값 시딩
```gdscript
var pot := terrain_mult * (1.25 if is_coastal else 1.0) * (1.15 if has_river else 1.0)

infra      = clamp(randfn(1.8, 0.9) * pot, 0.0, 5.0)
population = tiles.size() * randf_range(180.0, 520.0) * pot
gdp_pc     = gdp_pc_anchor(infra) * randf_range(0.75, 1.0)   # 반드시 앵커 아래에서 시작
gdp        = gdp_pc * population
```
**앵커 아래에서 시작하는 것이 중요하다.** 그래야 초반에 모든 국가가 성장하는 그림이 나온다.

---

## 3. 문화 (고양이 품종)

문화는 스킨이 아니라 **AI 성향 파라미터 프리셋**이다. 국가 생성 시 각 값에 ±노이즈를 주어 같은 품종이라도 판마다 다른 나라가 나오게 한다.

| 문화 | 성향 | 경제적 성격 |
|---|---|---|
| **샴 (Siamese)** | 귀족제·외교·첩보. 전쟁보다 속국화 | 저위험 저수익, 안정 배당 |
| **랙돌 (Ragdoll)** | 평화·문화·인구폭발. 군사 최약체 | 성장주. 침략당하면 폭락 |
| **치즈 태비 (Cheese Tabby)** | 무모함·확장·약탈. 내정 엉망 | 고변동성. 대박 아니면 파산 |
| **러시안블루 (Russian Blue)** | 폐쇄·기술·요새화 | 늦게 터지는 테크주 |
| **코리안숏헤어 (Korean Shorthair)** | 적응·모방·생존력 | 어떤 시대든 중위권. 헷지용 |

#### 파라미터 (0.0~1.0)
```gdscript
aggression      # 선전포고 성향
curiosity       # 기술/탐험 투자
cohesion        # 불만 저항력
greed           # 배상금/약탈 선호
fertility       # 인구 성장률
fiscal_prudence # 흑자 시 부채 상환 비율
development     # 인프라 투자 인내심
maritime        # 해군/월경지 선호
```

> `culture_bias(key)` 함수로 전 시스템에서 조회한다. 이것이 **문화 설정을 경제 결과로 자동 번역**하는 통로다. 예: 랙돌은 `development`가 높아 인내심 있게 인프라를 쌓고, 치즈 태비는 늘 재정난이라 못 쌓는다.

---

## 4. 경제 시스템

### 4.1 인프라 (건물 통합 개념)

건물 개념을 폐기하고 **인프라 단일 수치(0~10)**로 통일한다.

| 인프라 | 상태 | 1인당 GDP 앵커 |
|---|---|---|
| 0 | 미개척 | 80 |
| 2 | 촌락, 흙길 | 260 |
| 4 | 포장도로, 시장 | 700 |
| 6 | 항만, 창고, 수로 | 1,500 |
| 8 | 대규모 상공업 | 2,700 |
| 10 | 문명의 정점 | 4,000 |

### 4.2 앵커 곡선 — GDP 폭주 방지 장치

**이것이 경제 시스템의 심장이다.** 인프라가 1인당 GDP의 하드 상한을 정의한다.

```gdscript
const GDP_PC_MAX := 4000.0
const CURVE_K := 0.42

func gdp_pc_anchor(infra: float) -> float:
    var x := (infra - 5.0) * CURVE_K
    var s  := 1.0 / (1.0 + exp(-x * 2.2))
    var s0 := 1.0 / (1.0 + exp( 5.0 * CURVE_K * 2.2))
    var s1 := 1.0 / (1.0 + exp(-5.0 * CURVE_K * 2.2))
    return GDP_PC_MAX * (s - s0) / (s1 - s0) + 80.0
```

### 4.3 생산 틱 — 앵커로의 수렴

```gdscript
func tick_production(p: Province, n: Nation) -> void:
    var anchor := gdp_pc_anchor(p.infra)
    anchor *= p.terrain_mult
    anchor *= n.law_modifier("productivity")
    anchor *= (1.0 - p.unrest * 0.6)
    if p.has_city:
        anchor *= 1.2

    var gap := anchor - p.gdp_pc
    if gap > 0.0:
        p.gdp_pc += gap * 0.06        # 성장은 느리게 (따라잡기)
    else:
        p.gdp_pc += gap * 0.18        # 하락은 빠르게

    p.gdp = p.gdp_pc * p.population
```

> **왜 폭주하지 않는가**: GDP는 앵커를 넘지 못하고, 앵커는 인프라 10에서 4000으로 하드캡된다. 총 GDP는 오직 **인구 × 인프라**로만 증가한다. 지수 성장이 원천 차단된다.
>
> **부수 효과 (의도된 것)**: gap이 클수록 성장이 빠르므로 후진 지역이 더 빨리 성장하는 **수렴 효과**가 자연 발생한다. 후발 국가의 역전 가능성이 생겨 관전 재미가 상승한다.

### 4.4 건설비 / 유지비 — 초선형

```gdscript
func infra_build_cost(p: Province, n: Nation) -> float:
    var c := 120.0 * pow(p.infra + 1.0, 2.1)
    c *= p.terrain_cost_mult
    c *= (1.0 + p.distance_from_capital * 0.015)
    c *= n.infra_cost_mult              # 기술 고문 효과 (최대 -30%)
    return c

func infra_upkeep(p: Province) -> float:
    var u := 9.0 * pow(p.infra, 1.55)
    if p.has_city:
        u *= 3.0                        # 도시는 유지비 3배
    return u * p.admin_cost_mult
```

**유지비의 초선형성이 붕괴 나선의 핵심 연료다.**

### 4.5 인프라 감쇠

```gdscript
func tick_infra_decay(p: Province, n: Nation) -> void:
    if n.upkeep_paid_ratio < 1.0:
        p.infra = max(0.0, p.infra - (1.0 - n.upkeep_paid_ratio) * 0.12)
    if p.is_being_pillaged:
        p.infra = max(0.0, p.infra - 0.5)
```

**인프라가 무너질 수 있다는 것**이 제국의 화려한 붕괴를 가능하게 한다.

### 4.6 인구 이동

인프라가 직접 인구를 끌어오지 않는다. **인프라 → 소득 → 이주** 순서가 더 자연스럽고 창발적이다.

```gdscript
func tick_migration(n: Nation) -> void:
    var mean_pc := n.gdp / max(n.population, 1.0)
    for p in n.provinces:
        var pull := (p.gdp_pc / max(mean_pc, 1.0)) - 1.0
        pull -= p.unrest * 1.5
        pull -= max(p.pop_density_ratio - 1.0, 0.0) * 0.8    # 과밀 페널티
        p.pending_migration = p.population * clamp(pull, -0.06, 0.06) * 0.5
    _rebalance(n)   # 유출 총량 = 유입 총량으로 정규화
```

> ⚠️ **`_rebalance`는 필수다.** 없으면 인구가 무에서 생성되어 GDP가 결국 폭주한다.
> ⚠️ **과밀 페널티도 필수다.** 없으면 전 국민이 수도 한 곳에 모인다.

### 4.7 도시 시스템

#### 자격 조건 — 이중 조건 (상대 + 절대)

```gdscript
const CITY_RELATIVE_BONUS := 2.0
const CITY_ABSOLUTE_MIN   := 4.0
const CITY_MIN_POP        := 5000
const CITY_MIN_SPACING    := 3      # 프로빈스 인접 거리

func can_found_city(p: Province, n: Nation) -> bool:
    return not p.has_city \
        and p.infra >= n.infra_mean + CITY_RELATIVE_BONUS \
        and p.infra >= CITY_ABSOLUTE_MIN \
        and p.population >= CITY_MIN_POP \
        and n.nearest_city_distance(p) >= CITY_MIN_SPACING
```

> ⚠️ **왜 절대 조건이 필요한가 (중대한 익스플로잇 방지)**
>
> 상대 조건만 두면 **낙후지를 정복하는 것만으로 본토에 도시가 공짜로 생긴다.** 평균이 폭락하기 때문이다. AI가 이를 이용하면 무한 정복 루프가 돌아 "제국 붕괴" 설계와 정반대 결과가 나온다.
>
> 추가 방어: 평균은 반드시 **인구 가중 평균**으로 계산한다.
> ```gdscript
> infra_mean = Σ(p.infra × max(p.population,1)) / Σ(max(p.population,1))
> ```
> 이러면 낙후지 정복 시 인구도 함께 들어와 평균이 정당하게 하락한다.

#### 도시의 대가 (순수 이득 금지)

| 이득 | 대가 |
|---|---|
| 인접 프로빈스 인프라 성장 +25% | 유지비 **3배** |
| 1인당 GDP 앵커 ×1.2 | 반란 시 규모 3배 (불만의 진원지) |
| 세수 효율↑, 교역 허브 | 식량 자급 불가 → 보급 의존 |
| 인물 배출 확률↑ | **적의 최우선 공격 목표** (warscore 가치 높음) |

---

## 5. 인플레이션

### 5.1 원칙
- 즉시 계산값이 아니라 **누적 상태값**이다
- 반드시 **자기 강화 루프**여야 하이퍼인플레가 발생한다
- `lerp`로 **관성**을 주어야 한다. 매 턴 널뛰면 투자 게임으로 성립하지 않는다

### 5.2 구현

```gdscript
func tick(n: Nation) -> void:
    var money_growth  := n.money_supply / max(n.prev_money_supply, 1.0)
    var output_growth := n.real_gdp / max(n.prev_real_gdp, 1.0)
    var target := (money_growth / output_growth) - 1.0

    target += n.law_modifier("inflation_pressure")
    target *= (1.0 - n.inflation_damping)        # 경제 고문 효과

    n.inflation = lerp(n.inflation, target, 0.35)
    n.inflation = max(n.inflation, -0.5)          # ⚠️ 디플레 스파이럴 방지

    n.real_gdp = n.nominal_gdp / (1.0 + n.inflation)
```

> ⚠️ **하한 -0.5는 필수다.** 없으면 디플레 스파이럴로 실질 GDP가 무한대로 발산하는 버그가 발생한다. 이 구조에서 매우 흔한 함정이다.

---

## 6. 법률 시스템

### 6.1 원칙

> **모든 법률은 최소 1개 이상의 스탯을 깎아야 한다.** 순수 이득 법률이 하나라도 있으면 모든 AI가 그것만 선택하고 다양성이 죽는다.

### 6.2 데이터 구조

법률은 코드가 아니라 **데이터(.tres)**로 정의한다. 법률 추가 시 시뮬 코드를 건드리지 않는다.

```gdscript
class_name Law extends Resource

@export var id: String
@export var category: String
@export var severity: float          # -1.0(관대) ~ +1.0(가혹)
@export var modifiers: Dictionary    # {"tax_rate": 0.15, "unrest": 0.08, ...}
```

### 6.3 카테고리

| 카테고리 | 관대 ←──────→ 가혹 |
|---|---|
| **조세법** | 저율(성장↑ 세수↓) ~ 고율(세수↑ 불만↑ 성장↓) |
| **점령법** | 자치허용 ~ 동화강제 ~ 약탈/추방 |
| **통화법** | 경화(인플레↓ 유동성↓) ~ 화폐남발(즉시세수↑ 인플레↑) |
| **징병법** | 모병제(비용↑ 사기↑) ~ 강제징집(병력↑ 생산력↓ 불만↑) |
| **신분법** | 능력주의(인재↑ 귀족불만↑) ~ 세습(안정↑ 정체) |
| **교역법** | 자유무역 ~ 보호무역 ~ 금수 |
| **교육법** | 보편교육(비용↑ 인물능력↑) ~ 방임(비용↓ 인물능력↓) |
| **보건법** | 공공의료(비용↑ 수명↑) ~ 방임 |

### 6.4 AI 법률 선택 — 가혹함을 강제하지 않는다

> ⚠️ **"가혹한 점령법 선택 확률을 억지로 높인다"는 접근을 쓰지 않는다.** 부자연스럽고 튜닝이 어렵다.
>
> 대신 **AI의 합리적 선택이 자연히 가혹함으로 향하도록** 구조를 짠다:
> 1. 제국이 커질수록 행정비가 초선형 증가 (`provinces^1.3`)
> 2. → 큰 제국은 항상 재정 압박 상태
> 3. → 재정난 AI는 단기 수익 법률의 효용 점수가 높게 계산됨
> 4. → **AI가 스스로 판단해서 가혹해진다**

```gdscript
func evaluate_law(n: Nation, law: Law) -> float:
    var desperation := clamp(-n.treasury / max(n.gdp, 1.0), 0.0, 1.0)

    var score := 0.0
    score += law.modifiers.get("immediate_income", 0.0) * (1.0 + desperation * 4.0)
    score += law.modifiers.get("stability", 0.0) * (1.0 - desperation * 0.8)
    score += law.modifiers.get("long_term_growth", 0.0) * (1.0 - desperation)
    score += n.culture_bias_for_law(law)
    return score
```

법률 변경 속도는 정치 고문 능력에 비례한다 (`n.law_change_speed`).

---

## 7. 신용 · 부채 · 파산

### 7.1 3단계 방어선

```
국고 고갈 → [1] 국채 발행 → [2] 화폐 발행 → [3] 파산
```

대제국이 오래 버티는 이유는 **신용 한도가 GDP 기반**이라 덩치만큼 빌릴 수 있기 때문이다.

### 7.2 신용도 / 한도 / 금리

```gdscript
func credit_limit(n: Nation) -> float:
    return n.gdp * 3.5 \
         * (0.4 + n.credit_rating * 0.6) \
         * (1.0 + n.prestige * 0.25) \
         * n.law_modifier("borrowing_capacity")

func credit_rating(n: Nation) -> float:
    var r := 1.0
    r -= clamp(n.debt / max(n.gdp * 3.5, 1.0), 0.0, 1.0) * 0.45
    r -= clamp(n.inflation / 0.25, 0.0, 1.0) * 0.25
    r -= n.default_history * 0.15
    r -= clamp(n.avg_unrest, 0.0, 1.0) * 0.15
    r += clamp(n.consecutive_surplus_turns / 40.0, 0.0, 1.0) * 0.2
    r += n.credit_bonus                                   # 경제 고문
    return clamp(r, 0.05, 1.0)

func interest_rate(n: Nation) -> float:
    return 0.02 + pow(1.0 - n.credit_rating, 2.2) * 0.28  # 2% ~ 30%
```

> **설계 의도**: 한도는 GDP에 **선형**으로 늘지만, 행정비·유지비는 **초선형**으로 는다. 따라서 대제국의 붕괴는 **지연될 뿐 회피되지 않는다.**

### 7.3 재정 틱

```gdscript
func tick(n: Nation) -> void:
    n.credit_rating = credit_rating(n)
    n.debt += n.debt * interest_rate(n)                # 복리
    n.treasury += (n.income - n.expenses)

    if n.treasury < 0.0:
        var need := -n.treasury
        var room := credit_limit(n) - n.debt
        n.treasury = 0.0

        if room > need:
            n.debt += need                            # [1] 차입
        else:
            if room > 0.0:
                n.debt += room
                need -= room
            n.money_supply += need                    # [2] 화폐 발행
            n.printing_streak += 1

            if n.inflation > 0.60 or n.printing_streak > 12:
                trigger_default(n)                    # [3] 파산
    else:
        n.printing_streak = 0
        var repay := min(n.treasury * n.culture_bias("fiscal_prudence"), n.debt)
        n.debt -= repay
        n.treasury -= repay
```

> **파산 조건을 "국고 마이너스"가 아니라 "하이퍼인플레 또는 연속 화폐발행"으로 정의한 것이 핵심이다.** 그래야 제국이 인플레로 서서히 썩어가는 긴 몰락 과정이 연출된다.

### 7.4 파산 효과

```gdscript
func trigger_default(n: Nation) -> void:
    n.debt *= 0.35                        # 탕감 → 회생 여지 확보
    n.treasury = 0.0
    n.default_history += 1
    n.credit_rating = 0.05
    n.bankruptcy_timer = 25

    n.military_modifier *= 0.5            # 군사력 -50%
    for a in n.armies:
        a.morale *= 0.5                   # 봉급 미지급

    for other in world.nations:
        if other == n: continue
        other.opinion_of[n.id] -= 35.0
        if other.is_creditor_of(n):
            other.opinion_of[n.id] -= 30.0
            other.treasury -= other.loans_to[n.id] * 0.65   # 실제 손실
        other.threat_of[n.id] *= 0.6      # ⚠️ 위협 인식 하락 → 하이에나 유도

    for p in n.provinces:
        p.unrest += 0.25
    n.inflation += 0.15

    EventBus.national_default.emit(n)
```

> **`threat` 감소가 의도적으로 중요하다.** 파산국은 위협적으로 보이지 않으므로 `threat > opinion` 조건에 의해 **주변국이 동시에 달려든다.** 제국 분할의 방아쇠다.

---

## 8. 보급 시스템

### 8.1 요구사항
- 가까워도 주변 인프라가 부실하면 보급이 낮다
- 멀어도 인프라가 촘촘하면 보급이 높다
- 수도 + 주변 도시들이 보급 기지 역할

### 8.2 핵심 발상: **거리가 아니라 비용**

위 요구사항은 **"인프라의 역수를 가중치로 한 다중 소스 다익스트라"**로 정확히 표현된다.

```
프로빈스 통과 비용 = BASE_COST / (1 + infra × 0.85)
→ 인프라 높은 곳은 거의 공짜로 통과
→ 인프라 0인 황무지는 통과 비용 폭증
```

```gdscript
const BASE_COST := 10.0
const SUPPLY_RANGE := 100.0

func _sources(n: Nation) -> Dictionary:
    var src := { n.capital_province: 0.0 }
    for c in n.cities:
        src[c.id] = min(src.get(c.id, INF), max(0.0, 28.0 - c.infra * 3.0))
    return src

func _step_cost(p: Province, n: Nation) -> float:
    if p.is_water:
        return BASE_COST * 0.55 if n.has_naval_control(p) else -1.0
    if p.owner_nation != n.id and not p.is_occupied_by(n):
        return -1.0                                   # 적 영토 통과 불가 = 포위망
    var c := BASE_COST / (1.0 + p.infra * 0.85)
    c *= p.terrain_supply_mult                        # 산악 1.8, 습지 1.6
    c *= (1.0 + p.unrest * 1.2)                       # 불온 지역은 보급대 습격
    return c

# 비용 → 보급률
supply = clamp(1.0 - pow(cost / (SUPPLY_RANGE * n.supply_range_mult), 1.8), 0.05, 1.0)
# 도달 불가 = 0.05 (약탈로만 연명)
```

### 8.3 요구사항 충족 검증

| 상황 | 비용 | 보급 |
|---|---|---|
| 15프로빈스 거리, 전부 인프라 0 | 150 | **0.05** ❌ |
| 15프로빈스 거리, 인프라 6 도로망 | ~24.6 | **0.92** ✅ |
| 5프로빈스 거리, 인프라 1 낙후지 | 27 | 0.90 |
| 5프로빈스 거리, 산악+불온+인프라1 | ~107 | **0.05** ❌ |

"주변 도시가 얼마나 촘촘한가"도 자동 반영된다 — **도시에서 비용이 리셋되므로 도시 사슬 자체가 보급선**이 된다.

### 8.4 성능

> ⚠️ 매 턴 전 국가에 대해 다익스트라를 돌리면 무겁다. **더티 플래그**를 걸어 전쟁 중이거나 영토/인프라가 변한 국가만 재계산한다.
> ```gdscript
> if n.supply_dirty or n.at_war:
>     n.supply_field = compute_supply_field(n)
>     n.supply_dirty = false
> ```

---

## 9. 군사 · 전투 (결정론적)

### 9.1 전투력

```gdscript
func combat_power(a: Army) -> float:
    var base := a.troops * a.tech_level
    base *= a.power_mult                       # 장군 사교력
    base *= a.morale
    base *= a.nation.military_modifier         # 파산 시 ×0.5
    base *= a.nation.army_modifier             # 군사 고문
    base *= pow(a.supply_ratio + a.supply_bonus, 1.3)   # 보급의 지수적 영향
    return base
```

### 9.2 전투 해결 — 란체스터 법칙

```gdscript
var ratio := power_a / (power_a + power_b)
casualties_b = army_b.troops * ratio * ATTRITION
casualties_a = army_a.troops * (1.0 - ratio) * ATTRITION
```

전력차가 클수록 손실비가 제곱으로 벌어져 "1.5배 전력차 = 압승"이 자연 발생한다. **플레이어가 GDP·인프라 그래프만 보고 전쟁 결과를 예측할 수 있고, 그것이 곧 투자 기회다.**

### 9.3 소모

```gdscript
func tick_attrition(a: Army) -> void:
    var s := a.supply_ratio
    if s < 0.5:
        var loss := (0.5 - s) * 0.09 * (1.0 - a.attrition_res)
        a.troops -= int(a.troops * loss)
        a.morale = max(0.1, a.morale - (0.5 - s) * 0.06)
```

> **원정군은 자연히 약해진다.** 대제국이 변경 반란을 진압하려 해도 그 변경은 애초에 인프라가 낮아 보급이 안 된다. **진압 실패 → 반란 확산**이 자동으로 발생한다.

### 9.4 군사비
군사비는 **GDP의 비율**로 묶는다. 군비 확장 → GDP 잠식 → 장기 쇠퇴 사이클이 생긴다.

---

## 10. 불만 · 반란

```gdscript
func tick_unrest(p: Province, n: Nation) -> void:
    var d := 0.0
    d += n.occupation_law_severity * 0.05
    d += max(n.inflation - 0.05, 0.0) * 2.0            # 인플레는 최강 불만 요인
    d += p.culture_distance(n.culture) * 0.03
    d += p.distance_from_capital * 0.01
    d += 0.02 if p.is_exclave else 0.0
    d -= p.garrison_ratio * 0.04
    d -= n.unrest_suppression * 0.05                   # 정치 고문
    d -= n.culture_bias("cohesion") * 0.02

    p.unrest = clamp(p.unrest + d, 0.0, 1.0)
    if p.unrest >= 1.0:
        spawn_rebellion(p)     # 도시가 있으면 규모 ×3
```

반란군은 독립 세력으로 스폰되며, 진압에는 보급이 필요하다.

---

## 11. 외교

### 11.1 3축 관계 (단일 수치 금지)

| 축 | 의미 |
|---|---|
| `opinion` | 감정. 과거 행동 누적 (배신, 선물, 동맹, 파산) |
| `threat` | 위협 인식. 상대 전력 × 국경 접촉 × 팽창 속도 |
| `interest` | 이해관계. 무역 의존도, 공통의 적 |

### 11.2 전쟁 결정

```
선전포고 조건: threat > opinion + war_weariness + 방어동맹 억지력
```

> 이 구조에서 **밸런스 오브 파워가 자동 발생한다.** 1등 국가가 커지면 나머지가 알아서 뭉친다. 대제국 견제 장치가 하나 더 생기는 셈이다.

정치 고문의 `diplo_bonus`가 opinion에 가산된다.

### 11.3 방어동맹

`ALLY_MIN_THREAT`(0.70) 이상의 **공동 위협**을 둘 다 느낄 때 맺어진다. 호감이
아니라 공포로 맺어지므로 `opinion` 은 다이얼이 못 된다 (이력 없는 쌍의 opinion 은
정확히 0.0 이다). 국가당 상한 `ALLY_MAX`(1).

동맹국은 개전 후보에서 **완전히 빠지고**, 남의 동맹은 `deterrence` 로 억지력이 된다.

### 11.4 동맹 만료 — 임기와 재심사

**동맹에 만료가 없으면 그것은 영구 불가침 조약이다.** 300턴 중 한 번만 임계를
넘은 쌍이 영원히 묶이고, 동맹국이 개전 후보에서 빠지므로 그 이웃은 영영 공격
대상이 되지 못한다. 그래서 진입 임계(`ALLY_MIN_THREAT`)는 다이얼이 못 된다 —
올려도 체결 시점만 늦춰지고 최종 동맹 수는 그대로다.

M10.1 실측 (6런 × 300턴, 개전 관문):

```text
eligible                41804      표적 못 찾고 끝난 국가-턴  41644 (99.6%)
t_ally  (동맹이 지운 표적)  49187  ←  살아남은 표적(t_candidate) 3455 의 14배
```

```gdscript
const ALLIANCE_TERM := 80      # 임기. 만료는 해지가 아니라 재심사다.
```

만료 시점에 **형성 조건을 다시 묻는다.**

| 상황 | 결과 |
|---|---|
| 둘 다 두려워하는 제3국이 아직 있다 | 갱신 (`alliance_renewed`), 임기 재설정 |
| 공동 위협이 사라졌다 | 해지 (`alliance_ended`, `term_expired`) |
| 어느 쪽이든 교전 중 | 갱신. **참전 중 이탈은 배신이고 이 문서에 규격이 없다** |
| 동맹국이 소멸 | 즉시 정리 (`ally_dead`) |

쌍마다 한 번만 심사하도록 id 가 낮은 쪽에서 처리한다 (§15 결정론). 새 난수를
쓰지 않는다.

> **효과**: 동맹은 "한 번 맺으면 끝"이 아니라 **위협이 살아 있는 동안만 유지되는
> 계약**이 된다. 위협이던 나라가 무너지면 그 견제 동맹도 풀리고, 그때 비로소
> 승자가 다음 확장의 창을 얻는다.

임기 길이는 **전쟁과 파산을 맞바꾼다.** 20런 × 300턴 실측:

| ALLIANCE_TERM | 선전포고 | 영토 병합 | 최대국 GDP 점유 | 첫 파산 턴 | 총 파산 |
|---|---:|---:|---:|---:|---:|
| 없음 (영구) | 688 | 190 | 7.4% | 92.8 FAIL | 156 |
| 40 | 1278 | 391 | 7.8% | 77.9 FAIL | 293 |
| **80 (채택)** | 1058 | 300 | **9.5%** | **104.0 PASS** | 241 |

임기가 짧을수록 개전 창이 자주 열리고, 전시 군사비(×1.5)가 상시화되어 파산이
빨라진다 (TUNING_M8 이 `WAR_THRESHOLD` 를 내렸을 때 본 것과 같은 교환이다).
80 은 개전을 54% 늘리면서 **첫 파산 턴이 처음으로 목표 대역(100~250)에 들어온**
유일한 값이다.

배신(동맹국 공격)과 자발적 파기는 아직 규격이 없다. 넣는다면 `opinion` 후폭풍과
평판 항이 함께 필요하다.

---

## 12. 평화협상

### 12.1 전쟁 점수

```
warscore = 전투 승리 + 점령 영토 가치 - 자국 손실 - 전쟁 피로
```

warscore가 임계점을 넘으면 패자 AI가 협상에 응한다. 요구 조항의 총 비용이 warscore 이하여야 한다.

### 12.2 조약 조항

| 조항 | 비용 | 후폭풍 |
|---|---|---|
| 영토 할양 | 높음 | 해당 프로빈스 불만 대폭↑, 실지회복 명분 발생 |
| 배상금 | 중간 | **패자 인플레↑** (배상 위해 화폐 발행) |
| 속국화 | 매우 높음 | GDP 상납, 상시 반란 위험 |
| 백지평화 | 0 | 없음 |

> **승자도 대가를 치른다**: 가혹한 조약은 배상금으로 패자의 인플레를 터뜨리지만, 영토 할양은 승자의 행정비를 늘린다. 이것이 시뮬레이션에 리듬을 만든다.

#### 12.2.1 조약 수확 — 측정해 본 결과 대제국의 다이얼이 아니다

M10 에서 "조약당 수확이 0.73 프로빈스라 정복이 반란 상실을 못 따라잡는다"는 가설로
할양 비용을 내려 봤다. **틀렸다.** 기록해 둔다.

```gdscript
province_cost = COST_PROVINCE_BASE + COST_PROVINCE_VALUE * (프로빈스 가치 / 패자 GDP)
조약 예산 = |warscore|   (최대 100)
```

20런 × 300턴, `Peace.annex` / `Unrest._transfer_province` 의 프로빈스 목록 중복
버그를 고친 뒤의 실측:

| base / value | 영토 병합 | 최대 영토 | 최대국 GDP 점유 | 제국 수 |
|---|---:|---:|---:|---:|
| **8 / 35 (채택)** | 190 | 15 | 7.4% | 3 |
| 2 / 8 | 701 | 15 | 7.4% | 2 |

**비용을 1/4 로 내리면 병합 횟수만 3.7배가 되고 제국은 안 생긴다.** 땅이 더 빨리
손바뀜할 뿐 아무도 쌓지 못한다 — 싸게 뺏을 수 있으면 남도 싸게 뺏어 간다.
그래서 설계서 §12.2 의 "영토 할양 = 비용 높음"을 그대로 유지한다.

> **먼저 고쳐야 했던 것**: 이 다이얼을 처음 측정했을 때는 8/35 병합 166 vs
> 2/8 병합 579 · 최대 영토 40 · GDP 점유 19.2% 로 비용이 지배 변수처럼 보였다.
> 전부 `n.provinces` 에 같은 프로빈스가 여러 번 들어가는 버그가 만든 허상이었다
> (`realm_value` · `realm_province_count` 가 중복을 그대로 셌다). 버그를 고치자
> 두 설정의 최대 영토가 15로 같아졌다. **밸런스 다이얼을 돌리기 전에 불변식부터
> 확인할 것.**

대제국이 안 생기는 진짜 원인은 조약 수확이 아니라 **아무도 정복지를 유지하지
못한다**는 데 있다. 2/8 에서 병합 701 > 반란 상실 362 인데도 최대 영토가 15에
머문다 — 얻은 땅을 반란이 아니라 다른 정복자에게 다시 잃는다. 다음에 볼 곳은
개전 빈도(`WAR_THRESHOLD`)와 휴전·동맹이 승자를 얼마나 오래 보호하는지다.

### 12.3 영토 요구 우선순위 — 연결성 기반

요구사항: **수도와 이어진 땅 우선 → 해상 월경지는 낮은 확률 → 먹을 게 없으면 월경지라도 주장**

```gdscript
func _rank_provinces(winner, loser) -> Array:
    var occupied := loser.provinces.filter(func(p): return p.is_occupied_by(winner))
    var reachable := _land_reachable_from(winner)     # 승자 영토 + 확정 요구지에서 육상 BFS

    var out := []
    for p in occupied:
        var value := _province_value(p)
        var cost := value
        var score := value

        if reachable.has(p.id):
            score *= 2.2                              # ✅ 육상 연결 최우선
            cost  *= 0.85
        elif _is_coastal_exclave(p, winner):          # 🌊 같은 sea_basin 공유
            var accept := 0.12 + winner.naval_strength_near(p) * 0.35
            accept += winner.culture_bias("maritime") * 0.25
            if winner.rng.randf() > accept:
                score = -1.0                          # 이번엔 포기
            else:
                score *= 0.55
                cost  *= 1.6
        else:
            score = -1.0                              # 완전 고립 = 불가

        if score > 0.0:
            out.append({"prov": p, "score": score, "cost": cost})

    out.sort_custom(func(a,b): return a.score > b.score)

    # 🐟 "먹을 게 없으면" — 유효 후보 전무 시 월경지 강제 부활
    if out.is_empty() and not occupied.is_empty():
        for p in occupied:
            out.append({"prov": p, "score": _province_value(p),
                        "cost": _province_value(p) * 1.4})
        out.sort_custom(func(a,b): return a.score > b.score)
    return out
```

> ⚠️ **`_land_reachable_from`의 시드에 `_pending_annex`(이번에 요구 확정한 프로빈스)를 반드시 포함한다.** 한 곳을 먹으면 그 너머가 새로 "연결됨"이 되므로 국경이 한 덩어리로 자연 확장된다. 누더기 국경이 방지된다.

### 12.4 월경지의 대가

```gdscript
func on_province_annexed(p: Province, n: Nation) -> void:
    if not _land_reachable_from(n).has(p.id):
        p.is_exclave = true
        p.admin_cost_mult = 2.4        # 행정비 폭증
        p.unrest += 0.30               # 분리주의
        # 보급 시스템이 자동으로 낮은 supply 부여 → 진압 곤란
```

> **여기서 모든 시스템이 맞물린다**: 해외 월경지 획득 → 행정비 2.4배 + 보급 불가 → 재정난 가속 → 신용한도 소진 → 화폐 발행 → 인플레 → 전국 불만 → 월경지 반란 → 해상 보급 의존 진압군 → 제해권 상실 시 전멸 → 파산 → 군사력 -50% + 관계 악화 → 하이에나 참전 → **제국 분할**

---

## 13. 인물 시스템

### 13.1 데이터

```gdscript
class_name Character extends RefCounted

var id: int
var name: String
var culture: int
var birth_turn: int
var death_turn: int          # ⚠️ 생성 시점에 확정

# 4대 능력치 (0~100)
var intelligence: float
var charisma: float
var health: float
var creativity: float

var role: int = Role.NONE
var loyalty: float = 0.5
var ambition: float
var noble_birth: float       # 0~1
var home_province: int
```

> **`death_turn` 사전 확정의 이점**: 결정론 유지 + **플레이어가 정보로 구매·활용 가능**. "저 명장은 8턴 뒤 죽는다"를 아는 것 자체가 투자 우위가 된다.

### 13.2 생성 — 교육 법률이 인재 풀을 결정

```gdscript
func spawn_character(n: Nation, p: Province, turn: int) -> Character:
    var edu := n.law_modifier("education")           # -1.0 ~ +1.0
    var mean := 45.0 + edu * 22.0 + p.infra * 1.6 + (5.0 if p.has_city else 0.0)
    var dev  := 16.0 - edu * 3.0                     # 교육 좋으면 편차도 감소

    c.intelligence = _roll(mean + edu * 8.0, dev)          # 교육 영향 최대
    c.charisma     = _roll(mean, dev + 4.0)                # 교육 영향 최소
    c.creativity   = _roll(mean + edu * 5.0, dev + 5.0)
    c.health       = _roll(50.0 + p.gdp_pc / 90.0, 15.0)   # 소득이 건강 결정

    c.ambition = _roll(50.0, 20.0) / 100.0
    c.loyalty  = clamp(0.75 - c.ambition * 0.4 + edu * 0.1, 0.05, 1.0)

    var lifespan := 42.0 + c.health * 0.32                 # 42~74
    lifespan *= (1.0 + n.law_modifier("healthcare") * 0.15)
    lifespan += randfn(0.0, 6.0)
    c.death_turn = turn + int(max(lifespan, 18.0))
    return c
```

### 13.3 보직 — 총 7 고문 슬롯 + 장군

```gdscript
enum Role { NONE, POLITICAL, TECH, ECONOMIC, MILITARY, NAVAL, GENERAL }
const SLOTS := { POLITICAL: 3, TECH: 1, ECONOMIC: 1, MILITARY: 1, NAVAL: 1 }
```

| 보직 | 슬롯 | 점수 공식 |
|---|---|---|
| 정치 고문 | 3 | `charisma×0.70 + int×0.30` |
| 기술 고문 | 1 | `creativity×0.65 + int×0.35` |
| 경제 고문 | 1 | `int×0.75 + creativity×0.25` |
| 군사 고문 | 1 | `int×0.45 + charisma×0.35 + health×0.20` |
| 해군 고문 | 1 | `int×0.40 + creativity×0.35 + health×0.25` |
| 장군 | N | `charisma×0.40 + health×0.35 + int×0.25` |

### 13.4 고문 효과

```gdscript
# 정치 3인은 점수 합산 후 /300 → 0~1
n.law_change_speed   = 1.0 + pol * 1.2
n.unrest_suppression = pol * 0.35
n.diplo_bonus        = pol * 18.0

n.tech_rate          = 1.0 + tech * 0.8
n.infra_cost_mult    = 1.0 - tech * 0.30

n.inflation_damping  = eco * 0.45          # ⚠️ 인플레 억제
n.tax_efficiency     = 0.7 + eco * 0.5
n.credit_bonus       = eco * 0.15

n.army_modifier      = 1.0 + mil * 0.35
n.supply_range_mult  = 1.0 + mil * 0.30

n.navy_modifier      = 1.0 + nav * 0.40
n.sea_supply_mult    = 1.0 + nav * 0.35
```

> **의도된 극적 서사**: 유능한 경제 고문이 인플레를 억누르며 제국을 지탱하다가, **`death_turn`이 도래하면** 후임이 그만한 인재가 아니라 인플레가 폭발한다. **한 사람의 죽음이 제국을 무너뜨리는** 순간이 자연 발생한다. 플레이어에게는 최고의 매도 신호가 된다.

### 13.5 장군 효과

```gdscript
army.power_mult    = 1.0 + charisma/100 * 0.45      # 지휘
army.attrition_res = health/100 * 0.4               # 행군 손실 저항
army.supply_bonus  = intelligence/100 * 0.25        # 병참
army.ambush_chance = creativity/100 * 0.20          # 전술
```

### 13.6 배출 · 등용 · 이탈

```gdscript
# 배출률
rate = population / 900000.0
     * (1.0 + law_modifier("education") * 0.6)
     * (1.0 + city_count * 0.08)
# 프로빈스는 인구 가중 랜덤 선택

# 등용 — 신분법이 인재 배치를 결정
sort_key = role_score(c, r) * lerp(0.4, 1.0, (merit+1)/2)
         + c.noble_birth * (1.0 - merit) * 30.0
```
> **세습제 국가는 무능한 귀족이 고문이 된다.** 법률 선택이 인재 배치를 통해 국력으로 번역된다.

```gdscript
# 야심 = 반란 씨앗
if role == NONE and role_score(c, MILITARY) > 75: loyalty -= ambition * 0.02
if n.inflation > 0.2 or n.bankruptcy_timer > 0:   loyalty -= 0.03
if loyalty < 0.15 and role == GENERAL:            spawn_rebellion_led_by(c)  # 군벌
```

---

## 14. 투자 시장 (1차 — 최소 구현)

> **설계 방침**: 별도의 시장 시뮬레이션을 만들지 않는다. **이미 계산된 시뮬 수치가 그 자체로 훌륭한 가격 신호**이므로 그것을 그대로 변환하고 소량의 노이즈만 얹는다.

```gdscript
# 국채 (0~100)
func bond_price(n: Nation) -> float:
    return 100.0 * n.credit_rating * (1.0 - clamp(n.inflation, 0.0, 0.9))

# 프로빈스 지분 (지역 경제 주식)
func province_share_price(p: Province) -> float:
    return p.gdp / 1000.0 * (1.0 - p.unrest * 0.7) * p.supply

# 인물 후원 (출세 가능성 = 로또)
func character_stake_price(c: Character, turn: int) -> float:
    return role_score(c, c.best_role()) \
         * clamp(float(c.death_turn - turn) / 30.0, 0.0, 1.0) * 0.5
```

### 14.1 플레이어의 자연스러운 전략 (설계 검증용)
- `credit_rating` 하락 / `printing_streak` 증가 감지 → 채권 매도
- `infra` 상승 중 + `growth_headroom` 큼 → 프로빈스 지분 매수
- 젊고 능력치 높은 무명 인물 → 후원 (고위험 고수익)
- 경제 고문 `death_turn` 임박 → 해당국 전량 매도

```gdscript
func growth_headroom(p: Province) -> float:
    var a := gdp_pc_anchor(p.infra)
    return (a - p.gdp_pc) / a
```

### 14.2 향후 확장 (2차 이후)
- 정보 비대칭 상품화 (첩보 구매로 `death_turn`, 전쟁 계획 열람)
- 선물/공매도
- 자본을 통한 간접 개입 (반란군 후원, 암살 자금, 소문 유포)

---

## 15. 결정론 규약

1. 모든 RNG는 `RngPool`에서 시스템별 인스턴스로 발급. 전역 `randi()` 금지.
2. `Dictionary` 순회 순서에 의존 금지. 순회가 필요하면 정렬된 키 배열을 만든다.
3. 부동소수점 누적 순서를 시스템 실행 순서로 고정 (§1.4 준수).
4. 세이브 = `(world_seed, turn, 플레이어 행동 로그)`만으로 완전 재현 가능해야 한다.
5. 시뮬은 `_process`가 아닌 **명시적 `tick()` 호출**로만 진행. 배속·일시정지·헤드리스가 전부 무료로 얻어진다.

---

## 16. 밸런싱 파이프라인

### 16.1 헤드리스 배치 실행

```bash
godot --headless --script res://tools/batch_sim.gd -- --runs 500 --turns 300 --out runs.csv
python tools/analyze.py runs.csv
```

> ⚠️ **이 도구를 마일스톤 초반에 만든다.** 시스템이 이 정도로 얽히면 감(感)으로는 절대 밸런싱이 되지 않는다. 없이 시작하면 수 주를 낭비한다.

### 16.2 필수 검증 지표

| 지표 | 목표 범위 | 벗어나면 |
|---|---|---|
| 300턴 최대국 영토 점유율 | < 70% | 붕괴 나선이 약함 |
| 국가 수 (300턴) | 초기의 40~70% | 통합/분열 속도 조정 |
| 첫 파산 발생 턴 | 100~250 | 50턴 이전이면 신용한도 협소 |
| 파산 후 생존율 | 40~60% | 100% 멸망은 과도 |
| 전쟁 중 평균 보급률 | 0.6~0.8 | 0.3 미만이면 `SUPPLY_RANGE` 확대 |
| 세계 총 도시 수 | 15~40 | 100 초과 시 조건 헐거움 |
| 최고 인프라 값 (300턴) | 7~9 | 10 도달 시 건설비 과소 |
| 1인당 GDP 지니계수 | 0.3~0.5 | 너무 평등하면 투자 동기 소멸 |
| 문화별 생존율 | 각 10% 이상 | 5% 미만이면 밸런스 붕괴 |
| 인구 총합 보존 | 오차 < 0.1% | 새면 마이그레이션 버그 |
| 월경지 보유국 평균 수명 | 본토형보다 짧을 것 | 같으면 페널티 부족 |

### 16.3 알려진 함정 (회귀 테스트로 감시)

- [ ] **정복 직후 도시 생성 스파이크** → 인구 가중 평균 미적용 버그
- [ ] **디플레 스파이럴로 실질 GDP 발산** → `inflation` 하한 -0.5 누락
- [ ] **인구 무한 증식** → `_rebalance_migration` 누락
- [ ] **수도 한 곳에 전 인구 집중** → 과밀 페널티 누락
- [ ] **모든 AI가 동일 법률 채택** → 순수 이득 법률 존재

---

## 17. 마일스톤

각 단계는 **PNG/CSV 출력으로 눈으로 검증한 뒤** 다음으로 넘어간다.

### M1 — 지형 (뷰 없음)
- [ ] `hex.gd`, `map_generator.gd`
- [ ] `dump_map_png.gd`
- [ ] 시드 100개 배치 생성 → 대륙 크기 / 섬 개수 분포 확인
- **완료 기준**: 육지 정확히 5000, 검증 4조건 통과율 > 80%

### M2 — 프로빈스
- [ ] `province_splitter.gd`, `feature_tagger.gd`
- [ ] 프로빈스 색칠 PNG 덤프
- **완료 기준**: 전 프로빈스 1~30 타일, 고아 타일 0, 섬은 독립 프로빈스

### M3 — 경제 코어
- [ ] `economy.gd` (앵커/수렴/인프라/인구), `inflation.gd`
- [ ] 배치 도구 `batch_sim.gd` + `analyze.py`
- **완료 기준**: 300턴간 GDP가 앵커 상한을 초과하지 않음, 인구 총합 보존

### M4 — 법률 + AI 예산
- [ ] `law_system.gd`, `law_evaluator.gd`, `.tres` 데이터 세트
- **완료 기준**: 문화별로 법률 채택 분포가 유의미하게 다름

### M5 — 신용 · 파산
- [ ] `credit.gd`
- **완료 기준**: 첫 파산 100~250턴, 붕괴 나선이 로그로 관찰됨

### M6 — 인물
- [ ] `character_system.gd`
- **완료 기준**: 교육 법률에 따라 평균 능력치가 유의미하게 변동

### M7 — 보급 + 전투
- [ ] `supply.gd`, `military.gd`
- **완료 기준**: §8.3 검증 표의 4가지 케이스가 표대로 재현됨

### M8 — 외교 · 전쟁 · 평화
- [ ] `diplomacy.gd`, `peace.gd`, `unrest.gd`
- **완료 기준**: 밸런스 오브 파워 관찰, 국경이 누더기가 되지 않음

### M9 — 시장 + 뷰
- [ ] `market.gd`
- [ ] 헥스 렌더러, HUD, 차트
- **완료 기준**: 관전만으로 재미가 성립하는지 플레이 테스트

### M10 — 튜닝
- [ ] §16.2 전 지표를 목표 범위로 수렴

---

## 18. 구현자 유의사항 (요약)

1. **뷰보다 로그를 먼저 만든다.** PNG 덤프와 CSV 출력이 렌더러보다 우선이다.
2. **`Node` 상속 금지**를 sim/ 전역에 적용한다.
3. **전역 RNG 금지.** 결정론이 깨지면 이후 모든 작업이 무의미해진다.
4. **성능 병목은 프로빈스 단위 전환으로 이미 해결됐다.** 조기 최적화하지 말고, 실제 프로파일 후 필요하면 GDExtension으로 sim/ 코어만 이관한다.
5. **밸런스 수치는 전부 상수로 한곳에 모으거나 `.tres`로 뺀다.** 코드에 매직넘버를 흩뿌리지 않는다.
6. 각 시스템 구현 시 **§16.3 함정 목록을 회귀 테스트로 먼저 작성**한다.

---

*문서 버전 v0.1 — 1차 설계 확정본*
