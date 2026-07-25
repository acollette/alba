"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import {
  useAccount,
  useConnect,
  useDisconnect,
  usePublicClient,
  useReadContract,
  useWriteContract,
} from "wagmi";
import { formatUnits, parseUnits, toHex } from "viem";
import { escrowAbi, routerAbi, erc20Abi, oracleAbi } from "@/lib/abi";
import {
  ADDR,
  FACILITY_ID,
  FACILITY_SIZE,
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
type Role = "lender" | "borrower";

export default function Page() {
  const { address } = useAccount();
  const { facility } = useFacility();
  const lenderAddr = facility?.[1]?.toLowerCase();
  const borrowerAddr = facility?.[2]?.borrower?.toLowerCase();
  const you = address?.toLowerCase();
  const youAreLender = !!you && you === lenderAddr;
  const youAreBorrower = !!you && you === borrowerAddr;

  const [role, setRole] = useState<Role>("borrower");
  const touched = useRef(false);
  useEffect(() => {
    if (touched.current) return;
    if (youAreLender && !youAreBorrower) setRole("lender");
    if (youAreBorrower) setRole("borrower");
  }, [youAreLender, youAreBorrower]);

  return (
    <main>
      <Header />
      <div className="tabs" role="tablist" aria-label="view as">
        {(["lender", "borrower"] as Role[]).map((r) => (
          <button
            key={r}
            role="tab"
            aria-selected={role === r}
            className={role === r ? "active" : ""}
            onClick={() => {
              touched.current = true;
              setRole(r);
            }}
          >
            {r === "lender" ? "Lender" : "Borrower"}
            {((r === "lender" && youAreLender) || (r === "borrower" && youAreBorrower)) && (
              <span className="you">YOU</span>
            )}
          </button>
        ))}
      </div>

      <FacilityCard role={role} />
      {role === "borrower" ? (
        <>
          <BorrowerObligations />
          <DrawPanel />
        </>
      ) : (
        <LenderBook />
      )}
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
        <small>committed credit, settled by schedule</small>
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

function useFacility() {
  const facility = useReadContract({
    abi: escrowAbi,
    address: ADDR.escrow,
    functionName: "facilities",
    args: [FACILITY_ID],
  });
  const order = facility.data?.[0];
  const facilityHash = useReadContract({
    abi: routerAbi,
    address: ADDR.router,
    functionName: "hash",
    args: order ? [order] : undefined,
    query: { enabled: !!order },
  });
  const lender = facility.data?.[1];
  const drawn = useReadContract({
    abi: routerAbi,
    address: ADDR.router,
    functionName: "coveredAmount",
    args: lender && facilityHash.data ? [lender, facilityHash.data] : undefined,
    query: { enabled: !!lender && !!facilityHash.data, refetchInterval: 8000 },
  });
  return { facility: facility.data, drawn: drawn.data };
}

type DrawRow = {
  drawId: `0x${string}`;
  principal: bigint;
  collateral: bigint;
  debt: bigint;
  maturity: number;
  state: number;
  healthy: boolean;
  value: bigint;
  required: bigint;
};

function useDraws() {
  const client = usePublicClient();
  return useQuery({
    queryKey: ["draws"],
    enabled: !!client,
    refetchInterval: 15_000,
    queryFn: async (): Promise<DrawRow[]> => {
      const latest = await client!.getBlockNumber();
      const events = await client!.getContractEvents({
        abi: escrowAbi,
        address: ADDR.escrow,
        eventName: "Drawn",
        fromBlock: START_BLOCK,
        toBlock: latest,
      });
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

function FacilityCard({ role }: { role: Role }) {
  const { facility, drawn } = useFacility();
  const params = facility?.[2];
  const oraclePrice = useReadContract({
    abi: oracleAbi,
    address: ADDR.oracle,
    functionName: "answer",
    query: { refetchInterval: 8000 },
  });

  const rates = useQuery({
    queryKey: ["rates"],
    queryFn: async () => (await fetch(`${RATES_API}/api/rates`)).json(),
    refetchInterval: 90_000,
    retry: 1,
  });

  const available = drawn !== undefined ? FACILITY_SIZE - drawn : undefined;
  const rate = params ? Number(params.rateBps) / 100 : undefined;
  const bench = rates.data?.fixed?.benchmark90d?.aprPct as number | undefined;
  const model = rates.data?.suggested90d?.suggestedAprPct as number | undefined;
  const term = params ? Number(params.termSeconds) : undefined;

  return (
    <section className="card">
      <h2>
        Facility <span className="mono">0xFAC</span> · cbBTC / USDC
      </h2>
      <div className="row">
        <div className="tile">
          <div className="label">{role === "lender" ? "Your commitment" : "Committed"}</div>
          <div className="value num">{fmt(FACILITY_SIZE, USDC_DEC, 0)}</div>
          <div className="sub">
            {role === "lender" ? "USDC · never leaves your wallet until drawn" : "USDC · standing Aqua order"}
          </div>
        </div>
        <div className="tile accent">
          <div className="label">{role === "lender" ? "Deployed" : "Drawn"}</div>
          <div className="value num">{fmt(drawn, USDC_DEC, 0)}</div>
          <div className="sub">{role === "lender" ? "earning 4.60% fixed" : "cumulative, on-chain accounting"}</div>
        </div>
        <div className="tile">
          <div className="label">{role === "lender" ? "Undrawn" : "Available"}</div>
          <div className="value num">{fmt(available, USDC_DEC, 0)}</div>
          <div className="sub">
            {role === "lender" ? "committed capacity at rest" : "draw on demand, collateral per draw"}
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
        <span>
          margining{" "}
          <b className="num">
            {params
              ? `${Number(params.collateralRatioBps) / 100}% / ${Number(params.maintenanceRatioBps) / 100}%`
              : "—"}
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

function BorrowerObligations() {
  const draws = useDraws();
  const active = (draws.data ?? []).filter((d) => d.state === 1);
  if (!active.length) return null;
  return (
    <section className="card">
      <h2>Your obligations</h2>
      {active.map((d) => {
        const ratio = d.required > 0n ? Number((d.value * 1000n) / d.required) / 1000 : 2;
        const warn = ratio < 1.08;
        return (
          <div key={d.drawId} style={{ marginBottom: 14 }}>
            <div className="kv" style={{ marginTop: 0 }}>
              <span>
                draw <b className="mono">{d.drawId.slice(0, 10)}…</b>
              </span>
              <span>
                owed <b className="num">{fmt(d.debt, USDC_DEC, 0)} USDC</b>
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
              collateral covers <b className="num">{(ratio * 115).toFixed(0)}%</b> of debt · maintenance floor 115% ·
              breach first meets a CURE from your authorized funds, never a fire sale
            </div>
          </div>
        );
      })}
    </section>
  );
}

function LenderBook() {
  const draws = useDraws();
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
              <th>accrued owed</th>
              <th>matures</th>
              <th>collateral</th>
              <th>status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((d) => (
              <tr key={d.drawId}>
                <td className="mono">{d.drawId.slice(0, 10)}…</td>
                <td>{fmt(d.principal, USDC_DEC, 0)}</td>
                <td>{d.state === 1 ? fmt(d.debt, USDC_DEC, 0) : "—"}</td>
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

function DrawPanel() {
  const { isConnected, address } = useAccount();
  const [amount, setAmount] = useState("25000");
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

  const collateral = useReadContract({
    abi: escrowAbi,
    address: ADDR.escrow,
    functionName: "collateralForDraw",
    args: [FACILITY_ID, amountUnits],
    query: { enabled: amountUnits > 0n, refetchInterval: 15_000 },
  });

  const allowance = useReadContract({
    abi: erc20Abi,
    address: ADDR.cbbtc,
    functionName: "allowance",
    args: address ? [address, ADDR.escrow] : undefined,
    query: { enabled: !!address, refetchInterval: 8000 },
  });

  const needsApproval =
    collateral.data !== undefined && allowance.data !== undefined && allowance.data < collateral.data;

  async function onApprove() {
    setError("");
    try {
      setStatus("approving collateral…");
      await writeContractAsync({
        abi: erc20Abi,
        address: ADDR.cbbtc,
        functionName: "approve",
        args: [ADDR.escrow, collateral.data! * 2n],
      });
      setStatus("approved");
    } catch (e: unknown) {
      setError(String((e as Error).message ?? e).slice(0, 200));
      setStatus("");
    }
  }

  async function onDraw() {
    setError("");
    try {
      setStatus("drawing — collateral in, cash out, one transaction…");
      const drawId = toHex(BigInt(Date.now()), { size: 32 });
      await writeContractAsync({
        abi: escrowAbi,
        address: ADDR.escrow,
        functionName: "draw",
        args: [FACILITY_ID, drawId, amountUnits],
      });
      setStatus(`drawn ✓ drawId ${drawId.slice(0, 10)}…`);
    } catch (e: unknown) {
      setError(String((e as Error).message ?? e).slice(0, 200));
      setStatus("");
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
          requires <b className="num">{fmt(collateral.data, CBBTC_DEC, 4)}</b> cbBTC at the live oracle mark
        </span>
        {needsApproval ? (
          <button onClick={onApprove} disabled={!isConnected || isPending}>
            Approve cbBTC
          </button>
        ) : (
          <button onClick={onDraw} disabled={!isConnected || isPending || amountUnits === 0n}>
            Draw
          </button>
        )}
      </div>
      <div className="hint">
        One transaction: collateral locks in the escrow and the facility&apos;s Aqua order pays out — the escrow is the
        only doorway (<span className="mono">_onlyTaker</span>), so drawn funds without locked collateral are
        structurally impossible.
      </div>
      {status && <div className="hint">{status}</div>}
      {error && <div className="err">{error}</div>}
    </section>
  );
}

type Row = { key: string; kind: "accent" | "good" | "bad" | "plain"; what: string; meta: string; when: string };

function Timeline() {
  const client = usePublicClient();

  const logs = useQuery({
    queryKey: ["timeline"],
    enabled: !!client,
    refetchInterval: 15_000,
    queryFn: async (): Promise<Row[]> => {
      const rows: Row[] = [];
      const latest = await client!.getBlockNumber();
      const from = START_BLOCK;
      const [drawn, cured, released, armed] = await Promise.all([
        client!.getContractEvents({ abi: escrowAbi, address: ADDR.escrow, eventName: "Drawn", fromBlock: from, toBlock: latest }),
        client!.getContractEvents({ abi: escrowAbi, address: ADDR.escrow, eventName: "DrawCured", fromBlock: from, toBlock: latest }),
        client!.getContractEvents({ abi: escrowAbi, address: ADDR.escrow, eventName: "CollateralReleased", fromBlock: from, toBlock: latest }),
        client!.getContractEvents({ abi: escrowAbi, address: ADDR.escrow, eventName: "AuctionArmed", fromBlock: from, toBlock: latest }),
      ]);
      for (const l of drawn)
        rows.push({
          key: `d${l.transactionHash}${l.logIndex}`,
          kind: "accent",
          what: "Drawn",
          meta: `${fmt(l.args.amount, USDC_DEC, 0)} USDC against ${fmt(l.args.collateral, CBBTC_DEC, 4)} cbBTC · draw ${String(l.args.drawId).slice(0, 10)}…`,
          when: `block ${l.blockNumber}`,
        });
      for (const l of cured)
        rows.push({
          key: `c${l.transactionHash}${l.logIndex}`,
          kind: "good",
          what: l.args.fullClose ? "Cured — closed early" : "Cured — draw lives on",
          meta: `${fmt(l.args.amountPulled, USDC_DEC, 0)} USDC pulled from pre-authorized funds, zero penalty`,
          when: `block ${l.blockNumber}`,
        });
      for (const l of released)
        rows.push({
          key: `r${l.transactionHash}${l.logIndex}`,
          kind: "good",
          what: "Collateral released",
          meta: `${fmt(l.args.amount, CBBTC_DEC, 4)} cbBTC home to the borrower`,
          when: `block ${l.blockNumber}`,
        });
      for (const l of armed)
        rows.push({
          key: `a${l.transactionHash}${l.logIndex}`,
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
              {s.schedule_id} {s.executed_timestamp ? "— executed by the network" : "— armed, waiting"}
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
            <span className="t-when num">{r.when}</span>
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
