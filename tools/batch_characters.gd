extends SceneTree

## M6 인물 배치 검증.
##
##   godot4 --headless --path . --script res://tools/batch_characters.gd -- \
##     --runs 20 --turns 120 --out res://out/characters.csv


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 20))
	var turns := int(args.get("turns", 120))
	var seed0 := int(args.get("seed0", 1))
	var out_path: String = args.get("out", "res://out/characters.csv")
	var lines := PackedStringArray(["seed,world_turn,id,nation,culture,name,family_name,given_name,"
		+ "initial_pool,initial_advisor,birth_turn,death_turn,is_alive,role,home_province,education,intelligence,charisma,"
		+ "health,creativity,mean_talent,loyalty,ambition,noble_birth,rebellion_requested"])
	var initial_total := 0
	var alive_total := 0
	var advisor_total := 0
	var t0 := Time.get_ticks_msec()

	for run_idx in range(runs):
		var world := WorldState.create(seed0 + run_idx)
		var initial_count := world.characters.size()
		initial_total += initial_count
		var initial_advisors := {}
		for c in world.characters:
			if Character.is_advisor_role(c.role):
				initial_advisors[c.id] = true
		SimClock.run(world, turns)
		for c in world.characters:
			if c.is_alive:
				alive_total += 1
			if c.is_alive and Character.is_advisor_role(c.role):
				advisor_total += 1
			lines.append(_row(world, c, initial_count, initial_advisors))

	var file := FileAccess.open(out_path, FileAccess.WRITE)
	if file == null:
		push_error("CSV 저장 실패: %s" % out_path)
		quit(1)
		return
	file.store_string("\n".join(lines) + "\n")
	file.close()
	print("runs=%d turns=%d initial=%d characters=%d alive=%d advisors=%d (%.1fs)" % [
		runs, turns, initial_total, lines.size() - 1, alive_total, advisor_total,
		(Time.get_ticks_msec() - t0) / 1000.0])
	print("wrote %s" % ProjectSettings.globalize_path(out_path))
	quit(0)


func _row(world: WorldState, c: Character, initial_count: int,
		initial_advisors: Dictionary) -> String:
	var talent := (c.intelligence + c.charisma + c.creativity) / 3.0
	return ",".join(PackedStringArray([
		str(world.world_seed), str(world.turn), str(c.id), str(c.nation_id),
		Culture.NAMES[c.culture], _csv(c.name), _csv(c.family_name), _csv(c.given_name),
		str(int(c.id < initial_count)), str(int(initial_advisors.has(c.id))),
		str(c.birth_turn), str(c.death_turn), str(int(c.is_alive)), str(c.role),
		str(c.home_province), "%.3f" % c.education_at_birth,
		"%.3f" % c.intelligence, "%.3f" % c.charisma, "%.3f" % c.health,
		"%.3f" % c.creativity, "%.3f" % talent, "%.4f" % c.loyalty,
		"%.4f" % c.ambition, "%.4f" % c.noble_birth, str(int(c.rebellion_requested)),
	]))


func _csv(value: String) -> String:
	return '"' + value.replace('"', '""') + '"'


func _parse_args(argv: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < argv.size():
		var arg := argv[i]
		if arg.begins_with("--"):
			var key := arg.substr(2)
			if i + 1 < argv.size() and not argv[i + 1].begins_with("--"):
				out[key] = argv[i + 1]
				i += 1
			else:
				out[key] = true
		i += 1
	return out
