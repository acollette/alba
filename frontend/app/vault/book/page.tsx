"use client";

// /vault/book — the transparency page. Every Midnight lot, the MetaMorpho
// position and the idle balance, all read from public Base state with explorer
// links. The differentiator: a fund whose book is public.

import {
  VAULT,
  VAULT_DEPLOYED,
  VAULT_USDC_DEC,
  MIDNIGHT_CORE,
} from "@/lib/vault-config";
import {
  AddrLink,
  DeployGate,
  TxLink,
  VaultHeader,
  fmt,
  fmtDate,
  fmtId,
  fmtUsdCompact,
  marketBookValue,
  marketYieldPct,
  useMidnightActivity,
  useMidnightBook,
  useNow,
  useSleeves,
  useVaultCore,
  type MarketRow,
} from "../shared";

export default function BookPage() {
  const sleeves = useSleeves();
  const midnight = sleeves.data?.find((s) => s.kind === "midnight");
  return (
    <main>
      <VaultHeader active="book" />
      <DeployGate />
      {VAULT_DEPLOYED && (
        <>
          <PaperSummary />
          <LotsCard sleeve={midnight?.address} />
          <MarketsCard sleeve={midnight?.address} />
          <BufferAndIdleCard />
          <ActivityCard sleeve={midnight?.address} />
        </>
      )}
    </main>
  );
}

function PaperSummary() {
  const sleeves = useSleeves();
  const midnight = sleeves.data?.find((s) => s.kind === "midnight");
  const book = useMidnightBook(midnight?.address);
  const now = useNow();
  const rows = book.data ?? [];
  const face = rows.reduce((s, m) => s + m.units, 0n);
  const cost = rows.reduce((s, m) => s + m.cost, 0n);
  const carry = rows.reduce((s, m) => s + marketBookValue(m, now), 0n);
  const wavg =
    cost > 0n ? rows.reduce((s, m) => s + marketYieldPct(m) * Number(m.cost), 0) / Number(cost) : undefined;
  return (
    <section className="card">
      <h2>Midnight paper — the whole book, on-chain</h2>
      <div className="row">
        <div className="tile">
          <div className="label">Face outstanding</div>
          <div className="value num">{fmt(face, VAULT_USDC_DEC, 0)}</div>
          <div className="sub">USDC at par, redeems at maturity</div>
        </div>
        <div className="tile">
          <div className="label">Cost basis</div>
          <div className="value num">{fmt(cost, VAULT_USDC_DEC, 0)}</div>
          <div className="sub">USDC paid (discount = locked yield)</div>
        </div>
        <div className="tile accent">
          <div className="label">Carried value now</div>
          <div className="value num">{fmt(midnight?.totalAssets, VAULT_USDC_DEC, 0)}</div>
          <div className="sub">
            sleeve totalAssets() — accretion{carry > cost ? ` (+${fmt(carry - cost, VAULT_USDC_DEC, 2)} accrued)` : ""},
            cross-checked vs Midnight credit
          </div>
        </div>
        <div className="tile">
          <div className="label">Locked yield</div>
          <div className="value num">{wavg !== undefined ? `${wavg.toFixed(2)}%` : "—"}</div>
          <div className="sub">book-weighted annualized simple yield</div>
        </div>
      </div>
      <div className="kv">
        <span>
          sleeve {midnight ? <AddrLink addr={midnight.address} /> : <b>—</b>}
        </span>
        <span>
          Midnight core <AddrLink addr={MIDNIGHT_CORE} />
        </span>
        <span>
          vault <AddrLink addr={VAULT} />
        </span>
      </div>
    </section>
  );
}

function LotsCard({ sleeve }: { sleeve?: `0x${string}` }) {
  const activity = useMidnightActivity(sleeve);
  const book = useMidnightBook(sleeve);
  const now = useNow();
  const byId = new Map((book.data ?? []).map((m) => [m.id.toLowerCase(), m]));
  const lots = activity.data?.lots ?? [];
  return (
    <section className="card">
      <h2>Lots — every purchase, verifiable</h2>
      {lots.length ? (
        <table className="list">
          <thead>
            <tr>
              <th>market</th>
              <th>face</th>
              <th>cost</th>
              <th>bought</th>
              <th>matures</th>
              <th>accreted now</th>
              <th>to par</th>
            </tr>
          </thead>
          <tbody>
            {lots.map((l) => {
              const m = byId.get(l.id.toLowerCase());
              const maturity = m?.maturity ?? 0;
              const done = maturity > l.time ? Math.min(1, Math.max(0, (now - l.time) / (maturity - l.time))) : 1;
              const accreted = l.cost + ((l.units - l.cost) * BigInt(Math.floor(done * 1e6))) / 1_000_000n;
              return (
                <tr key={`${l.tx}${l.id}${l.time}`}>
                  <td className="mono">
                    <TxLink tx={l.tx}>{fmtId(l.id)}</TxLink>
                  </td>
                  <td>{fmt(l.units, VAULT_USDC_DEC, 0)}</td>
                  <td>{fmt(l.cost, VAULT_USDC_DEC, 2)}</td>
                  <td>{fmtDate(l.time)}</td>
                  <td>{maturity ? fmtDate(maturity) : "—"}</td>
                  <td>{fmt(accreted, VAULT_USDC_DEC, 2)}</td>
                  <td>
                    <span className="num">{(done * 100).toFixed(0)}%</span>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      ) : (
        <div className="hint">{activity.isLoading ? "scanning the chain…" : "no lots yet — the allocator hasn't bought paper"}</div>
      )}
      <div className="hint">
        each row is a `Bought` event — click through to the fill transaction. Lots accrete linearly from cost to
        par; per-lot values shown here are the linear carry, the market aggregates below (and the NAV) are the
        on-chain accounting truth including any credit haircut.
      </div>
    </section>
  );
}

function MarketsCard({ sleeve }: { sleeve?: `0x${string}` }) {
  const book = useMidnightBook(sleeve);
  const now = useNow();
  const rows = book.data ?? [];
  return (
    <section className="card">
      <h2>Market aggregates — the accounting the NAV uses</h2>
      {rows.length ? (
        <table className="list">
          <thead>
            <tr>
              <th>market</th>
              <th>face</th>
              <th>cost basis</th>
              <th>book value now</th>
              <th>locked yield</th>
              <th>matures</th>
              <th>cap</th>
              <th>status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((m: MarketRow) => {
              const matured = m.maturity <= now;
              return (
                <tr key={m.id}>
                  <td className="mono" title={m.id}>{fmtId(m.id)}</td>
                  <td>{fmt(m.units, VAULT_USDC_DEC, 0)}</td>
                  <td>{fmt(m.cost, VAULT_USDC_DEC, 2)}</td>
                  <td>{fmt(marketBookValue(m, now), VAULT_USDC_DEC, 2)}</td>
                  <td>{m.units > 0n ? `${marketYieldPct(m).toFixed(2)}%` : "—"}</td>
                  <td>{fmtDate(m.maturity)}</td>
                  <td>{fmtUsdCompact(m.maxUnits)}</td>
                  <td>
                    <span className={`badge ${m.units === 0n ? "" : matured ? "warn" : "ok"}`}>
                      <span className="dot" />
                      {m.units === 0n ? "empty" : matured ? "matured — claimable" : "accreting"}
                    </span>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      ) : (
        <div className="hint">{book.isLoading ? "reading the sleeve…" : "no markets allow-listed yet"}</div>
      )}
      <div className="hint">
        amortized cost (pull-to-par): value = cost + linear accretion, clamped to face, haircut pro-rata if
        Midnight&apos;s own credit falls below book — deterministic, oracle-free
      </div>
    </section>
  );
}

function BufferAndIdleCard() {
  const core = useVaultCore();
  const sleeves = useSleeves();
  const buffer = sleeves.data?.find((s) => s.kind === "metamorpho");
  return (
    <section className="card">
      <h2>Buffer &amp; idle — the liquid side</h2>
      <div className="row">
        <div className="tile">
          <div className="label">MetaMorpho position</div>
          <div className="value num">{fmt(buffer?.totalAssets, VAULT_USDC_DEC, 0)}</div>
          <div className="sub">USDC in the floating-rate buffer</div>
        </div>
        <div className="tile">
          <div className="label">Buffer instantly redeemable</div>
          <div className="value num">{fmt(buffer?.liquidAssets, VAULT_USDC_DEC, 0)}</div>
          <div className="sub">honors the target vault&apos;s own maxWithdraw</div>
        </div>
        <div className="tile">
          <div className="label">Idle USDC</div>
          <div className="value num">{fmt(core.data?.idle, VAULT_USDC_DEC, 0)}</div>
          <div className="sub">sitting in the vault contract</div>
        </div>
      </div>
      <div className="kv">
        <span>sleeve {buffer ? <AddrLink addr={buffer.address} /> : <b>—</b>}</span>
        <span>target vault {buffer?.target ? <AddrLink addr={buffer.target} /> : <b>—</b>}</span>
        {buffer && (
          <span>
            cap <b className="num">{fmtUsdCompact(buffer.cap)}</b>
          </span>
        )}
      </div>
    </section>
  );
}

function ActivityCard({ sleeve }: { sleeve?: `0x${string}` }) {
  const activity = useMidnightActivity(sleeve);
  const rows = activity.data?.activity ?? [];
  return (
    <section className="card">
      <h2>Book activity — the machine, observable</h2>
      <ul className="timeline">
        {rows.map((r) => (
          <li key={r.key}>
            <span className={`t-dot ${r.kind === "plain" ? "" : r.kind}`} />
            <span className="t-what">{r.what}</span>
            <span className="t-meta">{r.meta}</span>
            <span className="t-when num">
              <TxLink tx={r.tx}>{r.when}</TxLink>
            </span>
          </li>
        ))}
        {!rows.length && (
          <li>
            <span className="t-dot" />
            <span className="t-meta">{activity.isLoading ? "loading on-chain history…" : "no activity yet"}</span>
          </li>
        )}
      </ul>
      <div className="hint">
        buys, redemptions, allocations — every move of depositor money is a public event with a transaction to
        click. No statements to trust; the book is the chain.
      </div>
    </section>
  );
}
