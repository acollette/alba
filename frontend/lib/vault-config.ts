// AlbaVault stack (v1 curated fixed-income vault — contracts/src/vault/*).
// NOT deployed yet: every address ships as an env-overridable placeholder and the
// pages render a "not deployed" state until NEXT_PUBLIC_VAULT is set.
// Chain switch: Base mainnet (8453) is the launch target — Midnight exists nowhere
// else — while 31337 supports a local anvil/foundry deployment during development.

const ZERO = "0x0000000000000000000000000000000000000000" as const;

export const VAULT_CHAIN_ID = Number(process.env.NEXT_PUBLIC_VAULT_CHAIN_ID ?? "8453");

const USDC_BY_CHAIN: Record<number, `0x${string}`> = {
  8453: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", // native USDC, Base mainnet
  31337: ZERO, // local mock — set NEXT_PUBLIC_VAULT_USDC
};

/** The AlbaVault (ERC-4626 on USDC). Zero = not deployed; pages gate on this. */
export const VAULT = (process.env.NEXT_PUBLIC_VAULT ?? ZERO) as `0x${string}`;
export const VAULT_DEPLOYED = VAULT !== ZERO;

export const VAULT_USDC = (process.env.NEXT_PUBLIC_VAULT_USDC ??
  USDC_BY_CHAIN[VAULT_CHAIN_ID] ??
  ZERO) as `0x${string}`;

/** Midnight core (Base mainnet, verified) — used only for explorer links. */
export const MIDNIGHT_CORE = (process.env.NEXT_PUBLIC_MIDNIGHT ??
  "0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A") as `0x${string}`;

/** First block to scan for vault/sleeve events. Set at deploy time; while 0 on a
 * long chain the scanners clamp to a trailing window instead of genesis. */
export const VAULT_START_BLOCK = BigInt(process.env.NEXT_PUBLIC_VAULT_START_BLOCK ?? "0");

/** Block explorer for the active chain (null on local anvil — render plain text). */
export const VAULT_EXPLORER = VAULT_CHAIN_ID === 8453 ? "https://basescan.org" : null;

// Decimals. albaUSDC shares carry a 10^6 virtual-share offset on top of USDC's 6
// (the inflation guard), so ONE SHARE IS 1e12 — never format shares with 6.
export const VAULT_USDC_DEC = 6;
export const SHARE_DEC = 12;
export const SHARE_UNIT = 10n ** 12n;

/** Vault-level fee cap (AlbaVault.MAX_FEE_BPS) — mirrored for form validation. */
export const MAX_FEE_BPS = 500;
