// Live Base Sepolia stack (v9, Aave-matched margining). Override via NEXT_PUBLIC_* envs.
export const ADDR = {
  escrow: (process.env.NEXT_PUBLIC_ESCROW ?? "0x8dB282dBBd0fc55f1d231616BdA2dFd0d2Db951A") as `0x${string}`,
  router: (process.env.NEXT_PUBLIC_ROUTER ?? "0xa99e81a3ff4eD108c3C145dba9137EBD422b6914") as `0x${string}`,
  usdc: (process.env.NEXT_PUBLIC_USDC ?? "0xbAD8ffCCe5FD19719E0b633212e0F0C13249ee2B") as `0x${string}`,
  cbbtc: (process.env.NEXT_PUBLIC_CBBTC ?? "0xC2441F75E33626ECA1d3e9feA47342BcB4E7F6e2") as `0x${string}`,
  oracle: (process.env.NEXT_PUBLIC_ORACLE ?? "0x37BcB44C38932A87789e97214A927d87490F426E") as `0x${string}`,
} as const;

export const DEFAULT_FACILITY_ID = (process.env.NEXT_PUBLIC_FACILITY_ID ??
  "0x0000000000000000000000000000000000000000000000000000000000000fac") as `0x${string}`;

export const AQUA = (process.env.NEXT_PUBLIC_AQUA ?? "0x29C10C31eB844D038A0Dc858997f8ADea1da3270") as `0x${string}`;
export const BUILDER = (process.env.NEXT_PUBLIC_BUILDER ?? "0x6CB061163D5Bed7801611b1670603979EaB3EA13") as `0x${string}`;
export const CHAIN_ID = 84532; // Base Sepolia — reads pinned here regardless of wallet network

export const FACILITY_SIZE = BigInt(process.env.NEXT_PUBLIC_FACILITY_SIZE ?? "300000000000"); // 300k USDC (6 dec)

export const START_BLOCK = BigInt(process.env.NEXT_PUBLIC_START_BLOCK ?? "44612900");

export const RATES_API = process.env.NEXT_PUBLIC_RATES_API ?? "http://localhost:8787";

// Hedera sentinel/trigger (v10) — schedule IDs surfaced from the mirror node
export const HEDERA_TRIGGER = "0x2F1A66A0Cea351B3308d317a96107B4528fc0E37";
export const HEDERA_MIRROR = "https://testnet.mirrornode.hedera.com";

export const USDC_DEC = 6;
export const CBBTC_DEC = 8;
