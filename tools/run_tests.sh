#!/usr/bin/env bash
# 기존 회귀 10종 + 힌트 대조 + M13 지구 지도. 하나라도 깨지면 exit 1.
#
#   tools/run_tests.sh [테스트이름...]
#
# Godot 의 assert 실패는 그 함수만 중단시키고 _initialize 는 계속 진행한다.
# 그래서 테스트는 마지막 줄에 "PASS" 를 찍고 quit(0) 으로 끝난다 — 종료 코드만
# 보면 깨진 테스트가 통과로 보인다. 출력의 SCRIPT ERROR 를 실패로 센다.

set -uo pipefail
cd "$(dirname "$0")/.."

TESTS=(test_laws test_law_hints test_credit test_characters test_military
       test_war test_naval test_rebellion test_empire test_market test_view test_earth_map
       test_culture)
[ $# -gt 0 ] && TESTS=("$@")

failed=0
for t in "${TESTS[@]}"; do
	out=$(timeout 600 godot --headless --log-file "/tmp/cat-empire-$t.log" \
		--script "res://tools/$t.gd" 2>&1)
	code=$?
	errors=$(printf '%s\n' "$out" | grep -c 'SCRIPT ERROR')
	if [ "$code" -ne 0 ] || [ "$errors" -ne 0 ]; then
		failed=$((failed + 1))
		printf 'FAIL %-18s exit=%d  script_errors=%d\n' "$t" "$code" "$errors"
		printf '%s\n' "$out" | grep -A1 'SCRIPT ERROR' | sed 's/^/     /'
	else
		printf 'PASS %-18s\n' "$t"
	fi
done

if [ "$failed" -ne 0 ]; then
	echo "--- $failed / ${#TESTS[@]} 실패"
	exit 1
fi
echo "--- ${#TESTS[@]} 종 전부 PASS"
