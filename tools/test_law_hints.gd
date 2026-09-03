extends SceneTree

## M11.3 — 법률 힌트 ↔ 시뮬 실제 전수 대조.
##
##   godot --headless --script res://tools/test_law_hints.gd
##
## `occupation_pillage.immediate_income` 은 LawEvaluator 만 읽는 값이었고 Economy 는
## 한 번도 읽지 않았다. AI 의 91% 가 아무 효과 없는 법을 채택했다 (1차 §5.2).
## 하나가 나왔다면 나머지도 의심해야 한다 — 그래서 손으로 관리하는 목록이 아니라
## 소스를 직접 훑어 소비처를 찾는다. 소비처가 사라지면 테스트가 깨진다.

const SIM_DIRS := ["res://sim/systems", "res://sim/model", "res://sim/worldgen", "res://sim/util"]
const AI_DIRS := ["res://sim/ai"]
## Nation.law_modifier 자체는 통로일 뿐 소비처가 아니다.
const NOT_A_CONSUMER := "res://sim/model/nation.gd"


func _initialize() -> void:
	var pool := LawSystem.laws_by_category()
	var used := {}                      # key -> [law_id...]
	for cat in pool:
		for law: Law in pool[cat]:
			for key: String in law.modifiers:
				if not used.has(key):
					used[key] = ([] as Array[String])
				used[key].append(law.id)

	var sim_hits := _scan(SIM_DIRS)
	var ai_hits := _scan(AI_DIRS)
	var failures := 0

	var keys := used.keys()
	keys.sort()
	print("%-20s %-5s %-6s %-4s %-4s %s" % ["key", "종류", ".tres", "시뮬", "AI", "판정"])
	for key: String in keys:
		var kind := _kind_of(key)
		var sim_n: int = sim_hits.get(key, []).size()
		var ai_n: int = ai_hits.get(key, []).size()
		var verdict := "OK"
		if kind == "미선언":
			verdict = "FAIL 선언 없음"
		elif kind == "힌트":
			if ai_n == 0:
				verdict = "FAIL AI 소비처 없음"
			elif sim_n > 0:
				verdict = "FAIL 힌트가 시뮬에 샌다"
		elif sim_n == 0:
			verdict = "FAIL 유령값 — 시뮬 소비처 없음"
		if verdict != "OK":
			failures += 1
		print("%-20s %-5s %-6d %-4d %-4d %s" % [key, kind, used[key].size(), sim_n, ai_n, verdict])

	# 반대 방향: 선언만 되고 어느 법도 쓰지 않는 키는 죽은 선언이다.
	for key: String in Law.MULTIPLICATIVE + Law.ADDITIVE + Law.AI_HINTS:
		if not used.has(key):
			failures += 1
			print("%-20s %-5s %-6d %-4s %-4s FAIL 선언만 있고 쓰는 법이 없다"
				% [key, _kind_of(key), 0, "-", "-"])

	print("\n소비처 상세")
	for key: String in keys:
		var where: Array = sim_hits.get(key, []) + ai_hits.get(key, [])
		print("  %-20s %s" % [key, ", ".join(where) if not where.is_empty() else "(없음)"])

	print("\n%s  (%d 위반)" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(1 if failures > 0 else 0)


func _kind_of(key: String) -> String:
	if key in Law.MULTIPLICATIVE:
		return "곱셈"
	if key in Law.ADDITIVE:
		return "덧셈"
	if key in Law.AI_HINTS:
		return "힌트"
	return "미선언"


## key -> ["file.gd:12", ...]. `law_modifier("x")` 와 `modifier("x")` 를 모두 잡는다.
func _scan(dirs: Array) -> Dictionary:
	var out := {}
	for d: String in dirs:
		for path in _gd_files(d):
			if path == NOT_A_CONSUMER:
				continue
			var text := FileAccess.get_file_as_string(path)
			var line_no := 0
			for line in text.split("\n"):
				line_no += 1
				if line.strip_edges().begins_with("#"):
					continue
				for key: String in Law.MULTIPLICATIVE + Law.ADDITIVE + Law.AI_HINTS:
					if not line.contains('modifier("%s")' % key):
						continue
					if not out.has(key):
						out[key] = ([] as Array[String])
					out[key].append("%s:%d" % [path.get_file(), line_no])
	return out


func _gd_files(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("디렉토리를 열 수 없다: %s" % dir_path)
		return out
	var files := dir.get_files()
	files.sort()
	for f in files:
		if f.ends_with(".gd"):
			out.append(dir_path + "/" + f)
	return out
