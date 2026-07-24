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

  // SOFR-style discipline: the headline composite is VOLUME-WEIGHTED and venues below
  // a liquidity floor are excluded from it (they stay visible in `protocols`). A $24k
  // book must not move a benchmark anchored by $450M of borrow.
  const rated = perProtocol.filter((p) => p.borrowApr != null);
  const included = rated.filter((p) => p.totalBorrowUSD >= MIN_BORROW_USD);
  const weight = included.reduce((s, p) => s + p.totalBorrowUSD, 0);
  const composite = weight
    ? round2(included.reduce((s, p) => s + p.borrowApr * p.totalBorrowUSD, 0) / weight)
    : null;

  return {
    protocols: rated.map((p) => ({ ...p, includedInComposite: p.totalBorrowUSD >= MIN_BORROW_USD })),
    composite: {
      borrowApr: composite,
      method: `borrow-balance-weighted mean, venues ≥ $${(MIN_BORROW_USD / 1e6).toFixed(0)}M borrow`,
      venues: included.map((p) => p.protocol),
      totalBorrowUSD: Math.round(weight),
    },
    band: included.length
      ? {
          borrowMin: Math.min(...included.map((p) => p.borrowApr)),
          borrowMax: Math.max(...included.map((p) => p.borrowApr)),
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

const num = (x) => (x == null ? null : Math.round(Number(x) * 100) / 100);
const round2 = (v) => Math.round(v * 100) / 100;
