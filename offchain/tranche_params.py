"""
TrancheHook: Monte Carlo derivation of buffer (B) and alpha (a)  [revised: 1 + 3, tick-native range]

Economic model: shared fund pool (assumes equal tranches S:J=1)
  - The hook captures all swap fees F (= fee_rate x turnover, relative to principal) into the fund
  - The fund is split between Junior:Senior as a:(1-a)
  - Senior protection (up to buffer) is funded from the Junior share of the fund (Junior principal is untouched)

---------------------------------------------------------------------
[Range parameterization] tick-native (matches the on-chain position 1:1)
  The LP range is given as Uniswap ticks. The pool is assumed initialized at tick 0
  (entry price = 1.0), so price(tick) = 1.0001^tick and the modeled range maps directly
  to the on-chain position deployed at the same [tick_lower, tick_upper].
  Ticks must be multiples of the pool's tickSpacing (60 for a 0.30% fee pool) to be valid on-chain.

[Fix 3] Fee normalization and the plain baseline
  Equal tranches (half of each capital is Senior/Junior), fee conservation:
    - A matched pair (Senior 1 + Junior 1, 2 units) earns fees = 2F
    - Junior pool = a*2F, Senior pool = (1-a)*2F   ->  per unit: Senior = 2(1-a)F, Junior = 2aF
    - A plain LP earns the full raw pool fee: R_plain = F - IL
  Conservation: matched pair total = 2F - 2*E[IL] = 2 units of plain ✓ (general S:J is an extension)

[Fix 1] Junior risk premium
  Forcing R_senior = R_junior leaves Junior dominated (same return, higher risk). Give Junior a premium:
    D = lambda * max(sigma_junior - sigma_senior, 0)   (lambda = price of risk, Sharpe-like)
    sigma_senior = std(residual), sigma_junior = std(IL + absorbed)   (independent of a, non-circular)
  -> Solve R_junior = R_senior + D. lambda=0 reproduces the old "equal return" case.

Derivation (equal tranches):
  R_senior = 2(1-a)F - R_resid ;  R_junior = 2aF - E[IL] - E[absorbed]
  R_junior = R_senior + D  =>  a = 0.5 + E[absorbed]/(2F) + D/(4F)
  D=0  =>  a = 0.5 + E[absorbed]/(2F) = DL/(2F)+0.5  (matches the documented formula)
---------------------------------------------------------------------
"""

import numpy as np

TICK_BASE = 1.0001  # Uniswap v3/v4: price(tick) = 1.0001^tick


# ──────────────────────────────────────────────────────────────────
# Tick <-> price helpers (match Uniswap TickMath; price(tick) = 1.0001^tick)
# ──────────────────────────────────────────────────────────────────
def tick_to_price(tick):
    return TICK_BASE ** tick


def price_to_tick(price):
    """Nearest tick below `price` (floor). For reference / converting a desired price band to ticks."""
    return int(np.floor(np.log(price) / np.log(TICK_BASE)))


def align_tick(tick, spacing=60):
    """Snap a tick down to a multiple of `spacing` (valid on-chain tick for that pool)."""
    return (int(np.floor(tick / spacing))) * spacing


# ──────────────────────────────────────────────────────────────────
# Concentrated-liquidity IL (same logic as Solidity ILMath.ilFromSqrtPrices); unchanged
# ──────────────────────────────────────────────────────────────────
def il_concentrated(P_entry, P_cur, P_L, P_U):
    """Price-ratio based concentrated-liquidity IL. IL = 1 - V_LP / V_HODL (token1-denominated, L=1)."""
    spE = np.sqrt(P_entry)
    spC = np.sqrt(P_cur)
    spL = np.sqrt(P_L)
    spU = np.sqrt(P_U)

    def amounts(sp):
        spc = np.clip(sp, spL, spU)
        x = (1.0 / spc - 1.0 / spU)  # token0 amount (L=1)
        y = (spc - spL)              # token1 amount (L=1)
        return x, y

    x0, y0 = amounts(np.full_like(spC, spE) if np.ndim(spC) else spE)
    V_hodl = x0 * P_cur + y0                      # entry amounts valued at the current price
    xC, yC = amounts(spC)
    V_lp = xC * P_cur + yC                         # current amounts valued at the current price
    il = 1.0 - V_lp / V_hodl
    return np.maximum(il, 0.0)


# ──────────────────────────────────────────────────────────────────
# Generate the IL distribution  [range now given as on-chain ticks]
# ──────────────────────────────────────────────────────────────────
def il_distribution(sigma, T_days, tick_lower, tick_upper, N=500_000, seed=42):
    """
    Range is given as Uniswap ticks. Pool assumed initialized at tick 0 (entry price = 1.0),
    so (tick_lower, tick_upper) maps 1:1 to the on-chain LP position deployed at the same ticks.
    Smaller |range| = narrower = higher concentration = larger IL.
    """
    rng = np.random.default_rng(seed)
    T = T_days / 365.0
    P_entry = 1.0  # tick 0
    # Price ratio r ~ lognormal. drift=-sigma^2 T/2 is the martingale adjustment making E[P]=P_entry.
    mu = -0.5 * sigma**2 * T
    P_cur = rng.lognormal(np.log(P_entry) + mu, sigma * np.sqrt(T), N)

    P_L = tick_to_price(tick_lower)
    P_U = tick_to_price(tick_upper)
    return il_concentrated(P_entry, P_cur, P_L, P_U)


# ──────────────────────────────────────────────────────────────────
# Derive buffer and alpha  [unchanged: range-agnostic]
# ──────────────────────────────────────────────────────────────────
def derive_buffer_alpha(il_samples, F, buffer_percentile, lambda_risk=0.30):
    """lambda_risk: price of the Junior premium (Sharpe-like). 0 = old "equal return". Equal tranches S:J=1."""
    EL = il_samples.mean()                             # E[IL]
    B = np.percentile(il_samples, buffer_percentile)   # buffer

    absorbed = np.minimum(il_samples, B)               # Junior absorption (per sample)
    residual = np.maximum(il_samples - B, 0.0)         # Senior residual loss (per sample)
    E_absorbed = absorbed.mean()
    R_resid = residual.mean()

    # [1] Risk premium D = lambda*max(sigma_J - sigma_S, 0). sigma independent of a (constant term drops out).
    sigma_senior = residual.std()                      # std(R_senior) = std(residual)
    sigma_junior = (il_samples + absorbed).std()       # std(R_junior) = std(IL+absorbed)
    premium = lambda_risk * max(sigma_junior - sigma_senior, 0.0)

    # [1+3] alpha for equal tranches: a = 0.5 + E_absorbed/(2F) + premium/(4F)
    alpha = 0.5 + E_absorbed / (2.0 * F) + premium / (4.0 * F)

    R_senior = 2.0 * (1 - alpha) * F - R_resid
    R_junior = 2.0 * alpha * F - EL - E_absorbed

    physical_ok = (0.5 < alpha < 1.0)
    fund_ok = (E_absorbed <= 2.0 * alpha * F)
    profit_ok = (R_senior > 0) and (R_junior > 0)
    premium_ok = (R_junior >= R_senior - 1e-12)
    feasible = physical_ok and fund_ok and profit_ok and premium_ok

    return dict(
        EL=EL, B=B, alpha=alpha, premium=premium,
        E_absorbed=E_absorbed, R_resid=R_resid,
        sigma_senior=sigma_senior, sigma_junior=sigma_junior,
        R_senior=R_senior, R_junior=R_junior,
        physical_ok=physical_ok, fund_ok=fund_ok,
        profit_ok=profit_ok, premium_ok=premium_ok, feasible=feasible,
        fund_capacity=2.0 * alpha * F,
    )


# ──────────────────────────────────────────────────────────────────
# Risk metrics  [unchanged: plain = full F]
# ──────────────────────────────────────────────────────────────────
def risk_metrics(il_samples, F, B, alpha):
    """Risk metrics for each tranche and a plain LP (equal tranches S:J=1)."""
    absorbed = np.minimum(il_samples, B)
    residual = np.maximum(il_samples - B, 0.0)

    R_senior = 2.0 * (1 - alpha) * F - residual
    R_junior = 2.0 * alpha * F - il_samples - absorbed
    R_plain = F - il_samples

    def stat(R):
        return dict(mean=R.mean(), std=R.std(),
                    p05=np.percentile(R, 5), p01=np.percentile(R, 1),
                    loss_prob=(R < 0).mean())
    return dict(senior=stat(R_senior), junior=stat(R_junior), plain=stat(R_plain))


# ──────────────────────────────────────────────────────────────────
# Charts (the PNGs referenced from the READMEs)
# ──────────────────────────────────────────────────────────────────
def save_charts(il_samples, B, buffer_pct, rm, outdir="."):
    import os
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    COLORS = {"senior": "#2EC4B6", "plain": "#94A3B8", "junior": "#FF6B6B"}

    def style(ax):
        for side in ("top", "right"):
            ax.spines[side].set_visible(False)
        ax.grid(axis="y", alpha=0.25)

    # money_chart.png — risk vs return of the three profiles
    fig, ax = plt.subplots(figsize=(7.6, 4.6), dpi=150)
    profiles = [("Senior", "senior"), ("Plain LP", "plain"), ("Junior", "junior")]
    xs = [rm[k]["std"] * 100 for _, k in profiles]
    ys = [rm[k]["mean"] * 100 for _, k in profiles]
    ax.plot(xs, ys, "--", color="#CBD5E1", lw=1.2, zorder=1)
    for (name, k), x, y in zip(profiles, xs, ys):
        ax.scatter(x, y, s=180, color=COLORS[k], edgecolor="white", lw=1.5, zorder=2)
        ax.annotate(f"{name}\n{y:+.2f}%  ·  P(loss) {rm[k]['loss_prob']:.1%}",
                    (x, y), textcoords="offset points", xytext=(12, -8), fontsize=9)
    ax.set_xlabel("Risk — std of period return (%)")
    ax.set_ylabel("Expected period return (%)")
    ax.set_title("Same pool, same fees — three risk profiles", fontsize=11)
    ax.margins(x=0.25, y=0.25)
    style(ax)
    fig.tight_layout()
    money_path = os.path.join(outdir, "money_chart.png")
    fig.savefig(money_path)
    plt.close(fig)

    # il_distribution.png — simulated IL with the buffer at the chosen percentile
    fig, ax = plt.subplots(figsize=(6.2, 4.0), dpi=150)
    vals = il_samples * 100
    clip = np.percentile(vals, 99.5)
    bins = np.linspace(0, clip, 121)
    ax.hist(vals[vals <= B * 100], bins=bins, color="#2EC4B6", alpha=0.8,
            label="absorbed by Junior (Senior whole)")
    ax.hist(vals[(vals > B * 100) & (vals <= clip)], bins=bins, color="#FF6B6B", alpha=0.8,
            label="tail beyond B (Senior residual)")
    ax.axvline(B * 100, color="#475569", ls="--", lw=1.4)
    ax.text(B * 100, ax.get_ylim()[1] * 0.97,
            f"  buffer B = {B * 100:.2f}% ({buffer_pct}th pct)",
            color="#475569", va="top", fontsize=9)
    ax.legend(frameon=False, fontsize=9, loc="center right")
    ax.set_xlabel("Impermanent loss (% of principal)")
    ax.set_ylabel("Simulated paths")
    ax.set_title("Simulated IL distribution and the protection buffer", fontsize=11)
    style(ax)
    fig.tight_layout()
    il_path = os.path.join(outdir, "il_distribution.png")
    fig.savefig(il_path)
    plt.close(fig)

    return money_path, il_path


# ──────────────────────────────────────────────────────────────────
# Main: sweet-spot search
# ──────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    SIGMA = 0.60
    HOOK_FEE_RATE = 0.003
    BUFFER_PCT = 90       # design knob: protect Senior up to the 90th percentile
    LAMBDA = 0.30         # [1] price of the Junior risk premium
    TICK_SPACING = 60     # 0.30% fee pool

    # Symmetric tick half-widths (multiples of TICK_SPACING -> valid on-chain ranges).
    # Smaller = tighter range = larger IL.
    TICK_HALFWIDTHS = [6000, 3000, 1200]

    print("=" * 108)
    print(f" buffer/alpha derivation (sigma={SIGMA:.0%}, fee={HOOK_FEE_RATE:.2%}, buffer={BUFFER_PCT}%ile, lambda={LAMBDA})")
    print(" tick-native range (pool at tick 0) / equal tranches S:J=1 / Junior risk premium / plain=full-F")
    print("=" * 108)

    for T_days in [30, 90]:
        for hw in TICK_HALFWIDTHS:
            tl, tu = -hw, +hw
            il = il_distribution(SIGMA, T_days, tl, tu)
            print(f"--- T={T_days}d  ticks[{tl:+d}, {tu:+d}]  price[{tick_to_price(tl):.4f}, {tick_to_price(tu):.4f}] ---")
            print(f"{'turn':>5}{'E[IL]':>8}{'F':>7}{'B':>8}{'a':>7}{'prem':>8}"
                  f"{'phys':>6}{'fund':>6}{'prof':>6}{'prem?':>6}{'sat':>5}{'R_S':>9}{'R_J':>9}")
            for turnover in [5, 10, 20, 40]:
                F = HOOK_FEE_RATE * turnover
                r = derive_buffer_alpha(il, F, BUFFER_PCT, LAMBDA)
                astr = f"{r['alpha']:.3f}" if r['alpha'] < 2 else ">1"
                print(f"{turnover:>5}{r['EL']:>8.4f}{F:>7.3f}{r['B']:>8.4f}{astr:>7}{r['premium']:>8.4f}"
                      f"{'OK' if r['physical_ok'] else 'NG':>6}"
                      f"{'OK' if r['fund_ok'] else 'NG':>6}"
                      f"{'OK' if r['profit_ok'] else 'NG':>6}"
                      f"{'OK' if r['premium_ok'] else 'NG':>6}"
                      f"{'Y' if r['feasible'] else 'N':>5}"
                      f"{r['R_senior']:>9.4f}{r['R_junior']:>9.4f}")
            print()

    # ── Representative sweet spot (with risk metrics) ──
    REP_HW = 6000
    REP_TURN = 20
    tl, tu = -REP_HW, +REP_HW
    print("=" * 108)
    print(f" Representative case: T=30d, ticks[{tl:+d}, {tu:+d}] "
          f"(price[{tick_to_price(tl):.4f}, {tick_to_price(tu):.4f}]), turnover={REP_TURN}x")
    print(" -> deploy the on-chain position at exactly these ticks (pool initialized at tick 0)")
    print("=" * 108)
    il = il_distribution(SIGMA, 30, tl, tu)
    F = HOOK_FEE_RATE * REP_TURN
    r = derive_buffer_alpha(il, F, BUFFER_PCT, LAMBDA)
    print(f"  Derived: B = {r['B']:.4f} ({r['B']*100:.2f}% of principal)   ->  BUFFER_WAD = {int(round(r['B']*1e18))}")
    print(f"           a = {r['alpha']:.4f}  (Junior {r['alpha']*100:.1f}% / Senior {(1-r['alpha'])*100:.1f}%)"
          f"   ->  ALPHA_WAD  = {int(round(r['alpha']*1e18))}")
    print(f"           premium D = {r['premium']:.4f}  (sigma_J={r['sigma_junior']:.4f}, sigma_S={r['sigma_senior']:.4f})")
    print(f"  E[IL]={r['EL']:.4f}  E[absorbed]={r['E_absorbed']:.4f}  Senior residual={r['R_resid']:.4f}")
    print(f"  Expected return: Senior={r['R_senior']:+.4f}  Junior={r['R_junior']:+.4f}"
          f"  (Junior-Senior={r['R_junior']-r['R_senior']:+.4f})")
    print(f"  feasible: {r['feasible']}")
    print()
    rm = risk_metrics(il, F, r['B'], r['alpha'])
    print(f"  {'':8}{'mean R':>9}{'std dev':>10}{'p05':>9}{'p01':>9}{'loss prob':>11}")
    for name, key in [("Senior", "senior"), ("Plain LP", "plain"), ("Junior", "junior")]:
        s = rm[key]
        print(f"  {name:8}{s['mean']:>+9.4f}{s['std']:>10.4f}{s['p05']:>+9.4f}{s['p01']:>+9.4f}{s['loss_prob']:>10.1%}")

    import os
    charts = save_charts(il, r['B'], BUFFER_PCT, rm, outdir=os.path.dirname(os.path.abspath(__file__)))
    print()
    print(f"  charts: {charts[0]}")
    print(f"          {charts[1]}")