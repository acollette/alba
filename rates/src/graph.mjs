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

  const rates = perProtocol.filter((p) => p.borrowApr != null);
  return {
    protocols: perProtocol,
    band: rates.length
      ? {
          borrowMin: Math.min(...rates.map((p) => p.borrowApr)),
          borrowMax: Math.max(...rates.map((p) => p.borrowApr)),
        }
      : null,
  };
}

const num = (x) => (x == null ? null : Math.round(Number(x) * 100) / 100);
