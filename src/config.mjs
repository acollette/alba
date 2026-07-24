// The Graph — Messari-standardized lending subgraphs, ALL on Base, queried through
// the decentralized gateway. Query IDs from messari/subgraphs deployment.json.
export const GRAPH_GATEWAY = "https://gateway.thegraph.com/api";

export const LENDING_SUBGRAPHS = [
  { protocol: "Aave v3", id: "D7mapexM5ZsQckLJai2FawTKXJ7CqYGKM8PErnS3cJi9" },
  { protocol: "Compound v3", id: "AwoxEZbiWLvv6e3QdvdMZw4WDURdGbvPfHmZRc8Dpfz9" },
  { protocol: "Moonwell", id: "33ex1ExmYQtwGVwri1AP3oMFPGSce6YbocBP7fWbsBrg" },
  { protocol: "Seamless", id: "2u4mWUV4xS19ef1MbnxZHWLLMwdPxtVifH46JbonXwXP" },
];

// THE query. One pattern, every protocol — the entire point of the standardized schema.
export const MARKETS_QUERY = `{
  markets(where: {inputToken_: {symbol_in: ["USDC", "USDbC"]}},
          orderBy: totalBorrowBalanceUSD, orderDirection: desc, first: 5) {
    name
    inputToken { symbol }
    rates { rate side type }
    totalBorrowBalanceUSD
  }
}`;

// Morpho Midnight (Base mainnet) — public REST API over indexed on-chain state.
// Core contract: 0xadedd8ab6de832766fedf0fac4992e5c4d3ea18a
export const MIDNIGHT_API = "https://api.morpho.org/v0/midnight";
export const BASE_CHAIN_ID = 8453;
export const USDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913";
export const CBBTC = "0xcbb7c0000ab88b473b1f5afd9ef808440eed33bf";

// Midnight tick → zero-coupon price (logistic curve, from @morpho-org/midnight-sdk TickLib)
export const LN_ONE_PLUS_DELTA = 4987541511039073e-18;
export const MAX_TICK = 6744;

export const CACHE_TTL_MS = 90_000;
