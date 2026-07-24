import {
  MIDNIGHT_API,
  BASE_CHAIN_ID,
  USDC,
  CBBTC,
  LN_ONE_PLUS_DELTA,
  MAX_TICK,
} from "./config.mjs";

/** Midnight tick → zero-coupon price (0..1). Logistic curve per the Midnight SDK. */
const tickToPrice = (tick) =>
  1 / (1 + Math.exp(LN_ONE_PLUS_DELTA * (MAX_TICK / 2 - tick)));

/**
 * The live Morpho Midnight cbBTC/USDC fixed-rate curve: for each maturity, the
 * best-ask implied APR from the deepest market's live order book.
 */
export async function fetchMidnightCurve() {
  const res = await fetch(`${MIDNIGHT_API}/markets?chainId=${BASE_CHAIN_ID}`);
  const { data: markets } = await res.json();
  const now = Date.now() / 1000;

  // deepest USDC-loan / cbBTC-collateral market per maturity, ≥5 days out
  const byMaturity = new Map();
  for (const m of markets) {
    if (m.loan_token.toLowerCase() !== USDC) continue;
    if (!m.collaterals?.some((c) => c.token.toLowerCase() === CBBTC)) continue;
    if ((m.maturity - now) / 86400 < 5) continue;
    const prev = byMaturity.get(m.maturity);
    if (!prev || BigInt(m.total_units) > BigInt(prev.total_units)) {
      byMaturity.set(m.maturity, m);
    }
  }

  const points = await Promise.all(
    [...byMaturity.values()].map(async (m) => {
      const r = await fetch(
        `${MIDNIGHT_API}/books/${m.market_id}/asks/takeable-offers`,
      );
      const { data: offers } = await r.json();
      if (!offers?.length) return null;
      const bestTick = Math.min(...offers.map((o) => Number(o.offer.tick)));
      const price = tickToPrice(bestTick);
      const t = m.maturity - now;
      return {
        maturity: m.maturity,
        maturityDate: new Date(m.maturity * 1000).toISOString().slice(0, 10),
        days: Math.round(t / 86400),
        aprPct: Math.round((1 / price - 1) * ((365 * 86400) / t) * 10000) / 100,
        zeroCouponPrice: Math.round(price * 1e5) / 1e5,
        marketId: m.market_id,
      };
    }),
  );

  const curve = points.filter(Boolean).sort((a, b) => a.days - b.days);

  /** Linear interpolation on the curve for an arbitrary tenor (e.g. our 90d draws). */
  const interpolate = (days) => {
    if (!curve.length) return null;
    if (days <= curve[0].days) return curve[0].aprPct;
    if (days >= curve.at(-1).days) return curve.at(-1).aprPct;
    for (let i = 0; i < curve.length - 1; i++) {
      const [a, b] = [curve[i], curve[i + 1]];
      if (days >= a.days && days <= b.days) {
        const w = (days - a.days) / (b.days - a.days);
        return Math.round((a.aprPct + w * (b.aprPct - a.aprPct)) * 100) / 100;
      }
    }
    return null;
  };

  return { curve, benchmark90d: interpolate(90), interpolate };
}
