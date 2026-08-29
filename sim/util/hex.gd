class_name Hex extends RefCounted

## odd-r 오프셋 헥스 좌표 유틸.
## 홀수 row 가 오른쪽으로 0.5 만큼 밀린 배치.

const SQRT3_2 := 0.8660254

## (col, row) 델타. [0] = 짝수 row, [1] = 홀수 row.
const NEIGHBOR_DELTAS := [
	[Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)],
	[Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(1, 1)],
]


static func index(col: int, row: int, w: int) -> int:
	return row * w + col


static func col_of(idx: int, w: int) -> int:
	return idx % w


static func row_of(idx: int, w: int) -> int:
	return idx / w


## 노이즈 샘플링용 평면 좌표. 이 보정 없이 샘플링하면 지형이 세로로 찌그러진다.
static func to_plane(col: int, row: int) -> Vector2:
	return Vector2(col + (0.5 if row % 2 == 1 else 0.0), row * SQRT3_2)


## 맵 범위 안의 이웃 타일 인덱스만 반환.
static func neighbors(idx: int, w: int, h: int) -> PackedInt32Array:
	var col := idx % w
	var row := idx / w
	var out := PackedInt32Array()
	for d: Vector2i in NEIGHBOR_DELTAS[row & 1]:
		var nc := col + d.x
		var nr := row + d.y
		if nc >= 0 and nc < w and nr >= 0 and nr < h:
			out.append(nr * w + nc)
	return out


## 모든 타일의 이웃 목록을 한 번에 캐시. 반복 호출보다 훨씬 빠르다.
static func build_neighbor_cache(w: int, h: int) -> Array:
	var cache := []
	cache.resize(w * h)
	for idx in range(w * h):
		cache[idx] = neighbors(idx, w, h)
	return cache


static func to_cube(col: int, row: int) -> Vector3i:
	var q := col - (row - (row & 1)) / 2
	return Vector3i(q, row, -q - row)


static func distance(a_col: int, a_row: int, b_col: int, b_row: int) -> int:
	var a := to_cube(a_col, a_row)
	var b := to_cube(b_col, b_row)
	return (absi(a.x - b.x) + absi(a.y - b.y) + absi(a.z - b.z)) / 2
