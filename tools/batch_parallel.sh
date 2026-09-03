#!/usr/bin/env bash
# batch_sim.gd 를 시드 구간으로 쪼개 동시에 돌리고 CSV 5종을 다시 합친다.
#
#   tools/batch_parallel.sh --runs 12 --turns 600 --out res://out/m14_600.csv [--jobs N] ...
#
# batch_sim 은 시드 seed0+i 로 런을 독립 생성하므로 구간을 나눠도 결과가 같다.
# 모든 CSV 행이 seed 열을 갖기 때문에 단순 이어붙이기로 합쳐진다.
# 인식하지 못한 옵션은 그대로 batch_sim 에 넘긴다.
#
# 동시 실행 수는 MAX_JOBS(기본 8)로 강제 제한된다. 예전 기본값은 nproc 이라
# 배치 하나가 전 코어와 8GB 를 먹고 기계를 멈춰 세웠다. 넘겨도 잘린다.
# 정말로 풀로 돌려야 하면 CAT_IMPERIUM_ALLOW_HEAVY=1 을 명시해야 한다.

set -uo pipefail
cd "$(dirname "$0")/.."

RUNS=12
TURNS=600
SEED0=1
OUT="res://out/parallel.csv"
JOBS=""
SCRIPT="res://tools/batch_sim.gd"
PASS=()

while [ $# -gt 0 ]; do
	case "$1" in
		--runs)  RUNS=$2; shift 2 ;;
		--turns) TURNS=$2; shift 2 ;;
		--seed0) SEED0=$2; shift 2 ;;
		--out)   OUT=$2; shift 2 ;;
		--jobs)  JOBS=$2; shift 2 ;;
		--script) SCRIPT=$2; shift 2 ;;
		*)       PASS+=("$1"); shift ;;
	esac
done

MAX_JOBS=${MAX_JOBS:-8}
CORES=$(nproc)
[ "$MAX_JOBS" -gt "$CORES" ] && MAX_JOBS=$CORES
[ -z "$JOBS" ] && JOBS=$MAX_JOBS
if [ "${CAT_IMPERIUM_ALLOW_HEAVY:-0}" != "1" ] && [ "$JOBS" -gt "$MAX_JOBS" ]; then
	echo "--- jobs $JOBS 요청 → $MAX_JOBS 로 제한 (코어 $CORES). 해제: CAT_IMPERIUM_ALLOW_HEAVY=1"
	JOBS=$MAX_JOBS
fi
[ "$JOBS" -gt "$RUNS" ] && JOBS=$RUNS
[ "$JOBS" -lt 1 ] && JOBS=1

# 배치는 언제나 대화형 작업에 자리를 내준다.
NICE=(nice -n 19)
command -v ionice > /dev/null && NICE=(ionice -c 3 nice -n 19)

OUT_LOCAL=${OUT#res://}
OUT_DIR=$(dirname "$OUT_LOCAL")
STEM=$(basename "$OUT_LOCAL" .csv)
SHARD_DIR="$OUT_DIR/.shards_$STEM"
mkdir -p "$SHARD_DIR"
rm -f "$SHARD_DIR"/*.csv

base=$((RUNS / JOBS))
extra=$((RUNS % JOBS))
seed=$SEED0
pids=()
for ((j = 0; j < JOBS; j++)); do
	n=$base
	[ "$j" -lt "$extra" ] && n=$((base + 1))
	[ "$n" -eq 0 ] && continue
	"${NICE[@]}" godot --headless --script "$SCRIPT" -- \
		--runs "$n" --turns "$TURNS" --seed0 "$seed" \
		--out "res://$SHARD_DIR/s$j.csv" "${PASS[@]+"${PASS[@]}"}" \
		> "$SHARD_DIR/s$j.log" 2>&1 &
	pids+=($!)
	seed=$((seed + n))
done

failed=0
for pid in "${pids[@]}"; do
	wait "$pid" || failed=$((failed + 1))
done

# CSV 5종을 각각 합친다. 헤더는 첫 샤드 것만 남긴다.
for suffix in "" _defaults _credit_events _nations _empires _events; do
	target="$OUT_DIR/$STEM$suffix.csv"
	: > "$target"
	first=1
	for f in "$SHARD_DIR"/s*"$suffix".csv; do
		# 접미사 없는 본 파일 루프에서 파생 파일이 함께 잡히지 않게 거른다.
		if [ -z "$suffix" ] && [[ "$f" =~ _(defaults|credit_events|nations|empires|events)\.csv$ ]]; then
			continue
		fi
		[ -f "$f" ] || continue
		if [ "$first" -eq 1 ]; then
			cat "$f" >> "$target"
			first=0
		else
			tail -n +2 "$f" >> "$target"
		fi
	done
	[ "$first" -eq 1 ] && rm -f "$target"
done

rows=$(($(wc -l < "$OUT_DIR/$STEM.csv") - 1))
seeds=$(tail -n +2 "$OUT_DIR/$STEM.csv" | cut -d, -f1 | sort -u | wc -l)
echo "샤드 $JOBS 개, 시드 $seeds 개, 행 $rows → $OUT_DIR/$STEM.csv"
if [ "$failed" -ne 0 ]; then
	echo "--- 샤드 $failed 개 실패. 로그: $SHARD_DIR/*.log"
	exit 1
fi
