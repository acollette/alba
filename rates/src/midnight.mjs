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

// Desk conventions (see docs/PRICING.md):
// - a curve point must be EXECUTABLE: price = size-weighted average to fill CLIP_USDC,
//   never the touch price of a dust book
// - books that cannot fill MIN_DEPTH_USDC are excluded from the curve entirely
export const CLIP_USDC = 25_000;
export const MIN_DEPTH_USDC = 5_000;

/**
 * Live Morpho Midnight cbBTC/USDC fixed-rate curve, constructed like a desk would:
 * depth-filtered, clip-size executable pricing, log-discount-factor interpolation
 * (piecewise-flat forwards), flat-forward extrapolation beyond the last liquid point.
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

      // Walk the book best-first; executable price = VWAP to fill the clip
      const levels = offers
        .map((o) => ({ price: tickToPrice(Number(o.offer.tick)), usdc: Number(o.units) / 1e6 }))
        .sort((a, b) => b.price - a.price); // higher zc price = cheaper borrow = better for taker
      const depth = levels.reduce((s, l) => s + l.usdc, 0);
      if (depth < MIN_DEPTH_USDC) return null; // dust book — not a quotable point

      let remaining = CLIP_USDC, cost = 0, filled = 0;
      for (const l of levels) {
        const take = Math.min(remaining, l.usdc);
        cost += take * l.price;
        filled += take;
        remaining -= take;
        if (remaining <= 0) break;
      }
      const price = cost / filled; // clip VWAP (whole book if depth < clip)
      const t = m.maturity - now;
      return {
        maturity: m.maturity,
        maturityDate: new Date(m.maturity * 1000).toISOString().slice(0, 10),
        days: Math.round(t / 86400),
        years: t / (365 * 86400),
        aprPct: round2(((1 / price - 1) * (365 * 86400)) / t * 100),
        zeroCouponPrice: Math.round(price * 1e5) / 1e5,
        depthUSDC: Math.round(depth),
        clipFilledUSDC: Math.round(filled),
        marketId: m.market_id,
      };
    }),
  );

  const curve = points.filter(Boolean).sort((a, b) => a.days - b.days);
  return { curve, benchmark: makeBenchmark(curve) };
}

/**
 * benchmark(days): simple-interest APR (ACT/365 — the convention of Alba's on-chain
 * repayment formula) for an arbitrary tenor.
 * Interpolation: linear in ln(discount factor) vs time == piecewise-constant forward
 * rates (standard short-end bootstrap). Beyond the last liquid point: carry the last
 * forward flat and label the result extrapolated.
 */
function makeBenchmark(curve) {
  const pts = curve.map((c) => ({ t: c.years, lnDF: Math.log(c.zeroCouponPrice), days: c.days }));
  return (days) => {
    if (!pts.length) return null;
    const t = days / 365;
    let lnDF, method;
    if (pts.length === 1) {
      lnDF = (pts[0].lnDF / pts[0].t) * t;
      method = days === pts[0].days ? "observed" : "flat-yield from single point";
    } else if (t <= pts[0].t) {
      lnDF = (pts[0].lnDF / pts[0].t) * t; // flat yield to first point
      method = "short-end flat yield";
    } else if (t >= pts.at(-1).t) {
      const [a, b] = pts.slice(-2);
      const fwd = (b.lnDF - a.lnDF) / (b.t - a.t); // last forward segment
      lnDF = pts.at(-1).lnDF + fwd * (t - pts.at(-1).t);
      method =
        days === pts.at(-1).days ? "observed" : `flat-forward extrapolation from ${pts.at(-1).days}d`;
    } else {
      const i = pts.findIndex((p, j) => j < pts.length - 1 && t >= p.t && t <= pts[j + 1].t);
      const [a, b] = [pts[i], pts[i + 1]];
      const w = (t - a.t) / (b.t - a.t);
      lnDF = a.lnDF + w * (b.lnDF - a.lnDF);
      method = `log-DF interpolation ${a.days}d–${b.days}d`;
    }
    const df = Math.exp(lnDF);
    return {
      days,
      aprPct: round2(((1 / df - 1) / t) * 100),
      discountFactor: Math.round(df * 1e5) / 1e5,
      method,
    };
  };
}

const round2 = (v) => Math.round(v * 100) / 100;
