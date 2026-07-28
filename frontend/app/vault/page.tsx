"use client";

// /vault — the depositor page: NAV, share price, blended APY, sleeve
// allocation, the maturity ladder, and deposit/withdraw with HONEST liquidity
// display. maxWithdraw reflects what actually works right now — never promise
// instant exit from term paper.

import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useAccount, useReadContract, useWriteContract } from "wagmi";
import { parseUnits } from "viem";
import { erc20Abi } from "@/lib/abi";
import { RATES_API } from "@/lib/config";
import { vaultAbi } from "@/lib/vault-abi";
import {
  VAULT,
  VAULT_CHAIN_ID,
  VAULT_DEPLOYED,
  VAULT_USDC,
  VAULT_USDC_DEC,
  SHARE_DEC,
} from "@/lib/vault-config";
import {
  DeployGate,
  MaturityLadder,
  VaultHeader,
  WAD,
  YEAR,
  AddrLink,
  fmt,
  fmtDate,
  fmtUsdCompact,
  marketYieldPct,
  useMidnightBook,
  useNow,
  useSleeves,
  useVaultCore,
} from "./shared";

export default function VaultPage() {
  return (
    <main>
      <VaultHeader active="overview" />
      <DeployGate />
      {VAULT_DEPLOYED && (
        <>
          <OverviewCard />
          <AllocationCard />
          <LadderCard />
          <PositionCard />
        </>
      )}
      <section className="card">
        <h2>How this vault holds its shape</h2>
        <div className="hint">
          NAV is <b>idle USDC + every sleeve&apos;s reported value</b>. Midnight paper is carried at{" "}
          <b>amortized cost</b> — purchase price accreting linearly to par — so the share price is deterministic:
          no oracle, no mark-to-market, no manipulation surface. Withdrawal limits reflect only what is instantly
          liquid; the rest unlocks as paper matures. The whole book is public —{" "}
          <a href="/vault/book">inspect every lot →</a>
        </div>
      </section>
    </main>
  );
}

function useRates() {
  return useQuery({
    queryKey: ["vault-rates"],
    queryFn: async () => (await fetch(`${RATES_API}/api/rates`)).json(),
    refetchInterval: 90_000,
    retry: 1,
  });
}

function OverviewCard() {
  const core = useVaultCore();
  const sleeves = useSleeves();
  const midnight = sleeves.data?.find((s) => s.kind === "midnight");
  const buffer = sleeves.data?.find((s) => s.kind === "metamorpho");
  const book = useMidnightBook(midnight?.address);
  const rates = useRates();
  const now = useNow(15_000);

  const c = core.data;
  // Locked-in paper accretion, USDC/yr (only markets still accreting).
  const paperYr = (book.data ?? [])
    .filter((m) => m.maturity > now)
    .reduce((s, m) => s + (m.ratePerSecWad * YEAR) / WAD, 0n);
  const floatPct = rates.data?.floating?.composite?.borrowApr as number | undefined;
  const nav = c ? Number(c.nav) : 0;
  const paperPct = nav > 0 ? (Number(paperYr) / nav) * 100 : 0;
  const bufferPct = nav > 0 && buffer && floatPct !== undefined ? (Number(buffer.totalAssets) / nav) * floatPct : undefined;
  const feePct = c ? c.feeBps / 100 : 0;
  const blended = c && nav > 0 ? paperPct + (bufferPct ?? 0) - feePct : undefined;

  return (
    <section className="card">
      <h2>
        Alba USDC vault <span className="mono">albaUSDC</span>
        <span style={{ float: "right" }}>
          <span className={`badge ${c ? (c.paused ? "warn" : "ok") : ""}`}>
            <span className="dot" />
            {c ? (c.paused ? "PAUSED — deposits & withdrawals frozen" : "live") : "loading"}
          </span>
        </span>
      </h2>
      <div className="row">
        <div className="tile accent">
          <div className="label">NAV</div>
          <div className="value num">{fmt(c?.nav, VAULT_USDC_DEC, 0)}</div>
          <div className="sub">USDC · idle + Σ sleeve book values</div>
        </div>
        <div className="tile">
          <div className="label">Share price</div>
          <div className="value num">{c ? Number(fmt(c.sharePrice, VAULT_USDC_DEC, 6)).toFixed(6) : "—"}</div>
          <div className="sub">USDC per albaUSDC · amortized cost, no oracle</div>
        </div>
        <div className="tile">
          <div className="label">Blended APY (est.)</div>
          <div className="value num">{blended !== undefined ? `${blended.toFixed(2)}%` : "—"}</div>
          <div className="sub">
            paper {paperPct.toFixed(2)}% locked
            {bufferPct !== undefined ? ` · buffer ${bufferPct.toFixed(2)}% floating` : " · buffer floating (est. unavailable)"}
            {feePct ? ` · −${feePct.toFixed(2)}% fee` : " · no fee"}
          </div>
        </div>
        <div className="tile">
          <div className="label">Instant liquidity</div>
          <div className="value num">{fmt(c?.liquid, VAULT_USDC_DEC, 0)}</div>
          <div className="sub">USDC withdrawable right now, vault-wide</div>
        </div>
      </div>
      <div className="kv">
        <span>
          management fee <b className="num">{c ? `${(c.feeBps / 100).toFixed(2)}%/yr` : "—"}</b>
          {c && c.feeBps > 0 && (
            <>
              {" "}
              → <AddrLink addr={c.feeRecipient} />
            </>
          )}
        </span>
        <span>
          sleeves <b className="num">{sleeves.data?.length ?? "—"}</b>
        </span>
        <span>
          vault <AddrLink addr={VAULT} />
        </span>
        <span>
          chain <b className="num">{VAULT_CHAIN_ID}</b>
        </span>
      </div>
    </section>
  );
}

function AllocationCard() {
  const core = useVaultCore();
  const sleeves = useSleeves();
  const midnight = sleeves.data?.find((s) => s.kind === "midnight");
  const buffer = sleeves.data?.find((s) => s.kind === "metamorpho");
  const c = core.data;
  const nav = c?.nav ?? 0n;
  const pct = (v: bigint | undefined) => (v !== undefined && nav > 0n ? Number((v * 10_000n) / nav) / 100 : 0);
  const segs = [
    { label: "idle USDC", v: c?.idle, color: "var(--good)", sub: "in the vault, instant" },
    { label: "MetaMorpho buffer", v: buffer?.totalAssets, color: "var(--accent)", sub: "floating rate, instant-ish" },
    { label: "Midnight paper", v: midnight?.totalAssets, color: "var(--bench)", sub: "term, unlocks at maturity" },
  ];
  return (
    <section className="card">
      <h2>Allocation — where the money sits</h2>
      <div className="meter" style={{ height: 14, display: "flex", marginTop: 4 }}>
        {segs.map((s) => (
          <div
            key={s.label}
            title={`${s.label} ${pct(s.v).toFixed(1)}%`}
            style={{ width: `${pct(s.v)}%`, background: s.color, borderRadius: 0 }}
          />
        ))}
      </div>
      <div className="kv">
        {segs.map((s) => (
          <span key={s.label}>
            <span style={{ display: "inline-block", width: 9, height: 9, borderRadius: 2, background: s.color, marginRight: 6 }} />
            {s.label} <b className="num">{fmt(s.v, VAULT_USDC_DEC, 0)}</b>{" "}
            <span style={{ color: "var(--ink-3)" }}>
              ({pct(s.v).toFixed(1)}% · {s.sub})
            </span>
          </span>
        ))}
      </div>
      {buffer && (
        <div className="hint">
          buffer cap {fmtUsdCompact(buffer.cap)} · paper cap {midnight ? fmtUsdCompact(midnight.cap) : "—"} — curator
          caps bound every allocation on-chain
        </div>
      )}
    </section>
  );
}

function LadderCard() {
  const core = useVaultCore();
  const sleeves = useSleeves();
  const midnight = sleeves.data?.find((s) => s.kind === "midnight");
  const book = useMidnightBook(midnight?.address);
  const buckets = (book.data ?? []).map((m) => ({ maturity: m.maturity, face: m.units }));
  const wavg =
    book.data && book.data.some((m) => m.units > 0n)
      ? book.data.reduce((s, m) => s + marketYieldPct(m) * Number(m.cost), 0) /
        book.data.reduce((s, m) => s + Number(m.cost), 0)
      : undefined;
  return (
    <section className="card">
      <h2>Maturity ladder — when money comes home</h2>
      <MaturityLadder instant={core.data?.liquid} buckets={buckets} />
      <div className="hint">
        each bar is face value redeeming at par on that date{wavg !== undefined ? (
          <>
            {" "}
            · book-weighted locked yield <b className="num">{wavg.toFixed(2)}%</b>
          </>
        ) : null}{" "}
        · paper is never sold to serve a withdrawal — it matures on schedule
      </div>
    </section>
  );
}

function PositionCard() {
  const { address, isConnected } = useAccount();
  const core = useVaultCore();
  const sleeves = useSleeves();
  const midnight = sleeves.data?.find((s) => s.kind === "midnight");
  const book = useMidnightBook(midnight?.address);
  const { writeContractAsync, isPending } = useWriteContract();
  const now = useNow(15_000);

  const [depositAmt, setDepositAmt] = useState("");
  const [withdrawAmt, setWithdrawAmt] = useState("");
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");

  const asset = core.data?.asset ?? VAULT_USDC;
  const usdcBal = useReadContract({
    abi: erc20Abi, address: asset, functionName: "balanceOf",
    args: address ? [address] : undefined, chainId: VAULT_CHAIN_ID,
    query: { enabled: !!address, refetchInterval: 10_000 },
  });
  const allowance = useReadContract({
    abi: erc20Abi, address: asset, functionName: "allowance",
    args: address ? [address, VAULT] : undefined, chainId: VAULT_CHAIN_ID,
    query: { enabled: !!address, refetchInterval: 10_000 },
  });
  const shareBal = useReadContract({
    abi: vaultAbi, address: VAULT, functionName: "balanceOf",
    args: address ? [address] : undefined, chainId: VAULT_CHAIN_ID,
    query: { enabled: !!address, refetchInterval: 10_000 },
  });
  const positionValue = useReadContract({
    abi: vaultAbi, address: VAULT, functionName: "convertToAssets",
    args: shareBal.data !== undefined ? [shareBal.data] : undefined, chainId: VAULT_CHAIN_ID,
    query: { enabled: shareBal.data !== undefined, refetchInterval: 10_000 },
  });
  const maxW = useReadContract({
    abi: vaultAbi, address: VAULT, functionName: "maxWithdraw",
    args: address ? [address] : undefined, chainId: VAULT_CHAIN_ID,
    query: { enabled: !!address, refetchInterval: 10_000 },
  });
  const maxD = useReadContract({
    abi: vaultAbi, address: VAULT, functionName: "maxDeposit",
    args: address ? [address] : undefined, chainId: VAULT_CHAIN_ID,
    query: { enabled: !!address, refetchInterval: 15_000 },
  });

  const depositUnits = useMemo(() => {
    try { return parseUnits(depositAmt || "0", VAULT_USDC_DEC); } catch { return 0n; }
  }, [depositAmt]);
  const withdrawUnits = useMemo(() => {
    try { return parseUnits(withdrawAmt || "0", VAULT_USDC_DEC); } catch { return 0n; }
  }, [withdrawAmt]);

  const previewShares = useReadContract({
    abi: vaultAbi, address: VAULT, functionName: "previewDeposit",
    args: [depositUnits], chainId: VAULT_CHAIN_ID,
    query: { enabled: depositUnits > 0n, refetchInterval: 15_000 },
  });
  const previewBurn = useReadContract({
    abi: vaultAbi, address: VAULT, functionName: "previewWithdraw",
    args: [withdrawUnits], chainId: VAULT_CHAIN_ID,
    query: { enabled: withdrawUnits > 0n, refetchInterval: 15_000 },
  });

  const paused = core.data?.paused ?? false;
  // maxDeposit is uint256.max unless paused — respect it without rendering it.
  const depositBlocked = maxD.data !== undefined && depositUnits > maxD.data;
  const needsApproval = allowance.data !== undefined && depositUnits > 0n && allowance.data < depositUnits;
  const overMax = maxW.data !== undefined && withdrawUnits > maxW.data;

  const upcoming = (book.data ?? []).filter((m) => m.units > 0n && m.maturity > now);

  const refresh = () => {
    usdcBal.refetch(); allowance.refetch(); shareBal.refetch();
    positionValue.refetch(); maxW.refetch(); core.refetch();
  };

  async function onDeposit() {
    setError("");
    try {
      if (needsApproval) {
        setStatus("approving USDC to the vault…");
        await writeContractAsync({
          abi: erc20Abi, address: asset, functionName: "approve",
          args: [VAULT, depositUnits], chainId: VAULT_CHAIN_ID,
        });
        await allowance.refetch();
        setStatus("approved — confirm the deposit");
        return;
      }
      setStatus("depositing…");
      await writeContractAsync({
        abi: vaultAbi, address: VAULT, functionName: "deposit",
        args: [depositUnits, address!], chainId: VAULT_CHAIN_ID,
      });
      setStatus("deposited ✓ — shares minted at the current NAV price");
      setDepositAmt("");
      refresh();
    } catch (e: unknown) {
      setError(String((e as Error).message ?? e).slice(0, 200));
      setStatus("");
    }
  }

  async function onWithdraw() {
    setError("");
    try {
      setStatus("withdrawing — served from idle, then the buffer…");
      await writeContractAsync({
        abi: vaultAbi, address: VAULT, functionName: "withdraw",
        args: [withdrawUnits, address!, address!], chainId: VAULT_CHAIN_ID,
      });
      setStatus("withdrawn ✓");
      setWithdrawAmt("");
      refresh();
    } catch (e: unknown) {
      setError(String((e as Error).message ?? e).slice(0, 200));
      setStatus("");
    }
  }

  return (
    <section className="card">
      <h2>Your position</h2>
      <div className="row">
        <div className="tile">
          <div className="label">Shares</div>
          <div className="value num">{fmt(shareBal.data, SHARE_DEC, 4)}</div>
          <div className="sub">albaUSDC (12 decimals)</div>
        </div>
        <div className="tile accent">
          <div className="label">Value</div>
          <div className="value num">{fmt(positionValue.data, VAULT_USDC_DEC, 2)}</div>
          <div className="sub">USDC at current NAV</div>
        </div>
        <div className="tile">
          <div className="label">Withdrawable now</div>
          <div className="value num">{fmt(maxW.data, VAULT_USDC_DEC, 2)}</div>
          <div className="sub">min(your value, vault instant liquidity)</div>
        </div>
      </div>

      <div className="row" style={{ alignItems: "center", marginTop: 14 }}>
        <input
          value={depositAmt}
          onChange={(e) => setDepositAmt(e.target.value.replace(/[^0-9.]/g, ""))}
          inputMode="decimal"
          placeholder="deposit USDC"
          aria-label="deposit amount in USDC"
        />
        <span style={{ color: "var(--ink-3)" }}>
          {depositUnits > 0n ? <>≈ <b className="num">{fmt(previewShares.data, SHARE_DEC, 4)}</b> shares</> : <>balance {fmt(usdcBal.data, VAULT_USDC_DEC, 2)}</>}
        </span>
        <button onClick={onDeposit} disabled={!isConnected || isPending || depositUnits === 0n || paused || depositBlocked}>
          {needsApproval ? "Approve USDC" : "Deposit"}
        </button>
      </div>

      <div className="row" style={{ alignItems: "center", marginTop: 8 }}>
        <input
          value={withdrawAmt}
          onChange={(e) => setWithdrawAmt(e.target.value.replace(/[^0-9.]/g, ""))}
          inputMode="decimal"
          placeholder="withdraw USDC"
          aria-label="withdraw amount in USDC"
        />
        <button
          className="ghost"
          style={{ padding: "6px 12px" }}
          disabled={maxW.data === undefined}
          onClick={() => maxW.data !== undefined && setWithdrawAmt(fmt(maxW.data, VAULT_USDC_DEC, 6).replace(/,/g, ""))}
        >
          max
        </button>
        <span style={{ color: "var(--ink-3)" }}>
          {withdrawUnits > 0n && <>burns ≈ <b className="num">{fmt(previewBurn.data, SHARE_DEC, 4)}</b> shares</>}
        </span>
        <button onClick={onWithdraw} disabled={!isConnected || isPending || withdrawUnits === 0n || paused || overMax}>
          Withdraw
        </button>
      </div>

      {/* the honest-liquidity line: what works NOW, and when the rest arrives */}
      <div className="hint">
        instant: <b className="num">{fmt(core.data?.liquid, VAULT_USDC_DEC, 0)} USDC</b> vault-wide (idle{" "}
        {fmt(core.data?.idle, VAULT_USDC_DEC, 0)} + buffer) · more unlocks as paper matures:{" "}
        {upcoming.length
          ? upcoming.map((m, i) => (
              <span key={m.id}>
                {i > 0 && " · "}
                <b>{fmtDate(m.maturity)}</b> +{fmtUsdCompact(m.units)}
              </span>
            ))
          : "no term paper outstanding"}
      </div>
      {overMax && (
        <div className="err">
          amount exceeds instant liquidity — {fmt(maxW.data, VAULT_USDC_DEC, 2)} USDC works right now; the rest
          arrives on the maturity dates above (paper is never fire-sold to fund an exit)
        </div>
      )}
      {paused && <div className="err">vault is paused — deposits and withdrawals are frozen until the admin resumes</div>}
      {status && <div className="hint">{status}</div>}
      {error && <div className="err">{error}</div>}
    </section>
  );
}
