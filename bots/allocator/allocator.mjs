#!/usr/bin/env node
/**
 * Alba allocator bot — WS5, DRY-RUN ONLY (VAULT_PLAN.md §4).
 *
 * Runs against LIVE Base mainnet reads (Morpho Midnight REST + The Graph) and logs
 * exactly what it WOULD do. No keys, no transactions, no contracts. Portfolio state
 * is simulated in state.json so consecutive runs evolve a virtual book — a
 * paper-trading simulator of the exact v1 strategy.
 *
 * SIDE SEMANTICS (verified against live offer objects — see README):
 *   - ASKS  = standing offers with `buy:false`: BORROWER-side makers selling
 *     zero-coupon paper (taking a fixed-rate loan). This is the side WE take:
 *     the vault lends by lifting an ask — pay `price` per unit face now, receive
 *     par at maturity. THE ONLY EXECUTABLE SIDE FOR A BUYER OF PAPER.
 *   - BIDS  = standing offers with `buy:true`: LENDER-side makers bidding to buy
 *     paper. That is competing lend demand — context only, never executable by us.
 *   The rates curve's "lend-floor" points are bid-side marks: indicative, not
 *   something the vault can fill.
 *
 * Reuses rates/ read-only: fetchMidnightCurve (curve + benchmark context),
 * fetchFloatingBand / fetchTrailingComposite (floating benchmark when
 * GRAPH_API_KEY is set), config constants. Zero dependencies, Node >= 18.
 *
 * Usage:
 *   node bots/allocator/allocator.mjs             # one shot (cron-safe, file-locked)
 *   node bots/allocator/allocator.mjs --loop 300  # run every 300s
 *   node bots/allocator/allocator.mjs --reset     # re-seed the simulated portfolio
 *   flags: --config/--state/--log <path> to relocate files (used by tests)
 */

import { readFileSync, writeFileSync, appendFileSync, existsSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { fetchMidnightCurve, MIN_DEPTH_USDC } from "../../rates/src/midnight.mjs";
import { fetchFloatingBand, fetchTrailingComposite } from "../../rates/src/graph.mjs";
import {
  MIDNIGHT_API,
  BASE_CHAIN_ID,
  USDC,
  CBBTC,
  LN_ONE_PLUS_DELTA,
  MAX_TICK,
} from "../../rates/src/config.mjs";

// ─── paths & CLI ────────────────────────────────────────────────────────────────

const here = (f) => fileURLToPath(new URL(f, import.meta.url));
const argv = process.argv.slice(2);
const flag = (name) => {
  const i = argv.indexOf(name);
  return i === -1 ? null : (argv[i + 1] ?? true);
};
const PATHS = {
  config: flag("--config") ?? here("./config.json"),
  state: flag("--state") ?? here("./state.json"),
  log: flag("--log") ?? here("./decisions.jsonl"),
  lock: (flag("--state") ?? here("./state.json")) + ".lock",
};
let RESET = argv.includes("--reset"); // consumed by the first loadState (loop-safe)
const LOOP_SEC = flag("--loop") ? Number(flag("--loop")) : null;

const cfg = JSON.parse(readFileSync(PATHS.config, "utf8"));

// ─── small helpers ──────────────────────────────────────────────────────────────

const round2 = (v) => Math.round(v * 100) / 100;
const cents = (v) => Math.round(v * 100) / 100; // money, 2dp
const usd = (v) =>
  "$" + Math.round(v).toLocaleString("en-US");
const pct = (v) => (v == null ? "n/a" : v.toFixed(2) + "%");
// Midnight tick → zero-coupon price. Same logistic curve as rates/src/midnight.mjs
// (function is module-local there, so re-derived here from the shared constants).
const tickToPrice = (tick) => 1 / (1 + Math.exp(LN_ONE_PLUS_DELTA * (MAX_TICK / 2 - tick)));
// Simple-interest APR, ACT/365 — the same convention as the rates curve.
const yieldPct = (price, days) => ((1 / price - 1) * 365 * 100) / days;

async function getJSON(url) {
  const res = await fetch(url, { signal: AbortSignal.timeout(20_000) });
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}: ${url}`);
  return res.json();
}

// ─── decision log (JSONL + console) ─────────────────────────────────────────────

let seq = 0;
function decide(run, type, human, detail) {
  const entry = { ts: new Date().toISOString(), run, seq: ++seq, type, summary: human, ...detail };
  appendFileSync(PATHS.log, JSON.stringify(entry) + "\n");
  console.log(`  [${type.toUpperCase().padEnd(9)}] ${human}`);
  return entry;
}

// ─── simulated portfolio state ──────────────────────────────────────────────────

function freshState() {
  return {
    version: 1,
    mode: "dry-run",
    createdAt: new Date().toISOString(),
    runCount: 0,
    lastRunAt: null, // unix seconds
    depositsUSDC: cfg.simulatedAumUSDC,
    idleUSDC: cfg.simulatedAumUSDC,
    bufferUSDC: 0, // simulated MetaMorpho position (cost + accrued interest)
    lots: [], // { id, marketId, maturity, maturityDate, buyTime, faceUSDC, costUSDC, vwapPrice, ytmAprPct }
    nextLotId: 1,
    lastNavUSDC: cfg.simulatedAumUSDC,
    totals: { boughtFaceUSDC: 0, maturedFaceUSDC: 0, bufferInterestUSDC: 0 },
  };
}
function loadState() {
  const state = !RESET && existsSync(PATHS.state) ? JSON.parse(readFileSync(PATHS.state, "utf8")) : freshState();
  RESET = false; // in --loop mode, only the first iteration reseeds
  return state;
}
const saveState = (s) => writeFileSync(PATHS.state, JSON.stringify(s, null, 2) + "\n");

/** Amortized cost with linear accretion to par (VAULT_PLAN.md: pull-to-par, no oracle). */
function lotValue(lot, now) {
  const span = lot.maturity - lot.buyTime;
  const w = span <= 0 ? 1 : Math.min(1, Math.max(0, (now - lot.buyTime) / span));
  return lot.costUSDC + (lot.faceUSDC - lot.costUSDC) * w;
}

function nav(state, now) {
  const fixed = state.lots.reduce((s, l) => s + lotValue(l, now), 0);
  return { fixed, total: state.idleUSDC + state.bufferUSDC + fixed };
}

// ─── file lock (cron safety: single writer, stale-steal on crash) ───────────────

function acquireLock() {
  const payload = JSON.stringify({ pid: process.pid, at: Date.now() });
  try {
    writeFileSync(PATHS.lock, payload, { flag: "wx" });
    return true;
  } catch {
    try {
      const { at } = JSON.parse(readFileSync(PATHS.lock, "utf8"));
      if (Date.now() - at > cfg.staleLockMinutes * 60_000) {
        writeFileSync(PATHS.lock, payload); // stale — steal it
        return true;
      }
    } catch {
      writeFileSync(PATHS.lock, payload); // unreadable lock — steal it
      return true;
    }
    return false;
  }
}
const releaseLock = () => rmSync(PATHS.lock, { force: true });

// ─── market data ────────────────────────────────────────────────────────────────

/** All Midnight markets on Base (cursor-paginated; sorted by size desc). */
async function fetchAllMarkets() {
  const markets = [];
  let cursor = null;
  for (let page = 0; page < cfg.maxMarketPages; page++) {
    const url =
      `${MIDNIGHT_API}/markets?chainId=${BASE_CHAIN_ID}` +
      (cursor ? `&cursor=${encodeURIComponent(cursor)}` : "");
    const { data, cursor: next } = await getJSON(url);
    markets.push(...(data ?? []));
    if (!next || !data?.length) break;
    cursor = next;
  }
  return markets;
}

/**
 * One side of a market's book, as live, unexpired levels.
 * `wantBuyFlag`: false → asks (borrower-makers, executable by us);
 *               true  → bids (lender-makers, context only).
 * Levels sorted best-for-a-paper-BUYER first (lowest price = highest yield) for
 * asks; best bid (highest price) first for bids.
 */
async function fetchBook(marketId, wantBuyFlag, now) {
  const { data } = await getJSON(`${MIDNIGHT_API}/books/${marketId}/${wantBuyFlag ? "bids" : "asks"}/takeable-offers`);
  const levels = (data ?? [])
    .filter(
      (o) =>
        o.offer.buy === wantBuyFlag && // sanity: side flag matches
        Number(o.offer.start) <= now &&
        Number(o.offer.expiry) > now, // drop expired maker intents (they are hours-long)
    )
    .map((o) => ({
      tick: Number(o.offer.tick),
      price: tickToPrice(Number(o.offer.tick)),
      faceUSDC: Number(o.units) / 1e6,
      maker: o.offer.maker,
      expiresInMin: Math.round((Number(o.offer.expiry) - now) / 60),
    }))
    .sort((a, b) => (wantBuyFlag ? b.price - a.price : a.price - b.price));
  return { levels, depthUSDC: levels.reduce((s, l) => s + l.faceUSDC, 0) };
}

// ─── benchmarks ─────────────────────────────────────────────────────────────────

async function fetchBenchmarks(run) {
  const key = process.env.GRAPH_API_KEY;
  if (key) {
    try {
      const [band, trailing] = await Promise.all([
        fetchFloatingBand(key),
        fetchTrailingComposite(key, 90),
      ]);
      const included = band.protocols.filter((p) => p.includedInComposite && p.supplyApr != null);
      const supply = included.length
        ? included.sort((a, b) => a.supplyApr - b.supplyApr)[Math.floor(included.length / 2)].supplyApr
        : cfg.fallbackBufferSupplyAprPct;
      return {
        source: "graph-live",
        floatingAprPct: band.composite.borrowApr,
        floatingMethod: band.composite.method,
        supplyAprPct: supply,
        trailing90dAprPct: trailing?.aprPct ?? null,
      };
    } catch (err) {
      decide(run, "note", `Graph benchmark fetch failed (${err.message}) — using config fallback`, {
        severity: "warn",
      });
    }
  }
  return {
    source: "config-fallback",
    floatingAprPct: cfg.fallbackFloatingAprPct,
    floatingMethod: "config fallbackFloatingAprPct (GRAPH_API_KEY unset — dry-run without secrets)",
    supplyAprPct: cfg.fallbackBufferSupplyAprPct,
    trailing90dAprPct: null,
  };
}

// ─── one full decision cycle ────────────────────────────────────────────────────

async function runOnce() {
  if (!acquireLock()) {
    console.log("another allocator run holds the lock — exiting (cron-safe)");
    return;
  }
  const state = loadState();
  const run = state.runCount + 1;
  const now = Math.floor(Date.now() / 1000);
  try {
    console.log(
      `\n── Alba allocator · DRY-RUN · run #${run} · ${new Date().toISOString()} ──` +
        `\n   (no keys, no transactions — logging what the bot WOULD do)`,
    );

    // 1. Benchmarks: floating composite (+ spread floor = the hurdle), Midnight curve context.
    const bench = await fetchBenchmarks(run);
    const requiredAprPct = round2(bench.floatingAprPct + cfg.minSpreadBps / 100);
    const { curve } = await fetchMidnightCurve(); // reused as-is from rates/
    decide(
      run,
      "benchmark",
      `floating ${pct(bench.floatingAprPct)} (${bench.source}) → hurdle ${pct(requiredAprPct)} ` +
        `(spread floor ${cfg.minSpreadBps}bps) · curve: ${
          curve.map((c) => `${c.days}d ${pct(c.aprPct)} [${c.side}]`).join(" · ") || "empty"
        }`,
      { benchmarks: bench, requiredAprPct, minSpreadBps: cfg.minSpreadBps, midnightCurve: curve },
    );

    // 2. Buffer accretion since last run (simulated MetaMorpho interest).
    if (state.lastRunAt && state.bufferUSDC > 0) {
      const dt = now - state.lastRunAt;
      const interest = cents((state.bufferUSDC * (bench.supplyAprPct / 100) * dt) / (365 * 86400));
      if (interest > 0) {
        state.bufferUSDC = cents(state.bufferUSDC + interest);
        state.totals.bufferInterestUSDC = cents(state.totals.bufferInterestUSDC + interest);
        decide(run, "accrual", `buffer earned $${interest.toFixed(2)} over ${Math.round(dt / 60)}min at ${pct(bench.supplyAprPct)} (simulated MetaMorpho supply)`, {
          bufferUSDC: state.bufferUSDC,
          supplyAprPct: bench.supplyAprPct,
          dtSeconds: dt,
        });
      }
    }

    // 3. Maturities: lot → par → idle. (Live mode: submit sleeve redeem() instead.)
    for (const lot of [...state.lots]) {
      if (lot.maturity <= now) {
        state.lots = state.lots.filter((l) => l.id !== lot.id);
        state.idleUSDC = cents(state.idleUSDC + lot.faceUSDC);
        state.totals.maturedFaceUSDC = cents(state.totals.maturedFaceUSDC + lot.faceUSDC);
        decide(
          run,
          "redeem",
          `lot #${lot.id} matured ${lot.maturityDate}: ${usd(lot.faceUSDC)} par → idle ` +
            `(cost ${usd(lot.costUSDC)}, realized ${pct(lot.ytmAprPct)} for ${Math.round((lot.maturity - lot.buyTime) / 86400)}d) — WOULD submit on-chain redeem`,
          { lot },
        );
      }
    }

    // 4. Portfolio geometry before buys.
    const navPre = nav(state, now);
    const bucketOf = (days) => cfg.buckets.find((b) => days >= b.minDays && days <= b.maxDays);
    const exposureByBucket = Object.fromEntries(cfg.buckets.map((b) => [b.name, 0]));
    const exposureByMaturity = new Map();
    for (const lot of state.lots) {
      const d = (lot.maturity - now) / 86400;
      const v = lotValue(lot, now);
      const b = bucketOf(Math.max(0, d));
      if (b) exposureByBucket[b.name] += v;
      exposureByMaturity.set(lot.maturity, (exposureByMaturity.get(lot.maturity) ?? 0) + v);
    }
    // Cash spendable on paper = total liquid minus the protected buffer floor.
    const bufferFloor = (cfg.bufferTargetPct / 100) * navPre.total;
    let spendable = Math.max(0, state.idleUSDC + state.bufferUSDC - bufferFloor);

    // 5. Scan the market: every USDC/cbBTC maturity, ask-side (executable) book.
    const markets = (await fetchAllMarkets()).filter(
      (m) =>
        m.loan_token.toLowerCase() === USDC &&
        m.collaterals?.some((c) => c.token.toLowerCase() === CBBTC) &&
        m.maturity > now,
    );
    const inTenor = [];
    const outOfTenor = [];
    for (const m of markets) {
      const days = (m.maturity - now) / 86400;
      (days >= cfg.minDaysToMaturity && days <= cfg.maxDaysToMaturity ? inTenor : outOfTenor).push({
        ...m,
        days,
      });
    }
    if (outOfTenor.length)
      decide(
        run,
        "skip",
        `${outOfTenor.length} market(s) outside the ${cfg.minDaysToMaturity}–${cfg.maxDaysToMaturity}d tenor window — not scored`,
        {
          reason: "tenor",
          markets: outOfTenor.map((m) => ({ marketId: m.market_id, days: round2(m.days) })),
        },
      );

    // Read books (asks = executable for us; bids = competing lender demand, context).
    const scored = [];
    const emptyBooks = [];
    for (const m of inTenor) {
      const [asks, bids] = await Promise.all([
        fetchBook(m.market_id, false, now),
        fetchBook(m.market_id, true, now),
      ]);
      if (asks.depthUSDC < cfg.minBookDepthUSDC) {
        emptyBooks.push({
          marketId: m.market_id,
          days: round2(m.days),
          askDepthUSDC: Math.round(asks.depthUSDC),
          bidDepthUSDC: Math.round(bids.depthUSDC),
        });
        continue;
      }
      scored.push({ m, asks, bids });
    }
    if (emptyBooks.length)
      decide(
        run,
        "skip",
        `${emptyBooks.length} in-tenor market(s) with no executable ask-side depth ≥ ${usd(cfg.minBookDepthUSDC)} dust floor ` +
          `(borrowers aren't offering paper there — the common state of a nascent book)`,
        { reason: "no-executable-asks", dustFloorUSDC: cfg.minBookDepthUSDC, markets: emptyBooks },
      );

    // 6. Score & size each live book, best touch yield first.
    scored.sort(
      (a, b) => yieldPct(b.asks.levels[0].price, b.m.days) - yieldPct(a.asks.levels[0].price, a.m.days),
    );
    let buys = 0;
    for (const { m, asks, bids } of scored) {
      const days = m.days;
      const maturityDate = new Date(m.maturity * 1000).toISOString().slice(0, 10);
      const bucket = bucketOf(days);
      const levels = asks.levels.map((l) => ({
        ...l,
        price: Math.round(l.price * 1e5) / 1e5,
        yieldPct: round2(yieldPct(l.price, days)),
        clearsHurdle: yieldPct(l.price, days) >= requiredAprPct,
      }));
      const bestBid = bids.levels[0];
      const context = {
        marketId: m.market_id,
        maturityDate,
        days: round2(days),
        bucket: bucket?.name ?? null,
        side: "asks (borrower-makers, buy:false — the side a lender takes)",
        askDepthUSDC: Math.round(asks.depthUSDC),
        askLevels: levels,
        competingLendBids: bestBid
          ? {
              note: "bid side (buy:true) = other lenders' standing demand — context only, not executable by us",
              bestBidYieldPct: round2(yieldPct(bestBid.price, days)),
              depthUSDC: Math.round(bids.depthUSDC),
            }
          : { note: "no live lender bids", depthUSDC: 0 },
      };

      if (!bucket) {
        decide(run, "skip", `${maturityDate} (${Math.round(days)}d): no ladder bucket covers this tenor`, {
          reason: "no-bucket",
          ...context,
        });
        continue;
      }

      // Only levels that clear the hurdle are takeable (sorted best-first, so a prefix).
      const eligible = [];
      for (const l of levels) {
        if (!l.clearsHurdle) break;
        eligible.push(l);
      }
      const eligibleDepth = eligible.reduce((s, l) => s + l.faceUSDC * l.price, 0); // cash terms
      if (!eligible.length) {
        const best = levels[0];
        decide(
          run,
          "skip",
          `${maturityDate} (${Math.round(days)}d, ${bucket.name}): best executable ask yields ${pct(best.yieldPct)} ` +
            `< hurdle ${pct(requiredAprPct)} (gap ${Math.round((best.yieldPct - requiredAprPct) * 100)}bps) — ` +
            `fixed pays less than floating + spread floor; nothing worth buying · ask depth ${usd(asks.depthUSDC)}`,
          { reason: "below-hurdle", requiredAprPct, ...context },
        );
        continue;
      }

      // Sizing: every constraint computed and logged; the clip is their min.
      const constraints = {
        maxSingleBuyUSDC: cfg.maxSingleBuyUSDC,
        bucketRoomUSDC: cents(
          Math.max(0, (bucket.targetWeightPct / 100) * navPre.total - exposureByBucket[bucket.name]),
        ),
        maturityCapRoomUSDC: cents(
          Math.max(
            0,
            (cfg.perMaturityMaxPctOfAum / 100) * navPre.total - (exposureByMaturity.get(m.maturity) ?? 0),
          ),
        ),
        bookDepthCapUSDC: cents((cfg.perMaturityMaxPctOfBookDepth / 100) * asks.depthUSDC),
        eligibleDepthUSDC: cents(eligibleDepth),
        spendableCashUSDC: cents(spendable),
      };
      const clip = Math.min(...Object.values(constraints));
      const binding = Object.entries(constraints).sort((a, b) => a[1] - b[1])[0][0];
      if (clip < cfg.minClipUSDC) {
        decide(
          run,
          "skip",
          `${maturityDate} (${Math.round(days)}d, ${bucket.name}): ${eligible.length} level(s) clear the hurdle ` +
            `but sized clip ${usd(clip)} < ${usd(cfg.minClipUSDC)} dust floor (binding: ${binding})`,
          { reason: "clip-below-dust-floor", requiredAprPct, constraints, binding, ...context },
        );
        continue;
      }

      // Walk eligible asks best-first: WOULD-BUY.
      let cash = clip,
        cost = 0,
        face = 0;
      const fills = [];
      for (const l of eligible) {
        const takeFace = Math.min(l.faceUSDC, cash / l.price);
        if (takeFace <= 0) break;
        cost += takeFace * l.price;
        face += takeFace;
        cash -= takeFace * l.price;
        fills.push({ tick: l.tick, price: l.price, faceUSDC: cents(takeFace), yieldPct: l.yieldPct, maker: l.maker });
        if (cash <= 0.01) break;
      }
      cost = cents(cost);
      face = cents(face);
      const vwap = cost / face;
      const lot = {
        id: state.nextLotId++,
        marketId: m.market_id,
        maturity: m.maturity,
        maturityDate,
        buyTime: now,
        faceUSDC: face,
        costUSDC: cost,
        vwapPrice: Math.round(vwap * 1e5) / 1e5,
        ytmAprPct: round2(yieldPct(vwap, days)),
      };
      // Spend idle first, then draw buffer (final rebalance re-targets it).
      const fromIdle = Math.min(state.idleUSDC, cost);
      state.idleUSDC = cents(state.idleUSDC - fromIdle);
      state.bufferUSDC = cents(state.bufferUSDC - (cost - fromIdle));
      spendable = cents(spendable - cost);
      state.lots.push(lot);
      state.totals.boughtFaceUSDC = cents(state.totals.boughtFaceUSDC + face);
      exposureByBucket[bucket.name] += cost;
      exposureByMaturity.set(m.maturity, (exposureByMaturity.get(m.maturity) ?? 0) + cost);
      buys++;
      decide(
        run,
        "buy",
        `WOULD BUY ${usd(face)} face ${maturityDate} paper (${Math.round(days)}d, ${bucket.name}) for ${usd(cost)} ` +
          `@ ${lot.vwapPrice} → ${pct(lot.ytmAprPct)} YTM (hurdle ${pct(requiredAprPct)}, +${Math.round((lot.ytmAprPct - requiredAprPct) * 100)}bps) · ` +
          `lifting ${fills.length} standing borrower ask(s) · lot #${lot.id} — DRY-RUN, no transaction sent`,
        { requiredAprPct, constraints, binding, fills, lot, ...context },
      );
    }
    if (!buys && scored.length === 0 && inTenor.length > 0) {
      decide(run, "no-op", "nothing worth buying: no in-tenor market has an executable ask-side book above the dust floor", {
        reason: "market-empty",
        inTenorMarkets: inTenor.length,
      });
    }

    // 7. Buffer rebalance toward target (simulated MetaMorpho deposit/withdraw).
    const navPost = nav(state, now);
    const targetBuffer = cents((cfg.bufferTargetPct / 100) * navPost.total);
    const drift = state.bufferUSDC - targetBuffer;
    if (Math.abs(drift) > (cfg.bufferTolerancePct / 100) * navPost.total) {
      const move = cents(Math.min(Math.abs(drift), drift < 0 ? state.idleUSDC : state.bufferUSDC));
      if (drift < 0) {
        state.idleUSDC = cents(state.idleUSDC - move);
        state.bufferUSDC = cents(state.bufferUSDC + move);
      } else {
        state.bufferUSDC = cents(state.bufferUSDC - move);
        state.idleUSDC = cents(state.idleUSDC + move);
      }
      decide(
        run,
        "rebalance",
        `WOULD ${drift < 0 ? "deposit idle → MetaMorpho buffer" : "withdraw MetaMorpho buffer → idle"} ${usd(move)} ` +
          `(buffer ${usd(state.bufferUSDC)} vs target ${usd(targetBuffer)} = ${cfg.bufferTargetPct}% of NAV) — DRY-RUN`,
        { moveUSDC: move, direction: drift < 0 ? "idle->buffer" : "buffer->idle", targetBufferUSDC: targetBuffer, bufferUSDC: state.bufferUSDC },
      );
    } else {
      decide(run, "no-op", `buffer ${usd(state.bufferUSDC)} within ${cfg.bufferTolerancePct}% of NAV of target ${usd(targetBuffer)} — no rebalance`, {
        reason: "buffer-in-band",
        bufferUSDC: state.bufferUSDC,
        targetBufferUSDC: targetBuffer,
      });
    }

    // 8. NAV report (amortized-cost accretion — deterministic, oracle-free).
    const navEnd = nav(state, now);
    const weights = Object.fromEntries(
      cfg.buckets.map((b) => [b.name, round2((100 * (exposureByBucket[b.name] ?? 0)) / navEnd.total)]),
    );
    const sharePrice = navEnd.total / state.depositsUSDC;
    decide(
      run,
      "nav",
      `NAV $${navEnd.total.toFixed(2)} · share ${sharePrice.toFixed(6)} · ` +
        `idle ${usd(state.idleUSDC)} · buffer ${usd(state.bufferUSDC)} · fixed ${usd(navEnd.fixed)} in ${state.lots.length} lot(s) · ` +
        `ladder ${Object.entries(weights).map(([k, v]) => `${k} ${v}%`).join(" / ")} · Δ since last run $${(navEnd.total - state.lastNavUSDC).toFixed(2)}`,
      {
        navUSDC: cents(navEnd.total),
        sharePrice: Math.round(sharePrice * 1e6) / 1e6,
        idleUSDC: state.idleUSDC,
        bufferUSDC: state.bufferUSDC,
        fixedUSDC: cents(navEnd.fixed),
        lots: state.lots,
        ladderWeightsPct: weights,
        deltaUSDC: cents(navEnd.total - state.lastNavUSDC),
        totals: state.totals,
      },
    );

    state.lastNavUSDC = cents(navEnd.total);
    state.runCount = run;
    state.lastRunAt = now;
    saveState(state);
  } finally {
    releaseLock();
  }
}

// ─── entry ──────────────────────────────────────────────────────────────────────

const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));
if (LOOP_SEC) {
  console.log(`loop mode: one decision cycle every ${LOOP_SEC}s (ctrl-c to stop)`);
  for (;;) {
    try {
      await runOnce();
    } catch (err) {
      console.error("run failed (will retry next tick):", err.message);
    }
    await sleep(LOOP_SEC);
  }
} else {
  await runOnce();
}
