// Live Base Sepolia stack (v6, two-wallet lender/borrower). Override via NEXT_PUBLIC_* envs.
export const ADDR = {
  escrow: (process.env.NEXT_PUBLIC_ESCROW ?? "0x4CD5fa75186bEccc51215207037D5c1Fbe4ADebb") as `0x${string}`,
  router: (process.env.NEXT_PUBLIC_ROUTER ?? "0xe51FD28546EB5449e7C9607Ef937706c5e2AfB95") as `0x${string}`,
  usdc: (process.env.NEXT_PUBLIC_USDC ?? "0xa816781C4Fb9700476e38b73fED09c5dD6DC1fFb") as `0x${string}`,
  cbbtc: (process.env.NEXT_PUBLIC_CBBTC ?? "0x3a53c0117Edfc8E745f7254F75d11e5085E210a8") as `0x${string}`,
  oracle: (process.env.NEXT_PUBLIC_ORACLE ?? "0x869105F636D6Ac7fDa4E49B6787359E114c96Ddb") as `0x${string}`,
} as const;

export const DEFAULT_FACILITY_ID = (process.env.NEXT_PUBLIC_FACILITY_ID ??
  "0x0000000000000000000000000000000000000000000000000000000000000fac") as `0x${string}`;

export const AQUA = (process.env.NEXT_PUBLIC_AQUA ?? "0x29C10C31eB844D038A0Dc858997f8ADea1da3270") as `0x${string}`;
export const BUILDER = (process.env.NEXT_PUBLIC_BUILDER ?? "0xB84a8eaCaa349A50e9F7C87e2aDbF7EaC98DEa1c") as `0x${string}`;
export const CHAIN_ID = 84532; // Base Sepolia — reads pinned here regardless of wallet network

export const FACILITY_SIZE = BigInt(process.env.NEXT_PUBLIC_FACILITY_SIZE ?? "300000000000"); // 300k USDC (6 dec)

export const START_BLOCK = BigInt(process.env.NEXT_PUBLIC_START_BLOCK ?? "44604000");

export const RATES_API = process.env.NEXT_PUBLIC_RATES_API ?? "http://localhost:8787";

// Hedera sentinel/trigger (v7) — schedule IDs surfaced from the mirror node
export const HEDERA_TRIGGER = "0xe636135Bc58B5c732479B3303425C47653B8801f";
export const HEDERA_MIRROR = "https://testnet.mirrornode.hedera.com";

export const USDC_DEC = 6;
export const CBBTC_DEC = 8;
