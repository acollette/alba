// Live Base Sepolia stack (v8, revolving + margin controls). Override via NEXT_PUBLIC_* envs.
export const ADDR = {
  escrow: (process.env.NEXT_PUBLIC_ESCROW ?? "0xFC4D35C361fD5D0518a116ab56d2E4181ebf59ec") as `0x${string}`,
  router: (process.env.NEXT_PUBLIC_ROUTER ?? "0x973aB7E04dBAc82255d94f11F8FB2518b4Fd9dAE") as `0x${string}`,
  usdc: (process.env.NEXT_PUBLIC_USDC ?? "0xc0832552c1cc746eba1B2fAC11484AAe1d943Dc0") as `0x${string}`,
  cbbtc: (process.env.NEXT_PUBLIC_CBBTC ?? "0x23391447bE5122149fE370102515226cE799Ab2D") as `0x${string}`,
  oracle: (process.env.NEXT_PUBLIC_ORACLE ?? "0xf38939758b0074CE6e80E1206AD56F4Aef872237") as `0x${string}`,
} as const;

export const DEFAULT_FACILITY_ID = (process.env.NEXT_PUBLIC_FACILITY_ID ??
  "0x0000000000000000000000000000000000000000000000000000000000000fac") as `0x${string}`;

export const AQUA = (process.env.NEXT_PUBLIC_AQUA ?? "0x29C10C31eB844D038A0Dc858997f8ADea1da3270") as `0x${string}`;
export const BUILDER = (process.env.NEXT_PUBLIC_BUILDER ?? "0x3AE1b534f15966C815FaCA58eCf368a806488232") as `0x${string}`;
export const CHAIN_ID = 84532; // Base Sepolia — reads pinned here regardless of wallet network

export const FACILITY_SIZE = BigInt(process.env.NEXT_PUBLIC_FACILITY_SIZE ?? "300000000000"); // 300k USDC (6 dec)

export const START_BLOCK = BigInt(process.env.NEXT_PUBLIC_START_BLOCK ?? "44612600");

export const RATES_API = process.env.NEXT_PUBLIC_RATES_API ?? "http://localhost:8787";

// Hedera sentinel/trigger (v9) — schedule IDs surfaced from the mirror node
export const HEDERA_TRIGGER = "0x952dE361ae3392A483049517088c51C2618DFD18";
export const HEDERA_MIRROR = "https://testnet.mirrornode.hedera.com";

export const USDC_DEC = 6;
export const CBBTC_DEC = 8;
