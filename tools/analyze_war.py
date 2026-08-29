#!/usr/bin/env python3
"""M8 외교·전쟁·평화 CSV 요약. 완료 기준은 밸런스 오브 파워와 국경 형태다."""

import argparse

import pandas as pd


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("csv")
    args = parser.parse_args()
    df = pd.read_csv(args.csv)
    events = pd.read_csv(args.csv.replace(".csv", "_events.csv"))
    runs = df.seed.nunique()
    alive = df[df.alive == 1]

    print("[M8 완료 기준]")
    frag = alive[alive.provinces > 0].fragments
    ok_border = frag.mean() <= 1.35 and (frag > 2).mean() < 0.05
    print(f"  국경 덩어리 수      평균 {frag.mean():.2f}  최대 {frag.max()}  "
          f"3덩어리 이상 {(frag > 2).mean() * 100:.1f}%  "
          f"{'PASS' if ok_border else 'FAIL'}")

    top = df.groupby("seed").share_of_world.max()
    ok_power = top.mean() < 0.25
    print(f"  최대 국가 세계 GDP 점유율  평균 {top.mean() * 100:.1f}%  "
          f"최대 {top.max() * 100:.1f}%  {'PASS' if ok_power else 'FAIL'}")
    print(f"  종합: {'PASS' if ok_border and ok_power else 'FAIL'}")

    print("\n[생존과 규모]")
    print(f"  runs={runs}  건국국가 생존 {alive.shape[0]}/{df.shape[0]} "
          f"({alive.shape[0] / df.shape[0] * 100:.0f}%)")
    print(f"  영토 평균 {alive.provinces.mean():.1f}  최대 {alive.provinces.max()}  "
          f"월경지 보유국 {(alive.exclaves > 0).sum()}")

    print("\n[전쟁]")
    declared = events[events.kind == "war_declared"]
    ended = events[events.kind == "war_ended"]
    print(f"  선전포고 {len(declared)}건 (턴당 {len(declared) / runs / 300:.3f}) — "
          f"{dict(declared.reason.value_counts())}")
    print(f"  종전 {len(ended)}건 — {dict(ended.reason.value_counts())}")
    print(f"  동맹 {int((events.kind == 'alliance_formed').sum())}건  "
          f"강화조약 {int((events.kind == 'peace_signed').sum())}건  "
          f"속국화 {int((events.kind == 'vassalized').sum())}건")
    print(f"  영토 병합 {int(df.provinces_annexed.sum())}  "
          f"할양 {int(df.provinces_ceded.sum())}  "
          f"반란 상실 {int(df.rebellions_lost.sum())}")

    print("\n[문화별 (생존국 기준)]")
    by_culture = alive.groupby("culture").agg(
        n=("nation", "count"), provinces=("provinces", "mean"),
        troops=("troops", "mean"), ships=("ships", "mean"),
        allies=("allies", "mean"))
    for culture, row in by_culture.sort_values("provinces", ascending=False).iterrows():
        print(f"    {culture:<12} 생존 {int(row['n']):>3}  영토 {row['provinces']:>4.1f}  "
              f"병력 {row['troops']:>6.0f}  함선 {row['ships']:>5.0f}  "
              f"동맹 {row['allies']:.2f}")


if __name__ == "__main__":
    main()
