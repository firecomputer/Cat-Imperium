#!/usr/bin/env python3
"""M6 인물 CSV에서 문화 작명·7석 등용·교육 효과를 검증한다."""

import argparse

import pandas as pd

EXPECTED_CULTURES = {"샴", "랙돌", "치즈 태비", "러시안블루", "코리안숏헤어"}
INITIAL_PER_NATION = 12
ADVISORS_PER_NATION = 7
MIN_TALENT_GAP = 15.0
MIN_EDUCATION_CORRELATION = 0.45
# M10: 건국 스냅샷만 검사했기 때문에 턴 60 이후 풀이 3.2명까지 마르는 것을
# 한 번도 못 잡았다. 종료 시점의 풀과 고문석 충원율을 실제 기준으로 삼는다.
MIN_POOL_PER_NATION = 8.0
MAX_POOL_PER_NATION = 30.0
MIN_ADVISOR_FILL = 0.80
MIN_MAX_LIFESPAN = 200
MIN_FOUNDER_DEATH_SPREAD = 60


def verdict(ok: bool) -> str:
    return "PASS" if ok else "FAIL"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("csv")
    args = parser.parse_args()
    df = pd.read_csv(args.csv)

    runs = df.seed.nunique()
    nations = df[["seed", "nation"]].drop_duplicates().shape[0]
    # 건국 국가만 초기 풀을 갖는다. 반란국은 게임 중에 생기므로 분모에서 뺀다 —
    # 안 빼면 초기 12명/7석 검사가 반란이 난 시드에서 무조건 FAIL 이 된다.
    founding = df[df.initial_pool == 1][["seed", "nation"]].drop_duplicates().shape[0]
    initial = df[df.initial_pool == 1]
    initial_advisors = df[df.initial_advisor == 1]
    alive = df[df.is_alive == 1]
    advisors = alive[alive.role.isin([1, 2, 3, 4, 5])]

    expected_initial = founding * INITIAL_PER_NATION
    expected_advisors = founding * ADVISORS_PER_NATION
    initial_counts = initial.groupby(["seed", "nation"]).size()
    advisor_counts = initial_advisors.groupby(["seed", "nation"]).size()
    initial_ok = (len(initial_counts) == founding
                  and initial_counts.eq(INITIAL_PER_NATION).all())
    advisor_ok = (len(advisor_counts) == founding
                  and advisor_counts.eq(ADVISORS_PER_NATION).all())
    cultures_ok = set(df.culture.unique()) == EXPECTED_CULTURES
    names_ok = bool(df.name.notna().all() and (df.name.str.len() > 1).all())

    q_low = df.education.quantile(0.25)
    q_high = df.education.quantile(0.75)
    low = df[df.education <= q_low].mean_talent
    high = df[df.education >= q_high].mean_talent
    gap = high.mean() - low.mean()
    corr = df.education.corr(df.mean_talent)
    education_ok = gap >= MIN_TALENT_GAP and corr >= MIN_EDUCATION_CORRELATION

    print(f"runs={runs} characters={len(df)} alive={len(alive)} nations={nations}")
    print("\n[M6 구조]")
    print(f"  문화별 이름 데이터       : {sorted(df.culture.unique())}  "
          f"{verdict(cultures_ok and names_ok)}")
    print(f"  초기 인물 12명/국가      : {len(initial)}/{expected_initial}  "
          f"{verdict(initial_ok)}")
    print(f"  건국 고문 7명/국가       : {len(initial_advisors)}/{expected_advisors}  "
          f"{verdict(advisor_ok)}")

    # 살아 있는 인물이 하나라도 남은 국가만 분모로 센다. 소멸한 국가와
    # 반란국까지 세면 충원율이 실제보다 낮게 나온다.
    live_nations = alive[["seed", "nation"]].drop_duplicates().shape[0]
    pool_per_nation = len(alive) / max(live_nations, 1)
    advisor_fill = len(advisors) / max(live_nations * ADVISORS_PER_NATION, 1)
    pool_ok = MIN_POOL_PER_NATION <= pool_per_nation <= MAX_POOL_PER_NATION
    fill_ok = advisor_fill >= MIN_ADVISOR_FILL

    lifespan = df.death_turn - df.birth_turn
    max_lifespan = int(lifespan.max())
    lifespan_ok = max_lifespan >= MIN_MAX_LIFESPAN

    founder_spread = initial.groupby(["seed", "nation"]).death_turn.agg(
        lambda s: s.max() - s.min())
    spread = float(founder_spread.mean())
    spread_ok = spread >= MIN_FOUNDER_DEATH_SPREAD

    print("\n[M10 장기 인물 풀]")
    print(f"  종료 시 국가당 생존 인물  : {pool_per_nation:.2f} "
          f"(기준 {MIN_POOL_PER_NATION:.0f}~{MAX_POOL_PER_NATION:.0f})  "
          f"{verdict(pool_ok)}")
    print(f"  종료 시 고문석 충원율     : {advisor_fill * 100:.1f}% "
          f"(기준 ≥{MIN_ADVISOR_FILL * 100:.0f}%)  {verdict(fill_ok)}")
    print(f"  실현 수명 최대            : {max_lifespan} "
          f"(기준 ≥{MIN_MAX_LIFESPAN})  {verdict(lifespan_ok)}")
    print(f"  실현 수명 평균            : {lifespan.mean():.1f}")
    print(f"  건국 세대 사망 턴 폭      : {spread:.1f} "
          f"(기준 ≥{MIN_FOUNDER_DEATH_SPREAD})  {verdict(spread_ok)}")

    print("\n[M6 완료 기준 — 교육에 따른 평균 능력]")
    print(f"  하위 교육(≤{q_low:+.2f}) : {low.mean():.2f} (n={len(low)})")
    print(f"  상위 교육(≥{q_high:+.2f}) : {high.mean():.2f} (n={len(high)})")
    print(f"  평균 능력 차이            : {gap:+.2f} (기준 ≥{MIN_TALENT_GAP:.1f})")
    print(f"  교육-능력 상관계수        : {corr:+.3f} (기준 ≥{MIN_EDUCATION_CORRELATION:.2f})  "
          f"{verdict(education_ok)}")

    print("\n[문화별 표본]")
    summary = df.groupby("culture").agg(
        characters=("id", "size"),
        unique_names=("name", "nunique"),
        mean_talent=("mean_talent", "mean"),
        mean_education=("education", "mean"),
    ).sort_index()
    print(summary.to_string(float_format=lambda value: f"{value:.2f}"))


if __name__ == "__main__":
    main()
