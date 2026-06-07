# TrancheHook — Off-Chain Parameter Derivation

This directory contains the **actuarial engine** behind TrancheHook. It derives the two
on-chain risk parameters — the protection **buffer `B`** and the fee-split **`α`** — that
are injected into the hook at deployment.

> **TrancheHook in one line:** impermanent loss is not eliminated, it becomes a *choice*.
> **Senior** LPs buy downside protection; **Junior** LPs underwrite it for a premium.

The on-chain hook executes the tranche waterfall and settlement. *How* the buffer and
split are chosen — so that protection is solvent, both tranches are profitable, and Junior
is actually compensated for taking first-loss risk — is decided here, off-chain, from the
pair's volatility. This script is the bridge between the risk model and the contract.

---

## Pipeline

```
volatility σ + pool config
        │
        ▼
Monte Carlo IL distribution      (concentrated-liquidity, range-aware)
        │
        ▼
derive (B, α)                    (buffer percentile + fee-split solving R_J = R_S + premium)
        │
        ▼
feasibility + risk metrics       (is it solvent? is each tranche better off?)
        │
        ▼
constructor values               BUFFER_WAD, ALPHA_WAD, HOOK_FEE_WAD
```

---

## Economic model (recap)

A **shared-fund pool** model:

- The hook captures a small additive fee on each swap into a fund (denominated in `currency1`).
  Over the holding period this accumulates to `F` (expressed as a fraction of principal).
- The fund is split `α : (1 − α)` between **Junior** and **Senior**.
- **Senior** loss is absorbed up to the buffer `B` out of *Junior's* fund share — the cost of
  protection is spread across all Junior LPs, never drawn from Junior principal.
- **Junior** bears its own IL normally and underwrites Senior's protection, in exchange for the
  larger fee share `α` (which includes a risk premium, see below).

The premium is realized **purely as the fee-skew `α`** — there is no separate explicit premium
payment.

---

## Files

| File | Purpose |
|------|---------|
| `tranche_params.py` | Monte Carlo engine: IL distribution → `(B, α)` → feasibility + risk metrics |
| `requirements.txt`  | `numpy` |

---

## Quick start

```bash
pip install -r requirements.txt
python tranche_params.py
```

This prints (1) a sweet-spot search table over holding period, range width, and turnover, and
(2) a detailed breakdown of a representative case with per-tranche risk metrics.

---

## The derivation

### 1. Impermanent loss (concentrated liquidity)

IL is computed from the price ratio, range-aware, and **identical to the on-chain
`ILMath.ilFromSqrtPrices`**. The Uniswap v2 full-range formula is *not* used — it understates
IL by up to ~7.5× for narrow ranges.

For a position with liquidity `L` in range `[P_L, P_U]`, holding token amounts `(x, y)`:

$$V = x \cdot P + y \quad\text{(token1-denominated)}$$

$$\text{IL} = 1 - \frac{V_\text{LP}(P_\text{cur})}{V_\text{HODL}(P_\text{cur})}$$

where HODL values the **entry** token quantities at the current price, and LP values the
**current** (range-clamped) quantities at the current price.

### 2. Price model

Terminal price ratio is lognormal with the martingale (mean-preserving) drift adjustment:

$$P_\text{cur} = P_\text{entry}\cdot e^{\,\mathcal{N}(-\sigma^2 T/2,\; \sigma^2 T)}, \qquad \mathbb{E}[P_\text{cur}] = P_\text{entry}$$

(IL of a static position is path-independent, so a single terminal draw is sufficient.)

### 3. Tranche returns (equal tranches, S:J = 1)

Fees are conserved across the matched pair. Per unit of principal:

```
R_senior = 2(1 − α)·F − E[max(IL − B, 0)]      # fee share − residual loss above buffer
R_junior = 2α·F − E[IL] − E[min(IL, B)]         # fee share − own IL − protection paid out
R_plain  = F − IL                               # baseline: full fee, full IL, no protection
```

### 4. Junior risk premium

Equalizing expected returns (`R_S = R_J`) would leave Junior **dominated** — same return, more
risk — so no rational LP would choose it. Junior is given a premium for first-loss exposure:

$$\Delta = \lambda \cdot \max(\sigma_J - \sigma_S,\; 0)$$

with `σ_S = std(residual)`, `σ_J = std(IL + absorbed)` (both independent of `α`, so non-circular),
and `λ` the price of risk (Sharpe-like knob).

### 5. Buffer and split

```
B = percentile(IL distribution, p)              # design knob p (default 90th percentile)
α = 0.5 + E[absorbed] / (2F) + Δ / (4F)
```

With `λ = 0` this reduces to `α = 0.5 + E[absorbed]/(2F)`, matching the documented feasibility
relation `α = ΔL/(2F) + 0.5`.

---

## Reading the output

The search table flags each `(T, range, turnover)` combination:

| Column | Meaning |
|--------|---------|
| `E[IL]` | Mean impermanent loss over the period |
| `F`     | Accumulated fund as a fraction of principal |
| `B`     | Derived buffer (fraction of principal) |
| `α`     | Derived Junior fee share |
| `prem`  | Junior risk premium `Δ` |
| `phys`  | `0.5 < α < 1` (a valid split exists) |
| `fund`  | `E[absorbed] ≤ 2α·F` (Junior's fee can fund the protection it sells) |
| `prof`  | Both tranches have positive expected return |
| `prem?` | Junior is not dominated (`R_J ≥ R_S`) |
| `sat`  | All of the above hold → parameters are feasible |

Combinations fail (typically `α > 1`) when fees are too thin to cover IL — the on-chain
expression of the feasibility condition `ΔL < F`. Feasibility tightens with narrower ranges and
longer horizons (larger IL), and loosens with higher turnover (more fees).

### Representative result

`σ = 60%`, `T = 30d`, range `±0.5`, turnover `20×`, `λ = 0.30`:

```
B = 4.20% of principal      α = 0.637  (Junior 63.7% / Senior 36.3%)      premium Δ = 0.70%
```

| Tranche | Mean return | Std | 1st pct | Loss probability |
|---------|-------------|-----|---------|------------------|
| **Senior**  | +4.10% | 0.011 | −1.53% | **1.8%** |
| Plain LP    | +4.46% | 0.022 | −4.09% | 4.8% |
| **Junior**  | +4.81% | 0.034 | −6.64% | **11.6%** |

Returns and risk are both **monotone** across the three profiles — a genuine tranche structure:
Senior trades a little expected return for roughly halved downside; Junior earns a premium for
absorbing it; plain LP sits in between, unprotected.

---

## Mapping to the on-chain hook

The hook constructor takes three immutables. Convert the derived fractions to WAD (`× 1e18`):

| Model output | Constructor arg | Example (representative case) |
|--------------|-----------------|-------------------------------|
| `B`               | `BUFFER_WAD`   | `0.0420 → 42000000000000000` |
| `α`               | `ALPHA_WAD`    | `0.637  → 637000000000000000` |
| per-swap fee rate | `HOOK_FEE_WAD` | `rate × 1e18` |

Notes:
- `HOOK_FEE_WAD` is the **per-swap** additive rate. `F` in the model is its *accumulation* over
  the assumed `turnover`; turnover is an environment assumption, not a contract parameter.
- The fee is **additive** (charged on top of the pool LP fee — design choice "Y"). It is the
  premium that funds protection. Production rates are small (competitive); the high values used in
  the test suite (10–20%) exist only to make the protection visible in a short demo.

---

## Assumptions and known limitations

Stated up front, by design — these are deliberate scope choices, not oversights:

1. **Equal tranches (S : J = 1).** The fee normalization and the fund constraint assume equal
   Senior/Junior capital. A general capital structure changes the `α` formula and the solvency
   bound; it is the natural next extension.
2. **Solvency in expectation.** `fund_ok` checks `E[absorbed] ≤ 2α·F`. In adverse realizations the
   fund can still run dry (the protection then caps at the available fund). A tail constraint
   (e.g. `P[absorbed > fund]` small) is stronger and not yet enforced as a gate.
3. **EMA vs. true price.** The model measures IL at the true terminal price; the hook measures it
   against a lagging on-chain EMA. The realized absorbed amount is therefore typically *smaller*
   than modeled, making the derived buffer mildly conservative.
4. **Premium uses standard deviation.** `Δ` is proportional to excess return volatility. Since IL is
   one-sided, a downside risk measure (semi-deviation, CVaR) is a reasonable alternative.
5. **σ is exogenous.** Volatility is an input here. Estimating it from on-chain history (and
   refreshing parameters) is the live-pipeline extension — and a natural fit for an off-chain
   AVS / oracle.

---

## References

- On-chain IL: `src/ILMath.sol` (`ilFromSqrtPrices`) — mirrors `il_concentrated` here.
- Uniswap v3 concentrated-liquidity token-amount math.