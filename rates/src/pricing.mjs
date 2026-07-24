/**
 * Alba facility pricing — the desk build-up (full methodology: docs/PRICING.md):
 *
 *   rate(T) = benchmark(T)                    — Midnight zero-coupon curve, this tenor
 *           + gap-risk spread(T, ratio, vol)  — the cost of maturity-only margining
 *           + liquidity/commitment premium    — bespoke, non-fungible, committed capacity
 *           + settlement fee                  — protocol constant
 *
 * Gap risk: with no mid-term margining, the lender is short a European put on the
 * collateral. A draw of P with collateral ratio c (e.g. 1.30) and repayment K=P(1+rT)
 * loses money at maturity iff  ρ · S_T · cP / S_0 < K   (ρ = auction recovery vs oracle).
 * Expected loss = ρ · BSput(S0 = cP, K' = K/ρ, σ, T), annualized over P.
 * All conventions simple-interest ACT/365, matching AlbaProgramBuilder.repaymentAmount.
 */

export const DEFAULTS = {
  volAnnual: 0.40, // cbBTC annualized vol — configurable; sensitivity table in PRICING.md
  recovery: 0.90, // auction clears between start (105%) and floor (85%) of oracle; mid-conservative
  liquidityPremiumBps: 50, // bespoke/non-fungible position + committed capacity
  settlementFeeBps: 0, // protocol settlement fee (constant when enabled on-chain)
};

export function quoteFacilityRate({ tenorDays, collateralRatioBps, benchmarkAprPct, opts = {} }) {
  const { volAnnual, recovery, liquidityPremiumBps, settlementFeeBps } = { ...DEFAULTS, ...opts };
  const T = tenorDays / 365;
  const c = collateralRatioBps / 10_000;
  const r = benchmarkAprPct / 100;

  // Solve iteratively: K depends on the final rate, which depends on K. Two passes converge
  // far inside display precision (spread moves K by bps).
  let ratePct = benchmarkAprPct;
  let gapBps = 0;
  for (let i = 0; i < 3; i++) {
    const K = 1 + (ratePct / 100) * T; // repayment per 1 principal
    const put = bsPut(c, K / recovery, volAnnual, T, r);
    const expectedLossPerPrincipal = recovery * put;
    gapBps = (expectedLossPerPrincipal / T) * 10_000; // annualized, in bps
    ratePct = benchmarkAprPct + (gapBps + liquidityPremiumBps + settlementFeeBps) / 100;
  }

  return {
    tenorDays,
    collateralRatioBps,
    suggestedAprPct: round2(ratePct),
    breakdown: {
      benchmarkAprPct: round2(benchmarkAprPct),
      gapRiskBps: Math.round(gapBps),
      liquidityPremiumBps,
      settlementFeeBps,
    },
    model: {
      volAnnual,
      recovery,
      note: "gap risk = recovery-adjusted Black-Scholes put on collateral (maturity-only margining)",
    },
  };
}

/** Black–Scholes European put, unit notional in the underlying's currency. */
function bsPut(S0, K, sigma, T, r) {
  if (T <= 0 || sigma <= 0) return Math.max(K - S0, 0);
  const sqT = Math.sqrt(T);
  const d1 = (Math.log(S0 / K) + (r + (sigma * sigma) / 2) * T) / (sigma * sqT);
  const d2 = d1 - sigma * sqT;
  return K * Math.exp(-r * T) * cdf(-d2) - S0 * cdf(-d1);
}

/** Standard normal CDF (Abramowitz–Stegun 7.1.26, |err| < 7.5e-8). */
function cdf(x) {
  const sign = x < 0 ? -1 : 1;
  const ax = Math.abs(x) / Math.SQRT2;
  const t = 1 / (1 + 0.3275911 * ax);
  const y =
    1 -
    (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) *
      t *
      Math.exp(-ax * ax);
  return 0.5 * (1 + sign * y);
}

const round2 = (v) => Math.round(v * 100) / 100;
