#!/usr/bin/env python3
"""godot 배치를 기계가 감당할 수준으로 묶는다.

--jobs 20 한 번이 24코어와 8GB 를 먹고 기계를 멈춰 세운 적이 있다.
tools/batch_parallel.sh 안에도 상한이 있지만, 이 훅은 그 스크립트를
우회하는 직접 실행(godot ... & 를 여러 번, xargs -P, parallel -j)까지 막는다.

해제: 명령 앞에 CAT_IMPERIUM_ALLOW_HEAVY=1 을 붙인다.
"""
import json
import re
import subprocess
import sys

MAX_JOBS = 8


def running_godot() -> int:
    try:
        out = subprocess.run(["pgrep", "-c", "godot"], capture_output=True, text=True)
        return int(out.stdout.strip() or 0)
    except (ValueError, OSError):
        return 0


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0
    command = payload.get("tool_input", {}).get("command", "")
    if not re.search(r"godot|batch_parallel|tools/batch_", command):
        return 0
    if "CAT_IMPERIUM_ALLOW_HEAVY=1" in command:
        return 0

    for flag in (r"--jobs\s+(\d+)", r"-P\s*(\d+)", r"-j\s*(\d+)"):
        for value in re.findall(flag, command):
            if int(value) > MAX_JOBS:
                print(f"차단: 동시 실행 {value} 개 요청. 상한 {MAX_JOBS}. "
                      f"해제하려면 CAT_IMPERIUM_ALLOW_HEAVY=1 을 명시하고 사용자에게 먼저 물어라.",
                      file=sys.stderr)
                return 2

    launches = len(re.findall(r"(?<![\w/-])godot\b", command))
    if launches > MAX_JOBS:
        print(f"차단: 한 명령에서 godot {launches} 회 실행. 상한 {MAX_JOBS}.", file=sys.stderr)
        return 2

    live = running_godot()
    if live >= MAX_JOBS:
        print(f"차단: 이미 godot {live} 개가 돌고 있다. 끝나기를 기다려라 "
              f"(확인: ps aux | grep godot).", file=sys.stderr)
        return 2
    return 0


sys.exit(main())
