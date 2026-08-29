#!/usr/bin/env python3
"""batch_sim.gd 가 뽑은 CSV 를 §16.2 지표로 요약한다.

    godot --headless --script res://tools/batch_sim.gd -- --runs 100 --turns 300 --out res://out/runs.csv
    python tools/analyze.py out/runs.csv [--plot out/runs.png]
"""
import argparse
from pathlib import Path

import pandas as pd

POP_ERROR_LIMIT = 0.1      # %
INFRA_MAX_RANGE = (7.0, 9.0)
CITY_RANGE = (15, 40)
FIRST_DEFAULT_RANGE = (100, 250)


def verdict(ok: bool) -> str:
    return "PASS" if ok else "FAIL"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--plot", help="인프라/GDP 추이 PNG 경로")
    ap.add_argument("--defaults", help="파산 이벤트 CSV (기본: <csv>_defaults.csv)")
    ap.add_argument("--events", help="신용 이벤트 CSV (기본: <csv>_credit_events.csv)")
    args = ap.parse_args()

    df = pd.read_csv(args.csv)
    last = df[df.turn == df.turn.max()]
    runs = df.seed.nunique()

    print(f"runs={runs}  turns={df.turn.max()}  provinces={last.provinces.mean():.0f}"
          f"  nations={last.nations.mean():.0f}")

    worst_pop = df.pop_error_pct.abs().max()
    hard = int(df.hard_anchor_violations.sum())
    soft_after_start = int(df[df.turn > 0].soft_anchor_violations.sum())

    print("\n[M3 완료 기준]")
    print(f"  GDP 앵커 상한 초과 (누적 샘플)     : {hard}  {verdict(hard == 0)}")
    print(f"  인구 총합 보존 (최대 오차)          : {worst_pop:.6f}%  "
          f"{verdict(worst_pop < POP_ERROR_LIMIT)}")

    print("\n[§16.2 중 현재 측정 가능한 지표]")
    infra_max = last.max_infra
    cities = last.cities
    print(f"  최고 인프라 (300턴)  평균 {infra_max.mean():.2f}  "
          f"[{infra_max.min():.2f}, {infra_max.max():.2f}]  "
          f"{verdict(INFRA_MAX_RANGE[0] <= infra_max.mean() <= INFRA_MAX_RANGE[1])}")
    print(f"  세계 총 도시 수      평균 {cities.mean():.1f}  "
          f"[{cities.min()}, {cities.max()}]  "
          f"{verdict(CITY_RANGE[0] <= cities.mean() <= CITY_RANGE[1])}")

    default_path = Path(args.defaults) if args.defaults else Path(args.csv).with_name(
        Path(args.csv).stem + "_defaults.csv")
    print("\n[M5 완료 기준]")
    if default_path.exists():
        defaults = pd.read_csv(default_path)
    else:
        defaults = pd.DataFrame()
    if defaults.empty:
        print("  첫 파산                    : 없음  FAIL")
    else:
        first = defaults.groupby("seed").turn.min()
        first_ok = FIRST_DEFAULT_RANGE[0] <= first.mean() <= FIRST_DEFAULT_RANGE[1]
        print(f"  첫 파산 턴                : 평균 {first.mean():.1f}  "
              f"중앙값 {first.median():.1f}  [{first.min()}, {first.max()}]  "
              f"{verdict(first_ok)}")
        print(f"  파산 발생 시드            : {len(first)}/{runs}  "
              f"50턴 이전 {int((first < 50).sum())}개")
        print(f"  총 파산 / 재파산 국가     : {len(defaults)} / "
              f"{int((defaults.groupby(['seed', 'nation']).size() > 1).sum())}")

    debt_finite = df.mean_debt_ratio.notna().all() and (df.mean_debt_ratio.abs() < 10.0).all()
    print(f"  평균 부채/GDP (300턴)     : {last.mean_debt_ratio.mean():.3f}  "
          f"최대 국가 {last.max_debt_ratio.max():.3f}  "
          f"{verdict(debt_finite)}")
    print(f"  평균 1차 재정수지/GDP     : {last.mean_primary_balance_ratio.mean():+.3f}")
    print(f"  평균 이자부담/GDP         : {last.mean_interest_burden.mean():.3f}")

    event_path = Path(args.events) if args.events else Path(args.csv).with_name(
        Path(args.csv).stem + "_credit_events.csv")
    if event_path.exists():
        events = pd.read_csv(event_path)
        counts = events.kind.value_counts()
        print("  신용 이벤트               : "
              + ", ".join(f"{kind}={int(count)}" for kind, count in counts.items()))
        if not defaults.empty:
            first_default = defaults.sort_values("turn").iloc[0]
            chain = events[(events.seed == first_default.seed)
                           & (events.nation == first_default.nation)
                           & (events.turn <= first_default.turn)]
            stages = " -> ".join(
                f"{row.kind}@{int(row.turn)}" for row in chain.itertuples())
            print(f"  첫 붕괴 나선              : {stages}")

    print("\n[참고]")
    print(f"  프로빈스 평균 인프라 (300턴) : {last.mean_infra.mean():.2f}")
    print(f"  앵커 초과 샘플 (턴>0, 소프트) : {soft_after_start} "
          f"(인프라 감쇠 직후 과도상태, 최대 배율 {df.max_soft_overshoot.max():.3f})")
    print(f"  최대 1인당 GDP               : {last.max_gdp_pc.max():.0f}")
    print(f"  세계 GDP 배수 (0턴 대비)     : "
          f"{last.gdp.mean() / df[df.turn == 0].gdp.mean():.2f}x")
    print(f"  인플레 평균 {last.mean_inflation.mean():+.4f}  "
          f"최저 {df.min_inflation.min():+.4f}  "
          f"하한(-0.5) 도달 {int((df.min_inflation <= -0.4999).sum())}회")

    if args.plot:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt

        by_turn = df.groupby("turn").agg(
            mean_infra=("mean_infra", "mean"),
            max_infra=("max_infra", "mean"),
            gdp=("gdp", "mean"),
        )
        fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(8, 7), sharex=True)
        ax1.plot(by_turn.index, by_turn.mean_infra, label="mean infra")
        ax1.plot(by_turn.index, by_turn.max_infra, label="max infra")
        ax1.set_ylabel("infra")
        ax1.legend()
        ax1.grid(alpha=0.3)
        ax2.plot(by_turn.index, by_turn.gdp)
        ax2.set_ylabel("world GDP")
        ax2.set_xlabel("turn")
        ax2.grid(alpha=0.3)
        fig.tight_layout()
        fig.savefig(args.plot, dpi=110)
        print(f"\nwrote {args.plot}")


if __name__ == "__main__":
    main()
