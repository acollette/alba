"use client";

// Shared plumbing for the vault pages (/vault, /vault/book, /vault/admin).
// Same desk-terminal idioms as app/page.tsx: publicClient reads pinned to one
// chain, windowed event scans, wallet-derived roles, no component library.

import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useAccount, useConnect, useDisconnect, usePublicClient } from "wagmi";
import { formatUnits, keccak256, stringToHex } from "viem";
import { erc20Abi } from "@/lib/abi";
import { vaultAbi, midnightSleeveAbi, metaMorphoSleeveAbi } from "@/lib/vault-abi";
import {
  VAULT,
  VAULT_CHAIN_ID,
  VAULT_DEPLOYED,
  VAULT_EXPLORER,
  VAULT_START_BLOCK,
  VAULT_USDC_DEC,
  SHARE_UNIT,
} from "@/lib/vault-config";

// ---------------------------------------------------------------- constants

export const WAD = 10n ** 18n;
export const YEAR = 31_536_000n;

/** AccessControl role ids — keccak of the role string, admin is bytes32(0). */
export const ROLES = {
  admin: "0x0000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`,
  curator: keccak256(stringToHex("CURATOR_ROLE")),
  allocator: keccak256(stringToHex("ALLOCATOR_ROLE")),
  guardian: keccak256(stringToHex("GUARDIAN_ROLE")),
} as const;
export type RoleKey = keyof typeof ROLES;

// --------------------------------------------------------------- formatting

export const fmt = (v: bigint | undefined, dec: number, digits = 2) =>
  v === undefined ? "—" : Number(formatUnits(v, dec)).toLocaleString("en-US", { maximumFractionDigits: digits });

export const fmtUsdCompact = (v: bigint) =>
  "$" + Number(formatUnits(v, VAULT_USDC_DEC)).toLocaleString("en-US", { notation: "compact", maximumFractionDigits: 1 });

export const fmtAddr = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "—");

export const fmtId = (id: string) => `${id.slice(0, 10)}…`;

export const fmtDate = (ts?: number) =>
  ts ? new Date(ts * 1000).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }) : "—";

/** Live clock (1s tick) for accretion displays that should visibly move. */
export function useNow(intervalMs = 1000) {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), intervalMs);
    return () => clearInterval(t);
  }, [intervalMs]);
  return now;
}

// ------------------------------------------------------------ explorer links

export function AddrLink({ addr, label }: { addr: `0x${string}`; label?: string }) {
  const text = label ?? fmtAddr(addr);
  if (!VAULT_EXPLORER) return <span className="mono">{text}</span>;
  return (
    <a className="mono" href={`${VAULT_EXPLORER}/address/${addr}`} target="_blank" rel="noreferrer">
      {text} ↗
    </a>
  );
}

export function TxLink({ tx, children }: { tx: `0x${string}`; children: React.ReactNode }) {
  if (!VAULT_EXPLORER) return <span className="mono">{children}</span>;
  return (
    <a className="mono" href={`${VAULT_EXPLORER}/tx/${tx}`} target="_blank" rel="noreferrer">
      {children} ↗
    </a>
  );
}

// ----------------------------------------------------------------- chrome

export function VaultHeader({ active }: { active: "overview" | "book" | "admin" }) {
  const { address, isConnected, chain } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const tab = (href: string, key: typeof active, label: string) => (
    <a href={href} style={active === key ? { color: "var(--ink-1)", fontWeight: 600 } : undefined}>
      {label}
    </a>
  );
  return (
    <div className="topbar">
      <div style={{ display: "flex", alignItems: "baseline", gap: 18, flexWrap: "wrap" }}>
        <div className="brand">
          AL<em>BA</em>
          <small>yield vault</small>
        </div>
        <nav className="kv" style={{ margin: 0 }}>
          {tab("/vault", "overview", "vault")}
          {tab("/vault/book", "book", "book")}
          {tab("/vault/admin", "admin", "console")}
          <a href="/">credit desk →</a>
        </nav>
      </div>
      <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
        <span className={`badge ${isConnected ? "ok" : ""}`}>
          <span className="dot" />
          {isConnected ? chain?.name ?? "unknown chain" : "disconnected"}
        </span>
        {isConnected ? (
          <button className="ghost mono" onClick={() => disconnect()}>
            {address?.slice(0, 6)}…{address?.slice(-4)}
          </button>
        ) : (
          <button onClick={() => connect({ connector: connectors[0] })}>Connect</button>
        )}
      </div>
    </div>
  );
}

/** Rendered while addresses are still placeholders — every read below is gated
 * on VAULT_DEPLOYED, so the pages stay honest instead of spinning forever. */
export function DeployGate() {
  if (VAULT_DEPLOYED) return null;
  return (
    <section className="card">
      <h2>Vault contracts not deployed</h2>
      <div className="hint">
        This UI targets chain <b className="num">{VAULT_CHAIN_ID}</b>
        {VAULT_CHAIN_ID === 8453 ? " (Base mainnet)" : VAULT_CHAIN_ID === 31337 ? " (local anvil)" : ""} but no
        vault address is configured yet. Set <span className="mono">NEXT_PUBLIC_VAULT</span> (and for a local
        deployment <span className="mono">NEXT_PUBLIC_VAULT_CHAIN_ID=31337</span>,{" "}
        <span className="mono">NEXT_PUBLIC_VAULT_USDC</span>,{" "}
        <span className="mono">NEXT_PUBLIC_VAULT_START_BLOCK</span>) — the pages light up as soon as the
        addresses exist.
      </div>
    </section>
  );
}

// ------------------------------------------------------------- event scans

// Public RPCs cap eth_getLogs ranges; scan in windows (same rationale as the
// credit-desk page). While VAULT_START_BLOCK is unset on a long chain, clamp to
// a trailing window rather than walking from genesis.
const LOG_CHUNK = 8_000n;
const FALLBACK_WINDOW = 200_000n;

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function scanLogs(client: any, abi: any, address: `0x${string}`, eventName: string, latest: bigint) {
  let from = VAULT_START_BLOCK;
  if (from === 0n && latest > FALLBACK_WINDOW) from = latest - FALLBACK_WINDOW;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const out: any[] = [];
  for (let start = from; start <= latest; start += LOG_CHUNK + 1n) {
    const end = start + LOG_CHUNK > latest ? latest : start + LOG_CHUNK;
    const batch = await client.getContractEvents({ abi, address, eventName, fromBlock: start, toBlock: end });
    out.push(...batch);
  }
  return out;
}

// ------------------------------------------------------------- vault reads

export type VaultCore = {
  nav: bigint;
  liquid: bigint;
  idle: bigint;
  supply: bigint;
  sharePrice: bigint; // USDC (6 dec) per one whole share (1e12)
  feeBps: number;
  feeRecipient: `0x${string}`;
  lastFeeAccrual: number;
  paused: boolean;
  asset: `0x${string}`;
};

export function useVaultCore() {
  const client = usePublicClient({ chainId: VAULT_CHAIN_ID });
  return useQuery({
    queryKey: ["vault-core"],
    enabled: !!client && VAULT_DEPLOYED,
    refetchInterval: 12_000,
    queryFn: async (): Promise<VaultCore> => {
      const c = client!;
      const [nav, liquid, supply, feeBps, feeRecipient, lastFeeAccrual, paused, asset, sharePrice] =
        await Promise.all([
          c.readContract({ abi: vaultAbi, address: VAULT, functionName: "totalAssets" }),
          c.readContract({ abi: vaultAbi, address: VAULT, functionName: "liquidAssets" }),
          c.readContract({ abi: vaultAbi, address: VAULT, functionName: "totalSupply" }),
          c.readContract({ abi: vaultAbi, address: VAULT, functionName: "feeBps" }),
          c.readContract({ abi: vaultAbi, address: VAULT, functionName: "feeRecipient" }),
          c.readContract({ abi: vaultAbi, address: VAULT, functionName: "lastFeeAccrual" }),
          c.readContract({ abi: vaultAbi, address: VAULT, functionName: "paused" }),
          c.readContract({ abi: vaultAbi, address: VAULT, functionName: "asset" }),
          c.readContract({ abi: vaultAbi, address: VAULT, functionName: "convertToAssets", args: [SHARE_UNIT] }),
        ]);
      const idle = await c.readContract({ abi: erc20Abi, address: asset, functionName: "balanceOf", args: [VAULT] });
      return {
        nav,
        liquid,
        idle,
        supply,
        sharePrice,
        feeBps: Number(feeBps),
        feeRecipient,
        lastFeeAccrual: Number(lastFeeAccrual),
        paused,
        asset,
      };
    },
  });
}

// ---------------------------------------------------------------- sleeves

export type SleeveInfo = {
  address: `0x${string}`;
  kind: "midnight" | "metamorpho" | "unknown";
  totalAssets: bigint;
  liquidAssets: bigint;
  cap: bigint;
  active: boolean;
  target?: `0x${string}`; // MetaMorpho target vault
};

/** Walk the vault registry and classify each sleeve by probing its immutables
 * (MIDNIGHT() exists only on the Midnight sleeve, TARGET() only on MetaMorpho). */
export function useSleeves() {
  const client = usePublicClient({ chainId: VAULT_CHAIN_ID });
  return useQuery({
    queryKey: ["vault-sleeves"],
    enabled: !!client && VAULT_DEPLOYED,
    refetchInterval: 15_000,
    queryFn: async (): Promise<SleeveInfo[]> => {
      const c = client!;
      const n = await c.readContract({ abi: vaultAbi, address: VAULT, functionName: "sleeveCount" });
      const out: SleeveInfo[] = [];
      for (let i = 0n; i < n; i++) {
        const address = await c.readContract({ abi: vaultAbi, address: VAULT, functionName: "sleeves", args: [i] });
        const [cfg, totalAssets, liquidAssets] = await Promise.all([
          c.readContract({ abi: vaultAbi, address: VAULT, functionName: "sleeveConfig", args: [address] }),
          c.readContract({ abi: midnightSleeveAbi, address, functionName: "totalAssets" }),
          c.readContract({ abi: midnightSleeveAbi, address, functionName: "liquidAssets" }),
        ]);
        let kind: SleeveInfo["kind"] = "unknown";
        let target: `0x${string}` | undefined;
        try {
          await c.readContract({ abi: midnightSleeveAbi, address, functionName: "MIDNIGHT" });
          kind = "midnight";
        } catch {
          try {
            target = await c.readContract({ abi: metaMorphoSleeveAbi, address, functionName: "TARGET" });
            kind = "metamorpho";
          } catch {}
        }
        out.push({ address, kind, totalAssets, liquidAssets, cap: cfg[1], active: cfg[0], target });
      }
      return out;
    },
  });
}

// ------------------------------------------------------------ midnight book

export type MarketRow = {
  id: `0x${string}`;
  units: bigint; // outstanding face
  cost: bigint; // amortized cost basis
  maxUnits: bigint; // curator concentration cap
  lastAccrual: number;
  maturity: number;
  accruedWad: bigint;
  ratePerSecWad: bigint;
};

/** Amortized book value now: cost + linear accretion, clamped to face. This is
 * the pre-haircut carry — the sleeve's totalAssets() (which cross-checks
 * Midnight's own credit) is the authoritative number the NAV uses. */
export function marketBookValue(m: MarketRow, now: number): bigint {
  if (m.units === 0n) return 0n;
  const t = BigInt(Math.min(now, m.maturity));
  const last = BigInt(m.lastAccrual);
  let v = m.cost + (m.accruedWad + m.ratePerSecWad * (t > last ? t - last : 0n)) / WAD;
  if (v > m.units) v = m.units;
  return v;
}

/** Annualized simple yield locked into a market's book, in percent. */
export function marketYieldPct(m: MarketRow): number {
  if (m.cost === 0n) return 0;
  return (Number((m.ratePerSecWad * YEAR) / WAD) / Number(m.cost)) * 100;
}

export function useMidnightBook(sleeve?: `0x${string}`) {
  const client = usePublicClient({ chainId: VAULT_CHAIN_ID });
  return useQuery({
    queryKey: ["midnight-book", sleeve],
    enabled: !!client && !!sleeve,
    refetchInterval: 15_000,
    queryFn: async (): Promise<MarketRow[]> => {
      const c = client!;
      const address = sleeve!;
      const n = await c.readContract({ abi: midnightSleeveAbi, address, functionName: "marketCount" });
      const rows: MarketRow[] = [];
      for (let i = 0n; i < n; i++) {
        const id = await c.readContract({ abi: midnightSleeveAbi, address, functionName: "marketIds", args: [i] });
        const b = await c.readContract({ abi: midnightSleeveAbi, address, functionName: "book", args: [id] });
        rows.push({
          id,
          units: b[0],
          cost: b[1],
          maxUnits: b[2],
          lastAccrual: Number(b[3]),
          maturity: Number(b[4]),
          accruedWad: b[5],
          ratePerSecWad: b[6],
        });
      }
      return rows.sort((a, b) => a.maturity - b.maturity);
    },
  });
}

// ------------------------------------------------------------------- lots

export type Lot = {
  id: `0x${string}`; // market id
  units: bigint; // face bought
  cost: bigint; // USDC paid
  time: number; // buy timestamp
  tx: `0x${string}`;
};

export type ActivityRow = {
  key: string;
  kind: "accent" | "good" | "bad" | "plain";
  what: string;
  meta: string;
  when: string;
  block: bigint;
  tx: `0x${string}`;
};

/** Lot table + activity feed rebuilt from the sleeve's event log. Individual
 * lots are NOT stored on-chain (the sleeve aggregates per market); the events
 * are the paper trail, the book() aggregates are the accounting truth. */
export function useMidnightActivity(sleeve?: `0x${string}`) {
  const client = usePublicClient({ chainId: VAULT_CHAIN_ID });
  return useQuery({
    queryKey: ["midnight-activity", sleeve],
    enabled: !!client && !!sleeve,
    refetchInterval: 20_000,
    queryFn: async (): Promise<{ lots: Lot[]; activity: ActivityRow[] }> => {
      const c = client!;
      const address = sleeve!;
      const latest = await c.getBlockNumber();
      const [bought, redeemed, sold, allocated, deallocated] = await Promise.all([
        scanLogs(c, midnightSleeveAbi, address, "Bought", latest),
        scanLogs(c, midnightSleeveAbi, address, "Redeemed", latest),
        scanLogs(c, midnightSleeveAbi, address, "EmergencySold", latest),
        scanLogs(c, vaultAbi, VAULT, "Allocated", latest),
        scanLogs(c, vaultAbi, VAULT, "Deallocated", latest),
      ]);

      // one getBlock per unique block for buy timestamps
      const blockNums = [...new Set(bought.map((l) => l.blockNumber as bigint))];
      const stamps = new Map<bigint, number>();
      await Promise.all(
        blockNums.map(async (bn) => {
          const b = await c.getBlock({ blockNumber: bn });
          stamps.set(bn, Number(b.timestamp));
        }),
      );

      const lots: Lot[] = bought.map((l) => ({
        id: l.args.id as `0x${string}`,
        units: l.args.units as bigint,
        cost: l.args.cost as bigint,
        time: stamps.get(l.blockNumber as bigint) ?? 0,
        tx: l.transactionHash as `0x${string}`,
      }));
      lots.sort((a, b) => b.time - a.time);

      const rows: ActivityRow[] = [];
      for (const l of bought)
        rows.push({
          key: `b${l.transactionHash}${l.logIndex}`,
          tx: l.transactionHash,
          block: l.blockNumber,
          kind: "accent",
          what: "Paper bought",
          meta: `${fmt(l.args.units as bigint, VAULT_USDC_DEC, 0)} face for ${fmt(l.args.cost as bigint, VAULT_USDC_DEC, 0)} USDC · market ${fmtId(String(l.args.id))}`,
          when: `block ${l.blockNumber}`,
        });
      for (const l of redeemed)
        rows.push({
          key: `r${l.transactionHash}${l.logIndex}`,
          tx: l.transactionHash,
          block: l.blockNumber,
          kind: "good",
          what: "Par redeemed",
          meta: `${fmt(l.args.units as bigint, VAULT_USDC_DEC, 0)} USDC claimed at par · market ${fmtId(String(l.args.id))}`,
          when: `block ${l.blockNumber}`,
        });
      for (const l of sold)
        rows.push({
          key: `s${l.transactionHash}${l.logIndex}`,
          tx: l.transactionHash,
          block: l.blockNumber,
          kind: "bad",
          what: "Emergency sale",
          meta: `${fmt(l.args.units as bigint, VAULT_USDC_DEC, 0)} face sold for ${fmt(l.args.proceeds as bigint, VAULT_USDC_DEC, 0)} USDC (curator escape hatch)`,
          when: `block ${l.blockNumber}`,
        });
      for (const l of allocated)
        rows.push({
          key: `a${l.transactionHash}${l.logIndex}`,
          tx: l.transactionHash,
          block: l.blockNumber,
          kind: "plain",
          what: "Allocated",
          meta: `${fmt(l.args.assets as bigint, VAULT_USDC_DEC, 0)} USDC vault → sleeve ${fmtAddr(String(l.args.sleeve))}`,
          when: `block ${l.blockNumber}`,
        });
      for (const l of deallocated)
        rows.push({
          key: `d${l.transactionHash}${l.logIndex}`,
          tx: l.transactionHash,
          block: l.blockNumber,
          kind: "plain",
          what: "Deallocated",
          meta: `${fmt(l.args.withdrawn as bigint, VAULT_USDC_DEC, 0)} USDC sleeve ${fmtAddr(String(l.args.sleeve))} → vault`,
          when: `block ${l.blockNumber}`,
        });
      rows.sort((a, b) => (a.block === b.block ? 0 : a.block < b.block ? 1 : -1));
      return { lots, activity: rows };
    },
  });
}

// ------------------------------------------------------------ role holders

/** AccessControl has no on-chain enumeration — membership is rebuilt from
 * RoleGranted/RoleRevoked logs, replayed in order. */
export function useRoleMembers() {
  const client = usePublicClient({ chainId: VAULT_CHAIN_ID });
  return useQuery({
    queryKey: ["vault-role-members"],
    enabled: !!client && VAULT_DEPLOYED,
    refetchInterval: 30_000,
    queryFn: async (): Promise<Record<RoleKey, `0x${string}`[]>> => {
      const c = client!;
      const latest = await c.getBlockNumber();
      const [granted, revoked] = await Promise.all([
        scanLogs(c, vaultAbi, VAULT, "RoleGranted", latest),
        scanLogs(c, vaultAbi, VAULT, "RoleRevoked", latest),
      ]);
      const events = [...granted.map((l) => ({ ...l, grant: true })), ...revoked.map((l) => ({ ...l, grant: false }))];
      events.sort((a, b) =>
        a.blockNumber === b.blockNumber ? Number(a.logIndex) - Number(b.logIndex) : a.blockNumber < b.blockNumber ? -1 : 1,
      );
      const members: Record<RoleKey, Set<string>> = {
        admin: new Set(),
        curator: new Set(),
        allocator: new Set(),
        guardian: new Set(),
      };
      for (const e of events) {
        const role = String(e.args.role).toLowerCase();
        const key = (Object.keys(ROLES) as RoleKey[]).find((k) => ROLES[k].toLowerCase() === role);
        if (!key) continue;
        if (e.grant) members[key].add(String(e.args.account));
        else members[key].delete(String(e.args.account));
      }
      return {
        admin: [...members.admin] as `0x${string}`[],
        curator: [...members.curator] as `0x${string}`[],
        allocator: [...members.allocator] as `0x${string}`[],
        guardian: [...members.guardian] as `0x${string}`[],
      };
    },
  });
}

/** The connected wallet's role membership — the wallet IS the role. */
export function useMyRoles() {
  const { address } = useAccount();
  const client = usePublicClient({ chainId: VAULT_CHAIN_ID });
  return useQuery({
    queryKey: ["vault-my-roles", address],
    enabled: !!client && !!address && VAULT_DEPLOYED,
    refetchInterval: 30_000,
    queryFn: async (): Promise<Record<RoleKey, boolean>> => {
      const c = client!;
      const [admin, curator, allocator, guardian] = await Promise.all(
        (Object.keys(ROLES) as RoleKey[]).map((k) =>
          c.readContract({ abi: vaultAbi, address: VAULT, functionName: "hasRole", args: [ROLES[k], address!] }),
        ),
      );
      return { admin, curator, allocator, guardian };
    },
  });
}

// --------------------------------------------------------- maturity ladder

/** Bars per maturity bucket (face amounts), with the instant-liquidity bucket
 * at t=0 — the same hand-rolled SVG idiom as rates/src/dashboard.html. */
export function MaturityLadder({
  instant,
  buckets,
}: {
  instant: bigint | undefined;
  buckets: { maturity: number; face: bigint }[];
}) {
  const now = Math.floor(Date.now() / 1000);
  const W = 860;
  const H = 216;
  const M = { l: 14, r: 14, t: 30, b: 40 };
  const ih = H - M.t - M.b;
  const iw = W - M.l - M.r;
  const barW = 52;
  const instantX = M.l + barW / 2;
  const timeX0 = M.l + barW + 46; // where the time axis starts
  const live = buckets.filter((b) => b.face > 0n);
  const horizon = Math.max(now + 30 * 86400, ...live.map((b) => b.maturity)) + 7 * 86400;
  const span = horizon - now;
  const x = (t: number) => timeX0 + ((Math.max(t, now) - now) / span) * (M.l + iw - timeX0);
  const vmax = [instant ?? 0n, ...live.map((b) => b.face)].reduce((a, b) => (b > a ? b : a), 1n);
  const h = (v: bigint) => (v === 0n ? 0 : Math.max(3, (Number(v) / Number(vmax)) * ih));
  const y0 = M.t + ih;

  // month ticks: ~4 across the span
  const ticks: number[] = [];
  const step = Math.max(7 * 86400, Math.round(span / 4 / 86400) * 86400);
  for (let t = now + step; t < horizon; t += step) ticks.push(t);

  const bar = (cx: number, v: bigint, fill: string, labelTop: string, labelBottom: string, key: string, sub?: string) => (
    <g key={key}>
      <rect x={cx - barW / 2} y={y0 - h(v)} width={barW} height={h(v)} rx={3} fill={fill} opacity={0.85} />
      <text x={cx} y={y0 - h(v) - 8} textAnchor="middle" fontSize={11.5} fontWeight={600} fill="var(--ink-1)" style={{ fontVariantNumeric: "tabular-nums" }}>
        {labelTop}
      </text>
      <text x={cx} y={y0 + 16} textAnchor="middle" fontSize={10.5} fill="var(--ink-2)">
        {labelBottom}
      </text>
      {sub && (
        <text x={cx} y={y0 + 29} textAnchor="middle" fontSize={9.5} fill="var(--ink-3)">
          {sub}
        </text>
      )}
    </g>
  );

  return (
    <svg
      viewBox={`0 0 ${W} ${H}`}
      style={{ width: "100%", height: "auto", display: "block" }}
      role="img"
      aria-label="Liquidity ladder: instant liquidity now, then face amounts unlocking at each paper maturity"
    >
      {/* baseline + divider between the instant bucket and the time axis */}
      <line x1={M.l} y1={y0} x2={W - M.r} y2={y0} stroke="var(--grid)" strokeWidth={1} />
      <line x1={timeX0 - 24} y1={M.t - 6} x2={timeX0 - 24} y2={y0} stroke="var(--grid)" strokeWidth={1} strokeDasharray="3 4" />
      {ticks.map((t) => (
        <text key={t} x={x(t)} y={H - 4} textAnchor="middle" fontSize={10} fill="var(--ink-3)">
          {new Date(t * 1000).toLocaleDateString("en-US", { month: "short", day: "numeric" })}
        </text>
      ))}
      {bar(instantX, instant ?? 0n, "var(--good)", instant !== undefined ? fmtUsdCompact(instant) : "—", "instant", "instant", "idle + buffer")}
      {live.map((b) =>
        bar(
          x(b.maturity),
          b.face,
          b.maturity <= now ? "var(--accent)" : "var(--bench)",
          fmtUsdCompact(b.face),
          fmtDate(b.maturity),
          `m${b.maturity}${b.face}`,
          b.maturity <= now ? "matured" : `${Math.max(1, Math.round((b.maturity - now) / 86400))}d`,
        ),
      )}
      {!live.length && (
        <text x={(timeX0 + W - M.r) / 2} y={M.t + ih / 2} textAnchor="middle" fontSize={12} fill="var(--ink-3)">
          no term paper on the book yet — everything is instant
        </text>
      )}
    </svg>
  );
}
