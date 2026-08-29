extends SceneTree

## M9 메인 씬·UI 거래 흐름 스모크 테스트.
##
##   godot4 --headless --path . --script res://tools/test_view.gd

var main: Control


func _initialize() -> void:
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


## 전쟁이 붙은 세계에서 지도 오버레이가 실제 교전·공성을 잡아내는지 본다.
func _check_war_overlay() -> void:
	SimClock.run(main.world, 120)
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
	var battles := 0
	for pid in main.world.armies_by_province.keys():
		var nations := {}
		for army_id: int in main.world.armies_at(pid):
			if main.world.armies[army_id].is_alive:
				nations[main.world.armies[army_id].nation_id] = true
		var ids: Array = nations.keys()
		var contested := false
		for i in range(ids.size()):
			for j in range(i + 1, ids.size()):
				if Diplomacy.are_at_war(main.world, int(ids[i]), int(ids[j])):
					contested = true
		if contested:
			battles += 1
	assert(battles > 0, "이 시드 120턴에는 교전중인 프로빈스가 있어야 한다")
	assert(renderer._battle_markers.size() == battles,
		"교전 마커 수가 실제 교전 수와 같아야 한다")
	var joined := "\n".join(main.event_lines)
	assert(joined.contains("전투"), "기록에 전투 줄이 남아야 한다")
	assert(joined.contains("[url=p:"), "기록의 지역이 지도 링크여야 한다")
	main.map_renderer.set_show_war(false)
	assert(not renderer.show_war, "전쟁 오버레이를 끌 수 있어야 한다")
	main.map_renderer.set_show_war(true)
