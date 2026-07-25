// Live Base Sepolia stack (v5, sentinel-hardened). Override via NEXT_PUBLIC_* envs.
export const ADDR = {
  escrow: (process.env.NEXT_PUBLIC_ESCROW ?? "0x1cCe09DEa73c584D01B00D23b0DA36040e7C0EBa") as `0x${string}`,
  router: (process.env.NEXT_PUBLIC_ROUTER ?? "0xE300cEf02a044dBb885AA20C3aa3DBada48E54dc") as `0x${string}`,
  usdc: (process.env.NEXT_PUBLIC_USDC ?? "0x7F29563801e1B5545796c6aE8b8F137528e28482") as `0x${string}`,
  cbbtc: (process.env.NEXT_PUBLIC_CBBTC ?? "0x0fFC12d5BFa76A0929453096C12b1D5882D7bDfd") as `0x${string}`,
  oracle: (process.env.NEXT_PUBLIC_ORACLE ?? "0x0CA7B7332478cAb455Bf3ACcf40FF223072b2dfB") as `0x${string}`,
} as const;

export const FACILITY_ID = (process.env.NEXT_PUBLIC_FACILITY_ID ??
  "0x0000000000000000000000000000000000000000000000000000000000000fac") as `0x${string}`;

export const FACILITY_SIZE = BigInt(process.env.NEXT_PUBLIC_FACILITY_SIZE ?? "300000000000"); // 300k USDC (6 dec)

export const START_BLOCK = BigInt(process.env.NEXT_PUBLIC_START_BLOCK ?? "44584000");

export const RATES_API = process.env.NEXT_PUBLIC_RATES_API ?? "http://localhost:8787";

// Hedera sentinel/trigger (v6) — schedule IDs surfaced from the mirror node
export const HEDERA_TRIGGER = "0xeb3D736b5Ce06fe875011Bae95218BD1616bC2f8";
export const HEDERA_MIRROR = "https://testnet.mirrornode.hedera.com";

export const USDC_DEC = 6;
export const CBBTC_DEC = 8;
