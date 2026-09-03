extends SceneTree

## M9 메인 씬·UI 거래 흐름 스모크 테스트.
##
##   godot4 --headless --path . --script res://tools/test_view.gd

const NationPalette = preload("res://view/nation_palette.gd")
## 국가색끼리의 최소 OKLab 거리 하한. 잡으려는 것은 예전 방식의 색 충돌(거리 0)이다.
## 실측: 40국 0.104, 120국 0.068, 200국 0.051 — 국가 수가 늘어도 여유가 남는 선으로 둔다.
const PALETTE_MIN_DISTANCE := 0.045

var main: Control


func _initialize() -> void:
	# M13 기본값은 EarthMapSource 이지만 1차 UI 회귀는 기존 노이즈 지형에 고정한다.
	OS.set_environment("CAT_IMPERIUM_MAP_SOURCE", "noise")
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	call_deferred("_run")


func _run() -> void:
	await process_frame
	await process_frame
	assert(main.world != null, "메인 씬이 세계를 생성해야 한다")
	assert(main.map_renderer.world == main.world, "지도에 같은 WorldState 가 연결돼야 한다")
	assert(main.selected_province >= 0, "초기 수도 프로빈스가 선택돼야 한다")

	main.tabs.current_tab = 1
	main.market_category.select(0)
	main._refresh_market_list(true)
	assert(main.market_list.item_count > 0, "국채 목록이 비어 있으면 안 된다")
	var cash_before: float = main.world.portfolio.cash
	main.trade_quantity.value = 1
	main._trade(true)
	assert(main.world.portfolio.cash < cash_before, "UI 매수가 현금을 차감해야 한다")
	assert(main.world.portfolio.trade_count == 1)

	main._step_once()
	assert(main.world.turn == 1, "한 턴 버튼이 시뮬을 정확히 한 번 진행해야 한다")
	assert(main.world.portfolio.net_worth_history.size() == 1,
		"시장 틱이 포트폴리오 차트를 기록해야 한다")
	await process_frame

	_check_names()
	_check_palette()
	_check_search()
	await _check_war_overlay()
	await _check_naval_view()
	print("view tests: PASS")
	quit(0)


## 국명은 기록·검색에서 국가를 알아보는 유일한 수단이다. 비어 있거나 겹치면 안 된다.
func _check_names() -> void:
	var seen := {}
	for n in main.world.nations:
		assert(not n.name.is_empty(), "모든 국가에 이름이 있어야 한다")
		assert(not seen.has(n.name), "국명이 겹치면 안 된다: %s" % n.name)
		seen[n.name] = true
	assert(main._nation_name(0).begins_with(main.world.nations[0].name),
		"뷰 표기가 국명으로 시작해야 한다")


## 색이 겹치면 나라를 가르는 방법이 클릭해서 하나씩 확인하는 것밖에 없다.
## 같은 색 금지만으로는 부족하다 — 눈에 안 갈리는 이웃 색까지 막아야 한다.
func _check_palette() -> void:
	var renderer = main.map_renderer
	var seen := {}
	var labs: Array[Vector3] = []
	for n in main.world.nations:
		if not n.is_alive:
			continue
		var color: Color = renderer._nation_color(n.id)
		assert(not seen.has(color), "살아 있는 두 나라가 같은 색을 쓰면 안 된다")
		seen[color] = true
		labs.append(NationPalette.to_oklab(color))
	var closest := INF
	for i in range(labs.size()):
		for j in range(i + 1, labs.size()):
			closest = minf(closest, labs[i].distance_to(labs[j]))
	print("palette: %d개국 최소 OKLab 거리 %.4f" % [labs.size(), closest])
	assert(closest >= PALETTE_MIN_DISTANCE,
		"가장 가까운 두 국가색도 눈에 갈릴 만큼 떨어져야 한다: %.4f" % closest)


func _check_search() -> void:
	main._open_search()
	assert(main.search_panel.visible, "F 검색 패널이 열려야 한다")
	main._on_search_changed("")
	assert(main.search_list.item_count > 0, "빈 질의는 전체 국가를 보여야 한다")
	var target: Nation = main.world.nations[3]
	main._on_search_changed(target.name)
	assert(main.search_list.item_count > 0, "국명 검색 결과가 있어야 한다")
	assert(str(main.search_list.get_item_metadata(0)) == "n:%d" % target.id,
		"검색 결과가 그 국가를 가리켜야 한다")
	main._on_search_submitted("")
	assert(not main.search_panel.visible, "선택 후 검색 패널이 닫혀야 한다")
	assert(main.selected_nation == target.id, "검색 이동이 그 국가를 선택해야 한다")


## 해역 표시 (M9.2). 함대가 한 점에 쌓이면 관전에서 아무것도 읽히지 않는다.
func _check_naval_view() -> void:
	var renderer = main.map_renderer
	var zones := {}
	for f in main.world.fleets:
		if f.is_alive and f.ships > 0:
			zones[f.zone_id] = true
	assert(zones.size() > 1, "이 시드 120턴에는 여러 해역에 함대가 있어야 한다")
	var spots := {}
	for marker in renderer._fleet_markers:
		spots[marker["pos"]] = true
	assert(spots.size() > 1, "함대 마커가 한 점에 겹치면 안 된다")

	renderer.set_mode(renderer.MapMode.NAVAL)
	await process_frame
	var painted := false
	for color in renderer._sea_colors:
		if color != renderer.WATER:
			painted = true
			break
	assert(painted, "제해권 지도는 통제된 해역을 칠해야 한다")
	renderer.set_mode(renderer.MapMode.POLITICAL)

	_check_names()                            # 반란국이 생긴 뒤에도 이름은 유일하다
	_check_palette()                          # 반란국도 같은 규칙으로 색을 받는다
	_check_layers()
	_check_diplomacy_panel()


## 새 레이어가 _province_color 의 match 에서 빠지면 조용히 국가 레이어가 그려진다.
## 그림이 실제로 달라지는지로 본다.
func _check_layers() -> void:
	var renderer = main.map_renderer
	renderer.set_mode(renderer.MapMode.POLITICAL)
	renderer._rebuild_colors()
	var political: PackedColorArray = renderer._last_color.duplicate()
	for layer in [renderer.MapMode.DIPLOMACY, renderer.MapMode.CULTURE,
			renderer.MapMode.SEPARATISM]:
		renderer.set_mode(layer)
		renderer._rebuild_colors()
		assert(renderer._last_color != political,
			"레이어 %s 가 국가 레이어와 같은 그림을 그리면 안 된다"
				% renderer.MODE_NAMES[layer])
	renderer.set_mode(renderer.MapMode.POLITICAL)


## 전쟁 상대·동맹·속국·전쟁 지지도·분리주의는 예전에는 화면 어디에도 없었다.
func _check_diplomacy_panel() -> void:
	var at_war := -1
	for n in main.world.nations:
		if not n.is_alive or n.provinces.is_empty():
			continue
		for war_id in n.wars:
			if main.world.wars[war_id].is_active:
				at_war = n.id
				break
		if at_war >= 0:
			break
	assert(at_war >= 0, "이 시점에는 전쟁 중인 나라가 있어야 한다")
	main._focus_nation(at_war)
	var text: String = main.nation_detail.text
	assert(text.contains("전쟁 지지도"), "전쟁 지지도가 패널에 있어야 한다")
	assert(text.contains("분리주의"), "선택 지역의 분리주의가 패널에 있어야 한다")
	assert(text.contains("vs "), "누구와 싸우는지가 패널에 있어야 한다")
	assert(main.map_renderer.diplomacy_focus == main.selected_nation,
		"외교 레이어 기준국이 선택 국가를 따라야 한다")


## 전쟁이 붙은 세계에서 지도 오버레이가 실제 교전·공성을 잡아내는지 본다.
func _check_war_overlay() -> void:
	# 턴 120 을 못 박으면 시뮬 쪽 변경이 이 시드의 우연한 전황을 바꿀 때마다
	# 뷰와 무관한 이유로 깨진다 (M10 이 test_rebellion·test_war 에서 고친 것과 같다).
	# 검사의 목적은 "교전이 있는 세계에서 오버레이가 맞는가" 이므로 교전이 생길
	# 때까지 진행한다.
	SimClock.run(main.world, 120)
	while _contested_provinces() == 0 and main.world.turn < 400:
		SimClock.run(main.world, 20)
	main._process_new_events()
	main.map_renderer.on_world_advanced()
	await process_frame
	var renderer = main.map_renderer
	assert(not renderer._army_markers.is_empty(), "군대가 지도에 표시돼야 한다")
	var sieges := 0
	for p in main.world.provinces:
		if p.siege_by_nation >= 0 and p.siege_progress > 0.0:
			sieges += 1
	assert(renderer._siege_markers.size() == sieges,
		"공성 마커 수가 실제 공성 수와 같아야 한다")
	var battles := _contested_provinces()
	assert(battles > 0, "교전중인 프로빈스가 있는 상태로 검사해야 한다")
	assert(renderer._battle_markers.size() == battles,
		"교전 마커 수가 실제 교전 수와 같아야 한다")
	var joined := "\n".join(main.event_lines)
	assert(joined.contains("전투"), "기록에 전투 줄이 남아야 한다")
	assert(joined.contains("[url=p:"), "기록의 지역이 지도 링크여야 한다")
	main.map_renderer.set_show_war(false)
	assert(not renderer.show_war, "전쟁 오버레이를 끌 수 있어야 한다")
	main.map_renderer.set_show_war(true)


## 서로 전쟁 중인 두 나라의 군대가 같이 서 있는 프로빈스 수.
## world.armies 를 직접 훑는다. armies_by_province 는 10단계(Military)에서만 재구축되고
## Military.create_army 는 색인에 넣지 않으므로, 11단계(Unrest)에서 태어난 반란군은
## 턴이 끝날 때 색인에 없다. 렌더러는 world.armies 를 읽으므로 색인으로 재면 어긋난다.
func _contested_provinces() -> int:
	var by_province := {}
	for army in main.world.armies:
		if not army.is_alive or army.province_id < 0:
			continue
		if not by_province.has(army.province_id):
			by_province[army.province_id] = {}
		by_province[army.province_id][army.nation_id] = true
	var battles := 0
	for pid in by_province.keys():
		var nations: Dictionary = by_province[pid]
		var ids: Array = nations.keys()
		var contested := false
		for i in range(ids.size()):
			for j in range(i + 1, ids.size()):
				if Diplomacy.are_at_war(main.world, int(ids[i]), int(ids[j])):
					contested = true
		if contested:
			battles += 1
	return battles
