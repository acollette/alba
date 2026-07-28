// Hand-written minimal ABIs for the vault UI — only what the pages call.
// Source of truth: contracts/src/vault/{AlbaVault,MidnightSleeve,MetaMorphoSleeve}.sol
// (solc 0.8.30, OZ v5 ERC4626/AccessControl/Pausable). Keep in sync by reading
// the Solidity, not by regenerating: the UI intentionally sees a narrow surface.

export const vaultAbi = [
  // ---- ERC-20 share token (albaUSDC, 12 decimals: USDC 6 + offset 6)
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ name: "a", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "totalSupply", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },

  // ---- ERC-4626 core
  { type: "function", name: "asset", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "totalAssets", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "convertToAssets", stateMutability: "view", inputs: [{ name: "shares", type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "convertToShares", stateMutability: "view", inputs: [{ name: "assets", type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "previewDeposit", stateMutability: "view", inputs: [{ name: "assets", type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "previewWithdraw", stateMutability: "view", inputs: [{ name: "assets", type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "maxDeposit", stateMutability: "view", inputs: [{ name: "receiver", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "maxWithdraw", stateMutability: "view", inputs: [{ name: "owner", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "maxRedeem", stateMutability: "view", inputs: [{ name: "owner", type: "address" }], outputs: [{ type: "uint256" }] },
  {
    type: "function", name: "deposit", stateMutability: "nonpayable",
    inputs: [{ name: "assets", type: "uint256" }, { name: "receiver", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function", name: "withdraw", stateMutability: "nonpayable",
    inputs: [{ name: "assets", type: "uint256" }, { name: "receiver", type: "address" }, { name: "owner", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function", name: "redeem", stateMutability: "nonpayable",
    inputs: [{ name: "shares", type: "uint256" }, { name: "receiver", type: "address" }, { name: "owner", type: "address" }],
    outputs: [{ type: "uint256" }],
  },

  // ---- AlbaVault accounting & registry
  { type: "function", name: "liquidAssets", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "sleeveCount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "sleeves", stateMutability: "view", inputs: [{ name: "i", type: "uint256" }], outputs: [{ type: "address" }] },
  {
    type: "function", name: "sleeveConfig", stateMutability: "view",
    inputs: [{ name: "sleeve", type: "address" }],
    outputs: [{ name: "active", type: "bool" }, { name: "cap", type: "uint96" }],
  },
  { type: "function", name: "feeBps", stateMutability: "view", inputs: [], outputs: [{ type: "uint16" }] },
  { type: "function", name: "feeRecipient", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "lastFeeAccrual", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { type: "function", name: "paused", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },

  // ---- AccessControl (roles ARE the UI's permissions; no enumeration on-chain,
  //      membership lists are rebuilt from RoleGranted/RoleRevoked logs)
  {
    type: "function", name: "hasRole", stateMutability: "view",
    inputs: [{ name: "role", type: "bytes32" }, { name: "account", type: "address" }],
    outputs: [{ type: "bool" }],
  },
  {
    type: "event", name: "RoleGranted",
    inputs: [
      { name: "role", type: "bytes32", indexed: true },
      { name: "account", type: "address", indexed: true },
      { name: "sender", type: "address", indexed: true },
    ],
  },
  {
    type: "event", name: "RoleRevoked",
    inputs: [
      { name: "role", type: "bytes32", indexed: true },
      { name: "account", type: "address", indexed: true },
      { name: "sender", type: "address", indexed: true },
    ],
  },

  // ---- curation writes (curator / guardian / admin)
  { type: "function", name: "addSleeve", stateMutability: "nonpayable", inputs: [{ name: "sleeve", type: "address" }, { name: "cap", type: "uint96" }], outputs: [] },
  { type: "function", name: "removeSleeve", stateMutability: "nonpayable", inputs: [{ name: "sleeve", type: "address" }], outputs: [] },
  { type: "function", name: "setSleeveCap", stateMutability: "nonpayable", inputs: [{ name: "sleeve", type: "address" }, { name: "cap", type: "uint96" }], outputs: [] },
  { type: "function", name: "setFee", stateMutability: "nonpayable", inputs: [{ name: "newFeeBps", type: "uint16" }], outputs: [] },
  { type: "function", name: "setFeeRecipient", stateMutability: "nonpayable", inputs: [{ name: "newFeeRecipient", type: "address" }], outputs: [] },
  { type: "function", name: "pause", stateMutability: "nonpayable", inputs: [], outputs: [] },
  { type: "function", name: "unpause", stateMutability: "nonpayable", inputs: [], outputs: [] },

  // ---- allocation events (transparency timeline)
  {
    type: "event", name: "Allocated",
    inputs: [{ name: "sleeve", type: "address", indexed: true }, { name: "assets", type: "uint256", indexed: false }],
  },
  {
    type: "event", name: "Deallocated",
    inputs: [
      { name: "sleeve", type: "address", indexed: true },
      { name: "requested", type: "uint256", indexed: false },
      { name: "withdrawn", type: "uint256", indexed: false },
    ],
  },
] as const;

export const midnightSleeveAbi = [
  // identity probes (sleeve classification: MIDNIGHT() only exists here)
  { type: "function", name: "MIDNIGHT", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "VAULT", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },

  // ISleeve views
  { type: "function", name: "totalAssets", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "liquidAssets", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },

  // per-market aggregate book (amortized cost + linear accretion)
  { type: "function", name: "marketCount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "marketIds", stateMutability: "view", inputs: [{ name: "i", type: "uint256" }], outputs: [{ type: "bytes32" }] },
  {
    type: "function", name: "book", stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [
      { name: "units", type: "uint128" },
      { name: "cost", type: "uint128" },
      { name: "maxUnits", type: "uint128" },
      { name: "lastAccrual", type: "uint64" },
      { name: "maturity", type: "uint64" },
      { name: "accruedWad", type: "uint256" },
      { name: "ratePerSecWad", type: "uint256" },
    ],
  },
  { type: "function", name: "minYieldWad", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "maxBuyAssets", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },

  // lot-level history (the on-chain paper trail the /vault/book page renders)
  {
    type: "event", name: "Bought",
    inputs: [
      { name: "id", type: "bytes32", indexed: true },
      { name: "units", type: "uint256", indexed: false },
      { name: "cost", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event", name: "Redeemed",
    inputs: [{ name: "id", type: "bytes32", indexed: true }, { name: "units", type: "uint256", indexed: false }],
  },
  {
    type: "event", name: "EmergencySold",
    inputs: [
      { name: "id", type: "bytes32", indexed: true },
      { name: "units", type: "uint256", indexed: false },
      { name: "proceeds", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event", name: "MarketAllowed",
    inputs: [
      { name: "id", type: "bytes32", indexed: true },
      { name: "maturity", type: "uint256", indexed: false },
      { name: "maxUnits", type: "uint128", indexed: false },
    ],
  },
] as const;

export const metaMorphoSleeveAbi = [
  // identity probe (TARGET() only exists here)
  { type: "function", name: "TARGET", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "VAULT", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "totalAssets", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "liquidAssets", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

/** Minimal 4626 target surface (the MetaMorpho vault the buffer sits in). */
export const erc4626Abi = [
  { type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ name: "a", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "maxWithdraw", stateMutability: "view", inputs: [{ name: "owner", type: "address" }], outputs: [{ type: "uint256" }] },
] as const;
