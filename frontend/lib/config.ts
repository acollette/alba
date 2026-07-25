// Live Base Sepolia stack (v10, uncapped revolver program). Override via NEXT_PUBLIC_* envs.
export const ADDR = {
  escrow: (process.env.NEXT_PUBLIC_ESCROW ?? "0x27a192BB64B3537BeEE6A458E609D4F89Cfa49ca") as `0x${string}`,
  router: (process.env.NEXT_PUBLIC_ROUTER ?? "0x67bC67135A153EEAFDbF352f70EbaA0428d6636b") as `0x${string}`,
  usdc: (process.env.NEXT_PUBLIC_USDC ?? "0x9EB96112863ad3286e1f893532c676838D44E393") as `0x${string}`,
  cbbtc: (process.env.NEXT_PUBLIC_CBBTC ?? "0x2E08FE4EF972DD20dCCdA57066d7735Ae8aF55d2") as `0x${string}`,
  oracle: (process.env.NEXT_PUBLIC_ORACLE ?? "0xeBcC1E49Fb8AeBF95C9653821783e4887ae3aD45") as `0x${string}`,
} as const;

export const DEFAULT_FACILITY_ID = (process.env.NEXT_PUBLIC_FACILITY_ID ??
  "0x0000000000000000000000000000000000000000000000000000000000000fac") as `0x${string}`;

export const AQUA = (process.env.NEXT_PUBLIC_AQUA ?? "0x29C10C31eB844D038A0Dc858997f8ADea1da3270") as `0x${string}`;
export const EXECUTOR = (process.env.NEXT_PUBLIC_EXECUTOR ?? "0x81C35F38B209e7F4A025588cb93be8b51c3897E4") as `0x${string}`;
export const BUILDER = (process.env.NEXT_PUBLIC_BUILDER ?? "0x99928dACccf994868bC9ba80de0B47c8DA54151B") as `0x${string}`;
export const CHAIN_ID = 84532; // Base Sepolia — reads pinned here regardless of wallet network

export const FACILITY_SIZE = BigInt(process.env.NEXT_PUBLIC_FACILITY_SIZE ?? "300000000000"); // 300k USDC (6 dec)

export const START_BLOCK = BigInt(process.env.NEXT_PUBLIC_START_BLOCK ?? "44621902");

export const RATES_API = process.env.NEXT_PUBLIC_RATES_API ?? "http://localhost:8787";

// Hedera sentinel/trigger (v11) — schedule IDs surfaced from the mirror node
export const HEDERA_TRIGGER = "0xF6Ad8045FdD4A07c2B6f36E9b5043d13a86598a7";
export const HEDERA_MIRROR = "https://testnet.mirrornode.hedera.com";

export const USDC_DEC = 6;
export const CBBTC_DEC = 8;
