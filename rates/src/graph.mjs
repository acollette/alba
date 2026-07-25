import { GRAPH_GATEWAY, LENDING_SUBGRAPHS, MARKETS_QUERY } from "./config.mjs";

/**
 * Floating-rate band: the SAME Messari-standardized query against every subgraph.
 * Zero per-protocol code — the schema does the work.
 */
export async function fetchFloatingBand(apiKey) {
  const perProtocol = await Promise.all(
    LENDING_SUBGRAPHS.map(async ({ protocol, id }) => {
      const res = await fetch(`${GRAPH_GATEWAY}/${apiKey}/subgraphs/id/${id}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ query: MARKETS_QUERY }),
      });
      const { data, errors } = await res.json();
      if (errors) throw new Error(`${protocol}: ${errors[0].message}`);

      // Largest USDC market per protocol; variable borrow/lend rates
      const market = (data.markets ?? []).find((m) => m.rates?.length);
      if (!market) return { protocol, error: "no USDC market" };
      const rate = (side) =>
        market.rates.find((r) => r.side === side && r.type === "VARIABLE")?.rate;
      return {
        protocol,
        market: market.name ?? market.inputToken.symbol,
        borrowApr: num(rate("BORROWER")),
        supplyApr: num(rate("LENDER")),
        totalBorrowUSD: num(market.totalBorrowBalanceUSD),
      };
    }),
  );

  // SOFR-style discipline, twice over. (1) Liquidity floor: venues below $1M borrow are
  // excluded from the headline (still visible in `protocols`) — a $24k book must not move
  // a benchmark anchored by ~$450M. (2) The composite is the borrow-weighted MEDIAN —
  // the same statistic SOFR actually is — so one small venue in a utilization spike
  // (rates go vertical above the kink) cannot drag the benchmark. Venues printing >3×
  // the median are flagged `stressed`: still in the table and the median calc, but kept
  // out of the DISPLAY band so an outlier doesn't wreck the chart scale.
  const rated = perProtocol.filter((p) => p.borrowApr != null);
  const included = rated.filter((p) => p.totalBorrowUSD >= MIN_BORROW_USD);
  const weight = included.reduce((s, p) => s + p.totalBorrowUSD, 0);
  const composite = included.length ? round2(weightedMedian(included)) : null;
  const isStressed = (p) => composite != null && p.borrowApr > STRESS_MULTIPLE * composite;
  const calm = included.filter((p) => !isStressed(p));

  return {
    protocols: rated.map((p) => ({
      ...p,
      includedInComposite: p.totalBorrowUSD >= MIN_BORROW_USD,
      stressed: isStressed(p),
    })),
    composite: {
      borrowApr: composite,
      method: `borrow-balance-weighted median (the SOFR statistic), venues ≥ $${(MIN_BORROW_USD / 1e6).toFixed(0)}M borrow`,
      venues: included.map((p) => p.protocol),
      totalBorrowUSD: Math.round(weight),
    },
    band: calm.length
      ? {
          borrowMin: Math.min(...calm.map((p) => p.borrowApr)),
          borrowMax: Math.max(...calm.map((p) => p.borrowApr)),
          excludesStressed: calm.length < included.length,
        }
      : null,
    rawRange: rated.length
      ? {
          borrowMin: Math.min(...rated.map((p) => p.borrowApr)),
          borrowMax: Math.max(...rated.map((p) => p.borrowApr)),
        }
      : null,
  };
}

export const MIN_BORROW_USD = 1_000_000;
export const STRESS_MULTIPLE = 3; // venue rate > 3× the weighted median = utilization spike

/** Borrow-weighted median of {borrowApr, totalBorrowUSD} — the rate at which half the
 * borrowed dollars fund cheaper and half fund dearer. */
function weightedMedian(venues) {
  const sorted = [...venues].sort((a, b) => a.borrowApr - b.borrowApr);
  const half = sorted.reduce((s, v) => s + v.totalBorrowUSD, 0) / 2;
  let cum = 0;
  for (const v of sorted) {
    cum += v.totalBorrowUSD;
    if (cum >= half) return v.borrowApr;
  }
  return sorted[sorted.length - 1].borrowApr;
}

/**
 * 90d TRAILING composite (SOFR-average style): the NY Fed publishes 30/90/180-day SOFR
 * averages; this is the DeFi analog. Same standardized schema, TIME-SERIES this time —
 * each protocol's largest USDC market via Messari daily snapshots, still zero
 * per-protocol code. Per UTC day: borrow-weighted mean across venues over the liquidity
 * floor; trailing figure = simple mean of the daily composites. Backward-looking BY
 * DESIGN — it smooths utilization spikes out of the floating cross-check; the
 * forward-looking fixed benchmark stays the Midnight curve (see pricing.mjs).
 */
export async function fetchTrailingComposite(apiKey, days = 90) {
  const query = `{
    markets(where: {inputToken_: {symbol_in: ["USDC", "USDbC"]}},
            orderBy: totalBorrowBalanceUSD, orderDirection: desc, first: 1) {
      name
      dailySnapshots(first: ${days}, orderBy: timestamp, orderDirection: desc) {
        timestamp
        totalBorrowBalanceUSD
        rates { rate side type }
      }
    }
  }`;
  const perProtocol = await Promise.all(
    LENDING_SUBGRAPHS.map(async ({ protocol, id }) => {
      const res = await fetch(`${GRAPH_GATEWAY}/${apiKey}/subgraphs/id/${id}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ query }),
      });
      const { data, errors } = await res.json();
      if (errors) return { protocol, error: errors[0].message };
      const snapshots = (data.markets?.[0]?.dailySnapshots ?? [])
        .map((s) => ({
          day: Math.floor(Number(s.timestamp) / 86_400),
          borrowApr: num(s.rates?.find((r) => r.side === "BORROWER" && r.type === "VARIABLE")?.rate),
          borrowUSD: Number(s.totalBorrowBalanceUSD),
        }))
        .filter((s) => s.borrowApr != null && s.borrowUSD >= MIN_BORROW_USD);
      return { protocol, snapshots };
    }),
  );

  // Bucket by UTC day, take each day's borrow-weighted MEDIAN across venues (same
  // robust statistic as the spot composite), then average the daily figures
  const byDay = new Map();
  for (const p of perProtocol) {
    for (const s of p.snapshots ?? []) {
      const day = byDay.get(s.day) ?? [];
      day.push({ borrowApr: s.borrowApr, totalBorrowUSD: s.borrowUSD });
      byDay.set(s.day, day);
    }
  }
  const daily = [...byDay.values()].map(weightedMedian);
  if (!daily.length) return null;
  return {
    aprPct: round2(daily.reduce((a, b) => a + b, 0) / daily.length),
    daysRequested: days,
    daysWithData: daily.length,
    method: `simple mean of daily borrow-weighted medians (SOFR-average style), venues ≥ $${(MIN_BORROW_USD / 1e6).toFixed(0)}M/day`,
    venues: perProtocol.filter((p) => p.snapshots?.length).map((p) => p.protocol),
  };
}

/** Margin calibration: Aave v3 Base's live cbBTC risk params via the SAME standardized schema. */
export async function fetchCollateralBenchmark(apiKey) {
  const res = await fetch(`${GRAPH_GATEWAY}/${apiKey}/subgraphs/id/${LENDING_SUBGRAPHS[0].id}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      query: `{ markets(where: {inputToken_: {symbol_in: ["cbBTC"]}}) {
        name maximumLTV liquidationThreshold liquidationPenalty } }`,
    }),
  });
  const { data, errors } = await res.json();
  if (errors) throw new Error(errors[0].message);
  const m = data.markets?.[0];
  if (!m) return null;
  const maxLTV = Number(m.maximumLTV);
  const liqThreshold = Number(m.liquidationThreshold);
  return {
    source: m.name,
    maxLTVPct: maxLTV,
    liquidationThresholdPct: liqThreshold,
    liquidationPenaltyPct: Number(m.liquidationPenalty),
    // Alba's ratio convention (collateral / debt)
    collateralRatioBps: Math.round(1e6 / maxLTV),
    maintenanceRatioBps: Math.round(1e6 / liqThreshold),
  };
}

const num = (x) => (x == null ? null : Math.round(Number(x) * 100) / 100);
const round2 = (v) => Math.round(v * 100) / 100;
