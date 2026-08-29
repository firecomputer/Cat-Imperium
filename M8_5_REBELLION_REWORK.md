# Cat Empire — M8.5 반란·재통합 구조 보강 계획서

> **문서 목적**: M8 이후 튜닝에서 확인된 “반란을 사실상 예방할 수 없음”과 “반란 발생 후 재정복이 지나치게 어려움”을 구조적으로 해결한다.  
> M9(시장 + 뷰)에 들어가기 전에 반란 시스템을 **예방 가능하고, 전쟁으로 진압 가능하며, 실제로 살아남은 반란만 독립하는 구조**로 만든다.
>
> **기준 문서**
> - `CAT_EMPIRE_DESIGN.md` — 1차 설계 계획서
> - `TUNING_M8.md` — M8 이후 튜닝 기록
>
> **범위 제한**: M8.5에서는 아래 네 가지에만 집중한다.
>
> 1. `WarAI` 평시 치안 주둔 로직
> 2. 반란전 전용 warscore 및 항복 경로
> 3. 반란전 전용 강화 — 옛 모국 영토 재통합
> 4. 고정 60턴 독립 인정 → `recognition` 누적 시스템
>
> `rebel_organization`, 자치령, 사면/강경진압, separatism memory, 외국의 반란 지원 등은 **M8.5 범위 밖**이다. 필요하면 M9 이후 확장한다.

---

# 0. 왜 M8.5가 필요한가

M8 이후 재측정과 튜닝으로 수도거리 항의 하드캡 문제는 완화되었다.

최종 튜닝 기준:

| 지표 | 값 |
|---|---:|
| 반란 | 704 / 20런 |
| 영토 병합 | 61 / 20런 |
| 반란 : 정복 | 11.5 : 1 |
| 최고 인프라 | 8.43 |
| 세계 도시 수 | 26.2 |
| 첫 파산 턴 | 138.7 |
| 국경 덩어리 수 | 1.01 |
| 인구 총합 보존 오차 | 0.044% |

경제·도시·파산·국경 구조는 현재 목표 범위에 들어왔다.  
남은 문제는 **반란 시스템 자체의 상태 전이**다.

## 0.1 현재 구조의 문제

### A. 주둔이라는 설계된 대항 수단이 실제로 작동하지 않는다

`unrest.gd`에는 이미:

```gdscript
d -= p.garrison_ratio * 0.04
```

가 존재한다.

그러나 `WarAI._fronts`가 군대를 사실상 전선에만 배치하기 때문에, 반란 발생 프로빈스의 **93%가 `garrison_ratio == 0`** 이었다.

즉 현재 국가에는 불만을 적극적으로 관리할 실질적 수단이 없다.

---

### B. 반란전에는 전쟁 승리 경로가 없다

현재 `peace.gd`의 반란전 처리:

```gdscript
if _is_rebel_war(world, war):
    if length >= REBEL_RECOGNITION_TURNS:
        Diplomacy.end_war(world, war, "independence_recognized")
    return
```

반란전에는 일반 warscore 강화가 적용되지 않는다.

따라서 모국이 반란군 주력을 격파하고 대부분의 영토를 탈환해도:

- 반란국 전 영토 점령 → 즉시 전멸
- 그것에 실패 → 60턴 뒤 독립 인정

이라는 이진 구조다.

M8 튜닝 실측에서:

- 반란 독립 559
- 반란 전멸 106

으로 약 70%가 영구 독립했다.

---

### C. 일반 평화협상 비용은 재통합에 맞지 않는다

일반전은 `ACCEPT_SCORE := 35` 부근에서 평화가 성립하며, 프로빈스 요구 비용은 대략:

```text
15 + 60 × province_value_share
```

이다.

실측상 강화조약 59건에서 병합은 61프로빈스에 그쳤다.

외국 영토를 정복하는 비용으로는 문제없을 수 있지만, **반란으로 떨어져 나간 자기 영토를 되찾는 비용으로 사용하면 안 된다.**

---

### D. “60턴 생존”은 반란의 성공 여부를 측정하지 않는다

현재 반란군은:

- 영토를 거의 다 잃어도
- 주력군이 파괴돼도
- 모국이 압도적으로 우세해도

전멸 판정을 피한 채 타이머만 채우면 독립한다.

반란의 실제 성공과 독립 인정 사이의 연결이 약하다.

---

# 1. M8.5 설계 원칙

M8.5의 목적은 **반란 빈도를 강제로 낮추는 것이 아니다.**

반란은 1차 설계의 붕괴 나선에서 핵심 역할을 한다.

```text
재정난
→ 인플레이션
→ 불만
→ 변경 반란
→ 진압 비용
→ 추가 재정난
→ 파산
→ 제국 분할
```

따라서 반란 자체를 무력화하면 안 된다.

대신 다음 네 문장을 만족해야 한다.

> **강한 국가는 비용을 지불하면 반란을 예방할 수 있다.**

> **반란이 일어나도 군사적으로 이기면 진압할 수 있다.**

> **진압된 옛 영토는 일반 외국 영토처럼 하나씩 다시 구매하지 않는다.**

> **실제로 영토와 군사력을 유지한 반란만 독립국으로 인정된다.**

그리고 모든 시스템은 기존 결정론 규약을 유지한다.

- 전역 `randf()` 추가 금지
- Dictionary 순회 순서 의존 금지
- 동일 seed + 동일 행동 로그 → 동일 결과
- 시뮬레이션 코어는 `RefCounted`

---

# 2. 변경 1 — WarAI 평시 치안 주둔

## 2.1 목표

현재 죽어 있는 `garrison_ratio`를 실제 국가 운영 수단으로 만든다.

평화 중에도 일부 병력을 고불만 지역에 배치한다.

단, 주둔군은 **무료 안정도 버프가 아니라 군사력의 기회비용**이어야 한다.

```text
내부 치안 병력 증가
→ 반란 위험 감소
→ 국경/공격 병력 감소

대외전쟁 발생
→ 전선 수요 증가
→ 치안군 철수
→ 변경 불만 상승
→ 전쟁 중 반란 위험 증가
```

이 상호작용이 목적이다.

---

## 2.2 파일

주 변경:

```text
sim/ai/war_ai.gd
```

필요 시 보조:

```text
sim/model/army.gd
sim/model/province.gd
sim/systems/unrest.gd
```

---

## 2.3 치안 수요 점수

각 자국 프로빈스에 대해 `garrison_need`를 계산한다.

초기 구현은 **새로운 복잡한 상태값을 만들지 않는다.**

```gdscript
func _garrison_need(p: Province, n: Nation) -> float:
    var score := p.unrest

    # 이미 설계된 위험 특성을 반영
    score += 0.15 if p.is_exclave else 0.0
    score += min(p.distance_from_capital * 0.025, 0.20)

    # 도시는 경제적·정치적 가치가 높으므로 우선 방어
    score += 0.15 if p.has_city else 0.0

    # 매우 안정된 지역은 대상에서 제외
    return max(score, 0.0)
```

초기 임계:

```gdscript
const GARRISON_NEED_MIN := 0.35
```

`GARRISON_NEED_MIN` 미만은 평시 주둔 후보에서 제외한다.

> 수치는 M8.5 배치 결과로 조정한다.  
> 핵심은 `unrest`가 가장 큰 비중을 차지해야 한다는 점이다.

---

## 2.4 국가가 치안에 쓸 수 있는 병력

모든 군대를 치안으로 빼면 안 된다.

초기값:

```gdscript
const GARRISON_ARMY_SHARE_PEACE := 0.25
const GARRISON_ARMY_SHARE_WAR   := 0.08
```

의미:

- 평시: 가용 전력의 최대 25%
- 전쟁 중: 최대 8%

전쟁 중에도 치안군을 완전히 0으로 만들지 않는다.  
그렇게 하면 전쟁 선포와 동시에 전국 반란이 터지는 새 절벽이 생길 수 있다.

필요하다면 이후 문화 성향 또는 desperation으로 조정할 수 있지만 M8.5에서는 고정 상수로 시작한다.

---

## 2.5 배치 우선순위

후보 프로빈스를 다음 키로 정렬한다.

```text
1. garrison_need 내림차순
2. unrest 내림차순
3. province.id 오름차순
```

마지막 `province.id`는 결정론 보장을 위한 tie-breaker다.

각 군대는 가장 위험한 프로빈스부터 채운다.

---

## 2.6 `garrison_ratio`

기존 `unrest.gd`가 사용하는 `p.garrison_ratio`의 의미를 명확히 고정한다.

```text
garrison_ratio = 해당 프로빈스 치안 병력 / 필요 치안 병력
```

범위:

```gdscript
p.garrison_ratio = clamp(ratio, 0.0, 1.0)
```

필요 치안 병력은 초기에는 인구 기반으로 단순 계산한다.

```gdscript
func _required_garrison(p: Province) -> float:
    return max(500.0, p.population * 0.015)
```

예:

- 인구 20,000 → 500
- 인구 100,000 → 1,500

이 값은 실제 군대 규모 분포를 보고 튜닝한다.

---

## 2.7 전선과 치안의 우선순위

WarAI의 판단 순서:

```text
1. 수도 즉시 위협
2. 활성 전선 최소 방어력 확보
3. 평시/전시 치안 예산 산정
4. 고불만 프로빈스에 주둔
5. 남는 병력으로 공격/예비
```

치안 때문에 수도가 비거나 전선이 붕괴하면 안 된다.

반대로 현재처럼 전선이 없다는 이유로 모든 군대가 무의미하게 뭉쳐 있어도 안 된다.

---

## 2.8 반란 발생 직전 주둔군

M8.5에서는 새 `rebel_organization`을 만들지 않는다.

따라서 주둔군의 효과는 기존 그대로:

```gdscript
d -= p.garrison_ratio * 0.04
```

만 사용한다.

**반란군 초기 병력 감소 효과는 M8.5에 넣지 않는다.**

먼저 기존 설계된 억제 항 하나가 실제로 작동했을 때 결과를 측정한다.

---

# 3. 변경 2 — 반란전 전용 warscore

## 3.1 목표

반란전에도 명시적인 군사적 승패를 만든다.

현재:

```text
전 영토 점령 → 정부 승리
60턴 생존 → 반란 승리
```

를 다음으로 바꾼다.

```text
정부군이 군사적으로 압도
→ 반란 항복

반란군이 영토와 전투력을 유지
→ recognition 증가
→ 독립 인정
```

---

## 3.2 일반전 warscore와 분리

일반 국제전의 warscore 상수를 그대로 쓰지 않는다.

반란전은 전쟁 목적이 다르다.

새 함수:

```gdscript
func rebel_warscore(world: WorldState, war) -> float:
```

반환 범위:

```text
-100 ~ +100
```

정의:

- `+` : 모국 우세
- `-` : 반란군 우세

---

## 3.3 구성 요소

초기안:

```text
정부 warscore =
    탈환한 반란 원영토 비율   × 55
  + 반란군 전투손실 우위       × 25
  + 반란 수도 점령 여부        × 20
```

각 항은 독립적으로 clamp한다.

### A. 영토 통제

반란 발생 시 반란국이 획득한 프로빈스 ID를 전쟁 객체에 저장한다.

```gdscript
war.rebel_origin_provinces: PackedInt32Array
```

그중 현재 모국이 다시 통제하는 비율:

```gdscript
var reclaimed_ratio := reclaimed / max(origin_total, 1)
var territory_score := reclaimed_ratio * 55.0
```

이렇게 해야 이후 다른 나라에게 땅을 잃거나 소유권이 변해도 최초 반란 범위를 추적할 수 있다.

---

### B. 전투손실 우위

반란전 개시 시 누적 카운터를 초기화한다.

```gdscript
war.parent_losses
war.rebel_losses
```

전투 종료 시 해당 war에 손실을 누적한다.

```gdscript
var total := war.parent_losses + war.rebel_losses
var rebel_loss_share := war.rebel_losses / max(total, 1.0)
```

이를 `-1 ~ +1`로 중심화한다.

```gdscript
var casualty_balance := (rebel_loss_share - 0.5) * 2.0
var battle_score := clamp(casualty_balance * 25.0, -25.0, 25.0)
```

모국이 반란군을 훨씬 많이 죽였으면 양수다.

---

### C. 반란 수도

반란국 생성 시 수도를 저장한다.

```gdscript
war.rebel_capital_province: int
```

현재 모국이 통제하면:

```gdscript
capital_score = 20.0
```

그렇지 않으면 0.

반란 수도 하나만 먹었다고 즉시 끝나지 않도록 20점으로 제한한다.

---

## 3.4 정부 승리 임계

초기값:

```gdscript
const REBEL_PARENT_VICTORY_SCORE := 65.0
```

조건:

```gdscript
if rebel_warscore(world, war) >= REBEL_PARENT_VICTORY_SCORE:
    _resolve_rebel_defeat(world, war)
```

65의 의미:

예를 들어:

- 반란 원영토 70% 탈환 → 38.5
- 수도 탈환 → +20
- 전투손실 우위 → +10

합계 68.5 → 반란 항복.

즉 **전 프로빈스를 직접 밟을 필요는 없다.**

---

## 3.5 정부 자동승리 예외

반란국의 모든 프로빈스를 잃었다면 기존처럼 즉시 종료 가능하다.

```gdscript
if rebel_has_zero_controlled_provinces:
    _resolve_rebel_defeat(world, war)
```

이는 warscore 우회가 아니라 명백한 전멸 판정이다.

---

## 3.6 반란군의 즉시 독립 승리

M8.5에서는 반란군용 `warscore <= -X` 즉시 독립은 두지 않는다.

반란군의 성공은 §5 `recognition`이 담당한다.

이렇게 역할을 분리한다.

```text
정부 승리 → warscore
반란 승리 → recognition
```

정부는 적극적인 군사행동으로 빠르게 전쟁을 끝낼 수 있지만, 반란군은 **지속적으로 국가 기능을 유지해야 독립**한다.

---

# 4. 변경 3 — 반란전 전용 강화 / 재통합

## 4.1 목표

정부 승리 시 반란 프로빈스를 일반 평화협상 비용으로 하나씩 사지 않는다.

반란국은 원래 모국에서 분리된 세력이다.

따라서 정부가 반란전에서 승리하면:

```text
rebel_origin_provinces 중
현재 반란국이 소유한 프로빈스
→ 원모국으로 일괄 반환
```

한다.

---

## 4.2 일반 `peace.gd` 영토 요구 로직을 사용하지 않는다

다음 시스템을 **호출하지 않는다.**

- `ACCEPT_SCORE`
- `COST_PROVINCE_BASE`
- `COST_PROVINCE_VALUE`
- `_rank_provinces()`
- 일반 annex 예산

반란 진압은 국제전쟁의 영토 정복과 별도 경로다.

---

## 4.3 함수

예:

```gdscript
func _resolve_rebel_defeat(world: WorldState, war) -> void:
    var parent := world.nations[war.parent_nation_id]
    var rebel  := world.nations[war.rebel_nation_id]

    for pid in war.rebel_origin_provinces:
        var p := world.provinces[pid]
        if p.owner_nation == rebel.id:
            _restore_to_parent(world, p, parent)

    Diplomacy.end_war(world, war, "rebellion_suppressed")
    _remove_rebel_state_if_empty(world, rebel)
```

---

## 4.4 제3국이 점령/병합한 영토

중요한 예외다.

반란이 진행되는 동안 제3국이 해당 프로빈스를 합법적으로 병합했다면 정부 승리로 순간이동 반환시키면 안 된다.

따라서:

```gdscript
if p.owner_nation == rebel.id:
    restore
else:
    leave_unchanged
```

만 한다.

즉 정부가 되찾는 것은 **현재 반란국 소유인 원영토만**이다.

---

## 4.5 재통합 직후 unrest

재정복 즉시 `unrest = 0`으로 만들면 진압에 성공한 순간 모든 정치적 문제가 사라진다.

반대로 1.0을 유지하면 즉시 재반란할 수 있다.

M8.5에서는 별도 separatism 상태를 만들지 않으므로 단순 cooldown을 적용한다.

초기값:

```gdscript
const REINTEGRATION_UNREST := 0.35
const REINTEGRATION_GRACE_TURNS := 15
```

Province에 최소 상태 하나 추가:

```gdscript
var rebellion_grace_turns: int = 0
```

재통합 시:

```gdscript
p.unrest = min(p.unrest, REINTEGRATION_UNREST)
p.rebellion_grace_turns = REINTEGRATION_GRACE_TURNS
```

`unrest.tick()`에서 drift 계산은 계속하지만:

```gdscript
if p.rebellion_grace_turns > 0:
    p.rebellion_grace_turns -= 1
    # unrest는 변할 수 있으나 새 rebellion spawn은 막는다.
    return
```

**주의:** grace 기간 동안 unrest 누적 자체를 정지시키지 않는다.  
15턴 뒤 상황이 나쁘면 다시 위험해져야 한다.

---

## 4.6 재통합 비용은 “0”이 아니다

영토 warscore 비용만 0이다.

정부는 이미 다음 비용을 지불했다.

- 치안군 유지
- 전투 손실
- 보급 비용
- 전쟁 중 군사비
- 인프라 파괴
- 반란 동안 세수 상실

따라서 추가로 임의의 “재통합 골드 비용”을 만들지 않는다.

M8.5의 목표는 새 시스템을 추가하는 것이 아니라 **현재 전쟁 비용이 실제 비용으로 기능하도록 하는 것**이다.

---

# 5. 변경 4 — 60턴 타이머를 Recognition으로 교체

## 5.1 목표

현재:

```gdscript
if length >= 60:
    independence_recognized
```

를 제거한다.

반란국은 **영토를 실제로 유지해야 독립**한다.

---

## 5.2 데이터

전쟁 객체에 추가:

```gdscript
var recognition: float = 0.0
```

범위:

```text
0 ~ 100
```

독립 임계:

```gdscript
const REBEL_RECOGNITION_TARGET := 100.0
```

---

## 5.3 Recognition 증가 조건

M8.5에서는 단순하고 추적 가능한 세 항만 사용한다.

```text
1. 원영토 통제율
2. 반란 수도 유지
3. 전쟁 지속
```

초기 공식:

```gdscript
func _tick_rebel_recognition(world: WorldState, war) -> void:
    var rebel := world.nations[war.rebel_nation_id]

    var controlled_ratio := _rebel_origin_control_ratio(world, war)

    var gain := 0.0

    # 원영토를 지배하고 있어야 기본적으로 인정도가 오른다.
    gain += controlled_ratio * 1.2

    # 정치적 중심지를 유지하면 추가.
    if _rebel_controls_capital(world, war):
        gain += 0.35

    # 영토를 거의 잃으면 recognition이 감소한다.
    if controlled_ratio < 0.30:
        gain -= 1.25

    # 완전히 밀려난 상태에서는 빠르게 붕괴.
    if controlled_ratio <= 0.05:
        gain -= 2.0

    war.recognition = clamp(war.recognition + gain, 0.0, 100.0)
```

이 공식에서 반란국이 전 영토와 수도를 유지하면:

```text
약 +1.55 / turn
```

이므로 약 65턴에 독립한다.

즉 기존 60턴과 비슷한 시간 규모를 유지하지만, 이제 **성공적으로 영토를 지킨 경우에만** 그렇다.

영토 절반이면:

```text
+0.6 + 0.35 = +0.95
```

약 105턴.

영토 30% 미만이면 recognition이 정체하거나 감소한다.

---

## 5.4 왜 절대 “생존 턴” 보너스를 크게 주지 않는가

시간 자체에 큰 점수를 주면 결국 기존 60턴 타이머를 다른 이름으로 다시 만드는 셈이다.

따라서 전쟁 지속 자체는 별도 고정 보너스를 두지 않는다.

시간은 **통제율을 여러 턴 유지하는 행위**를 통해 이미 반영된다.

---

## 5.5 독립 인정

```gdscript
if war.recognition >= REBEL_RECOGNITION_TARGET:
    _resolve_rebel_independence(world, war)
```

독립 시:

- 반란국을 정상 국가로 유지
- `rebel_origin_provinces` 메타데이터는 전쟁 종료와 함께 폐기
- 일반 외교 대상이 됨
- 모국과의 전쟁 종료
- 기존의 `independence_recognized` 로그 이벤트 유지 가능

이후 국가 시스템은 일반 국가와 동일하게 작동한다.

M8.5에서는 별도의 “미승인국” 상태를 만들지 않는다.

---

## 5.6 최대 전쟁 길이 안전장치

Recognition이 오르지도 내리지도 않는 교착이 수백 턴 계속될 가능성을 감시한다.

초기에는 강제 종료 상수를 넣지 않는다.

대신 로그만 추가한다.

```text
rebel_war_age_100
rebel_war_age_150
rebel_war_age_200
```

배치에서 150턴 이상의 반란전이 반복되면 그때 별도 교착 해결 규칙을 설계한다.

**미리 120턴 강제 독립 같은 안전장치를 넣지 않는다.**  
그것은 다시 타이머 독립 문제를 만든다.

---

# 6. Peace tick의 최종 흐름

`peace.gd` 반란전 분기를 다음 순서로 바꾼다.

```gdscript
if _is_rebel_war(world, war):
    # 1. 완전 전멸
    if _rebel_has_no_controlled_origin(world, war):
        _resolve_rebel_defeat(world, war)
        return

    # 2. 정부군의 군사적 승리
    var score := rebel_warscore(world, war)
    if score >= REBEL_PARENT_VICTORY_SCORE:
        _resolve_rebel_defeat(world, war)
        return

    # 3. 반란국의 독립 인정도 갱신
    _tick_rebel_recognition(world, war)

    if war.recognition >= REBEL_RECOGNITION_TARGET:
        _resolve_rebel_independence(world, war)
        return

    # 일반 평화협상으로 내려가지 않는다.
    return
```

일반 국제전은 기존 로직을 그대로 사용한다.

---

# 7. 데이터 모델 변경

## Province

추가:

```gdscript
var rebellion_grace_turns: int = 0
```

---

## War 또는 전쟁 상태 객체

반란전에서만 유효:

```gdscript
var is_rebel_war: bool
var parent_nation_id: int
var rebel_nation_id: int

var rebel_origin_provinces: PackedInt32Array
var rebel_capital_province: int

var recognition: float = 0.0

var parent_losses: float = 0.0
var rebel_losses: float = 0.0
```

기존 구조상 동일 정보를 다른 필드에서 안정적으로 조회할 수 있다면 중복 저장하지 않는다.

단, `rebel_origin_provinces`는 **반란 시작 당시 스냅샷**이어야 하므로 명시 저장을 권장한다.

---

# 8. 로그 추가

M8.5는 결과만 보고 튜닝하면 다시 원인을 놓칠 수 있다.

`war.csv` 또는 별도 반란 로그에 다음을 추가한다.

## 반란 발생

```text
rebel_spawn
turn
parent_id
rebel_id
province_count
origin_population
avg_unrest
avg_garrison
capital_distance
```

---

## 매 반란전 종료

```text
rebel_war_end
turn
duration
result
recognition
parent_warscore
origin_provinces
parent_reclaimed_ratio
parent_losses
rebel_losses
```

`result`:

```text
suppressed
independence_recognized
annihilated
```

`annihilated`를 `suppressed`에 합쳐도 되지만 분석 편의를 위해 구분을 권장한다.

---

## 주둔

런 단위 집계:

```text
avg_garrison_ratio
share_provinces_garrisoned
share_high_unrest_garrisoned
army_share_on_garrison
rebellions_with_zero_garrison
```

특히 기존 93%였던:

```text
rebellions_with_zero_garrison
```

을 반드시 유지한다.

---

# 9. 신규 분석 지표

기존 `반란 : 정복`만으로 M8.5를 평가하지 않는다.

## 9.1 핵심 지표

| 지표 | 목표 |
|---|---|
| 반란 발생 프로빈스 중 주둔 0 비율 | **93% → 60% 이하** |
| 반란전 정부 진압률 | **30~60%** |
| 독립 인정률 | **30~60%** |
| 반란전 지속시간 중앙값 | **20~90턴** |
| 150턴 이상 반란전 | 전체의 **<5%** |
| 진압 후 15턴 내 재반란 | **0%** |
| 진압 후 50턴 내 재반란 | 측정만, 지나치게 높으면 후속 과제 |
| 평시 전체 군대 중 치안 비율 | **5~25%** |
| 전쟁 중 전체 군대 중 치안 비율 | **0~10%** |

정부 진압률과 독립 인정률을 둘 다 0이나 100으로 만들지 않는다.

관전 게임에서는 결과가 갈려야 한다.

---

## 9.2 기존 지표 회귀

M8.5 변경 후에도 다음은 유지해야 한다.

| 지표 | 기존 목표 |
|---|---|
| 최고 인프라 | 7~9 |
| 세계 도시 수 | 15~40 |
| 첫 파산 발생 턴 | 100~250 |
| 인구 총합 보존 | 오차 <0.1% |
| 문화별 생존율 | 각 10% 이상 |
| 국경 덩어리 수 | 현재 수준 유지 |
| 300턴 최대국 영토 점유 | <70% |

특히 치안군 때문에 대외전쟁 능력이 지나치게 떨어져 **정복이 다시 0에 수렴하지 않는지** 확인한다.

---

# 10. 예상되는 창발적 결과

M8.5는 단순한 반란 너프가 아니다.

## 10.1 평화로운 제국

```text
경제 안정
→ 충분한 군대 보유
→ 변경 주둔
→ unrest drift 감소
→ 반란 억제
```

영토 유지에 성공한다.

---

## 10.2 대외전쟁 중인 제국

```text
전쟁 발발
→ 치안군 일부 전선 이동
→ 변경 garrison_ratio 하락
→ 고불만 지역 반란
→ 군대를 다시 국내로 돌릴지 선택
```

전쟁과 내부 안정 사이의 실제 trade-off가 생긴다.

---

## 10.3 강하지만 재정적으로 지친 제국

```text
반란 발생
→ 정부군 투입
→ 군사적으로는 승리
→ 영토 재통합
→ 전쟁 비용과 인프라 피해 누적
→ 다음 위기에 더 취약
```

반란은 진압 가능하지만 공짜가 아니다.

---

## 10.4 실제로 무너지는 제국

```text
파산
→ 군사력 -50%
→ 치안군 부족
→ 여러 반란 동시 발생
→ 탈환률 부족
→ recognition 누적
→ 여러 독립국 탄생
```

이 경우에만 원래 설계의 “제국 분할”이 강하게 나타난다.

즉 **국가 크기 자체가 반란의 사형선고가 아니라, 국가 역량을 초과한 크기가 위험해진다.**

---

# 11. 구현 순서

상호 의존성을 줄이기 위해 아래 순서를 고정한다.

## M8.5-A — 주둔

- [ ] `WarAI`에 평시 치안 후보 산정
- [ ] 평시/전시 치안 병력 상한
- [ ] `garrison_ratio` 실제 계산
- [ ] 주둔 진단 로그
- [ ] 6런 프로브

**완료 확인:** 반란 발생 프로빈스의 주둔 0 비율이 유의미하게 감소.

---

## M8.5-B — 반란전 warscore

- [ ] 반란 시작 시 origin province snapshot
- [ ] rebel capital snapshot
- [ ] 반란전 손실 누적
- [ ] `rebel_warscore()`
- [ ] `REBEL_PARENT_VICTORY_SCORE`
- [ ] 정부 승리 로그

**완료 확인:** 전 영토 점령 없이도 일부 반란을 진압.

---

## M8.5-C — 재통합

- [ ] `_resolve_rebel_defeat()`
- [ ] origin territory 일괄 반환
- [ ] 제3국 소유 영토 제외
- [ ] `rebellion_grace_turns`
- [ ] 15턴 이내 즉시 재반란 방지

**완료 확인:** 진압 전쟁 1회가 1프로빈스 반환으로 끝나지 않음.

---

## M8.5-D — Recognition

- [ ] `recognition` 상태 추가
- [ ] 고정 `REBEL_RECOGNITION_TURNS` 제거
- [ ] 통제율 기반 recognition 증감
- [ ] 독립 인정 임계
- [ ] 장기 교착 로그

**완료 확인:** 영토를 대부분 잃은 반란이 시간만 채워 독립하는 현상이 사라짐.

---

# 12. A/B 튜닝 절차

한 번에 네 시스템을 켜고 수치를 만지지 않는다.

M8 튜닝 때와 마찬가지로 단계별 CSV를 남긴다.

권장:

```text
m85_base_*      현재 M8 최종
m85_a_*         주둔만
m85_b_*         + rebel warscore
m85_c_*         + reintegration
m85_d_*         + recognition 최종
```

각 단계:

```bash
godot4 --headless --path . --script res://tools/batch_war.gd -- \
  --runs 20 --turns 300 --out res://out/m85_d_war.csv

godot4 --headless --path . --script res://tools/batch_sim.gd -- \
  --runs 20 --turns 300 --out res://out/m85_d_sim.csv
```

6런 프로브 → 이상 없으면 20런 배치 순서로 진행한다.

---

# 13. 튜닝 우선순위

결과가 나쁠 때 아무 상수나 건드리지 않는다.

## 반란이 여전히 거의 전부 독립한다

순서:

1. `rebel_warscore` 구성요소가 실제로 움직이는지 확인
2. 정부군이 반란 전선으로 이동하는지 확인
3. `REBEL_PARENT_VICTORY_SCORE`
4. recognition gain

**반란 발생률부터 다시 낮추지 않는다.**

---

## 반란이 거의 전부 진압된다

순서:

1. 주둔군 비율이 과도한지
2. warscore의 territory 가중치
3. `REBEL_PARENT_VICTORY_SCORE`
4. recognition 상승 속도

---

## 대외전쟁이 사라진다

주둔 AI 문제다.

```text
GARRISON_ARMY_SHARE_PEACE
GARRISON_NEED_MIN
```

을 먼저 조정한다.

`WAR_THRESHOLD`나 동맹 상수를 다시 건드리지 않는다.

M8에서 외교 게이트를 과하게 완화하면 파산과 반란이 폭증한다는 것이 이미 확인되었다.

---

## 조기 파산이 늘어난다

주둔군 자체가 추가 병력을 생성해서는 안 된다.

기존 군대를 재배치할 뿐이어야 한다.

따라서 치안 때문에 직접 군사비가 증가했다면 구현 오류 가능성을 먼저 확인한다.

전쟁 증가로 파산이 늘었다면 warscore/recognition 지속시간을 확인한다.

---

# 14. 회귀 테스트

최소 자동 테스트:

### 주둔

```text
- unrest 0.8 지역이 unrest 0.1 지역보다 먼저 주둔된다.
- 동일 need에서는 province.id가 낮은 쪽이 먼저 선택된다.
- 평시 치안 병력이 설정 비율을 초과하지 않는다.
- 전쟁 중 치안 병력이 전시 상한을 초과하지 않는다.
```

### Warscore

```text
- 반란 원영토 100% 탈환 시 territory_score == 55.
- 수도 탈환 시 +20.
- 손실이 동일하면 battle_score ≈ 0.
- score >= 65이면 전 영토 점령 전에도 진압된다.
```

### 재통합

```text
- rebel 소유 origin province는 parent로 반환.
- 제3국 소유 province는 반환되지 않는다.
- 반환 직후 unrest <= 0.35.
- grace 15턴 동안 새 rebellion spawn 없음.
- grace 동안 unrest drift 자체는 계속 계산됨.
```

### Recognition

```text
- 100% 영토 + 수도 유지 → recognition 증가.
- 50% 영토 + 수도 유지 → 증가하지만 더 느림.
- 30% 미만 → 정체 또는 감소.
- 5% 이하 → 빠르게 감소.
- recognition 100 → 독립 인정.
- 단순 war age만으로 독립하지 않음.
```

### 결정론

최종 3런을 동일 seed로 두 번 실행하여 결과 파일이 **바이트 동일**해야 한다.

---

# 15. M8.5 완료 기준

다음 조건을 모두 만족하면 M9로 진행한다.

## 기능

- [ ] AI가 평시 고불만 프로빈스에 실제 병력을 주둔시킨다.
- [ ] `garrison_ratio`가 반란 억제에 실제로 사용된다.
- [ ] 반란전을 전 영토 점령 없이 군사적으로 진압할 수 있다.
- [ ] 진압 성공 시 반란국의 잔여 원영토가 일괄 재통합된다.
- [ ] 재통합 직후 즉시 재반란하지 않는다.
- [ ] 고정 60턴 독립 판정이 제거된다.
- [ ] 반란국이 영토를 유지할수록 recognition이 상승한다.
- [ ] 영토를 상실한 반란국은 시간만 버텨 독립할 수 없다.

## 밸런스

- [ ] 반란전 진압률 30~60%
- [ ] 독립 인정률 30~60%
- [ ] 반란전 지속시간 중앙값 20~90턴
- [ ] 150턴 이상 교착 <5%
- [ ] 반란 발생 시 주둔 0 비율 60% 이하
- [ ] 기존 M8 PASS 지표에 중대한 회귀 없음

## 기술

- [ ] 동일 seed 재실행 결과 바이트 동일
- [ ] 신규 RNG 의존 없음
- [ ] 일반 국제전 평화협상 동작 변경 없음
- [ ] `out/`에 M8.5 A/B CSV 보존
- [ ] 최종 튜닝 결과를 별도 `TUNING_M8_5.md`로 기록

---

# 16. 의도적으로 하지 않는 것

M8.5에서 아래 기능은 구현하지 않는다.

- `rebel_organization`
- 소요/폭동/반란 3단계 상태
- 자치령 협정
- 사면 vs 강경진압
- 장기 `separatism` 기억
- 도시 반란 효과 재설계
- 반란군 초기 병력에 주둔 효과 적용
- 외국의 반란군 지원
- 미승인국 외교 상태
- 일반 강화조약 비용 재조정

이 기능들은 매력적이지만 지금 넣으면 **무엇이 M8의 실제 문제를 해결했는지 측정할 수 없게 된다.**

M8.5의 질문은 좁게 유지한다.

> **“국가가 병력을 지불해 반란을 억제할 수 있고, 반란이 나더라도 실제 전쟁에서 이기면 영토를 되찾으며, 실제로 버틴 반란만 독립하는가?”**

이 질문에 YES가 나오면 M8.5는 완료다.

---

# 17. M8.5 이후 기대 구조

```text
                 ┌─ 충분한 치안 병력 ───────────────→ 안정
                 │
불만 상승 ───────┤
                 │
                 └─ 치안 부족
                       ↓
                    반란 발생
                       ↓
             ┌─────────┴─────────┐
             │                   │
       정부군 군사 우세       반란군 영토 유지
             │                   │
       warscore ≥ 65         recognition 누적
             │                   │
           진압              recognition = 100
             │                   │
       원영토 재통합             독립
             │
       15턴 grace
             │
    상황이 개선되면 안정,
    아니면 장기적으로 재반란
```

이 구조에서는 반란이 더 이상 “수도에서 멀면 언젠가 자동 독립하는 시스템”이 아니다.

동시에 강한 제국도 변경을 유지하려면 실제 병력을 묶어두어야 하며, 대외전쟁·파산·보급난으로 그 능력을 잃는 순간 반란이 성공하기 시작한다.

따라서 M8.5는 반란을 약화시키는 패치가 아니라, **1차 설계에서 의도한 제국 붕괴 나선을 하드캡이 아닌 국가 역량의 실패로 다시 연결하는 마일스톤**이다.
