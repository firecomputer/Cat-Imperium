#!/usr/bin/env python3
"""문화별 법률 채택 분포가 유의미하게 다른지 검정한다 (M4 완료 기준).

    godot --headless --script res://tools/batch_laws.gd -- --runs 60 --turns 150 --out res://out/laws.csv
    .venv/bin/python tools/analyze_laws.py out/laws.csv
"""
import argparse

import pandas as pd
from scipy.stats import chi2_contingency

ALPHA = 0.001
CRAMERS_V_STRONG = 0.15


def cramers_v(chi2: float, table: pd.DataFrame) -> float:
    n = table.to_numpy().sum()
    k = min(table.shape) - 1
    return (chi2 / (n * k)) ** 0.5 if n and k else 0.0


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--turn", type=int, help="분석할 턴 (기본: 마지막 턴)")
    ap.add_argument("--show", action="store_true", help="카테고리별 분포표 출력")
    args = ap.parse_args()

    df = pd.read_csv(args.csv)
    turn = args.turn if args.turn is not None else df.turn.max()
    snap = df[df.turn == turn]
    print(f"turn={turn}  nations={len(snap) // snap.category.nunique()}  "
          f"seeds={snap.seed.nunique()}")

    print(f"\n{'category':<13}{'chi2':>10}{'p':>12}{'CramersV':>11}   판정")
    strong = 0
    for cat in sorted(snap.category.unique()):
        sub = snap[snap.category == cat]
        table = pd.crosstab(sub.culture, sub.law_id)
        if table.shape[1] < 2:
            print(f"{cat:<13}{'-':>10}{'-':>12}{'-':>11}   단일 법률")
            continue
        chi2, p, _, _ = chi2_contingency(table)
        v = cramers_v(chi2, table)
        ok = p < ALPHA and v >= CRAMERS_V_STRONG
        strong += ok
        print(f"{cat:<13}{chi2:>10.1f}{p:>12.2e}{v:>11.3f}   {'다름' if ok else '차이 약함'}")
        if args.show:
            print(table.div(table.sum(axis=1), axis=0).round(2).to_string(), "\n")

    n_cat = snap.category.nunique()
    print(f"\n문화별 분포가 유의미하게 다른 카테고리: {strong}/{n_cat}  "
          f"(p<{ALPHA}, Cramer's V>={CRAMERS_V_STRONG})")

    sev = snap.groupby("culture").severity.mean().sort_values()
    print("\n문화별 평균 가혹도(severity)")
    print(sev.round(3).to_string())
    print("\n문화별 평균 desperation")
    print(snap.groupby("culture").desperation.mean().round(3).to_string())


if __name__ == "__main__":
    main()
