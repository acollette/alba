import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fetchFloatingBand } from "./graph.mjs";
import { fetchMidnightCurve } from "./midnight.mjs";
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
    const { curve, benchmark90d } = await cached("midnight", fetchMidnightCurve);
    return { curve, benchmark90d };
  },
  "/api/rates": async () => {
    const [band, midnight] = await Promise.all([
      cached("band", () => fetchFloatingBand(GRAPH_API_KEY)),
      cached("midnight", fetchMidnightCurve),
    ]);
    return {
      asOf: new Date().toISOString(),
      floating: band,
      fixed: { curve: midnight.curve, benchmark90d: midnight.benchmark90d },
    };
  },
};

createServer(async (req, res) => {
  res.setHeader("access-control-allow-origin", "*");
  try {
    const route = routes[req.url];
    if (route) {
      const body = JSON.stringify(await route(), null, 2);
      res.writeHead(200, { "content-type": "application/json" });
      return res.end(body);
    }
    if (req.url === "/" || req.url === "/dashboard") {
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
}).listen(PORT, () => console.log(`chronos-rates listening on :${PORT}`));
