"use client";

// /vault/admin — roles-gated curator console. House pattern: the WALLET is the
// role — membership is read from the vault's AccessControl, no toggles, no
// impersonation. Non-holders see everything read-only.

import { useState } from "react";
import { useAccount, useWriteContract } from "wagmi";
import { parseUnits } from "viem";
import { vaultAbi } from "@/lib/vault-abi";
import {
  VAULT,
  VAULT_CHAIN_ID,
  VAULT_DEPLOYED,
  VAULT_USDC_DEC,
  MAX_FEE_BPS,
} from "@/lib/vault-config";
import {
  AddrLink,
  DeployGate,
  VaultHeader,
  fmt,
  fmtAddr,
  fmtUsdCompact,
  useMyRoles,
  useRoleMembers,
  useSleeves,
  useVaultCore,
  type RoleKey,
} from "../shared";

const ROLE_LABEL: Record<RoleKey, { name: string; desc: string }> = {
  admin: { name: "DEFAULT_ADMIN", desc: "multisig + timelock — grants roles, unpauses" },
  curator: { name: "CURATOR", desc: "sleeve registry, caps, fees" },
  allocator: { name: "ALLOCATOR", desc: "bots — move funds within caps" },
  guardian: { name: "GUARDIAN", desc: "circuit breaker — pause only" },
};

export default function AdminPage() {
  const { isConnected } = useAccount();
  const roles = useMyRoles();
  const isCurator = roles.data?.curator ?? false;
  const isGuardian = roles.data?.guardian ?? false;
  const isAdmin = roles.data?.admin ?? false;
  const anyRole = isCurator || isGuardian || isAdmin || (roles.data?.allocator ?? false);
  return (
    <main>
      <VaultHeader active="admin" />
      <div className="kv" style={{ margin: "0 0 16px" }}>
        <span className={`badge ${anyRole ? "ok" : ""}`}>
          <span className="dot" />
          {!isConnected
            ? "connect a wallet — the console recognizes roles by address"
            : anyRole
              ? `authorized — ${(Object.keys(ROLE_LABEL) as RoleKey[])
                  .filter((k) => roles.data?.[k])
                  .map((k) => ROLE_LABEL[k].name)
                  .join(" · ")}`
              : "observer — this wallet holds no role; everything below is read-only"}
        </span>
      </div>
      <DeployGate />
      {VAULT_DEPLOYED && (
        <>
          <RolesCard />
          <SleeveRegistryCard canEdit={isCurator} />
          <FeeCard canEdit={isCurator} />
          <PauseCard isGuardian={isGuardian} isAdmin={isAdmin} />
        </>
      )}
    </main>
  );
}

function RolesCard() {
  const members = useRoleMembers();
  const { address } = useAccount();
  const you = address?.toLowerCase();
  return (
    <section className="card">
      <h2>Roles — read from the vault&apos;s AccessControl</h2>
      <table className="list">
        <thead>
          <tr>
            <th>role</th>
            <th>holders</th>
            <th>power</th>
          </tr>
        </thead>
        <tbody>
          {(Object.keys(ROLE_LABEL) as RoleKey[]).map((k) => (
            <tr key={k}>
              <td className="mono">{ROLE_LABEL[k].name}</td>
              <td>
                {members.data?.[k]?.length ? (
                  members.data[k].map((a, i) => (
                    <span key={a}>
                      {i > 0 && " · "}
                      <AddrLink addr={a} />
                      {you === a.toLowerCase() && <b> (you)</b>}
                    </span>
                  ))
                ) : members.isLoading ? (
                  <span className="hint" style={{ margin: 0 }}>scanning role events…</span>
                ) : (
                  <span style={{ color: "var(--ink-3)" }}>none granted</span>
                )}
              </td>
              <td style={{ color: "var(--ink-2)" }}>{ROLE_LABEL[k].desc}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <div className="hint">
        membership rebuilt from RoleGranted/RoleRevoked logs (AccessControl has no on-chain enumeration) — the
        allocator addresses above are the only keys that can move funds, and only vault ↔ sleeve within caps
      </div>
    </section>
  );
}

function SleeveRegistryCard({ canEdit }: { canEdit: boolean }) {
  const sleeves = useSleeves();
  const { writeContractAsync, isPending } = useWriteContract();
  const [caps, setCaps] = useState<Record<string, string>>({});
  const [newSleeve, setNewSleeve] = useState("");
  const [newCap, setNewCap] = useState("");
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");

  async function run(label: string, fn: () => Promise<unknown>) {
    setError("");
    try {
      setStatus(`${label}…`);
      await fn();
      setStatus(`${label} ✓`);
      sleeves.refetch();
    } catch (e: unknown) {
      setError(String((e as Error).message ?? e).slice(0, 200));
      setStatus("");
    }
  }

  return (
    <section className="card">
      <h2>Sleeve registry — caps bound every allocation</h2>
      {sleeves.data?.length ? (
        <table className="list">
          <thead>
            <tr>
              <th>sleeve</th>
              <th>kind</th>
              <th>assets</th>
              <th>liquid</th>
              <th>cap</th>
              <th>set cap (USDC)</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {sleeves.data.map((s) => (
              <tr key={s.address}>
                <td className="mono">
                  <AddrLink addr={s.address} />
                </td>
                <td>{s.kind === "midnight" ? "Midnight paper" : s.kind === "metamorpho" ? "MetaMorpho buffer" : "unknown"}</td>
                <td>{fmt(s.totalAssets, VAULT_USDC_DEC, 0)}</td>
                <td>{fmt(s.liquidAssets, VAULT_USDC_DEC, 0)}</td>
                <td>{fmtUsdCompact(s.cap)}</td>
                <td>
                  <div className="row" style={{ gap: 6, flexWrap: "nowrap" }}>
                    <input
                      style={{ width: 110, padding: "5px 8px" }}
                      value={caps[s.address] ?? ""}
                      placeholder={fmt(s.cap, VAULT_USDC_DEC, 0)}
                      onChange={(e) => setCaps({ ...caps, [s.address]: e.target.value.replace(/[^0-9.]/g, "") })}
                      disabled={!canEdit}
                      aria-label={`new cap for ${s.address}`}
                    />
                    <button
                      className="ghost"
                      style={{ padding: "5px 10px" }}
                      disabled={!canEdit || isPending || !caps[s.address]}
                      onClick={() =>
                        run(`setting cap on ${fmtAddr(s.address)}`, () =>
                          writeContractAsync({
                            abi: vaultAbi, address: VAULT, functionName: "setSleeveCap",
                            args: [s.address, parseUnits(caps[s.address]!, VAULT_USDC_DEC)], chainId: VAULT_CHAIN_ID,
                          }),
                        )
                      }
                    >
                      set
                    </button>
                  </div>
                </td>
                <td>
                  <button
                    className="ghost"
                    style={{ padding: "5px 10px" }}
                    title="deregister — reverts unless the sleeve reports zero assets"
                    disabled={!canEdit || isPending || s.totalAssets > 0n}
                    onClick={() =>
                      run(`removing ${fmtAddr(s.address)}`, () =>
                        writeContractAsync({
                          abi: vaultAbi, address: VAULT, functionName: "removeSleeve",
                          args: [s.address], chainId: VAULT_CHAIN_ID,
                        }),
                      )
                    }
                  >
                    remove
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      ) : (
        <div className="hint">{sleeves.isLoading ? "reading the registry…" : "no sleeves registered"}</div>
      )}
      <div className="row" style={{ alignItems: "center", marginTop: 12 }}>
        <input
          style={{ width: 340 }}
          className="mono"
          placeholder="new sleeve address (trusted code — behind the timelock)"
          value={newSleeve}
          onChange={(e) => setNewSleeve(e.target.value.trim())}
          disabled={!canEdit}
          aria-label="new sleeve address"
        />
        <input
          style={{ width: 130 }}
          placeholder="cap USDC"
          value={newCap}
          onChange={(e) => setNewCap(e.target.value.replace(/[^0-9.]/g, ""))}
          disabled={!canEdit}
          aria-label="new sleeve cap in USDC"
        />
        <button
          disabled={!canEdit || isPending || !/^0x[0-9a-fA-F]{40}$/.test(newSleeve) || !newCap}
          onClick={() =>
            run("registering sleeve", async () => {
              await writeContractAsync({
                abi: vaultAbi, address: VAULT, functionName: "addSleeve",
                args: [newSleeve as `0x${string}`, parseUnits(newCap, VAULT_USDC_DEC)], chainId: VAULT_CHAIN_ID,
              });
              setNewSleeve("");
              setNewCap("");
            })
          }
        >
          Add sleeve
        </button>
      </div>
      <div className="hint">
        sleeves are trusted code (a malicious sleeve is a malicious vault) — additions sit behind the admin
        timelock by deployment policy; caps are checked on-chain at every allocation
      </div>
      {status && <div className="hint">{status}</div>}
      {error && <div className="err">{error}</div>}
    </section>
  );
}

function FeeCard({ canEdit }: { canEdit: boolean }) {
  const core = useVaultCore();
  const { writeContractAsync, isPending } = useWriteContract();
  const [bps, setBps] = useState("");
  const [recipient, setRecipient] = useState("");
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");
  const c = core.data;

  async function run(label: string, fn: () => Promise<unknown>) {
    setError("");
    try {
      setStatus(`${label}…`);
      await fn();
      setStatus(`${label} ✓ — accrued-to-date fee settled first`);
      core.refetch();
    } catch (e: unknown) {
      setError(String((e as Error).message ?? e).slice(0, 200));
      setStatus("");
    }
  }

  const bpsNum = Number(bps || "0");
  return (
    <section className="card">
      <h2>Management fee — flat bps/yr, accrued as share dilution</h2>
      <div className="kv" style={{ marginTop: 0 }}>
        <span>
          current <b className="num">{c ? `${c.feeBps} bps (${(c.feeBps / 100).toFixed(2)}%/yr)` : "—"}</b>
        </span>
        <span>
          recipient {c ? <AddrLink addr={c.feeRecipient} /> : <b>—</b>}
        </span>
        <span>
          last settled <b>{c?.lastFeeAccrual ? new Date(c.lastFeeAccrual * 1000).toLocaleString() : "—"}</b>
        </span>
        <span>
          hard cap <b className="num">{MAX_FEE_BPS} bps</b>
        </span>
      </div>
      <div className="row" style={{ alignItems: "center", marginTop: 12 }}>
        <input
          style={{ width: 120 }}
          placeholder="new bps"
          value={bps}
          onChange={(e) => setBps(e.target.value.replace(/[^0-9]/g, ""))}
          disabled={!canEdit}
          aria-label="new fee in bps per year"
        />
        <button
          className="ghost"
          disabled={!canEdit || isPending || bps === "" || bpsNum > MAX_FEE_BPS}
          onClick={() =>
            run(`setting fee to ${bpsNum} bps`, () =>
              writeContractAsync({
                abi: vaultAbi, address: VAULT, functionName: "setFee",
                args: [bpsNum], chainId: VAULT_CHAIN_ID,
              }),
            )
          }
        >
          Set fee
        </button>
        <input
          style={{ width: 340 }}
          className="mono"
          placeholder="new fee recipient address"
          value={recipient}
          onChange={(e) => setRecipient(e.target.value.trim())}
          disabled={!canEdit}
          aria-label="new fee recipient"
        />
        <button
          className="ghost"
          disabled={!canEdit || isPending || !/^0x[0-9a-fA-F]{40}$/.test(recipient)}
          onClick={() =>
            run("setting fee recipient", () =>
              writeContractAsync({
                abi: vaultAbi, address: VAULT, functionName: "setFeeRecipient",
                args: [recipient as `0x${string}`], chainId: VAULT_CHAIN_ID,
              }),
            )
          }
        >
          Set recipient
        </button>
      </div>
      {bpsNum > MAX_FEE_BPS && <div className="err">fee is hard-capped at {MAX_FEE_BPS} bps on-chain</div>}
      {status && <div className="hint">{status}</div>}
      {error && <div className="err">{error}</div>}
    </section>
  );
}

function PauseCard({ isGuardian, isAdmin }: { isGuardian: boolean; isAdmin: boolean }) {
  const core = useVaultCore();
  const { writeContractAsync, isPending } = useWriteContract();
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");
  const paused = core.data?.paused;

  async function run(label: string, fn: () => Promise<unknown>) {
    setError("");
    try {
      setStatus(`${label}…`);
      await fn();
      setStatus(`${label} ✓`);
      core.refetch();
    } catch (e: unknown) {
      setError(String((e as Error).message ?? e).slice(0, 200));
      setStatus("");
    }
  }

  return (
    <section className="card">
      <h2>Circuit breaker</h2>
      <div className="row" style={{ alignItems: "center" }}>
        <span className={`badge ${paused === undefined ? "" : paused ? "warn" : "ok"}`}>
          <span className="dot" />
          {paused === undefined ? "loading" : paused ? "PAUSED" : "live"}
        </span>
        <button
          disabled={!isGuardian || isPending || paused !== false}
          title="guardian only — freezes deposits, withdrawals and allocation instantly"
          onClick={() =>
            run("pausing", () =>
              writeContractAsync({ abi: vaultAbi, address: VAULT, functionName: "pause", chainId: VAULT_CHAIN_ID }),
            )
          }
        >
          Pause
        </button>
        <button
          className="ghost"
          disabled={!isAdmin || isPending || paused !== true}
          title="admin only — a compromised guardian must not be able to unpause"
          onClick={() =>
            run("unpausing", () =>
              writeContractAsync({ abi: vaultAbi, address: VAULT, functionName: "unpause", chainId: VAULT_CHAIN_ID }),
            )
          }
        >
          Unpause
        </button>
      </div>
      <div className="hint">
        pause is guardian-instant; unpause is admin-only (behind the multisig + timelock). Deallocation stays
        callable while paused — recovery moves funds toward the vault, never away.
      </div>
      {status && <div className="hint">{status}</div>}
      {error && <div className="err">{error}</div>}
    </section>
  );
}
