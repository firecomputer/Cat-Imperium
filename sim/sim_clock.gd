class_name SimClock extends RefCounted

const EmpireSystem = preload("res://sim/systems/empire_system.gd")

## tick() 진입점. 시스템 실행 순서가 바뀌면 값이 한 턴씩 밀린다 (§1.4).
## 아직 없는 시스템은 자리만 남겨 순서를 눈에 보이게 둔다.
##
## Economy.aggregate 는 4~6 단계에서만 돌았다. 그런데 영토가 움직이는 곳은
## 11 단계(반란)와 13 단계(강화조약)다. 그래서 나라를 반쯤 잃은 국가가 그 턴
## 내내 잃기 전의 gdp·population 을 들고 있었고, 12~14 단계가 전부 그 낡은 값으로
## 위협·강화·행정·시장을 판단했다. 영토가 바뀐 직후에 다시 집계한다.


static func tick(world: WorldState) -> void:
	CharacterSystem.tick(world)         # 1. 생성/사망/등용
	LawSystem.tick(world)              # 2. AI 법률 심의/변경
	AdvisorEffects.apply(world)         # 3. 고문 효과
	Economy.tick_infra(world)          # 4. 인프라 건설/감쇠
	Economy.tick_production(world)     # 5. GDP 앵커 수렴
	Economy.tick_migration(world)      # 6. 인구 이동 (총합 보존 필수)
	EmpireSystem.collect_tribute(world) # 6.5 속국 공납 (세수 산정 뒤, 정산 전)
	Credit.tick(world)                 # 7. 수입/지출/차입/화폐발행/파산
	Inflation.tick(world)              # 8. 통화량 → 인플레 (관성 lerp)
	Naval.tick(world)                  # 8.5 해전·제해권 (문서에 없는 M8 추가 단계)
	Supply.recompute_if_dirty(world)   # 9. 보급 필드 (더티/전쟁국)
	Military.tick(world)               # 10. 보급 소모 (교전 선택은 M8)
	Unrest.tick(world)                 # 11. 불만 누적, 반란 발생
	Economy.aggregate(world)           # 11.5 반란이 떼어 간 땅을 집계에 반영
	Diplomacy.tick(world)              # 12. 관계 갱신, 선전포고
	Peace.tick(world)                  # 13. 전쟁 점수·강화 판정
	Economy.aggregate(world)           # 13.5 강화조약이 옮긴 땅을 집계에 반영
	EmpireSystem.tick(world)           # 13.6 통합·행정·권위·속국 충성
	NationPlacer.tick_titles(world)    # 13.7 국명 칭호 갱신 (표시 전용, 시뮬 무영향)
	Market.tick(world)                 # 14. 투자 가격·배당·포트폴리오 기록
	# 15. 이벤트 전달은 뷰 호스트가 world.events 를 단방향으로 읽는다.
	world.turn += 1


static func run(world: WorldState, turns: int) -> void:
	for i in range(turns):
		tick(world)
