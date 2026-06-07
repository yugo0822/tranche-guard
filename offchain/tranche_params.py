"""
TrancheHook: Monte Carlo derivation of buffer (B) and alpha (a)  [revised: 1 + 3]

Economic model: shared fund pool (assumes equal tranches S:J=1)
  - The hook captures all swap fees F (= fee_rate x turnover, relative to principal) into the fund
  - The fund is split between Junior:Senior as a:(1-a)
  - Senior protection (up to buffer) is funded from the Junior share of the fund (Junior principal is untouched)

---------------------------------------------------------------------
[Fix 3] Fee normalization and the plain baseline
  The original script used 0.5F for plain, which had no basis and unfairly made the tranche side look better.
  With equal tranches (half of each capital is Senior/Junior), correctly enforcing fee conservation gives:
    - A matched pair (Senior 1 + Junior 1, 2 units total) earns fees = 2F
    - Junior pool = a*2F, Senior pool = (1-a)*2F
    - Therefore per unit:  Senior = 2(1-a)F,  Junior = 2aF
    - A plain LP earns the full raw pool fee: R_plain = F - IL
  Conservation check: total return of a matched pair = 2F - 2*E[IL] = matches 2 units of plain ✓
  Note: a general S:J ratio is an extension of step 2 (this script assumes S:J=1).

[Fix 1] Junior risk premium
  If we force R_senior = R_junior, Junior becomes "same return at higher risk" = dominated, so nobody picks it.
  Give Junior a premium D as compensation for first-loss:
    D = lambda * max(sigma_junior - sigma_senior, 0)     (lambda = price of risk, a Sharpe-like knob)
    sigma_senior = std(residual),  sigma_junior = std(IL + absorbed)   (independent of a, hence non-circular)
  -> Solve R_junior = R_senior + D to derive a. With lambda=0 this matches the old "equal return" case.

Derivation (equal tranches):
  R_senior = 2(1-a)F - R_resid
  R_junior = 2aF - E[IL] - E[absorbed]
  Solving R_junior = R_senior + D gives:
    a = 0.5 + E[absorbed]/(2F) + D/(4F)
  When D=0, a = 0.5 + E[absorbed]/(2F) = DL/(2F)+0.5  <- matches the documented formula
---------------------------------------------------------------------
"""

import numpy as np


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
# Generate the IL distribution
# ──────────────────────────────────────────────────────────────────
def il_distribution(sigma, T_days, range_halfwidth, N=500_000, seed=42):
    """range_halfwidth: range half-width. Smaller = narrower range = higher concentration = larger IL."""
    rng = np.random.default_rng(seed)
    T = T_days / 365.0
    P_entry = 1.0
    # Price ratio r ~ lognormal. drift=-sigma^2 T/2 is the martingale adjustment making E[P]=P_entry
    #   (note: this sets the mean to P_entry. The median is P_entry*e^{-sigma^2 T/2} < P_entry.)
    mu = -0.5 * sigma**2 * T
    P_cur = rng.lognormal(np.log(P_entry) + mu, sigma * np.sqrt(T), N)

    P_L = P_entry * (1.0 - range_halfwidth)
    P_U = P_entry * (1.0 + range_halfwidth)
    return il_concentrated(P_entry, P_cur, P_L, P_U)


# ──────────────────────────────────────────────────────────────────
# Derive buffer and alpha  [reflects 1: premium + 3: normalization]
# ──────────────────────────────────────────────────────────────────
def derive_buffer_alpha(il_samples, F, buffer_percentile, lambda_risk=0.30):
    """
    lambda_risk: price of the Junior premium (Sharpe-like). 0 reproduces the old "equal return".
    Assumes equal tranches (S:J=1).
    """
    EL = il_samples.mean()                             # E[IL]
    B = np.percentile(il_samples, buffer_percentile)   # buffer

    absorbed = np.minimum(il_samples, B)               # Junior absorption (per sample)
    residual = np.maximum(il_samples - B, 0.0)         # Senior residual loss (per sample)
    E_absorbed = absorbed.mean()
    R_resid = residual.mean()

    # [1] Risk premium D = lambda*max(sigma_J - sigma_S, 0). sigma is independent of a (constant term drops out).
    sigma_senior = residual.std()                      # std(R_senior) = std(residual)
    sigma_junior = (il_samples + absorbed).std()       # std(R_junior) = std(IL+absorbed)
    premium = lambda_risk * max(sigma_junior - sigma_senior, 0.0)

    # [1+3] alpha for equal tranches (solving R_junior = R_senior + premium)
    #   a = 0.5 + E_absorbed/(2F) + premium/(4F)
    alpha = 0.5 + E_absorbed / (2.0 * F) + premium / (4.0 * F)

    # Expected returns (per unit, including the factor of 2 for equal tranches)
    R_senior = 2.0 * (1 - alpha) * F - R_resid
    R_junior = 2.0 * alpha * F - EL - E_absorbed

    # Feasibility checks
    physical_ok = (0.5 < alpha < 1.0)
    fund_ok = (E_absorbed <= 2.0 * alpha * F)          # absorption <= Junior fee budget (2aF)
    profit_ok = (R_senior > 0) and (R_junior > 0)
    premium_ok = (R_junior >= R_senior - 1e-12)        # Junior is not dominated
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
# Risk metrics (evidence that the tranching works)  [3: plain = full F]
# ──────────────────────────────────────────────────────────────────
def risk_metrics(il_samples, F, B, alpha):
    """Risk metrics for the return distributions of each tranche and a plain LP (equal tranches S:J=1)."""
    absorbed = np.minimum(il_samples, B)
    residual = np.maximum(il_samples - B, 0.0)

    R_senior = 2.0 * (1 - alpha) * F - residual    # [3] factor 2
    R_junior = 2.0 * alpha * F - il_samples - absorbed
    R_plain = F - il_samples                        # [3] a plain LP earns the full fee F

    def stat(R):
        return dict(mean=R.mean(), std=R.std(),
                    p05=np.percentile(R, 5), p01=np.percentile(R, 1),
                    loss_prob=(R < 0).mean())
    return dict(senior=stat(R_senior), junior=stat(R_junior), plain=stat(R_plain))


# ──────────────────────────────────────────────────────────────────
# Main: sweet-spot search
# ──────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    SIGMA = 0.60
    FEE_RATE = 0.003
    BUFFER_PCT = 90       # design knob: protect Senior up to the 90th percentile
    LAMBDA = 0.30         # [1] price of the Junior risk premium

    print("=" * 104)
    print(f" buffer/alpha derivation (sigma={SIGMA:.0%}, fee={FEE_RATE:.2%}, buffer={BUFFER_PCT}%ile, lambda={LAMBDA})")
    print(" assumes equal tranches S:J=1 / Junior given a risk premium / plain=full-F")
    print("=" * 104)
    print(f"{'T':>4}{'turn':>5}{'range':>7}{'E[IL]':>8}{'F':>7}{'B':>8}"
          f"{'a':>7}{'prem':>8}{'phys':>6}{'fund':>6}{'prof':>6}{'prem?':>6}{'sat':>6}"
          f"{'R_S':>9}{'R_J':>9}")

    for T_days in [30, 90]:
        for rng_hw in [0.5, 0.25, 0.1]:
            il = il_distribution(SIGMA, T_days, rng_hw)
            for turnover in [5, 10, 20, 40]:
                F = FEE_RATE * turnover
                r = derive_buffer_alpha(il, F, BUFFER_PCT, LAMBDA)
                astr = f"{r['alpha']:.3f}" if r['alpha'] < 2 else ">1"
                print(f"{T_days:>4}{turnover:>5}{rng_hw:>7.2f}{r['EL']:>8.4f}{F:>7.3f}"
                      f"{r['B']:>8.4f}{astr:>7}{r['premium']:>8.4f}"
                      f"{'OK' if r['physical_ok'] else 'NG':>6}"
                      f"{'OK' if r['fund_ok'] else 'NG':>6}"
                      f"{'OK' if r['profit_ok'] else 'NG':>6}"
                      f"{'OK' if r['premium_ok'] else 'NG':>6}"
                      f"{'Y' if r['feasible'] else 'N':>6}"
                      f"{r['R_senior']:>9.4f}{r['R_junior']:>9.4f}")
            print()

    # ── Detail for a representative sweet spot (with risk metrics) ──
    print("=" * 104)
    print(" Representative case detail: T=30d, range +/-0.5, turnover=20x")
    print("=" * 104)
    il = il_distribution(SIGMA, 30, 0.5)
    F = FEE_RATE * 20
    r = derive_buffer_alpha(il, F, BUFFER_PCT, LAMBDA)
    print(f"  Derived parameters: B (buffer) = {r['B']:.4f} ({r['B']*100:.2f}% of principal)")
    print(f"                      a (alpha)  = {r['alpha']:.4f}  -> Junior {r['alpha']*100:.1f}% / Senior {(1-r['alpha'])*100:.1f}%")
    print(f"                      premium D  = {r['premium']:.4f}  (sigma_J={r['sigma_junior']:.4f}, sigma_S={r['sigma_senior']:.4f})")
    print(f"  E[IL]={r['EL']:.4f}  E[absorbed]={r['E_absorbed']:.4f}  Senior residual loss={r['R_resid']:.4f}")
    print(f"  Expected return: Senior={r['R_senior']:+.4f}  Junior={r['R_junior']:+.4f}  (Junior-Senior={r['R_junior']-r['R_senior']:+.4f})")
    print()
    rm = risk_metrics(il, F, r['B'], r['alpha'])
    print(f"  {'':8}{'mean R':>9}{'std dev':>10}{'p05':>9}{'p01':>9}{'loss prob':>11}")
    for name, key in [("Senior", "senior"), ("Plain LP", "plain"), ("Junior", "junior")]:
        s = rm[key]
        print(f"  {name:8}{s['mean']:>+9.4f}{s['std']:>10.4f}{s['p05']:>+9.4f}"
              f"{s['p01']:>+9.4f}{s['loss_prob']:>10.1%}")
