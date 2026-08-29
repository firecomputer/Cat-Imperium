class_name LineChart extends Control

## HUD용 작은 다중 선 차트. 데이터는 뷰가 보관하며 시뮬을 변경하지 않는다.

const BG := Color("101724")
const GRID := Color(0.25, 0.34, 0.45, 0.22)
const TEXT := Color("9cacbd")

var chart_title := ""
var series: Array = []
var max_points := 140


func _ready() -> void:
	custom_minimum_size = Vector2(260, 175)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func set_data(title: String, value: Array) -> void:
	chart_title = title
	series = value
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	var plot := Rect2(48, 30, maxf(size.x - 62.0, 1.0), maxf(size.y - 55.0, 1.0))
	for i in range(5):
		var y := plot.position.y + plot.size.y * i / 4.0
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), GRID, 1.0)
	draw_string(_font(), Vector2(12, 20), chart_title,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("e4edf5"))

	var bounds := _bounds()
	if bounds.is_empty():
		draw_string(_font(), plot.get_center(), "기록 대기 중",
			HORIZONTAL_ALIGNMENT_CENTER, 120, 13, TEXT)
		return
	var low: float = bounds[0]
	var high: float = bounds[1]
	draw_string(_font(), Vector2(6, plot.position.y + 5), _short(high),
		HORIZONTAL_ALIGNMENT_LEFT, 40, 11, TEXT)
	draw_string(_font(), Vector2(6, plot.end.y), _short(low),
		HORIZONTAL_ALIGNMENT_LEFT, 40, 11, TEXT)

	for item in series:
		var values: Array = item.get("values", [])
		if values.is_empty():
			continue
		var start := maxi(0, values.size() - max_points)
		var count := values.size() - start
		var points := PackedVector2Array()
		for i in range(count):
			var x := plot.position.x if count == 1 else \
				plot.position.x + plot.size.x * i / float(count - 1)
			var normalized := (float(values[start + i]) - low) / maxf(high - low, 0.0001)
			points.append(Vector2(x, plot.end.y - normalized * plot.size.y))
		if points.size() >= 2:
			draw_polyline(points, item.get("color", Color.WHITE), 2.0, true)
		else:
			draw_circle(points[0], 2.5, item.get("color", Color.WHITE))

	var legend_x := plot.position.x
	for item in series:
		var color: Color = item.get("color", Color.WHITE)
		draw_line(Vector2(legend_x, size.y - 10), Vector2(legend_x + 13, size.y - 10), color, 2.0)
		draw_string(_font(), Vector2(legend_x + 18, size.y - 6),
			str(item.get("name", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, TEXT)
		legend_x += 92.0


## 테마 폰트를 쓴다. 기본 폰트에는 한글이 없어 대체 탐색이 매 프레임 돈다.
func _font() -> Font:
	return get_theme_default_font()


func _bounds() -> Array[float]:
	var low := INF
	var high := -INF
	for item in series:
		var values: Array = item.get("values", [])
		var start := maxi(0, values.size() - max_points)
		for i in range(start, values.size()):
			low = minf(low, float(values[i]))
			high = maxf(high, float(values[i]))
	if low == INF:
		return []
	if is_equal_approx(low, high):
		var padding := maxf(absf(low) * 0.05, 1.0)
		low -= padding
		high += padding
	else:
		var padding := (high - low) * 0.08
		low -= padding
		high += padding
	return [low, high]


func _short(value: float) -> String:
	var absolute := absf(value)
	if absolute >= 1000000000.0:
		return "%.1fB" % (value / 1000000000.0)
	if absolute >= 1000000.0:
		return "%.1fM" % (value / 1000000.0)
	if absolute >= 1000.0:
		return "%.1fK" % (value / 1000.0)
	return "%.1f" % value
