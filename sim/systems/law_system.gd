class_name LawSystem extends RefCounted

## 카테고리마다 법률 하나씩 채택한다. 심의는 한 번에 한 카테고리씩 돌아가며 이뤄진다.

const LAW_DIR := "res://data/laws"
const REVIEW_INTERVAL := 12.0

static var _by_category: Dictionary = {}


static func laws_by_category() -> Dictionary:
	if not _by_category.is_empty():
		return _by_category
	var dir := DirAccess.open(LAW_DIR)
	if dir == null:
		push_error("법률 디렉토리를 열 수 없다: %s" % LAW_DIR)
		return _by_category
	var files := dir.get_files()
	files.sort()   # 파일 순회 순서에 의존하지 않도록 정렬 (§15)
	for f in files:
		if not f.ends_with(".tres"):
			continue
		var law: Law = ResourceLoader.load(LAW_DIR + "/" + f)
		if not _by_category.has(law.category):
			_by_category[law.category] = []
		_by_category[law.category].append(law)
	return _by_category


## 건국 시 각 카테고리에서 가장 점수 높은 법률을 채택한다.
static func adopt_initial(world: WorldState) -> void:
	for n in world.nations:
		adopt_for(n)


## 신생국(반란 독립 포함)이 자기 문화 기준으로 전 카테고리를 한 번에 채택한다.
static func adopt_for(n: Nation) -> void:
	var pool := laws_by_category()
	for cat in Law.CATEGORIES:
		if pool.has(cat):
			n.laws[cat] = _best(n, pool[cat])


static func tick(world: WorldState) -> void:
	var pool := laws_by_category()
	for n in world.nations:
		if not n.is_alive:
			continue
		n.law_review_progress += n.law_change_speed
		if n.law_review_progress < REVIEW_INTERVAL:
			continue
		n.law_review_progress -= REVIEW_INTERVAL
		var cat: String = Law.CATEGORIES[(n.law_review_count + n.id) % Law.CATEGORIES.size()]
		n.law_review_count += 1
		if not pool.has(cat):
			continue
		var best := _best(n, pool[cat])
		if best != null and best != n.laws.get(cat):
			n.laws[cat] = best


static func _best(n: Nation, candidates: Array) -> Law:
	var best: Law = null
	var best_score := -INF
	for law: Law in candidates:
		var s := LawEvaluator.evaluate(n, law)
		# 동점은 id 사전순으로 깨서 결정론을 지킨다
		if s > best_score or (s == best_score and best != null and law.id < best.id):
			best_score = s
			best = law
	return best
