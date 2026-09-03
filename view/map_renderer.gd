class_name HexMapRenderer extends Control

const EmpireSystem = preload("res://sim/systems/empire_system.gd")

## M9 헥스 지도. 15,000개 타일 중 육지 5,000개만 그리며, 시뮬 상태를 읽기만 한다.
##
## 성능: 타일마다 폴리곤 + 안티에일리어스 외곽선을 그리면 redraw 당 1만 번의 드로우가 된다.
## 그래서 정점·인덱스·경계선을 생성 시 1회 캐시하고, 매 프레임에는 삼각형 배열 1개와
## 멀티라인 몇 개만 낸다. 색은 턴이 바뀔 때만 다시 채운다.
##
## 계층: _base (지형·경계) / _overlay (도시·전쟁·선택). 호버는 무거운 _base 를 건드리지 않는다.

signal province_selected(province_id: int)
## 교전 마커를 직접 집었을 때. 프로빈스 선택과 별개로 전투 패널을 연다.
signal battle_selected(province_id: int)

enum MapMode { POLITICAL, GDP, INFRA, UNREST, SUPPLY, NAVAL }

const MODE_NAMES := ["국가", "경제", "인프라", "불만", "보급", "제해권"]
const WATER := Color("101d2e")
const WATER_GRID := Color("1b3048")
const GRID := Color(0.025, 0.04, 0.065, 0.42)
const BORDER := Color(0.02, 0.03, 0.05, 0.75)
const NATION_BORDER := Color(0.86, 0.90, 0.95, 0.55)
const FRONT := Color("ff5964")
## 속국 채움 명도. 직할령(0.78)보다 어둡게 두어 같은 색 안에서 구분된다.
const VASSAL_VALUE := 0.62
const SELECTED := Color("ffd166")
const HOVERED := Color("f4f1de")
const HIGHLIGHT := Color("ffffff")
const BATTLE := Color("ff4d5e")
const ZONE_BORDER := Color(0.45, 0.62, 0.80, 0.30)
## 제해권 색은 물색과 국가색을 섞어 만든다. 알파로 얹으면 어두운 물 위에서
## 거의 보이지 않는다 (실측: 알파 0.42 는 화면에서 구분 불가).
const ZONE_FILL_MIX := 0.72
## 제해권 지도에서는 바다가 주인공이다. 육지는 어둡게 깔아 뒤로 물린다.
const NAVAL_LAND_DIM := 0.55
const HEX_RADIUS := 0.57735027

## 논리 단위(헥스 반지름 0.577 기준) 선 굵기.
const GRID_WIDTH := 0.022
const PROVINCE_WIDTH := 0.05
const NATION_WIDTH := 0.10
const FRONT_WIDTH := 0.17
## 축소하면 논리 단위 굵기가 1픽셀 밑으로 내려가 선이 점선처럼 부서진다.
## 화면 픽셀 기준 최소 굵기를 같이 준다.
const PROVINCE_MIN_PX := 1.0
const NATION_MIN_PX := 1.8
const FRONT_MIN_PX := 2.6
const MARKER_MIN_PX := 3.0
## 헥스 한 칸이 이보다 작게 보이면 벌집 격자선은 픽셀 이하라 보이지도 않는다.
## 1만 7천 개 변을 매 프레임 만드는 값이 가장 크므로 그 구간에서는 통째로 건너뛴다.
const GRID_MIN_UNIT := 9.0

var world: WorldState
var mode: int = MapMode.POLITICAL
var show_war := true
var selected_province: int = -1
var hovered_province: int = -1
var zoom: float = 1.0
var pan := Vector2.ZERO

var _base: Control
var _overlay: Control

var _tile_to_province := PackedInt32Array()
var _dragging := false

# 정적 지오메트리 (set_world 에서 1회)
var _verts := PackedVector2Array()
var _indices := PackedInt32Array()
var _colors := PackedColorArray()
var _tile_slot := PackedInt32Array()          # 타일 id → _verts 시작 인덱스
var _grid_lines := PackedVector2Array()       # 중복 제거한 헥스 변 (벌집 외형)
var _edge_points := PackedVector2Array()      # 프로빈스 경계 변, 2점씩
var _edge_a := PackedInt32Array()             # 변마다 양쪽 프로빈스 id (-1 = 바다/맵 밖)
var _edge_b := PackedInt32Array()
var _province_edges: Array = []               # 프로빈스 → 자기 경계 변 인덱스
# 해역 (M9.2). 바다 타일은 제해권 모드에서만 칠하므로 배열을 따로 둔다.
var _sea_verts := PackedVector2Array()
var _sea_indices := PackedInt32Array()
var _sea_colors := PackedColorArray()
var _sea_slot := PackedInt32Array()           # 타일 id → _sea_verts 시작 인덱스
var _zone_lines := PackedVector2Array()       # 해역 경계 변
var _zone_line_a := PackedInt32Array()        # 변마다 양쪽 해역 id (-1 = 육지/맵 밖)
var _zone_line_b := PackedInt32Array()
var _zone_line_colors := PackedColorArray()   # 변 하나당 색. 제해권 국가색으로 칠한다
var _tile_to_zone := PackedInt32Array()

# 턴마다 갱신되는 캐시
var _nation_lines := PackedVector2Array()
var _vassal_lines := PackedVector2Array()
var _vassal_colors := PackedColorArray()
var _front_lines := PackedVector2Array()
var _highlight_lines := PackedVector2Array()
var _controller_cache := PackedInt32Array()
var _last_color := PackedColorArray()         # 프로빈스별 직전 색. 바뀐 것만 다시 칠한다
var _army_markers: Array = []                 # {pos, color, radius}
var _battle_markers: Array = []               # {pos, province, sides:[{color, power}]}
var _siege_markers: Array = []                # {pos, progress, color}
var _fleet_markers: Array = []                # {pos, color, radius, battle}
var _transport_markers: Array = []            # {pos, color, radius, target}
var _last_zone_color := PackedColorArray()    # 해역별 직전 색
var _occupied_edges := PackedVector2Array()
var _occupied_colors := PackedColorArray()    # 변 하나당 색 하나

var _colors_dirty := true
var _edges_dirty := true
var _war_dirty := true
var _highlight_nations: Array[int] = []
var _highlight_until := 0.0
var _pulse := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	custom_minimum_size = Vector2(540, 480)
	_base = _make_layer(false)
	_overlay = _make_layer(true)
	resized.connect(_on_resized)


func _make_layer(is_overlay: bool) -> Control:
	var layer := MapLayer.new()
	layer.map = self
	layer.is_overlay = is_overlay
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.clip_contents = true
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(layer)
	return layer


## 자식 Control 두 장이 각자의 캔버스 아이템에 그린다. 그래야 호버가 지형을 다시 안 그린다.
class MapLayer extends Control:
	var map
	var is_overlay := false

	func _draw() -> void:
		if map == null:
			return
		if is_overlay:
			map._draw_overlay(self)
		else:
			map._draw_base(self)


func _on_resized() -> void:
	_base.queue_redraw()
	_overlay.queue_redraw()


func set_world(value: WorldState) -> void:
	world = value
	selected_province = -1
	hovered_province = -1
	zoom = 1.0
	pan = Vector2.ZERO
	_highlight_nations.clear()
	_highlight_until = 0.0
	_tile_to_province.resize(_map_total())
	_tile_to_province.fill(-1)
	_tile_to_zone.resize(_map_total())
	_tile_to_zone.fill(-1)
	if world != null:
		for p in world.provinces:
			for tile: int in p.tiles:
				_tile_to_province[tile] = p.id
		for z in world.sea_zones:
			for tile: int in z.tiles:
				_tile_to_zone[tile] = z.id
	_build_geometry()
	_colors_dirty = true
	_edges_dirty = true
	_war_dirty = true
	_redraw_all()


func set_mode(value: int) -> void:
	mode = clampi(value, MapMode.POLITICAL, MapMode.NAVAL)
	_last_zone_color.fill(Color(0, 0, 0, 0))
	_last_color.fill(Color(0, 0, 0, 0))
	_colors_dirty = true
	_base.queue_redraw()


func set_show_war(value: bool) -> void:
	show_war = value
	_overlay.queue_redraw()


## 시뮬이 한 턴 이상 진행된 뒤 뷰 호스트가 부른다. 여기서만 캐시를 무효화한다.
func on_world_advanced() -> void:
	_colors_dirty = true
	_edges_dirty = true
	_war_dirty = true
	_redraw_all()


func focus_province(province_id: int, center: bool = false) -> void:
	if world == null or province_id < 0 or province_id >= world.provinces.size():
		return
	selected_province = province_id
	if center:
		center_on(world.provinces[province_id].centroid)
	_overlay.queue_redraw()


## 기록의 해역 링크가 부른다. 해역은 프로빈스가 아니라 선택 대상이 되지 않는다.
func focus_zone(zone_id: int) -> void:
	var center := _zone_center(zone_id)
	if center == Vector2.INF:
		return
	center_on(center)


func center_on(logical: Vector2, min_zoom: float = 2.2) -> void:
	if zoom < min_zoom:
		zoom = min_zoom
	pan = Vector2.ZERO
	var without_pan := _screen_from_logical(logical)
	pan = size * 0.5 - without_pan
	_redraw_all()


## 기록에서 사건을 눌렀을 때 "어디 국가인지"를 몇 초간 보여 준다.
func highlight_nations(ids: Array, seconds: float = 3.5) -> void:
	_highlight_nations.clear()
	for id in ids:
		if int(id) >= 0:
			_highlight_nations.append(int(id))
	_highlight_until = Time.get_ticks_msec() / 1000.0 + seconds if seconds > 0.0 else 0.0
	_rebuild_highlight()
	set_process(true)
	_overlay.queue_redraw()


func clear_highlight() -> void:
	_highlight_nations.clear()
	_highlight_lines = PackedVector2Array()
	_highlight_until = 0.0
	_overlay.queue_redraw()


func _process(delta: float) -> void:
	var pulsing := show_war and not _battle_markers.is_empty()
	if pulsing:
		_pulse = fmod(_pulse + delta * 2.4, TAU)
		_overlay.queue_redraw()
	if _highlight_until > 0.0 and Time.get_ticks_msec() / 1000.0 > _highlight_until:
		clear_highlight()
	if not pulsing and _highlight_nations.is_empty():
		set_process(false)


# --- 지오메트리 캐시 -------------------------------------------------------

func _build_geometry() -> void:
	_verts = PackedVector2Array()
	_indices = PackedInt32Array()
	_colors = PackedColorArray()
	_grid_lines = PackedVector2Array()
	_edge_points = PackedVector2Array()
	_edge_a = PackedInt32Array()
	_edge_b = PackedInt32Array()
	_province_edges = []
	_sea_verts = PackedVector2Array()
	_sea_indices = PackedInt32Array()
	_sea_colors = PackedColorArray()
	_zone_lines = PackedVector2Array()
	_zone_line_a = PackedInt32Array()
	_zone_line_b = PackedInt32Array()
	_tile_slot.resize(_map_total())
	_tile_slot.fill(-1)
	_sea_slot.resize(_map_total())
	_sea_slot.fill(-1)
	if world == null:
		return

	for p in world.provinces:
		_province_edges.append(PackedInt32Array())
		for tile: int in p.tiles:
			var slot := _verts.size()
			_tile_slot[tile] = slot
			var center := _tile_center(tile)
			for i in range(6):
				var angle := deg_to_rad(-90.0 + i * 60.0)
				_verts.append(center + Vector2(cos(angle), sin(angle)) * HEX_RADIUS)
				_colors.append(WATER)
			for i in range(1, 5):
				_indices.append(slot)
				_indices.append(slot + i)
				_indices.append(slot + i + 1)

	var edge_of_delta := _edge_direction_tables()
	for p in world.provinces:
		for tile: int in p.tiles:
			var slot := _tile_slot[tile]
			var col := tile % _map_width()
			var row := tile / _map_width()
			var deltas: Array = Hex.NEIGHBOR_DELTAS[row & 1]
			for d in range(6):
				var delta: Vector2i = deltas[d]
				var nc := col + delta.x
				var nr := row + delta.y
				var neighbor := -1
				if nc >= 0 and nc < _map_width() and nr >= 0 and nr < _map_height():
					neighbor = nr * _map_width() + nc
				var other := -1 if neighbor < 0 else _tile_to_province[neighbor]
				# 변은 한 번만 담는다. 이웃도 육지면 낮은 타일 쪽에서만 만든다.
				if other >= 0 and neighbor < tile:
					continue
				var edge: int = edge_of_delta[row & 1][d]
				var a: Vector2 = _verts[slot + edge]
				var b: Vector2 = _verts[slot + (edge + 1) % 6]
				_grid_lines.append(a)
				_grid_lines.append(b)
				if other == p.id:
					continue
				var index := _edge_a.size()
				_edge_points.append(a)
				_edge_points.append(b)
				_edge_a.append(p.id)
				_edge_b.append(other)
				_province_edges[p.id].append(index)
				if other >= 0:
					_province_edges[other].append(index)

	_build_sea_geometry(edge_of_delta)

	_controller_cache.resize(world.provinces.size())
	_controller_cache.fill(-2)
	_last_color.resize(world.provinces.size())
	_last_color.fill(Color(0, 0, 0, 0))
	_last_zone_color.resize(world.sea_zones.size())
	_last_zone_color.fill(Color(0, 0, 0, 0))


## 바다 타일도 삼각형으로 캐시해 둔다. 제해권 지도에서만 제출하므로
## 평소에는 메모리만 차지하고 드로우 비용은 0이다.
func _build_sea_geometry(edge_of_delta: Array) -> void:
	for tile in range(_map_total()):
		if world.land[tile] != 0 or _tile_to_zone[tile] < 0:
			continue
		var slot := _sea_verts.size()
		_sea_slot[tile] = slot
		var center := _tile_center(tile)
		for i in range(6):
			var angle := deg_to_rad(-90.0 + i * 60.0)
			_sea_verts.append(center + Vector2(cos(angle), sin(angle)) * HEX_RADIUS)
			_sea_colors.append(WATER)
		for i in range(1, 5):
			_sea_indices.append(slot)
			_sea_indices.append(slot + i)
			_sea_indices.append(slot + i + 1)

	for tile in range(_map_total()):
		var zone := _tile_to_zone[tile]
		if zone < 0:
			continue
		var slot := _sea_slot[tile]
		var col := tile % _map_width()
		var row := tile / _map_width()
		var deltas: Array = Hex.NEIGHBOR_DELTAS[row & 1]
		for d in range(6):
			var delta: Vector2i = deltas[d]
			var nc := col + delta.x
			var nr := row + delta.y
			var neighbor := -1
			var other := -1
			if nc >= 0 and nc < _map_width() and nr >= 0 and nr < _map_height():
				neighbor = nr * _map_width() + nc
				other = _tile_to_zone[neighbor]
			if other == zone:
				continue
			if other >= 0 and neighbor < tile:
				continue                          # 변은 한 번만 담는다
			# 육지와 맞닿은 변은 프로빈스 경계가 이미 그린다.
			if other < 0 and nc >= 0 and nc < _map_width() \
					and nr >= 0 and nr < _map_height():
				continue
			var edge: int = edge_of_delta[row & 1][d]
			_zone_lines.append(_sea_verts[slot + edge])
			_zone_lines.append(_sea_verts[slot + (edge + 1) % 6])
			_zone_line_a.append(zone)
			_zone_line_b.append(other)


## 헥스 변 인덱스와 이웃 방향의 대응표. 짝수/홀수 row 각각 6개.
func _edge_direction_tables() -> Array:
	var tables := []
	for parity in range(2):
		var row := 2 + parity
		var center := Hex.to_plane(2, row)
		var table := PackedInt32Array()
		for d in range(6):
			var delta: Vector2i = Hex.NEIGHBOR_DELTAS[parity][d]
			var to_neighbor := (Hex.to_plane(2 + delta.x, row + delta.y) - center).normalized()
			var best := 0
			var best_dot := -INF
			for e in range(6):
				var mid_angle := deg_to_rad(-90.0 + e * 60.0 + 30.0)
				var dot := Vector2(cos(mid_angle), sin(mid_angle)).dot(to_neighbor)
				if dot > best_dot:
					best_dot = dot
					best = e
			table.append(best)
		tables.append(table)
	return tables


## 3만 개 정점 색을 매 턴 다시 쓰면 그것만으로 수 ms 다. 정치 지도에서는 대부분의
## 프로빈스 색이 그대로이므로 바뀐 것만 칠한다.
func _rebuild_colors() -> void:
	_colors_dirty = false
	if world == null:
		return
	for p in world.provinces:
		var color := _province_color(p)
		if _last_color[p.id] == color:
			continue
		_last_color[p.id] = color
		for tile: int in p.tiles:
			var slot := _tile_slot[tile]
			for i in range(6):
				_colors[slot + i] = color


## 제해권 지도에서만 바다를 칠한다. 해역은 118개뿐이라 전부 훑어도 싸다.
func _rebuild_sea_colors() -> void:
	if world == null:
		return
	var owner := PackedInt32Array()
	owner.resize(world.sea_zones.size())
	owner.fill(-1)
	for n in world.nations:
		if not n.is_alive:
			continue
		for z in n.naval_control_zones:
			if int(z) < owner.size():
				owner[int(z)] = n.id
	_rebuild_zone_line_colors(owner)
	for z in world.sea_zones:
		var color := WATER
		if owner[z.id] >= 0:
			color = WATER.lerp(_nation_color(owner[z.id]), ZONE_FILL_MIX)
		if _last_zone_color[z.id] == color:
			continue
		_last_zone_color[z.id] = color
		for tile: int in z.tiles:
			var slot := _sea_slot[tile]
			if slot < 0:
				continue
			for i in range(6):
				_sea_colors[slot + i] = color


## 채우기만으로는 어두운 물 위에서 잘 안 읽힌다. 제해권을 쥔 해역의 테두리를
## 그 나라 색으로 굵게 둘러 "누가 어느 바다를 쥐었나"를 한눈에 만든다.
func _rebuild_zone_line_colors(owner: PackedInt32Array) -> void:
	_zone_line_colors = PackedColorArray()
	_zone_line_colors.resize(_zone_line_a.size())
	for i in range(_zone_line_a.size()):
		var a := _zone_line_a[i]
		var b := _zone_line_b[i]
		var owner_a := -1 if a < 0 or a >= owner.size() else owner[a]
		var owner_b := -1 if b < 0 or b >= owner.size() else owner[b]
		if owner_a == owner_b:
			_zone_line_colors[i] = ZONE_BORDER
			continue
		var holder := owner_a if owner_a >= 0 else owner_b
		_zone_line_colors[i] = _nation_color(holder)


## 국경·전선·점령 외곽은 지배국이 바뀐 턴에만 다시 만든다.
func _rebuild_edges() -> void:
	_edges_dirty = false
	if world == null:
		return
	_nation_lines = PackedVector2Array()
	_vassal_lines = PackedVector2Array()
	_vassal_colors = PackedColorArray()
	_front_lines = PackedVector2Array()
	_occupied_edges = PackedVector2Array()
	_occupied_colors = PackedColorArray()
	for i in range(world.provinces.size()):
		_controller_cache[i] = world.provinces[i].controller()

	for e in range(_edge_a.size()):
		var pa := _edge_a[e]
		var pb := _edge_b[e]
		var ca := -1 if pa < 0 else _controller_cache[pa]
		var cb := -1 if pb < 0 else _controller_cache[pb]
		if ca == cb:
			continue
		var a: Vector2 = _edge_points[e * 2]
		var b: Vector2 = _edge_points[e * 2 + 1]
		_nation_lines.append(a)
		_nation_lines.append(b)
		var realm_holder := -1
		if ca >= 0 and world.nations[ca].overlord >= 0:
			realm_holder = world.nations[ca].overlord
		if cb >= 0 and world.nations[cb].overlord >= 0:
			var other_holder: int = world.nations[cb].overlord
			if realm_holder < 0 or other_holder < realm_holder:
				realm_holder = other_holder
		if realm_holder >= 0:
			_vassal_lines.append(a)
			_vassal_lines.append(b)
			# 채움색이 이제 종주국과 같은 계열이므로 0.15 로는 안 보인다.
			_vassal_colors.append(_nation_color(realm_holder).lightened(0.45))
		if ca >= 0 and cb >= 0 and Diplomacy.are_at_war(world, ca, cb):
			_front_lines.append(a)
			_front_lines.append(b)

	for p in world.provinces:
		if p.occupied_by_nation < 0:
			continue
		var color := _nation_color(p.occupied_by_nation)
		for e: int in _province_edges[p.id]:
			_occupied_edges.append(_edge_points[e * 2])
			_occupied_edges.append(_edge_points[e * 2 + 1])
			_occupied_colors.append(color)
	_rebuild_highlight()


func _rebuild_highlight() -> void:
	_highlight_lines = PackedVector2Array()
	if world == null or _highlight_nations.is_empty():
		return
	var wanted := {}
	for id in _highlight_nations:
		wanted[id] = true
	for e in range(_edge_a.size()):
		var pa := _edge_a[e]
		var pb := _edge_b[e]
		var ia := pa >= 0 and wanted.has(world.provinces[pa].controller())
		var ib := pb >= 0 and wanted.has(world.provinces[pb].controller())
		if ia == ib:
			continue
		_highlight_lines.append(_edge_points[e * 2])
		_highlight_lines.append(_edge_points[e * 2 + 1])


## 지도에서 "지금 어디서 싸우는지"가 보이게 하는 캐시. 턴마다 1회.
func _rebuild_war() -> void:
	_war_dirty = false
	_army_markers = []
	_battle_markers = []
	_siege_markers = []
	_fleet_markers = []
	_transport_markers = []
	if world == null:
		return

	var by_province := {}
	var power_by_province := {}
	for army in world.armies:
		if not army.is_alive or army.province_id < 0:
			continue
		if not by_province.has(army.province_id):
			by_province[army.province_id] = {}
		var slot: Dictionary = by_province[army.province_id]
		slot[army.nation_id] = float(slot.get(army.nation_id, 0.0)) + army.troops
		# 마커에 병력만 실으면 사기·보급·기술이 빠져 "누가 이기고 있는지"가 안 보인다.
		if not power_by_province.has(army.province_id):
			power_by_province[army.province_id] = {}
		var pslot: Dictionary = power_by_province[army.province_id]
		pslot[army.nation_id] = float(pslot.get(army.nation_id, 0.0)) \
			+ Military.combat_power(world, army)

	var pids: Array = by_province.keys()
	pids.sort()
	for pid in pids:
		var stacks: Dictionary = by_province[pid]
		var nation_ids: Array = stacks.keys()
		nation_ids.sort()
		var center: Vector2 = world.provinces[pid].centroid
		var contested := false
		for i in range(nation_ids.size()):
			for j in range(i + 1, nation_ids.size()):
				if Diplomacy.are_at_war(world, int(nation_ids[i]), int(nation_ids[j])):
					contested = true
		for i in range(nation_ids.size()):
			var nation_id := int(nation_ids[i])
			var troops := float(stacks[nation_id])
			var offset := Vector2.ZERO
			if nation_ids.size() > 1:
				var angle := TAU * i / float(nation_ids.size())
				offset = Vector2(cos(angle), sin(angle)) * 0.34
			_army_markers.append({
				"pos": center + offset,
				"color": _nation_color(nation_id),
				"radius": _troop_radius(troops),
			})
		if contested:
			var powers: Dictionary = power_by_province.get(pid, {})
			var sides := []
			for nation_id: int in nation_ids:
				sides.append({
					"color": _nation_color(nation_id),
					"power": maxf(float(powers.get(nation_id, 0.0)), 0.0),
				})
			_battle_markers.append({"pos": center, "province": pid, "sides": sides})

	for p in world.provinces:
		if p.siege_by_nation < 0 or p.siege_progress <= 0.0:
			continue
		_siege_markers.append({
			"pos": p.centroid,
			"progress": clampf(p.siege_progress / 100.0, 0.0, 1.0),
			"color": _nation_color(p.siege_by_nation),
		})

	var by_zone := {}
	for fleet in world.fleets:
		if not fleet.is_alive or fleet.ships <= 0:
			continue
		if not by_zone.has(fleet.zone_id):
			by_zone[fleet.zone_id] = {}
		var slot: Dictionary = by_zone[fleet.zone_id]
		slot[fleet.nation_id] = float(slot.get(fleet.nation_id, 0.0)) + fleet.ships
	var zones: Array = by_zone.keys()
	zones.sort()
	for zone in zones:
		var center := _zone_center(int(zone))
		if center == Vector2.INF:
			continue
		var stacks: Dictionary = by_zone[zone]
		var nation_ids: Array = stacks.keys()
		nation_ids.sort()
		var contested := false
		for i in range(nation_ids.size()):
			for j in range(i + 1, nation_ids.size()):
				if Diplomacy.are_at_war(world, int(nation_ids[i]), int(nation_ids[j])):
					contested = true
		for i in range(nation_ids.size()):
			var nation_id := int(nation_ids[i])
			var angle := TAU * i / float(maxi(nation_ids.size(), 1))
			_fleet_markers.append({
				"pos": center + Vector2(cos(angle), sin(angle)) * (0.0 if nation_ids.size() == 1 else 0.5),
				"color": _nation_color(nation_id),
				"radius": 0.22 + 0.18 * clampf(float(stacks[nation_id]) / 40.0, 0.0, 1.0),
				"battle": contested,
			})
	for army in world.armies:
		if not army.is_alive or army.at_sea_zone < 0:
			continue
		var center := _zone_center(army.at_sea_zone)
		if center == Vector2.INF:
			continue
		var target := Vector2.INF
		if army.landing_target >= 0 and army.landing_target < world.provinces.size():
			target = world.provinces[army.landing_target].centroid
		_transport_markers.append({
			"pos": center,
			"color": _nation_color(army.nation_id),
			"radius": _troop_radius(army.troops),
			"target": target,
		})

	if not _battle_markers.is_empty():
		set_process(true)


## 해역 중심. 함대·해전·수송선단 마커가 전부 여기 붙는다.
func _zone_center(zone_id: int) -> Vector2:
	if world == null or zone_id < 0 or zone_id >= world.sea_zones.size():
		return Vector2.INF
	return world.sea_zones[zone_id].centroid


func _troop_radius(troops: float) -> float:
	return 0.22 + 0.26 * clampf(log(maxf(troops, 1.0)) / log(80000.0), 0.0, 1.0)


# --- 그리기 ---------------------------------------------------------------

func _draw_base(layer: Control) -> void:
	layer.draw_rect(Rect2(Vector2.ZERO, layer.size), WATER)
	_draw_water_grid(layer)
	if world == null or _verts.is_empty():
		return
	if _colors_dirty:
		_rebuild_colors()
		if mode == MapMode.NAVAL:
			_rebuild_sea_colors()
	if _edges_dirty:
		_rebuild_edges()
	var transform := _map_transform()
	var scale := transform.get_scale().x
	layer.draw_set_transform(transform.origin, 0.0, Vector2.ONE * scale)
	if mode == MapMode.NAVAL and not _sea_verts.is_empty():
		RenderingServer.canvas_item_add_triangle_array(
			layer.get_canvas_item(), _sea_indices, _sea_verts, _sea_colors)
		if _zone_line_colors.size() * 2 == _zone_lines.size():
			layer.draw_multiline_colors(_zone_lines, _zone_line_colors,
				_line_width(NATION_WIDTH, NATION_MIN_PX, scale))
	RenderingServer.canvas_item_add_triangle_array(
		layer.get_canvas_item(), _indices, _verts, _colors)
	if scale >= GRID_MIN_UNIT:
		_multiline(layer, _grid_lines, GRID, GRID_WIDTH)
	_multiline(layer, _edge_points, BORDER, _line_width(PROVINCE_WIDTH, PROVINCE_MIN_PX, scale))
	_multiline(layer, _nation_lines, NATION_BORDER,
		_line_width(NATION_WIDTH, NATION_MIN_PX, scale))
	if not _vassal_lines.is_empty() and _vassal_colors.size() * 2 == _vassal_lines.size():
		layer.draw_multiline_colors(_vassal_lines, _vassal_colors,
			_line_width(NATION_WIDTH * 0.72, NATION_MIN_PX * 0.85, scale))
	if show_war:
		_multiline(layer, _front_lines, FRONT, _line_width(FRONT_WIDTH, FRONT_MIN_PX, scale))
	layer.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 논리 굵기와 화면 픽셀 최소치 중 큰 쪽.
func _line_width(logical: float, min_px: float, scale: float) -> float:
	return maxf(logical, min_px / maxf(scale, 0.001))


func _draw_overlay(layer: Control) -> void:
	if world == null:
		return
	if _war_dirty:
		_rebuild_war()
	var transform := _map_transform()
	var scale := transform.get_scale().x
	layer.draw_set_transform(transform.origin, 0.0, Vector2.ONE * scale)

	if show_war and not _occupied_edges.is_empty():
		layer.draw_multiline_colors(_occupied_edges, _occupied_colors,
			_line_width(NATION_WIDTH, NATION_MIN_PX, scale))

	# 도시와 수도는 지도 모드와 무관하게 관전 가능한 핵심 정보다.
	for p in world.provinces:
		if p.has_city:
			layer.draw_circle(p.centroid, 0.24, Color("f6bd60"))
	for n in world.nations:
		if n.is_alive and n.capital >= 0 and n.capital < world.provinces.size():
			var c: Vector2 = world.provinces[n.capital].centroid
			layer.draw_circle(c, 0.34, Color(0.04, 0.06, 0.09, 0.9))
			layer.draw_circle(c, 0.20, _nation_color(n.id))

	if show_war:
		_draw_war(layer, scale)

	_multiline(layer, _highlight_lines, HIGHLIGHT,
		_line_width(NATION_WIDTH * 1.8, NATION_MIN_PX * 1.8, scale))
	_draw_province_outline(layer, selected_province, SELECTED,
		_line_width(0.14, NATION_MIN_PX, scale))
	if hovered_province != selected_province:
		_draw_province_outline(layer, hovered_province, HOVERED,
			_line_width(0.09, PROVINCE_MIN_PX, scale))
	layer.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_war(layer: Control, scale: float) -> void:
	var thin := _line_width(0.10, FRONT_MIN_PX, scale)
	# 군대 마커는 수십 개가 동시에 뜬다. 테두리까지 굵으면 지도가 점으로 덮인다.
	var rim := _line_width(0.05, 1.0, scale)
	for marker in _army_markers:
		var pos: Vector2 = marker["pos"]
		var radius := maxf(float(marker["radius"]), MARKER_MIN_PX / maxf(scale, 0.001))
		layer.draw_circle(pos, radius + rim, Color(0.03, 0.05, 0.08, 0.85))
		layer.draw_circle(pos, radius, marker["color"])

	for marker in _siege_markers:
		var pos: Vector2 = marker["pos"]
		var progress: float = marker["progress"]
		var radius := maxf(0.52, MARKER_MIN_PX * 1.8 / maxf(scale, 0.001))
		layer.draw_arc(pos, radius, -PI * 0.5, -PI * 0.5 + TAU, 24,
			Color(0.03, 0.05, 0.08, 0.65), thin)
		layer.draw_arc(pos, radius, -PI * 0.5, -PI * 0.5 + TAU * progress,
			maxi(int(24 * progress), 2), marker["color"], thin * 1.3)

	var pulse := 1.0 + sin(_pulse) * 0.14
	for marker in _battle_markers:
		var pos: Vector2 = marker["pos"]
		# 막대는 펄스를 타지 않는다 — 폭이 흔들리면 전력비를 눈으로 못 잰다.
		var base := maxf(0.68, MARKER_MIN_PX * 2.2 / maxf(scale, 0.001))
		var radius := base * pulse
		layer.draw_arc(pos, radius, 0.0, TAU, 26, BATTLE, thin * 1.3)
		var arm := radius * 0.45
		layer.draw_line(pos + Vector2(-arm, -arm), pos + Vector2(arm, arm), BATTLE, thin)
		layer.draw_line(pos + Vector2(-arm, arm), pos + Vector2(arm, -arm), BATTLE, thin)
		_draw_power_bar(layer, pos + Vector2(0.0, -base * 1.6), base, marker["sides"], thin)

	for marker in _fleet_markers:
		var pos: Vector2 = marker["pos"]
		var radius := maxf(float(marker["radius"]), MARKER_MIN_PX / maxf(scale, 0.001))
		var points := PackedVector2Array([
			pos + Vector2(0.0, -radius * 1.3),
			pos + Vector2(radius, radius * 0.8),
			pos + Vector2(-radius, radius * 0.8),
		])
		layer.draw_colored_polygon(points, marker["color"])
		if marker["battle"]:
			layer.draw_arc(pos, radius * 2.0 * pulse, 0.0, TAU, 20, BATTLE, thin)

	# 승선한 부대. 목적지까지 선을 그어 "누가 어디로 상륙하려는지"를 보여 준다.
	for marker in _transport_markers:
		var pos: Vector2 = marker["pos"]
		var radius := maxf(float(marker["radius"]), MARKER_MIN_PX / maxf(scale, 0.001))
		var target: Vector2 = marker["target"]
		if target != Vector2.INF:
			layer.draw_line(pos, target, Color(marker["color"], 0.55), thin)
		layer.draw_colored_polygon(PackedVector2Array([
			pos + Vector2(-radius * 1.4, 0.0),
			pos + Vector2(radius * 1.4, 0.0),
			pos + Vector2(radius * 0.7, radius),
			pos + Vector2(-radius * 0.7, radius),
		]), marker["color"])
		layer.draw_line(pos + Vector2(0.0, -radius * 1.6), pos, marker["color"], thin)


## 전투력 비율 막대. 폭은 고정이고 칸 너비가 전력 지분이라, 색만 보면
## 어느 쪽이 우세한지 읽힌다 (병력이 아니라 사기·보급·기술을 먹은 전투력이다).
func _draw_power_bar(layer: Control, pos: Vector2, radius: float, sides: Array,
		thin: float) -> void:
	var total := 0.0
	for side in sides:
		total += float(side["power"])
	if total <= 0.0:
		return
	var width := radius * 2.6
	var height := maxf(radius * 0.36, thin * 2.0)
	var left := pos.x - width * 0.5
	var top := pos.y - height * 0.5
	layer.draw_rect(Rect2(left - thin, top - thin,
		width + thin * 2.0, height + thin * 2.0), Color(0.03, 0.05, 0.08, 0.85))
	var x := left
	for side in sides:
		var w := width * float(side["power"]) / total
		layer.draw_rect(Rect2(x, top, w, height), side["color"])
		x += w


func _draw_water_grid(layer: Control) -> void:
	var spacing := 36.0
	var offset := Vector2(fposmod(pan.x * 0.18, spacing), fposmod(pan.y * 0.18, spacing))
	var x := offset.x - spacing
	while x < layer.size.x:
		layer.draw_line(Vector2(x, 0), Vector2(x, layer.size.y), WATER_GRID, 1.0)
		x += spacing
	var y := offset.y - spacing
	while y < layer.size.y:
		layer.draw_line(Vector2(0, y), Vector2(layer.size.x, y), WATER_GRID, 1.0)
		y += spacing


## 프로빈스 외곽만 그린다. 타일마다 육각형을 그리던 예전 방식보다 훨씬 싸고 깔끔하다.
func _draw_province_outline(layer: Control, province_id: int, color: Color,
		width: float) -> void:
	if world == null or province_id < 0 or province_id >= _province_edges.size():
		return
	var lines := PackedVector2Array()
	for e: int in _province_edges[province_id]:
		lines.append(_edge_points[e * 2])
		lines.append(_edge_points[e * 2 + 1])
	_multiline(layer, lines, color, width)


## 빈 배열을 넘기면 엔진이 에러를 뱉는다.
func _multiline(layer: Control, points: PackedVector2Array, color: Color,
		width: float) -> void:
	if points.is_empty():
		return
	layer.draw_multiline(points, color, width)


func _province_color(p: Province) -> Color:
	match mode:
		MapMode.GDP:
			var value := clampf(log(1.0 + maxf(p.gdp_pc, 0.0)) / log(4081.0), 0.0, 1.0)
			return Color("372f5f").lerp(Color("5ee6a8"), value)
		MapMode.INFRA:
			return Color("33253f").lerp(Color("f3b562"), clampf(p.infra / 10.0, 0.0, 1.0))
		MapMode.UNREST:
			var u := clampf(p.unrest, 0.0, 1.0)
			return Color("45b97c").lerp(Color("ef476f"), u)
		MapMode.SUPPLY:
			return Color("d1495b").lerp(Color("4cc9f0"), clampf(p.supply, 0.0, 1.0))
	var holder := p.controller()
	var color := _nation_color(holder)
	if mode == MapMode.NAVAL:
		return color.darkened(NAVAL_LAND_DIM)
	if p.occupied_by_nation >= 0:
		color = color.lightened(0.18)
	if p.is_exclave:
		color = color.darkened(0.10)
	return color


## 속국은 종주국과 같은 색상(hue)을 쓰고 명도만 낮춘다. 중첩 속국은 없으므로
## (EmpireSystem.vassalize) 한 홉이면 realm 최상위에 닿는다.
func _nation_color(nation_id: int) -> Color:
	if world == null or nation_id < 0 or nation_id >= world.nations.size():
		return Color("596777")
	var n: Nation = world.nations[nation_id]
	var root := n
	var is_vassal := false
	if n.overlord >= 0 and n.overlord < world.nations.size() \
			and world.nations[n.overlord].is_alive:
		root = world.nations[n.overlord]
		is_vassal = true
	# 문화 12종(M13.7-a) 색상. 기존 5종의 hue 는 그대로 두고 신설 7종만 빈 구간에 넣는다.
	var culture_hues := [
		0.09, 0.50, 0.04, 0.63, 0.34,          # 샴 랙돌 치즈태비 러시안블루 코리안숏헤어
		0.56, 0.71, 0.14, 0.87, 0.21, 0.44, 0.78,
	]
	var hue: float = fmod(float(culture_hues[root.culture % culture_hues.size()])
		+ root.id * 0.047, 1.0)
	var saturation := 0.58 if not n.is_rebel else 0.82
	return Color.from_hsv(hue, saturation, VASSAL_VALUE if is_vassal else 0.78)


# --- 입력 -----------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_WHEEL_UP and button.pressed:
			_zoom_at(button.position, 1.18)
			accept_event()
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN and button.pressed:
			_zoom_at(button.position, 1.0 / 1.18)
			accept_event()
		elif button.button_index == MOUSE_BUTTON_MIDDLE \
				or button.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = button.pressed
			accept_event()
		elif button.button_index == MOUSE_BUTTON_LEFT and button.pressed:
			var battle := _battle_at(button.position)
			var pid := _province_at(button.position)
			if pid >= 0:
				selected_province = pid
				province_selected.emit(pid)
				_overlay.queue_redraw()
			if battle >= 0:
				battle_selected.emit(battle)
			accept_event()
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _dragging:
			pan += motion.relative
			_redraw_all()
		else:
			var pid := _province_at(motion.position)
			if pid != hovered_province:
				hovered_province = pid
				tooltip_text = _tooltip(pid) if pid >= 0 \
					else _zone_tooltip(_zone_at(motion.position))
				_overlay.queue_redraw()


func _redraw_all() -> void:
	_base.queue_redraw()
	_overlay.queue_redraw()


func _zoom_at(screen_point: Vector2, factor: float) -> void:
	var before := _logical_from_screen(screen_point)
	zoom = clampf(zoom * factor, 0.75, 5.0)
	var after_screen := _screen_from_logical(before)
	pan += screen_point - after_screen
	_redraw_all()


## 교전 마커는 프로빈스 중심에 겹쳐 있다. 마커 반지름은 _draw_war 와 같은 식이라야
## 보이는 것과 집히는 것이 어긋나지 않는다 (펄스 배율만 뺀다).
func _battle_at(screen_point: Vector2) -> int:
	if world == null or not show_war:
		return -1
	if _war_dirty:
		_rebuild_war()
	var transform := _map_transform()
	var scale := transform.get_scale().x
	var radius := maxf(0.68, MARKER_MIN_PX * 2.2 / maxf(scale, 0.001)) * scale
	for marker in _battle_markers:
		var pos: Vector2 = transform.origin + Vector2(marker["pos"]) * scale
		if screen_point.distance_to(pos) <= radius:
			return int(marker["province"])
	return -1


func _province_at(screen_point: Vector2) -> int:
	if world == null:
		return -1
	var tile := _tile_at(_logical_from_screen(screen_point))
	return -1 if tile < 0 else _tile_to_province[tile]


func _tile_at(logical: Vector2) -> int:
	var row := int(round(logical.y / Hex.SQRT3_2))
	var best_tile := -1
	var best_distance := INF
	for rr in range(row - 1, row + 2):
		if rr < 0 or rr >= _map_height():
			continue
		var col_guess := int(round(logical.x - (0.5 if rr % 2 == 1 else 0.0)))
		for cc in range(col_guess - 1, col_guess + 2):
			if cc < 0 or cc >= _map_width():
				continue
			var tile := rr * _map_width() + cc
			var distance := logical.distance_squared_to(_tile_center(tile))
			if distance < best_distance:
				best_distance = distance
				best_tile = tile
	if best_tile < 0 or best_distance > HEX_RADIUS * HEX_RADIUS:
		return -1
	return best_tile


func _zone_at(screen_point: Vector2) -> int:
	if world == null:
		return -1
	var tile := _tile_at(_logical_from_screen(screen_point))
	return -1 if tile < 0 else _tile_to_zone[tile]


## 바다 위에서는 "이 바다를 누가 쥐고 있나"가 유일하게 궁금한 값이다.
func _zone_tooltip(zone_id: int) -> String:
	if world == null or zone_id < 0 or zone_id >= world.sea_zones.size():
		return ""
	var holder := -1
	for n in world.nations:
		if n.is_alive and n.naval_control_zones.has(zone_id):
			holder = n.id
			break
	var text := "해역 %03d · 제해권 %s" % [zone_id,
		_nation_label(holder) if holder >= 0 else "무주공산"]
	var ships := {}
	for f in world.fleets:
		if f.is_alive and f.zone_id == zone_id and f.ships > 0:
			ships[f.nation_id] = int(ships.get(f.nation_id, 0)) + f.ships
	var keys: Array = ships.keys()
	keys.sort()
	for nation_id in keys:
		text += "\n  %s %d척" % [_nation_label(int(nation_id)), int(ships[nation_id])]
	for army in world.armies:
		if army.is_alive and army.at_sea_zone == zone_id:
			text += "\n  승선 %s %s → 프로빈스 %03d" % [_nation_label(army.nation_id),
				_troops_text(army.troops), army.landing_target]
	return text


func _tooltip(province_id: int) -> String:
	if world == null or province_id < 0 or province_id >= world.provinces.size():
		return ""
	var p: Province = world.provinces[province_id]
	var owner := "무주지"
	if p.owner_nation >= 0 and p.owner_nation < world.nations.size():
		owner = _nation_label(p.owner_nation)
	var text := "프로빈스 %03d · %s\nGDP %.1fM · 인프라 %.1f · 불만 %.0f%% · 보급 %.0f%%" % [
		p.id, owner, p.gdp / 1000000.0, p.infra, p.unrest * 100.0, p.supply * 100.0]
	if p.occupied_by_nation >= 0:
		text += "\n점령: %s" % _nation_label(p.occupied_by_nation)
	if p.siege_by_nation >= 0 and p.siege_progress > 0.0:
		text += "\n공성: %s %.0f%%" % [_nation_label(p.siege_by_nation), p.siege_progress]
	var stacks := {}
	for army_id: int in world.armies_at(province_id):
		var army: Army = world.armies[army_id]
		if not army.is_alive:
			continue
		var entry: Array = stacks.get(army.nation_id, [0.0, 0.0, 0])
		entry[0] += army.troops
		entry[1] += army.morale * army.troops
		entry[2] = int(entry[2]) + 1
		stacks[army.nation_id] = entry
	if not stacks.is_empty():
		var keys: Array = stacks.keys()
		keys.sort()
		text += "\n주둔 병력"
		for nation_id in keys:
			var entry: Array = stacks[nation_id]
			var troops: float = entry[0]
			text += "\n  %s %s · 사기 %.0f%%" % [_nation_label(int(nation_id)),
				_troops_text(troops), entry[1] / maxf(troops, 1.0) * 100.0]
	return text


func _nation_label(nation_id: int) -> String:
	if world == null or nation_id < 0 or nation_id >= world.nations.size():
		return "—"
	var n: Nation = world.nations[nation_id]
	if n.name.is_empty():
		return "%s #%02d" % [Culture.NAMES[n.culture], n.id]
	return "%s (%s)" % [n.name, Culture.NAMES[n.culture]]


func _troops_text(troops: float) -> String:
	if troops >= 1000.0:
		return "%.1fK" % (troops / 1000.0)
	return "%.0f" % troops


# --- 좌표 -----------------------------------------------------------------

func _map_transform() -> Transform2D:
	var unit := _base_unit() * zoom
	var map_size := Vector2((_map_width() + 0.5) * unit,
		(_map_height() - 1) * Hex.SQRT3_2 * unit + unit * 1.2)
	var origin := (size - map_size) * 0.5 + Vector2(unit * 0.5, unit * 0.6) + pan
	return Transform2D(0.0, Vector2(unit, unit), 0.0, origin)


func _base_unit() -> float:
	var by_width := maxf(size.x - 28.0, 1.0) / (_map_width() + 0.5)
	var by_height := maxf(size.y - 28.0, 1.0) \
		/ ((_map_height() - 1) * Hex.SQRT3_2 + 1.2)
	return minf(by_width, by_height)


func _logical_from_screen(point: Vector2) -> Vector2:
	var transform := _map_transform()
	return (point - transform.origin) / transform.get_scale().x


func _screen_from_logical(point: Vector2) -> Vector2:
	var transform := _map_transform()
	return transform.origin + point * transform.get_scale().x


func _tile_center(tile: int) -> Vector2:
	return Hex.to_plane(tile % _map_width(), tile / _map_width())


func _map_width() -> int:
	return world.map_width if world != null else EarthMapSource.W


func _map_height() -> int:
	return world.map_height if world != null else EarthMapSource.H


func _map_total() -> int:
	return world.land.size() if world != null else EarthMapSource.TOTAL
