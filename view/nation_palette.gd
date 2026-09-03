extends RefCounted

## 국가 색 배정. 예전에는 문화가 hue 를 정하고 국가 id 가 0.047 씩 밀었다 —
## 문화 12종이 hue 축을 이미 다 쓰는데다 오프셋은 21국마다 한 바퀴를 돌아,
## 서로 다른 나라가 화면에서 같은 색이 됐다. 이제 색은 문화가 아니라
## "이미 쓰인 색에서 가장 먼 곳"이 정한다. 문화는 문화 레이어가 답한다.
##
## 거리는 OKLab 에서 잰다. HSV·RGB 유클리드는 인지 거리와 어긋나서, 눈에는
## 똑같아 보이는 어두운 파랑 두 개를 "멀다"고 판정한다.
##
## 한 번 정해진 색은 그 나라가 죽을 때까지 바뀌지 않는다. 관전자가 색으로
## 나라를 추적하는데 이웃이 죽었다고 색이 갈아엎히면 추적이 끊긴다.
## 죽은 나라의 색은 다음 배정부터 다시 후보가 된다 — 안 그러면 반란이 이어지는
## 후반에 색 공간이 고갈된다.

## 후보 격자. hue 를 촘촘히 깔고 채도·명도로 축을 하나씩 더 쓴다 (72×5×5=1800).
## 격자를 432 에서 1800 으로 늘리면 40국 최소 거리가 0.086 에서 0.104 로 오른다.
const HUE_STEPS := 72
const SATURATIONS := [0.34, 0.50, 0.66, 0.82, 0.98]
const VALUES := [0.42, 0.56, 0.70, 0.84, 0.98]
## 지도 배경·선택 테두리·교전 마커와 헷갈리는 색은 국가에 주지 않는다.
const RESERVED := ["101d2e", "1b3048", "ffd166", "ff4d5e"]
const FALLBACK := Color("596777")

var _colors: Dictionary = {}                  # nation_id -> Color. 한 번 정하면 불변
var _candidates: PackedColorArray = PackedColorArray()
var _lab: PackedVector3Array = PackedVector3Array()
## 후보 → 예약색·살아 있는 배정색까지의 최소 OKLab 거리. 배정은 이 값의 최댓값을 고른다.
var _distance: PackedFloat32Array = PackedFloat32Array()
## _distance 에 반영돼 있는 살아 있는 국가 집합. 달라지면 처음부터 다시 잰다.
var _counted: Dictionary = {}


func _init() -> void:
	for h in range(HUE_STEPS):
		for s: float in SATURATIONS:
			for v: float in VALUES:
				_candidates.append(Color.from_hsv(float(h) / HUE_STEPS, s, v))
	for c in _candidates:
		_lab.append(to_oklab(c))
	_distance.resize(_candidates.size())
	_reset_distance()


func color_of(nation_id: int) -> Color:
	return _colors.get(nation_id, FALLBACK)


## 아직 색이 없는 국가에 색을 준다. 국가가 새로 생기거나 죽은 턴에만 일이 있다.
func sync(world: WorldState) -> void:
	if world == null:
		return
	var pending: Array[int] = []
	for n in world.nations:
		if n.is_alive and not _colors.has(n.id):
			pending.append(n.id)
	if pending.is_empty():
		return                                # 대부분의 턴은 여기서 끝난다
	# 죽은 나라의 색을 후보로 돌리는 재계산은 O(후보 × 국가) 다. 배정할 일이
	# 실제로 있는 턴에만 돌린다 — 매 턴 돌리면 사망 턴마다 수십 ms 가 샌다.
	var live := {}
	for n in world.nations:
		if n.is_alive and _colors.has(n.id):
			live[n.id] = true
	if live.size() != _counted.size():
		_recount(live)
	for nation_id in pending:
		var pick := _farthest()
		_colors[nation_id] = _candidates[pick]
		_counted[nation_id] = true
		_absorb(_lab[pick])


## 살아 있는 배정색 집합이 바뀌었다 (누가 죽었다). 거리를 처음부터 다시 잰다.
func _recount(live: Dictionary) -> void:
	_counted = live
	_reset_distance()
	for nation_id in _counted:
		_absorb(to_oklab(_colors[nation_id]))


func _reset_distance() -> void:
	_distance.fill(INF)
	for hex: String in RESERVED:
		_absorb(to_oklab(Color(hex)))


## 새 색 하나를 거리 표에 반영한다. 후보 하나당 곱셈 세 번이라 배정이 O(후보)다.
func _absorb(lab: Vector3) -> void:
	for i in range(_lab.size()):
		var d := _lab[i].distance_to(lab)
		if d < _distance[i]:
			_distance[i] = d


## 이미 쓰인 어떤 색과도 가장 먼 후보. 동률은 인덱스가 낮은 쪽 (§15 결정론).
func _farthest() -> int:
	var best := 0
	var best_distance := -1.0
	for i in range(_distance.size()):
		if _distance[i] > best_distance:
			best_distance = _distance[i]
			best = i
	return best


## sRGB → OKLab (Björn Ottosson). 색 거리를 재는 유일한 곳이다.
static func to_oklab(color: Color) -> Vector3:
	var c := color.srgb_to_linear()
	var l := 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b
	var m := 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b
	var s := 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b
	var l_ := pow(maxf(l, 0.0), 1.0 / 3.0)
	var m_ := pow(maxf(m, 0.0), 1.0 / 3.0)
	var s_ := pow(maxf(s, 0.0), 1.0 / 3.0)
	return Vector3(
		0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
		1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
		0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
