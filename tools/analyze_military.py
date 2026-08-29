#!/usr/bin/env python3
"""M7 보급·상비군 CSV와 §8.3 검증표를 요약한다."""

import argparse

import pandas as pd

BASE_COST = 10.0
SUPPLY_RANGE = 100.0
EXPONENT = 1.8
MIN_SUPPLY = 0.05


def supply(cost: float) -> float:
    return max(MIN_SUPPLY, min(1.0, 1.0 - (cost / SUPPLY_RANGE) ** EXPONENT))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("csv")
    args = parser.parse_args()
    df = pd.read_csv(args.csv)
    last = df[df.turn == df.turn.max()]

    cases = [
        ("15칸 인프라 0", 15 * BASE_COST, 0.05),
        ("15칸 인프라 6", 15 * BASE_COST / (1 + 6 * 0.85), 0.92),
        ("5칸 인프라 1", 5 * BASE_COST / (1 + 1 * 0.85), 0.90),
        ("5칸 산악·불온·인프라 1",
         5 * BASE_COST / (1 + 1 * 0.85) * 1.8 * (1 + 1.0 * 1.2), 0.05),
    ]
    print("[M7 §8.3 완료 기준]")
    all_ok = True
    for label, cost, target in cases:
        value = supply(cost)
        ok = abs(value - target) <= 0.015
        all_ok &= ok
        print(f"  {label:<25} 비용 {cost:>6.1f}  보급 {value:.3f}  "
              f"{'PASS' if ok else 'FAIL'}")
    print(f"  종합: {'PASS' if all_ok else 'FAIL'}")

    print("\n[생성 세계 국내 보급망 — 전쟁 전 참고값]")
    print(f"  runs={last.seed.nunique()} nations="
          f"{last[['seed', 'nation']].drop_duplicates().shape[0]} provinces={len(last)}")
    print(f"  평균 보급 {last.supply.mean():.3f}, 최저 {last.supply.min():.3f}, "
          f"0.6 미만 {(last.supply < 0.6).mean() * 100:.1f}%")
    print(f"  인프라-보급 상관계수 {last.infra.corr(last.supply):+.3f}")
    if last.city.any():
        print(f"  도시 평균 {last[last.city == 1].supply.mean():.3f}, "
              f"비도시 평균 {last[last.city == 0].supply.mean():.3f}")
    print("  전쟁 중 평균 0.6~0.8 지표는 M8의 원정군·점령지가 생긴 뒤 측정한다.")

    print("\n[상비군 — §9.4 군사비는 GDP 비율]")
    nations = last[["seed", "nation", "culture", "troops", "mil_share",
                    "manpower_cap", "gdp"]].drop_duplicates(["seed", "nation"])
    print(f"  GDP 대비 군사비 평균 {nations.mil_share.mean() * 100:.2f}%, "
          f"최대 {nations.mil_share.max() * 100:.2f}%")
    print(f"  동원률(병력/동원가능인구) 평균 "
          f"{(nations.troops / nations.manpower_cap).mean() * 100:.1f}%, "
          f"상한 도달국 {(nations.troops >= nations.manpower_cap - 1).sum()}")
    print("  문화별 GDP 대비 군사비:")
    by_culture = nations.groupby("culture").mil_share.agg(["mean", "count"])
    for culture, row in by_culture.sort_values("mean", ascending=False).iterrows():
        print(f"    {culture:<12} {row['mean'] * 100:>5.2f}%  (n={int(row['count'])})")
    print(f"  병력 0인 국가 {int((nations.troops == 0).sum())} / {len(nations)}")


if __name__ == "__main__":
    main()
