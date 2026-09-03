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
FIRST_DEFAULT_RANGE = (80, 250)          # M12 — 제국 형성을 위한 개전 압력 확대
DEBT_RATIO_MAX = 10.0      # §6.2 — 부채/GDP 상한
## 초과가 과도 상태인지 만성인지를 가르는 선. 영토 상실 → 분모 붕괴 → 파산 → 탕감
## 경로는 실측 3턴이면 닫힌다. 그보다 오래 초과로 남으면 상한이 작동하지 않는 것이다.
DEBT_OVER_TURNS_MAX = 15

# 2차 §2 신 지표. M11 은 현행 노이즈 지도를 기준선으로 이 대역을 처음 측정한다.
GINI_BETWEEN_RANGE = (0.30, 0.50)
GINI_WITHIN_RANGE = (0.20, 0.40)
WAR_SUPPLY_RANGE = (0.60, 0.80)
BANKRUPT_SURVIVE_RANGE = (0.40, 0.60)
EFFECTIVE_NATIONS_RANGE = (0.40, 0.70)   # 초기 대비
EMPIRE_FORMATION_MIN = 0.60              # 20런 중 12런
EMPIRE_DISSOLUTION_RANGE = (0.40, 0.70)
GINI_INVEST_GATE = 0.25                  # M15 투자층 착수 조건
EMPIRE_CONFIRM_TURNS_M12 = 24            # M12 의 강화된 유지 턴
EFFECTIVE_MIN_PROVINCES = 3              # 실효 국가 — batch_sim.gd 와 같은 정의


def verdict(ok: bool) -> str:
    return "PASS" if ok else "FAIL"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--plot", help="인프라/GDP 추이 PNG 경로")
    ap.add_argument("--defaults", help="파산 이벤트 CSV (기본: <csv>_defaults.csv)")
    ap.add_argument("--events", help="신용 이벤트 CSV (기본: <csv>_credit_events.csv)")
    ap.add_argument("--nations", help="국가 생애 CSV (기본: <csv>_nations.csv)")
    ap.add_argument("--empires", help="제국 에피소드 CSV (기본: <csv>_empires.csv)")
    args = ap.parse_args()

    df = pd.read_csv(args.csv)
    last = df[df.turn == df.turn.max()]
    runs = df.seed.nunique()

    print(f"runs={runs}  turns={df.turn.max()}  provinces={last.provinces.mean():.0f}"
          f"  nations={last.nations.mean():.0f}")

    worst_pop = df.pop_error_pct.abs().max()
    # hard 는 런 단위 누적 카운터다 (M11). 샘플 행마다 같은 값이 반복되므로 시드별 최대만 센다.
    hard = int(df.groupby("seed").hard_anchor_violations.max().sum())
    over_turns = int(df.anchor_over_turns_max.max()) if "anchor_over_turns_max" in df else -1
    soft_after_start = int(df[df.turn > 0].soft_anchor_violations.sum())

    print("\n[M3 완료 기준]")
    print(f"  앵커 위로 gdp_pc 상승 (불변식)     : {hard}  {verdict(hard == 0)}")
    print(f"  앵커 초과 최장 지속 (과도, 참고)   : {over_turns}턴")
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
        # 대역 판정은 실효 국가(파산 시점 프로빈스 >= 3) 기준이다. 1프로빈스 잔존국은
        # 세계가 아직 멀쩡할 때 먼저 무너지므로 전체 기준은 늘 대역 아래로 끌린다.
        eff_defaults = defaults[defaults.provinces >= EFFECTIVE_MIN_PROVINCES]
        first_all = defaults.groupby("seed").turn.min()
        for label, rows in (("실효", eff_defaults), ("전체", defaults)):
            if rows.empty:
                print(f"  첫 파산 턴 ({label})         : 없음  FAIL")
                continue
            first = rows.groupby("seed").turn.min()
            ok = FIRST_DEFAULT_RANGE[0] <= first.mean() <= FIRST_DEFAULT_RANGE[1]
            print(f"  첫 파산 턴 ({label})         : 평균 {first.mean():.1f}  "
                  f"중앙값 {first.median():.1f}  [{first.min()}, {first.max()}]  "
                  f"시드 {len(first)}/{runs}  "
                  f"{verdict(ok) if label == '실효' else '(참고)'}")
        print(f"  50턴 이전 첫 파산 시드    : {int((first_all < 50).sum())}개 (전체 기준)")
        print(f"  총 파산 / 재파산 국가     : {len(defaults)} / "
              f"{int((defaults.groupby(['seed', 'nation']).size() > 1).sum())}"
              f"  (실효 파산 {len(eff_defaults)}건)")

    # §6.2 의 기준은 *최대* 국가 부채/GDP < 10 이다. mean 을 보면 최대 96 이어도
    # 통과한다 — 1차가 404 를 FAIL 로 적어 놓고도 이 줄은 PASS 를 찍고 있었다.
    #
    # 다만 최대값 하나에는 두 가지가 섞인다. 영토를 잃어 GDP 가 무너진 나라는
    # 파산이 발동하기까지 2~3턴 동안 비율이 수천까지 뛴다 — 부채가 는 것이 아니라
    # 분모가 사라진 것이고, 파산하면 탕감으로 3.5 이하가 된다. 만성 채무는
    # *정상국*(화폐 발행도 파산 유예도 아닌 나라)에서 재야 한다.
    over_turns = int(_col(df, "debt_over_turns_max_eff").max())
    agg_eff = _col(df, "agg_debt_ratio_eff")
    agg_ok = bool(agg_eff.notna().all() and agg_eff.max() < DEBT_RATIO_MAX)
    chronic_ok = over_turns <= DEBT_OVER_TURNS_MAX
    print(f"  평균 부채/GDP ({df.turn.max()}턴)     : "
          f"실효 {_col(last, 'mean_debt_ratio_eff').mean():.3f}  "
          f"중앙값 {_col(last, 'median_debt_ratio_eff').mean():.3f}"
          f"   (전체 {last.mean_debt_ratio.mean():.3f} / "
          f"{last.median_debt_ratio.mean():.3f})")
    print(f"  집계 부채/GDP (총부채/총GDP): 실효 {_col(last, 'agg_debt_ratio_eff').mean():.3f}  "
          f"최대 {agg_eff.max():.3f}  [< {DEBT_RATIO_MAX}]  {verdict(agg_ok)}"
          f"   (전체 {df.agg_debt_ratio.max():.3f})")
    print(f"  {DEBT_RATIO_MAX:.0f}배 초과 최장 지속       : 실효 {over_turns}턴  "
          f"[<= {DEBT_OVER_TURNS_MAX}]  {verdict(chronic_ok)}"
          f"   (전체 {int(df.debt_over_turns_max.max())}턴)")
    print(f"  최대 부채/GDP (참고)        : "
          f"실효 {_col(df, 'max_debt_ratio_eff').max():.3f}   "
          f"(전체 {df.max_debt_ratio.max():.3f} — 영토 상실 직후 분모 붕괴 포함)")
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

    _report_m11(args, df, last, runs, defaults)

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


def _sidecar(args, name: str, override: str | None) -> pd.DataFrame:
    path = Path(override) if override else Path(args.csv).with_name(
        Path(args.csv).stem + f"_{name}.csv")
    return pd.read_csv(path) if path.exists() else pd.DataFrame()


def _band(label: str, value: float, lo: float, hi: float, fmt: str = ".4f") -> None:
    ok = lo <= value <= hi
    print(f"  {label:<28}: {value:{fmt}}  [{lo}~{hi}]  {verdict(ok)}")


def _band2(label: str, eff: float, whole: float, lo: float, hi: float,
           fmt: str = ".4f") -> bool:
    """M12 이중 산출. 판정은 실효 국가 기준, 전체는 괄호 참고값이다."""
    ok = lo <= eff <= hi
    print(f"  {label:<28}: 실효 {eff:{fmt}}  [{lo}~{hi}]  {verdict(ok)}"
          f"   (전체 {whole:{fmt}})")
    return ok


def _col(df: pd.DataFrame, name: str) -> pd.Series:
    """_eff 열이 없는 구 CSV 도 읽히게 한다 (M11 이전 산출물 대조용)."""
    return df[name] if name in df.columns else df[name.removesuffix("_eff")]


def _report_m11(args, df: pd.DataFrame, last: pd.DataFrame, runs: int,
                defaults: pd.DataFrame) -> None:
    horizon = int(df.turn.max())
    nations = _sidecar(args, "nations", args.nations)
    empires = _sidecar(args, "empires", args.empires)

    print("\n[M11.1 미측정 지표 4종 — M12 이중 산출]")
    gini_between = _col(last, "gini_between_eff").mean()
    _band2("1인당 GDP 지니 (국가 간)", gini_between, last.gini_between.mean(),
           *GINI_BETWEEN_RANGE)
    _band2("1인당 GDP 지니 (국가 내)", _col(last, "gini_within_eff").mean(),
           last.gini_within.mean(), *GINI_WITHIN_RANGE)

    # 보급은 야전군이 실제로 있는 샘플만 센다. 군대 0인 샘플의 0.0 이 평균을 끌어내린다.
    def _supply(mean_col: str, count_col: str) -> float | None:
        rows = df[_col(df, count_col) > 0]
        if rows.empty:
            return None
        w = _col(rows, count_col)
        return float((_col(rows, mean_col) * w).sum() / w.sum())

    supply_eff = _supply("war_supply_mean_eff", "war_armies_eff")
    supply_all = _supply("war_supply_mean", "war_armies")
    if supply_eff is None or supply_all is None:
        print("  전쟁 중 평균 보급률         : 표본 없음  FAIL")
    else:
        _band2("전쟁 중 평균 보급률", supply_eff, supply_all, *WAR_SUPPLY_RANGE)

    if nations.empty or defaults.empty:
        print("  파산 후 생존율              : 표본 없음  FAIL")
    else:
        death = nations.set_index(["seed", "nation"]).death_turn

        def _survive(rows: pd.DataFrame, window: int) -> float | None:
            rows = rows[rows.turn + window <= horizon]
            if rows.empty:
                return None
            d = rows.set_index(["seed", "nation"]).index.map(death)
            return float(((d < 0) | (d >= rows.turn.values + window)).mean())

        eff_defaults = defaults[defaults.provinces >= EFFECTIVE_MIN_PROVINCES]
        for window in (50, 100):
            eff = _survive(eff_defaults, window)
            whole = _survive(defaults, window)
            if eff is None or whole is None:
                print(f"  파산 후 {window}턴 생존율        : 관측 창 부족  --")
                continue
            _band2(f"파산 후 {window}턴 생존율", eff, whole, *BANKRUPT_SURVIVE_RANGE)
            print(f"    표본 실효 {len(eff_defaults[eff_defaults.turn + window <= horizon])}건"
                  f" / 전체 {len(defaults[defaults.turn + window <= horizon])}건")

    if nations.empty:
        print("  월경지 보유국 수명          : 표본 없음  FAIL")
    else:
        life = nations.copy()
        life["lifespan"] = life.death_turn.where(life.death_turn >= 0, horizon) - life.birth_turn
        # 반란 신생국은 1프로빈스로 태어나 대개 곧 죽고 월경지를 가질 일이 없다.
        # 섞으면 "월경지 보유국이 더 오래 산다" 는 반대 결론이 나온다 — 건국국가로 자른다.
        founding = life[life.birth_turn == 0]
        for label, pool in (("실효", founding[founding.peak_provinces
                                              >= EFFECTIVE_MIN_PROVINCES]),
                            ("전체", founding)):
            exc = pool[pool.ever_exclave == 1].lifespan
            main = pool[pool.ever_exclave == 0].lifespan
            if exc.empty or main.empty:
                print(f"  월경지 보유국 수명 ({label})  : 한쪽 표본 없음  --")
                continue
            shorter = exc.mean() < main.mean()
            print(f"  월경지/본토 평균 수명 ({label}): {exc.mean():.1f}턴 (n={len(exc)}) vs "
                  f"{main.mean():.1f}턴 (n={len(main)})  "
                  f"{verdict(shorter) if label == '실효' else '(참고)'}"
                  f" (월경지가 더 짧을 것)")
        born = life[life.birth_turn > 0]
        print(f"    건국 {len(founding)}개 / 반란 신생 {len(born)}개"
              f"(평균 수명 {born.lifespan.mean():.1f}턴)")
        print(f"    * 관측 창 {horizon}턴에서 절단됨 — 생존국은 수명이 과소평가된다")

    print("\n[M11.2 100턴 단위 스냅샷]")
    cols = dict(실효국가=("effective_nations", "mean"), 전체국가=("nations", "mean"),
                최대영토=("max_realm_provinces", "mean"),
                최대GDP점유=("max_realm_share", "mean"),
                제국=("empires_active", "mean"), 지니간=("gini_between", "mean"))
    if "empires_active_24" in df.columns:
        cols["제국24"] = ("empires_active_24", "mean")
    if "gini_between_eff" in df.columns:
        cols["지니간실효"] = ("gini_between_eff", "mean")
    snaps = df[df.turn % 100 == 0].groupby("turn").agg(**cols)
    print(snaps.to_string(float_format=lambda v: f"{v:.3f}"))

    start = df[df.turn == 0].effective_nations.mean()
    end = last.effective_nations.mean()
    retention = end / max(start, 1)
    _band2(f"국가 수 ({horizon}턴) / 초기", retention,
           last.nations.mean() / max(df[df.turn == 0].nations.mean(), 1),
           *EFFECTIVE_NATIONS_RANGE)
    print(f"    실효 초기 {start:.1f} → {horizon}턴 {end:.1f}"
          f"  (전체 {df[df.turn == 0].nations.mean():.1f} → {last.nations.mean():.1f})")

    # 에피소드 로그는 유지 12턴(느슨한 쪽)으로 남는다. duration 은 후보 진입부터
    # 조건 이탈까지의 연속 턴 수와 같으므로 duration >= 24 필터가 유지 24턴 정의와
    # 정확히 일치한다 — 재실행 없이 M12 정의를 재도출할 수 있다.
    print("\n[M11.2 제국 생애사 — 판정은 M12 정의(유지 24턴)]")
    m12 = empires[empires.duration >= EMPIRE_CONFIRM_TURNS_M12] if not empires.empty \
        else empires
    if m12.empty:
        print(f"  형성 런 (유지 {EMPIRE_CONFIRM_TURNS_M12}턴)        : 0/{runs}  FAIL")
        if not empires.empty:
            print(f"  형성 런 (유지 12턴, 참고)   : {len(empires)}건 / "
                  f"{empires.seed.nunique()}런")
        formed_ratio = 0.0
        gate_empire = False
    else:
        for label, keep in ((f"유지 {EMPIRE_CONFIRM_TURNS_M12}턴 (M12 정의)", m12),
                            ("유지 12턴 (1차 정의, 참고)", empires)):
            seeds = keep.seed.nunique()
            mark = verdict(seeds / runs >= EMPIRE_FORMATION_MIN) \
                if keep is m12 else "(참고)"
            print(f"  {label:<26}: {len(keep)}건 / {seeds}런 "
                  f"({seeds / runs * 100:.0f}%)  {mark}")
        formed_ratio = m12.seed.nunique() / runs
        gate_empire = formed_ratio >= EMPIRE_FORMATION_MIN
        print(f"  존속 턴                     : 중앙값 {m12.duration.median():.0f}  "
              f"최대 {m12.duration.max()}")
        print(f"  최대 realm 점유             : {m12.peak_realm_share.max():.4f}")
        # horizon 은 관측 창 끝에서 잘린 에피소드다. 스펙의 "관측 창 내 해체 비율" 은
        # 이것을 미해체로 세는 쪽이므로 그쪽으로 판정하고, 우측절단 제외값을 병기한다.
        dissolved = m12[m12.reason != "horizon"]
        censored = int((m12.reason == "horizon").sum())
        rate = len(dissolved) / len(m12)
        _band("제국 해체율 (관측 창 기준)", rate, *EMPIRE_DISSOLUTION_RANGE)
        closed = len(m12) - censored
        if closed > 0:
            print(f"    우측절단 제외 시          : {len(dissolved) / closed:.4f}  "
                  f"(절단 {censored}건 제외, n={closed})")
        print("  해체 원인                   : "
              + ", ".join(f"{k}={v}" for k, v in m12.reason.value_counts().items()))

    print("\n[M11 게이트 판정 — M12 지표 기준]")
    print(f"  제국 형성률 {formed_ratio * 100:.0f}% "
          f"(유지 {EMPIRE_CONFIRM_TURNS_M12}턴, 기준 {EMPIRE_FORMATION_MIN * 100:.0f}%)")
    print(f"  실효 국가 잔존률 {retention * 100:.0f}%")
    print(f"  지니(국가 간, 실효) {gini_between:.4f} "
          f"(M15 착수 조건 ≥ {GINI_INVEST_GATE})")
    if gate_empire:
        print("  → §6.1 은 관측 창 문제였다. M14 취소 유력, M13 은 유지")
    elif not empires.empty:
        print("  → 제국은 서지만 대역 미달. M13 이후 재판정, M14 는 축소 실행(C안)")
    else:
        print("  → 구조적 문제 확정. M13 → M14 전면 실행")
    if gini_between < GINI_INVEST_GATE:
        print("  → M15 투자층 보류. M13 지도 교체가 편차를 만든 뒤 재판정")
    else:
        print("  → M15 투자층 착수 가능")


if __name__ == "__main__":
    main()
