class_name Fleet extends RefCounted

## 함대. 설계서에 해군 절이 없어 여기서 규격을 정한다.
## 육군과 달리 프로빈스가 아니라 해역(SeaZone)에 존재하며, 통제권 다툼만 한다.

var id: int = -1
var nation_id: int = -1
var zone_id: int = -1
## 향하는 해역. 해역 그래프 위를 한 턴에 한 칸 움직인다.
var target_zone: int = -1
var ships: int = 0
var morale: float = 1.0
var is_alive: bool = true
