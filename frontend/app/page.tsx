"use client";

import { useEffect, useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import {
  useAccount,
  useConnect,
  useDisconnect,
  usePublicClient,
  useSwitchChain,
  useReadContract,
  useWriteContract,
} from "wagmi";
import { formatUnits, parseUnits, toHex } from "viem";
import { hederaTestnet } from "wagmi/chains";
import {
  escrowAbi,
  erc20Abi,
  oracleAbi,
  builderAbi,
  aquaAbi,
  executorAbi,
  triggerAbi,
  registerFacilityAbi,
} from "@/lib/abi";
import {
  ADDR,
  AQUA,
  BUILDER,
  EXECUTOR,
  CHAIN_ID,
  DEFAULT_FACILITY_ID,
  START_BLOCK,
  RATES_API,
  HEDERA_MIRROR,
  HEDERA_TRIGGER,
  USDC_DEC,
  CBBTC_DEC,
} from "@/lib/config";

const fmt = (v: bigint | undefined, dec: number, digits = 2) =>
  v === undefined ? "—" : Number(formatUnits(v, dec)).toLocaleString("en-US", { maximumFractionDigits: digits });

const STATE_LABEL = ["—", "active", "settled", "auction", "liquidated"] as const;
const EXPLORER = "https://sepolia.basescan.org";
const fmtDrawId = (id: string) => {
  try {
    const v = BigInt(id);
    if (v < 1_000_000_000n) return `#${v.toString()}`;
  } catch {}
  return `${id.slice(0, 6)}…${id.slice(-4)}`;
};

// Public RPCs cap eth_getLogs ranges; scan in windows so the book/timeline never
// silently empty as the chain advances past a single-range limit.
const LOG_CHUNK = 8_000n;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function scanEvents(client: any, eventName: string, from: bigint, to: bigint, args?: object) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const out: any[] = [];
  for (let start = from; start <= to; start += LOG_CHUNK + 1n) {
    const end = start + LOG_CHUNK > to ? to : start + LOG_CHUNK;
    const batch = await client.getContractEvents({
      abi: escrowAbi, address: ADDR.escrow, eventName, args, fromBlock: start, toBlock: end,
    });
    out.push(...batch);
  }
  return out;
}
type Role = "lender" | "borrower" | "observer";

function useFacilityParam(): { ready: boolean; id: `0x${string}` | null } {
  const [state, setState] = useState<{ ready: boolean; id: `0x${string}` | null }>({ ready: false, id: null });
  useEffect(() => {
    const q = new URLSearchParams(window.location.search).get("facility");
    setState({ ready: true, id: q && /^0x[0-9a-fA-F]{64}$/.test(q) ? (q as `0x${string}`) : null });
  }, []);
  return state;
}

export default function Page() {
  const { ready, id } = useFacilityParam();
  if (!ready) return <main />;
  return id ? <DealPage facilityId={id} /> : <DeskOverview />;
}

/// The aggregate view: every facility on the desk — ongoing and past — plus the
/// global machine timeline. Each row opens the shareable single-deal page.
function DeskOverview() {
  const { isConnected } = useAccount();
  const facilities = useAllFacilities();
  return (
    <main>
      <Header />
      <section className="card">
        <h2>Facilities — the desk</h2>
        {facilities.data?.length ? (
          <table className="list">
            <thead>
              <tr>
                <th>facility</th>
                <th>lender</th>
                <th>borrower</th>
                <th>commitment</th>
                <th>outstanding</th>
                <th>rate</th>
                <th>term</th>
                <th>availability</th>
                <th>status</th>
              </tr>
            </thead>
            <tbody>
              {facilities.data.map((f) => (
                <tr key={f.id}>
                  <td className="mono">
                    <a href={`/?facility=${f.id}`} title="open the deal page (shareable link)">
                      {fmtDrawId(f.id)} ↗
                    </a>
                  </td>
                  <td className="mono">{f.lender.slice(0, 6)}…{f.you === "lender" ? " (you)" : ""}</td>
                  <td className="mono">{f.borrower.slice(0, 6)}…{f.you === "borrower" ? " (you)" : ""}</td>
                  <td>{fmt(f.commitment, USDC_DEC, 0)}</td>
                  <td>{fmt(f.outstanding, USDC_DEC, 0)}</td>
                  <td>{(f.rateBps / 100).toFixed(2)}%</td>
                  <td>{f.termSeconds >= 86400 ? `${Math.round(f.termSeconds / 86400)}d` : `${f.termSeconds}s`}</td>
                  <td>{new Date(f.availabilityEnd * 1000).toLocaleDateString()}</td>
                  <td>
                    <span className={`badge ${f.status === "active" ? "ok" : ""}`}>
                      <span className="dot" />
                      {f.status}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <div className="hint">
            {facilities.isLoading ? "scanning the chain…" : "no facilities yet — publish the first deal below"}
          </div>
        )}
        <div className="hint">
          every row is a shareable deal link — copy the URL it opens and send it in Telegram
        </div>
      </section>
      {isConnected && <NewDealCard />}
      <Timeline />
    </main>
  );
}

type FacilityRow = {
  id: `0x${string}`;
  lender: string;
  borrower: string;
  commitment: bigint;
  outstanding: bigint;
  rateBps: number;
  termSeconds: number;
  availabilityEnd: number;
  status: "active" | "standing by" | "closed";
  you: "lender" | "borrower" | null;
};

function useAllFacilities() {
  const client = usePublicClient({ chainId: CHAIN_ID });
  const { address } = useAccount();
  const you = address?.toLowerCase();
  return useQuery({
    queryKey: ["all-facilities", you],
    enabled: !!client,
    refetchInterval: 20_000,
    queryFn: async (): Promise<FacilityRow[]> => {
      const latest = await client!.getBlockNumber();
      const regs = await scanEvents(client, "FacilityRegistered", START_BLOCK, latest);
      const rows = await Promise.all(
        regs.map(async (e: { args: { facilityId: `0x${string}` } }) => {
          const id = e.args.facilityId;
          const [f, outstanding] = await Promise.all([
            client!.readContract({ abi: escrowAbi, address: ADDR.escrow, functionName: "facilities", args: [id] }),
            client!.readContract({ abi: escrowAbi, address: ADDR.escrow, functionName: "outstandingOf", args: [id] }),
          ]);
          const p = f[2];
          const open = Date.now() / 1000 <= Number(p.availabilityEnd);
          return {
            id,
            lender: f[1],
            borrower: p.borrower,
            commitment: p.commitment,
            outstanding,
            rateBps: Number(p.rateBps),
            termSeconds: Number(p.termSeconds),
            availabilityEnd: Number(p.availabilityEnd),
            status: outstanding > 0n ? "active" : open ? "standing by" : "closed",
            you:
              you === f[1].toLowerCase() ? "lender" : you === p.borrower.toLowerCase() ? "borrower" : null,
          } as FacilityRow;
        }),
      );
      return rows;
    },
  });
}

function DealPage({ facilityId }: { facilityId: `0x${string}` }) {
  const { address, isConnected } = useAccount();
  const { facility } = useFacility(facilityId);
  const lenderAddr = facility?.[1]?.toLowerCase();
  const borrowerAddr = facility?.[2]?.borrower?.toLowerCase();
  const you = address?.toLowerCase();

  // Production semantics: the WALLET decides the role — no toggles, no impersonation.
  const role: Role = !you
    ? "observer"
    : you === lenderAddr
      ? "lender"
      : you === borrowerAddr
        ? "borrower"
        : "observer";

  return (
    <main>
      <Header />

      <div className="kv" style={{ margin: "0 0 16px" }}>
        <a href="/">← all deals</a>
        <span className={`badge ${role !== "observer" ? "ok" : ""}`}>
          <span className="dot" />
          {!isConnected
            ? "connect a wallet — the deal recognizes its parties by address"
            : role === "lender"
              ? "viewing as LENDER — your wallet is this facility's lender"
              : role === "borrower"
                ? "viewing as BORROWER — this deal was sold to your name"
                : "observer — this wallet is not a party; read-only"}
        </span>
      </div>

      <FacilityCard facilityId={facilityId} role={role} />
      {role === "borrower" && (
        <>
          <BorrowerObligations facilityId={facilityId} />
          <DrawPanel facilityId={facilityId} isParty={true} />
        </>
      )}
      {role === "lender" && <LenderBook facilityId={facilityId} />}
      <Timeline />
    </main>
  );
}

function Header() {
  const { address, isConnected, chain } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  return (
    <div className="topbar">
      <div className="brand">
        AL<em>BA</em>
        <small>credit desk</small>
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

function useFacility(facilityId: `0x${string}`) {
  const facility = useReadContract({
    abi: escrowAbi,
    address: ADDR.escrow,
    functionName: "facilities",
    args: [facilityId],
    chainId: CHAIN_ID,
  });
  // Lifetime gross volume = sum of Drawn events. (Not the router's coveredAmount:
  // the facility leg no longer carries a _stopWhenCovered odometer — it would fight
  // the revolving — so the event log is the source of truth for turnover.)
  const client = usePublicClient({ chainId: CHAIN_ID });
  const lifetime = useQuery({
    queryKey: ["lifetime", facilityId],
    enabled: !!client,
    refetchInterval: 15_000,
    queryFn: async (): Promise<bigint> => {
      const latest = await client!.getBlockNumber();
      const events = await scanEvents(client, "Drawn", START_BLOCK, latest, { facilityId });
      return events.reduce((sum: bigint, e: { args: { amount: bigint } }) => sum + e.args.amount, 0n);
    },
  });
  const available = useReadContract({
    abi: escrowAbi,
    address: ADDR.escrow,
    functionName: "availableToDraw",
    args: [facilityId],
    chainId: CHAIN_ID,
    query: { refetchInterval: 8000 },
  });
  return { facility: facility.data, lifetime: lifetime.data, available: available.data };
}

type DrawRow = {
  drawId: `0x${string}`;
  txHash: `0x${string}`;
  principal: bigint;
  collateral: bigint;
  debt: bigint;
  maturity: number;
  state: number;
  healthy: boolean;
  value: bigint;
  required: bigint;
};

function useDraws(facilityId: `0x${string}`) {
  const client = usePublicClient({ chainId: CHAIN_ID });
  return useQuery({
    queryKey: ["draws", facilityId],
    enabled: !!client,
    refetchInterval: 15_000,
    queryFn: async (): Promise<DrawRow[]> => {
      const latest = await client!.getBlockNumber();
      const events = await scanEvents(client, "Drawn", START_BLOCK, latest, { facilityId });
      const rows = await Promise.all(
        events.map(async (e) => {
          const id = e.args.drawId as `0x${string}`;
          const [d, debt, health] = await Promise.all([
            client!.readContract({ abi: escrowAbi, address: ADDR.escrow, functionName: "draws", args: [id] }),
            client!.readContract({ abi: escrowAbi, address: ADDR.escrow, functionName: "debtOf", args: [id] }),
            client!
              .readContract({ abi: escrowAbi, address: ADDR.escrow, functionName: "isHealthy", args: [id] })
              .catch(() => [true, 0n, 0n] as const),
          ]);
          return {
            drawId: id,
            txHash: e.transactionHash as `0x${string}`,
            principal: d[4],
            collateral: d[3],
            debt,
            maturity: Number(d[7]),
            state: Number(d[8]),
            healthy: health[0],
            value: health[1],
            required: health[2],
          };
        }),
      );
      return rows.sort((a, b) => b.maturity - a.maturity);
    },
  });
}

function FacilityCard({ facilityId, role }: { facilityId: `0x${string}`; role: Role }) {
  const { facility, lifetime, available } = useFacility(facilityId);
  const params = facility?.[2];
  const oraclePrice = useReadContract({
    abi: oracleAbi,
    address: (params?.oracle as `0x${string}`) ?? ADDR.oracle,
    functionName: "answer",
    chainId: CHAIN_ID,
    query: { refetchInterval: 8000 },
  });

  const rates = useQuery({
    queryKey: ["rates"],
    queryFn: async () => (await fetch(`${RATES_API}/api/rates`)).json(),
    refetchInterval: 90_000,
    retry: 1,
  });

  const commitment = params?.commitment;
  const outstanding =
    commitment !== undefined && available !== undefined ? commitment - available : undefined;
  const rate = params ? Number(params.rateBps) / 100 : undefined;
  const bench = rates.data?.fixed?.benchmark90d?.aprPct as number | undefined;
  const model = rates.data?.suggested90d?.suggestedAprPct as number | undefined;
  const term = params ? Number(params.termSeconds) : undefined;

  return (
    <section className="card">
      <h2>
        Facility <span className="mono">{fmtDrawId(facilityId)}</span> · cbBTC / USDC
      </h2>
      <div className="row">
        <div className="tile">
          <div className="label">{role === "lender" ? "Your commitment" : "Committed"}</div>
          <div className="value num">{fmt(commitment, USDC_DEC, 0)}</div>
          <div className="sub">
            {role === "lender" ? "USDC · never leaves your wallet until drawn" : "USDC · standing Aqua order"}
          </div>
        </div>
        <div className="tile accent">
          <div className="label">Outstanding</div>
          <div className="value num">{fmt(outstanding, USDC_DEC, 0)}</div>
          <div className="sub">
            {role === "lender"
              ? rate !== undefined
                ? `earning ${rate.toFixed(2)}% fixed · ${fmt(lifetime, USDC_DEC, 0)} lifetime volume`
                : "earning fixed"
              : `repaying replenishes capacity · ${fmt(lifetime, USDC_DEC, 0)} lifetime volume`}
          </div>
        </div>
        <div className="tile">
          <div className="label">{role === "lender" ? "Undrawn" : "Available"}</div>
          <div className="value num">{fmt(available, USDC_DEC, 0)}</div>
          <div className="sub">
            {role === "lender" ? "committed capacity at rest" : "revolving — draw, repay, draw again"}
          </div>
        </div>
      </div>
      <div className="kv">
        <span>
          rate <b className="num">{rate !== undefined ? `${rate.toFixed(2)}%` : "—"}</b>
        </span>
        <span>
          term{" "}
          <b className="num">
            {term !== undefined ? (term >= 86400 ? `${Math.round(term / 86400)}d` : `${term}s`) : "—"}
          </b>
        </span>
        <span title="collateral factor — the required initial margin">
          max LTV{" "}
          <b className="num">{params ? `${(1e6 / Number(params.collateralRatioBps)).toFixed(1)}%` : "—"}</b>
        </span>
        <span title="liquidation threshold — below this the cure→auction waterfall runs">
          liq. threshold{" "}
          <b className="num">{params ? `${(1e6 / Number(params.maintenanceRatioBps)).toFixed(1)}%` : "—"}</b>
        </span>
        <span>
          availability until{" "}
          <b>
            {params?.availabilityEnd ? new Date(Number(params.availabilityEnd) * 1000).toLocaleDateString() : "—"}
          </b>
        </span>
        <span>
          cbBTC oracle{" "}
          <b className="num">{oraclePrice.data !== undefined ? `$${fmt(oraclePrice.data as bigint, 8, 0)}` : "—"}</b>
        </span>
      </div>
      <div className="ratesline" style={{ marginTop: 12 }}>
        <span>
          Midnight 90d <b className="bench num">{bench !== undefined ? `${bench.toFixed(2)}%` : "—"}</b>
        </span>
        <span>
          floating composite{" "}
          <b className="num">
            {rates.data?.floating?.composite?.borrowApr !== undefined
              ? `${rates.data.floating.composite.borrowApr.toFixed(2)}%`
              : "—"}
          </b>
        </span>
        <span>
          desk model <b className="num">{model !== undefined ? `${model.toFixed(2)}%` : "—"}</b>
        </span>
        {rate !== undefined && model !== undefined && (
          <span>
            this facility{" "}
            <b className="num">
              {(rate - model >= 0 ? "+" : "−") + Math.abs(Math.round((rate - model) * 100)) + "bps"}
            </b>{" "}
            vs model
          </span>
        )}
        <a href={`${RATES_API}/`} target="_blank" rel="noreferrer">
          live curve →
        </a>
      </div>
    </section>
  );
}

function BorrowerObligations({ facilityId }: { facilityId: `0x${string}` }) {
  const draws = useDraws(facilityId);
  const { facility } = useFacility(facilityId);
  // live clock so the term bar and countdown tick every second
  const [now, setNow] = useState(() => Date.now() / 1000);
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now() / 1000), 1000);
    return () => clearInterval(t);
  }, []);
  const params = facility?.[2];
  const maint = params ? Number(params.maintenanceRatioBps) / 10_000 : 1.15;
  const term = params ? Number(params.termSeconds) : 0;
  const active = (draws.data ?? []).filter((d) => d.state === 1);
  if (!active.length) return null;
  return (
    <section className="card">
      <h2>Your obligations</h2>
      {active.map((d) => {
        const ratio = d.required > 0n ? Number((d.value * 1000n) / d.required) / 1000 : 2;
        const warn = ratio < 1.08;
        const elapsedPct = term > 0 ? Math.min(100, Math.max(0, ((now - (d.maturity - term)) / term) * 100)) : 0;
        const left = Math.max(0, d.maturity - now);
        const leftLabel =
          left >= 86400 ? `${Math.floor(left / 86400)}d ${Math.floor((left % 86400) / 3600)}h`
          : left >= 3600 ? `${Math.floor(left / 3600)}h ${Math.floor((left % 3600) / 60)}m`
          : `${Math.floor(left / 60)}m ${Math.floor(left % 60)}s`;
        return (
          <div key={d.drawId} style={{ marginBottom: 14 }}>
            <div className="kv" style={{ marginTop: 0 }}>
              <span>
                draw{" "}
                <a className="mono" href={`${EXPLORER}/tx/${d.txHash}`} target="_blank" rel="noreferrer">
                  <b>{fmtDrawId(d.drawId)} ↗</b>
                </a>
              </span>
              <span>
                owed <b className="num">{fmt(d.debt, USDC_DEC, 2)} USDC</b>{" "}
                <span style={{ color: "var(--ink-3)" }}>
                  (incl. {fmt(d.debt - d.principal, USDC_DEC, 2)} interest, accruing per second)
                </span>
              </span>
              <span>
                matures <b>{new Date(d.maturity * 1000).toLocaleString()}</b>
              </span>
              <span>
                collateral <b className="num">{fmt(d.collateral, CBBTC_DEC, 4)} cbBTC</b>
              </span>
              <span className={`badge ${d.healthy ? "ok" : "warn"}`}>
                <span className="dot" />
                {d.healthy ? "healthy" : "breached"}
              </span>
            </div>
            <div className={`meter ${warn ? "warn" : ""}`} title="collateral value vs maintenance requirement">
              <div style={{ width: `${Math.min(100, ratio * 66.7).toFixed(1)}%` }} />
            </div>
            <div className="hint">
              collateral covers <b className="num">{(ratio * maint * 100).toFixed(0)}%</b> of debt · liquidation price{" "}
              <b className="num">
                $
                {((Number(d.debt) / 1e6) * maint / (Number(d.collateral) / 1e8)).toLocaleString("en-US", {
                  maximumFractionDigits: 0,
                })}
              </b>{" "}
              · breach first meets a CURE from your authorized funds, never a fire sale
            </div>
            <div className="meter" title="term elapsed — the network settles this at maturity">
              <div style={{ width: `${elapsedPct.toFixed(2)}%`, background: "#2a78d6" }} />
            </div>
            <div className="hint">
              {left > 0 ? (
                <>term <b className="num">{elapsedPct.toFixed(0)}%</b> elapsed · settles by schedule in{" "}
                <b className="num">{leftLabel}</b> — no action needed, repayment pulls itself</>
              ) : (
                <>matured — awaiting the scheduled settlement pull</>
              )}
            </div>
            <TopUp drawId={d.drawId} />
          </div>
        );
      })}
    </section>
  );
}

function LenderBook({ facilityId }: { facilityId: `0x${string}` }) {
  const draws = useDraws(facilityId);
  const { facility } = useFacility(facilityId);
  const ratePct = facility?.[2] ? Number(facility[2].rateBps) / 100 : undefined;
  const rows = draws.data ?? [];
  const income = rows.filter((d) => d.state === 2);
  return (
    <section className="card">
      <h2>Your book — receivables by draw</h2>
      {rows.length ? (
        <table className="list">
          <thead>
            <tr>
              <th>draw</th>
              <th>principal</th>
              <th>rate</th>
              <th>owed (accruing)</th>
              <th>interest to date</th>
              <th>matures</th>
              <th>collateral</th>
              <th>status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((d) => (
              <tr key={d.drawId}>
                <td className="mono">
                  <a href={`${EXPLORER}/tx/${d.txHash}`} target="_blank" rel="noreferrer" title="view the draw transaction on Basescan">
                    {fmtDrawId(d.drawId)} ↗
                  </a>
                </td>
                <td>{fmt(d.principal, USDC_DEC, 0)}</td>
                <td>{ratePct !== undefined ? `${ratePct.toFixed(2)}%` : "—"}</td>
                <td>{d.state === 1 ? fmt(d.debt, USDC_DEC, 2) : "—"}</td>
                <td>{d.state === 1 ? fmt(d.debt - d.principal, USDC_DEC, 2) : "—"}</td>
                <td>{new Date(d.maturity * 1000).toLocaleDateString()}</td>
                <td>{fmt(d.collateral, CBBTC_DEC, 4)} cbBTC</td>
                <td>
                  <span className={`badge ${d.state === 2 ? "ok" : d.state >= 3 ? "warn" : d.healthy ? "ok" : "warn"}`}>
                    <span className="dot" />
                    {d.state === 1 && !d.healthy ? "breached" : STATE_LABEL[d.state]}
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      ) : (
        <div className="hint">no draws yet — committed capacity is standing by</div>
      )}
      <div className="hint">
        {income.length
          ? `${income.length} draw${income.length > 1 ? "s" : ""} settled to your wallet — pulled via Aqua, no signature ever requested`
          : "settlements pull straight to your wallet at maturity — no action, no signature, ever"}
      </div>
    </section>
  );
}

/// Beat 2 — origination: configure the deal, publish (approve + ship + register), share the link
function NewDealCard() {
  const { address, isConnected } = useAccount();
  const client = usePublicClient({ chainId: CHAIN_ID });
  const { writeContractAsync } = useWriteContract();

  const [borrower, setBorrower] = useState("");
  const [size, setSize] = useState("300000");
  const [ratePct, setRatePct] = useState("4.60");
  const [termSecs, setTermSecs] = useState("420");
  const [availDays, setAvailDays] = useState("364");
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");
  const [dealLink, setDealLink] = useState("");
  const [busy, setBusy] = useState(false);

  async function publish() {
    setError("");
    setDealLink("");
    if (!/^0x[0-9a-fA-F]{40}$/.test(borrower)) return setError("borrower must be an address (the deal has a name)");
    setBusy(true);
    try {
      const sizeUnits = parseUnits(size, USDC_DEC);
      const grossCeiling = sizeUnits * 4n; // Aqua safety rail; the escrow meters revolving capacity
      const rateBps = BigInt(Math.round(Number(ratePct) * 100));
      const termSeconds = BigInt(Math.round(Number(termSecs)));
      // Small ID so every facility displays as "#NNNNN" (a duplicate reverts loudly
      // on-chain — registerFacility rejects existing ids, Aqua rejects re-ships)
      const salt = BigInt(10_000 + Math.floor(Math.random() * 90_000));
      const facilityId = toHex(salt, { size: 32 });

      setStatus("1/3 approving USDC to Aqua (pull rights, funds stay put)…");
      const allowance = await client!.readContract({
        abi: erc20Abi, address: ADDR.usdc, functionName: "allowance", args: [address!, AQUA],
      });
      if (allowance < grossCeiling) {
        await writeContractAsync({
          abi: erc20Abi, address: ADDR.usdc, functionName: "approve", args: [AQUA, grossCeiling], chainId: CHAIN_ID,
        });
      }

      setStatus("2/3 shipping the facility order to Aqua…");
      const [order, strategy, tokens, amounts] = await client!.readContract({
        abi: builderAbi,
        address: BUILDER,
        functionName: "buildFacilityLeg",
        args: [
          { maker: address!, counterToken: ADDR.cbbtc, pullToken: ADDR.usdc, amount: grossCeiling, salt },
          ADDR.escrow,
        ],
      });
      await writeContractAsync({
        abi: aquaAbi, address: AQUA, functionName: "ship",
        args: [ADDR.router, strategy, tokens as `0x${string}`[], amounts as bigint[]], chainId: CHAIN_ID,
      });

      setStatus("3/3 registering the deal (one name on each side)…");
      await writeContractAsync({
        abi: registerFacilityAbi, address: ADDR.escrow, functionName: "registerFacility",
        args: [
          facilityId,
          order,
          {
            borrower: borrower as `0x${string}`,
            loanToken: ADDR.usdc,
            collateralToken: ADDR.cbbtc,
            oracle: ADDR.oracle,
            collateralRatioBps: 13_699n, // 73% max LTV
            maintenanceRatioBps: 12_821n, // 78% liquidation threshold
            rateBps,
            termSeconds: Number(termSeconds),
            auctionDuration: 3600,
            auctionDecay: 999940000000000000n,
            commitment: sizeUnits,
            availabilityEnd: Math.floor(Date.now() / 1000) + Math.round(Number(availDays) * 86400),
          },
        ],
        chainId: CHAIN_ID,
      });

      const link = `${window.location.origin}/?facility=${facilityId}`;
      setDealLink(link);
      setStatus("published — funds never left your wallet. Send the link.");
    } catch (e: unknown) {
      setError(String((e as Error).message ?? e).slice(0, 220));
      setStatus("");
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="card">
      <h2>New deal — configure, publish, send the link</h2>
      <div className="row" style={{ alignItems: "center" }}>
        <input
          style={{ width: 340 }}
          className="mono"
          placeholder="borrower address (the counterparty's name)"
          value={borrower}
          onChange={(e) => setBorrower(e.target.value.trim())}
        />
        <input value={size} onChange={(e) => setSize(e.target.value.replace(/[^0-9.]/g, ""))} aria-label="size USDC" />
        <span style={{ color: "var(--ink-2)" }}>USDC ·</span>
        <input
          style={{ width: 80 }}
          value={ratePct}
          onChange={(e) => setRatePct(e.target.value.replace(/[^0-9.]/g, ""))}
          aria-label="rate percent"
        />
        <span style={{ color: "var(--ink-2)" }}>% ·</span>
        <input
          style={{ width: 90 }}
          value={termSecs}
          onChange={(e) => setTermSecs(e.target.value.replace(/[^0-9]/g, ""))}
          aria-label="term seconds"
        />
        <span style={{ color: "var(--ink-2)" }} title="420s = 7-minute demo tenor · 7,776,000 = 90 days">
          sec draws ·
        </span>
        <input
          style={{ width: 70 }}
          value={availDays}
          onChange={(e) => setAvailDays(e.target.value.replace(/[^0-9.]/g, ""))}
          aria-label="availability days"
        />
        <span style={{ color: "var(--ink-2)" }}>day availability · margining LTV 73% / LT 78%</span>
        <button onClick={publish} disabled={!isConnected || busy}>
          Publish
        </button>
      </div>
      {status && <div className="hint">{status}</div>}
      {dealLink && (
        <div className="hint">
          deal link:{" "}
          <a href={dealLink} className="mono">
            {dealLink}
          </a>{" "}
          <button className="ghost" style={{ padding: "3px 10px" }} onClick={() => navigator.clipboard.writeText(dealLink)}>
            copy
          </button>{" "}
          — send it in Telegram; the borrower opens it, sees terms as code, and accepts by approving collateral.
        </div>
      )}
      {error && <div className="err">{error}</div>}
    </section>
  );
}

function TopUp({ drawId }: { drawId: `0x${string}` }) {
  const [amt, setAmt] = useState("");
  const { writeContractAsync, isPending } = useWriteContract();
  const [note, setNote] = useState("");
  async function go() {
    try {
      setNote("topping up — your liquidation price moves down…");
      await writeContractAsync({
        abi: escrowAbi,
        address: ADDR.escrow,
        functionName: "topUpCollateral",
        args: [drawId, parseUnits(amt || "0", CBBTC_DEC)],
        chainId: CHAIN_ID,
      });
      setNote("topped up ✓");
      setAmt("");
    } catch (e: unknown) {
      setNote(String((e as Error).message ?? e).slice(0, 120));
    }
  }
  return (
    <div className="row" style={{ alignItems: "center", marginTop: 6 }}>
      <input
        style={{ width: 110 }}
        placeholder="cbBTC"
        value={amt}
        onChange={(e) => setAmt(e.target.value.replace(/[^0-9.]/g, ""))}
        aria-label="top-up collateral amount"
      />
      <button className="ghost" onClick={go} disabled={isPending || !amt}>
        Top up collateral
      </button>
      {note && <span className="hint" style={{ marginTop: 0 }}>{note}</span>}
    </div>
  );
}

function DrawPanel({ facilityId, isParty }: { facilityId: `0x${string}`; isParty: boolean }) {
  const { isConnected, address } = useAccount();
  const client = usePublicClient({ chainId: CHAIN_ID });
  const { switchChainAsync } = useSwitchChain();
  const [amount, setAmount] = useState("25000");
  const [extra, setExtra] = useState("0");
  const { writeContractAsync, isPending } = useWriteContract();
  const [status, setStatus] = useState<string>("");
  const [error, setError] = useState<string>("");

  const amountUnits = useMemo(() => {
    try {
      return parseUnits(amount || "0", USDC_DEC);
    } catch {
      return 0n;
    }
  }, [amount]);
  const extraUnits = useMemo(() => {
    try {
      return parseUnits(extra || "0", CBBTC_DEC);
    } catch {
      return 0n;
    }
  }, [extra]);

  const collateral = useReadContract({
    abi: escrowAbi,
    address: ADDR.escrow,
    functionName: "collateralForDraw",
    args: [facilityId, amountUnits],
    chainId: CHAIN_ID,
    query: { enabled: amountUnits > 0n, refetchInterval: 15_000 },
  });

  const allowance = useReadContract({
    abi: erc20Abi,
    address: ADDR.cbbtc,
    functionName: "allowance",
    args: address ? [address, ADDR.escrow] : undefined,
    chainId: CHAIN_ID,
    query: { enabled: !!address, refetchInterval: 8000 },
  });

  const totalCollateral = collateral.data !== undefined ? collateral.data + extraUnits : undefined;
  const liqPreview =
    totalCollateral && totalCollateral > 0n && amountUnits > 0n
      ? ((Number(amountUnits) / 1e6) * 1.15) / (Number(totalCollateral) / 1e8)
      : undefined;
  const needsApproval =
    totalCollateral !== undefined && allowance.data !== undefined && allowance.data < totalCollateral;

  async function onApprove() {
    setError("");
    try {
      setStatus("approving collateral — this is the acceptance: terms are code…");
      await writeContractAsync({
        abi: erc20Abi,
        address: ADDR.cbbtc,
        functionName: "approve",
        args: [ADDR.escrow, totalCollateral! * 2n],
        chainId: CHAIN_ID,
      });
      setStatus("accepted — you can draw whenever you need the cash");
    } catch (e: unknown) {
      setError(String((e as Error).message ?? e).slice(0, 200));
      setStatus("");
    }
  }

  // Draw = the whole machine arms itself: cash out on Base, repayment pull-rights
  // shipped, settlement registered, and the HEDERA SCHEDULE created (wallet switches
  // network for one signature, then switches back). Two chains — so the button chains
  // the prompts; it cannot be one signature.
  async function onDraw() {
    setError("");
    try {
      // Small ID → renders "#NNNNN" like script-made draws; duplicates revert on-chain
      const drawIdNum = BigInt(10_000 + Math.floor(Math.random() * 90_000));
      const drawId = toHex(drawIdNum, { size: 32 });

      setStatus("1/6 drawing — collateral in, cash out, one transaction…");
      // waitForTransactionReceipt after EVERY step: the next step's args are read from
      // chain state this tx creates — proceeding at broadcast (not mined) makes the
      // wallet estimate against stale state and flag the next tx "likely to fail"
      const mined = async (hash: `0x${string}`) => client!.waitForTransactionReceipt({ hash });
      await mined(await writeContractAsync({
        abi: escrowAbi, address: ADDR.escrow, functionName: "draw",
        args: [facilityId, drawId, amountUnits, extraUnits], chainId: CHAIN_ID,
      }));

      setStatus("2/6 authorizing repayment pulls (USDC → Aqua, funds stay put)…");
      const allowance = await client!.readContract({
        abi: erc20Abi, address: ADDR.usdc, functionName: "allowance", args: [address!, AQUA],
      });
      const repayment = await client!.readContract({
        abi: escrowAbi, address: ADDR.escrow, functionName: "repaymentOf", args: [drawId],
      });
      if (allowance < repayment * 4n) {
        await mined(await writeContractAsync({
          abi: erc20Abi, address: ADDR.usdc, functionName: "approve",
          args: [AQUA, (1n << 256n) - 1n], chainId: CHAIN_ID,
        }));
      }

      setStatus("3/6 shipping the CURE leg — your no-penalty liquidation tier…");
      // Read-after-write across a load-balanced RPC: the receipt can come from one node
      // and this read hit a lagging one. Poll until the draw is visible everywhere —
      // shipping a zero-token order would be flagged (rightly) by the wallet.
      let cure = await client!.readContract({
        abi: escrowAbi, address: ADDR.escrow, functionName: "cureOrder", args: [drawId],
      });
      for (let tries = 0; cure[0].maker === "0x0000000000000000000000000000000000000000" && tries < 15; tries++) {
        await new Promise((r) => setTimeout(r, 1500));
        cure = await client!.readContract({
          abi: escrowAbi, address: ADDR.escrow, functionName: "cureOrder", args: [drawId],
        });
      }
      if (cure[0].maker === "0x0000000000000000000000000000000000000000") {
        throw new Error("draw not yet visible on the RPC — wait a few seconds and re-try; the draw itself is safe");
      }
      await mined(await writeContractAsync({
        abi: aquaAbi, address: AQUA, functionName: "ship",
        args: [ADDR.router, cure[1], [...cure[2]], [...cure[3]]], chainId: CHAIN_ID,
      }));

      setStatus("4/6 shipping the maturity leg — the repayment, pre-authorized…");
      const d = await client!.readContract({
        abi: escrowAbi, address: ADDR.escrow, functionName: "draws", args: [drawId],
      });
      const maturity = BigInt(d[7]);
      const leg = await client!.readContract({
        abi: builderAbi, address: BUILDER, functionName: "buildMaturityLeg",
        args: [
          { maker: address!, counterToken: ADDR.cbbtc, pullToken: ADDR.usdc, amount: repayment, salt: drawIdNum },
          Number(maturity), EXECUTOR,
        ],
      });
      await mined(await writeContractAsync({
        abi: aquaAbi, address: AQUA, functionName: "ship",
        args: [ADDR.router, leg[1], [...leg[2]], [...leg[3]]], chainId: CHAIN_ID,
      }));

      setStatus("5/6 registering the settlement with the cross-chain executor…");
      await mined(await writeContractAsync({
        abi: executorAbi, address: EXECUTOR, functionName: "registerSettlement",
        args: [drawId, leg[0], ADDR.cbbtc, ADDR.usdc], chainId: CHAIN_ID,
      }));

      setStatus("6/6 switching to Hedera — the network takes the appointment…");
      await switchChainAsync({ chainId: hederaTestnet.id });
      await writeContractAsync({
        abi: triggerAbi, address: HEDERA_TRIGGER, functionName: "scheduleDispatch",
        args: [BigInt(facilityId), drawIdNum, "SETTLE", maturity + 90n, 2_000_000n, 45_000_000n],
        chainId: hederaTestnet.id,
      });
      await switchChainAsync({ chainId: CHAIN_ID });
      setStatus(`drawn ✓ ${fmtDrawId(drawId)} — Hedera settles it at maturity, no further action`);
    } catch (e: unknown) {
      setError(String((e as Error).message ?? e).slice(0, 200));
      setStatus((s) => (s ? s + " — failed here; funds from completed steps are safe" : ""));
      try { await switchChainAsync({ chainId: CHAIN_ID }); } catch {}
    }
  }

  return (
    <section className="card">
      <h2>Draw</h2>
      <div className="row" style={{ alignItems: "center" }}>
        <input
          value={amount}
          onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))}
          inputMode="decimal"
          aria-label="draw amount in USDC"
        />
        <span style={{ color: "var(--ink-2)" }}>USDC</span>
        <span style={{ color: "var(--ink-3)" }}>
          requires <b className="num">{fmt(collateral.data, CBBTC_DEC, 4)}</b> cbBTC · extra
        </span>
        <input
          style={{ width: 90 }}
          value={extra}
          onChange={(e) => setExtra(e.target.value.replace(/[^0-9.]/g, ""))}
          aria-label="voluntary extra collateral"
        />
        <span style={{ color: "var(--ink-3)" }}>
          cbBTC → liq. price{" "}
          <b className="num">
            {liqPreview ? `$${liqPreview.toLocaleString("en-US", { maximumFractionDigits: 0 })}` : "—"}
          </b>
        </span>
        {needsApproval ? (
          <button onClick={onApprove} disabled={!isConnected || isPending}>
            Accept &amp; approve cbBTC
          </button>
        ) : (
          <button onClick={onDraw} disabled={!isConnected || isPending || amountUnits === 0n || !isParty}>
            Draw
          </button>
        )}
      </div>
      <div className="hint">
        Draw arms the whole machine: collateral locks and cash pays out in one tx, then your wallet ships the
        cure + repayment pull-rights, registers the settlement, and books the HEDERA SCHEDULE (one network
        switch) — from then on the loan settles itself.
      </div>
      {status && <div className="hint">{status}</div>}
      {error && <div className="err">{error}</div>}
    </section>
  );
}

type Row = {
  key: string;
  kind: "accent" | "good" | "bad" | "plain";
  what: string;
  meta: string;
  when: string;
  tx?: string;
};

function Timeline() {
  const client = usePublicClient({ chainId: CHAIN_ID });

  const logs = useQuery({
    queryKey: ["timeline"],
    enabled: !!client,
    refetchInterval: 15_000,
    queryFn: async (): Promise<Row[]> => {
      const rows: Row[] = [];
      const latest = await client!.getBlockNumber();
      const [drawn, cured, released, armed] = await Promise.all([
        scanEvents(client, "Drawn", START_BLOCK, latest),
        scanEvents(client, "DrawCured", START_BLOCK, latest),
        scanEvents(client, "CollateralReleased", START_BLOCK, latest),
        scanEvents(client, "AuctionArmed", START_BLOCK, latest),
      ]);
      for (const l of drawn)
        rows.push({
          key: `d${l.transactionHash}${l.logIndex}`,
          tx: l.transactionHash,
          kind: "accent",
          what: "Drawn",
          meta: `${fmt(l.args.amount, USDC_DEC, 0)} USDC against ${fmt(l.args.collateral, CBBTC_DEC, 4)} cbBTC · draw ${String(l.args.drawId).slice(0, 10)}…`,
          when: `block ${l.blockNumber}`,
        });
      for (const l of cured)
        rows.push({
          key: `c${l.transactionHash}${l.logIndex}`,
          tx: l.transactionHash,
          kind: "good",
          what: l.args.fullClose ? "Cured — closed early" : "Cured — draw lives on",
          meta: `${fmt(l.args.amountPulled, USDC_DEC, 0)} USDC pulled from pre-authorized funds, zero penalty`,
          when: `block ${l.blockNumber}`,
        });
      for (const l of released)
        rows.push({
          key: `r${l.transactionHash}${l.logIndex}`,
          tx: l.transactionHash,
          kind: "good",
          what: "Collateral released",
          meta: `${fmt(l.args.amount, CBBTC_DEC, 4)} cbBTC home to the borrower`,
          when: `block ${l.blockNumber}`,
        });
      for (const l of armed)
        rows.push({
          key: `a${l.transactionHash}${l.logIndex}`,
          tx: l.transactionHash,
          kind: "bad",
          what: "Auction armed",
          meta: `Dutch auction targeting ${fmt(l.args.target, USDC_DEC, 0)} USDC — halts the moment the lender is whole`,
          when: `block ${l.blockNumber}`,
        });
      rows.sort((a, b) => (a.when < b.when ? 1 : -1));
      return rows;
    },
  });

  const schedules = useQuery({
    queryKey: ["hedera-schedules"],
    refetchInterval: 60_000,
    retry: 1,
    queryFn: async () => {
      const acc = await (await fetch(`${HEDERA_MIRROR}/api/v1/accounts/${HEDERA_TRIGGER}`)).json();
      if (!acc?.account) return [];
      const sch = await (
        await fetch(`${HEDERA_MIRROR}/api/v1/schedules?account.id=${acc.account}&order=desc&limit=5`)
      ).json();
      return (sch?.schedules ?? []) as { schedule_id: string; executed_timestamp: string | null }[];
    },
  });

  return (
    <section className="card">
      <h2>Timeline — the machine, observable</h2>
      <ul className="timeline">
        {(schedules.data ?? []).map((s) => (
          <li key={s.schedule_id}>
            <span className={`t-dot ${s.executed_timestamp ? "good" : ""}`} />
            <span className="t-what">Hedera schedule</span>
            <span className="t-meta mono">
              <a href={`https://hashscan.io/testnet/schedule/${s.schedule_id}`} target="_blank" rel="noreferrer">
                {s.schedule_id} ↗
              </a>{" "}
              {s.executed_timestamp ? "— executed by the network" : "— armed, waiting"}
            </span>
            <span className="t-when">
              {s.executed_timestamp
                ? new Date(Number(s.executed_timestamp.split(".")[0]) * 1000).toLocaleTimeString()
                : ""}
            </span>
          </li>
        ))}
        {(logs.data ?? []).map((r) => (
          <li key={r.key}>
            <span className={`t-dot ${r.kind === "plain" ? "" : r.kind}`} />
            <span className="t-what">{r.what}</span>
            <span className="t-meta">{r.meta}</span>
            <span className="t-when num">
              {r.tx ? (
                <a href={`${EXPLORER}/tx/${r.tx}`} target="_blank" rel="noreferrer">
                  {r.when} ↗
                </a>
              ) : (
                r.when
              )}
            </span>
          </li>
        ))}
        {!logs.data?.length && !schedules.data?.length && (
          <li>
            <span className="t-dot" />
            <span className="t-meta">loading on-chain history…</span>
          </li>
        )}
      </ul>
      <div className="hint">
        Escrow events from Base Sepolia · schedule IDs from the Hedera mirror node — every step of the loop is public
        state, no servers involved.
      </div>
    </section>
  );
}
