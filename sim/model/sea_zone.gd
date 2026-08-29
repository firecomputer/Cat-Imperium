class_name SeaZone extends RefCounted

## 해역. 바다 분지(연결 성분)를 다시 쪼갠 단위로, 함대·제해권·상륙의 무대다.
## 분지 하나가 전 세계 바다라 제해권이 "1등 해군의 지구 독식"이 되던 문제를 여기서 끊는다.

var id: int = -1
var zone_id: int = -1
var tiles: PackedInt32Array = PackedInt32Array()
var centroid: Vector2 = Vector2.ZERO
## 인접 해역. 함대는 이 그래프 위를 한 턴에 한 칸 움직인다.
var neighbors: PackedInt32Array = PackedInt32Array()
## 이 해역에 접한 프로빈스. 상륙 목표와 해상 보급 도달점이 전부 여기서 나온다.
var coast_provinces: PackedInt32Array = PackedInt32Array()
## STRAIT 타일을 품은 해역. 병목이라 제해권이 쉽게 넘어가지 않는다.
var is_strait: bool = false
