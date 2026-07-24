/**
 * Alba facility pricing — the desk build-up (full methodology: md-files/PRICING.md):
 *
 *   rate(T) = benchmark(T)              — Midnight zero-coupon curve, this tenor
 *           + residual risk premium     — what continuous margining does NOT remove:
 *                                         oracle latency, jumps between sentinel checks,
 *                                         auction depth. A parameter, not a model — the
 *                                         margin buffer (initial 130% vs maintenance 115%)
 *                                         and the check frequency are the real risk knobs.
 *           + liquidity/commitment premium — bespoke, non-fungible, committed capacity
 *           + settlement fee            — protocol constant
 *
 * The former Black–Scholes gap-risk term is gone BY CONSTRUCTION: with permissionless
 * continuous liquidation + the cure waterfall, the lender is no longer short a European
 * put to maturity. Conventions: simple interest ACT/365, matching the on-chain formula.
 */

export const DEFAULTS = {
  residualRiskBps: 25, // between-checks jump + oracle latency + auction depth
  liquidityPremiumBps: 50, // bespoke/non-fungible position + committed capacity
  settlementFeeBps: 0, // protocol settlement fee (constant when enabled on-chain)
};

export function quoteFacilityRate({ tenorDays, collateralRatioBps, benchmarkAprPct, opts = {} }) {
  const { residualRiskBps, liquidityPremiumBps, settlementFeeBps } = { ...DEFAULTS, ...opts };
  const suggested = benchmarkAprPct + (residualRiskBps + liquidityPremiumBps + settlementFeeBps) / 100;
  return {
    tenorDays,
    collateralRatioBps,
    suggestedAprPct: round2(suggested),
    breakdown: {
      benchmarkAprPct: round2(benchmarkAprPct),
      residualRiskBps,
      liquidityPremiumBps,
      settlementFeeBps,
    },
    model: {
      note: "continuous margining (130% initial / 115% maintenance, cure-first liquidation) replaces the option-premium term",
    },
  };
}

const round2 = (v) => Math.round(v * 100) / 100;
