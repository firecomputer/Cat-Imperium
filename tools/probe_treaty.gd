extends SceneTree

## 강화조약이 왜 멈추는지. 루프 종료 시점의 잔여 후보와 남은 예산을 대조한다.
##   godot4 --headless --path . --script res://tools/probe_treaty.gd -- --runs 8 --turns 300

func _initialize() -> void:
	var runs := 8
	var turns := 300
	var argv := OS.get_cmdline_user_args()
	for i in range(argv.size() - 1):
		if argv[i] == "--runs":
			runs = int(argv[i + 1])
		if argv[i] == "--turns":
			turns = int(argv[i + 1])
	var rows := []
	for i in range(runs):
		var world := WorldState.create(1 + i, MapSource.Kind.NOISE)
		for t in range(turns):
			SimClock.tick(world)
		for e in world.events:
			if e["kind"] == "annex_budget":
				rows.append(e)
	if rows.is_empty():
		print("no treaties")
		quit(0)
		return
	_slice(rows, true, "압승 (warscore>=70)")
	_slice(rows, false, "그 외")
	quit(0)


func _slice(rows: Array, crushing: bool, label: String) -> void:
	var c := 0
	var picked := 0.0
	var lp := 0.0
	var left := 0.0
	var rest := 0.0
	var no_cand := 0
	var too_dear := 0
	var gap := 0.0
	for e: Dictionary in rows:
		if bool(e["crushing"]) != crushing:
			continue
		c += 1
		picked += float(e["picked"])
		lp += float(e["loser_prov"])
		left += float(e["left"])
		rest += float(e["rest"])
		if int(e["rest"]) == 0:
			no_cand += 1
		else:
			too_dear += 1
			gap += float(e["rest_min_cost"]) - float(e["left"])
	if c == 0:
		return
	print("[%s] %d 건" % [label, c])
	print("   병합 %.2f / 패자영토 %.2f   남은예산 %.1f   잔여후보 %.2f" \
		% [picked / c, lp / c, left / c, rest / c])
	print("   후보가 정말 없음   : %d (%.0f%%)" % [no_cand, 100.0 * no_cand / c])
	print("   후보는 있는데 비쌈 : %d (%.0f%%), 평균 %.1f 점 모자람" \
		% [too_dear, 100.0 * too_dear / c, gap / maxf(too_dear, 1)])
