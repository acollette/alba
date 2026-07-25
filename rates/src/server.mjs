import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fetchFloatingBand, fetchCollateralBenchmark, fetchTrailingComposite } from "./graph.mjs";
import { fetchMidnightCurve } from "./midnight.mjs";
import { quoteFacilityRate } from "./pricing.mjs";
import { CACHE_TTL_MS } from "./config.mjs";

const PORT = Number(process.env.PORT ?? 8787);
const GRAPH_API_KEY = process.env.GRAPH_API_KEY;
if (!GRAPH_API_KEY) {
  console.error("GRAPH_API_KEY is required (see .env.example)");
  process.exit(1);
}

// 90s cache: fresh enough to be live, kind to the gateway
const cache = new Map();
async function cached(key, fn) {
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < CACHE_TTL_MS) return hit.value;
  const value = await fn();
  cache.set(key, { at: Date.now(), value });
  return value;
}

const routes = {
  "/api/floating-band": () => cached("band", () => fetchFloatingBand(GRAPH_API_KEY)),
  "/api/midnight-curve": async () => {
    const { curve, benchmark } = await cached("midnight", fetchMidnightCurve);
    return { curve, benchmark90d: benchmark(90) };
  },
  "/api/quote": async (params) => {
    const tenorDays = Number(params.get("tenor") ?? 90);
    const collateralRatioBps = Number(params.get("ratioBps") ?? 13_000);
    const { benchmark } = await cached("midnight", fetchMidnightCurve);
    const bench = benchmark(tenorDays);
    if (!bench) return { error: "no curve" };
    const opts = {};
    for (const k of ["residualRiskBps", "liquidityPremiumBps", "settlementFeeBps"]) {
      if (params.has(k)) opts[k] = Number(params.get(k));
    }
    const q = quoteFacilityRate({ tenorDays, collateralRatioBps, benchmarkAprPct: bench.aprPct, opts });
    return { ...q, benchmark: bench };
  },
  "/api/rates": async () => {
    const [band, midnight, collateral, trailing] = await Promise.all([
      cached("band", () => fetchFloatingBand(GRAPH_API_KEY)),
      cached("midnight", fetchMidnightCurve),
      cached("collateral", () => fetchCollateralBenchmark(GRAPH_API_KEY)),
      cached("trailing", () => fetchTrailingComposite(GRAPH_API_KEY, 90)),
    ]);
    const bench90 = midnight.benchmark(90);
    return {
      asOf: new Date().toISOString(),
      floating: { ...band, trailing90d: trailing },
      collateralBenchmark: collateral,
      fixed: { curve: midnight.curve, benchmark90d: bench90 },
      suggested90d: bench90
        ? quoteFacilityRate({ tenorDays: 90, collateralRatioBps: 13_000, benchmarkAprPct: bench90.aprPct })
        : null,
    };
  },
};

createServer(async (req, res) => {
  res.setHeader("access-control-allow-origin", "*");
  try {
    const url = new URL(req.url, "http://x");
    const route = routes[url.pathname];
    if (route) {
      const body = JSON.stringify(await route(url.searchParams), null, 2);
      res.writeHead(200, { "content-type": "application/json" });
      return res.end(body);
    }
    if (url.pathname === "/" || url.pathname === "/dashboard") {
      const html = await readFile(new URL("./dashboard.html", import.meta.url));
      res.writeHead(200, { "content-type": "text/html" });
      return res.end(html);
    }
    res.writeHead(404, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "not found" }));
  } catch (err) {
    res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: String(err.message ?? err) }));
  }
}).listen(PORT, () => console.log(`alba-rates listening on :${PORT}`));
