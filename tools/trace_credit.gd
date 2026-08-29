extends SceneTree

## 한 국가의 M5 붕괴 나선을 턴별 TSV로 추적한다.
##
##   godot4 --headless --path . --script res://tools/trace_credit.gd -- \
##     --seed 1 --nation 31 --turns 80


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var seed := int(args.get("seed", 1))
	var nation_id := int(args.get("nation", 0))
	var turns := int(args.get("turns", 100))
	var world := WorldState.create(seed)
	if nation_id < 0 or nation_id >= world.nations.size():
		push_error("국가 id 범위 초과: %d" % nation_id)
		quit(1)
		return

	print("turn\tgdp\tincome\texpenses\tinterest\ttreasury\tdebt\tlimit\trating\t"
		+ "inflation\tprinting\tbankrupt\tdesperation")
	_print_row(world, world.nations[nation_id])
	for i in range(turns):
		SimClock.tick(world)
		_print_row(world, world.nations[nation_id])
	quit(0)


func _print_row(world: WorldState, n: Nation) -> void:
	print("%d\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.3f\t%.3f\t%d\t%d\t%.3f" % [
		world.turn, n.gdp, n.income, n.expenses, n.interest_expense, n.treasury,
		n.debt, Credit.credit_limit(n), n.credit_rating, n.inflation, n.printing_streak,
		n.bankruptcy_timer, LawEvaluator.desperation(n)])


func _parse_args(argv: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < argv.size():
		if argv[i].begins_with("--") and i + 1 < argv.size():
			out[argv[i].substr(2)] = argv[i + 1]
			i += 1
		i += 1
	return out
