export const escrowAbi = [
  {
    type: "function", name: "facilities", stateMutability: "view",
    inputs: [{ name: "facilityId", type: "bytes32" }],
    outputs: [
      {
        name: "order", type: "tuple",
        components: [
          { name: "maker", type: "address" },
          { name: "traits", type: "uint256" },
          { name: "data", type: "bytes" },
        ],
      },
      { name: "lender", type: "address" },
      {
        name: "params", type: "tuple",
        components: [
          { name: "borrower", type: "address" },
          { name: "loanToken", type: "address" },
          { name: "collateralToken", type: "address" },
          { name: "oracle", type: "address" },
          { name: "collateralRatioBps", type: "uint256" },
          { name: "maintenanceRatioBps", type: "uint256" },
          { name: "rateBps", type: "uint256" },
          { name: "termSeconds", type: "uint40" },
          { name: "auctionDuration", type: "uint16" },
          { name: "auctionDecay", type: "uint64" },
          { name: "commitment", type: "uint256" },
          { name: "availabilityEnd", type: "uint40" },
        ],
      },
      { name: "loanDecimals", type: "uint8" },
      { name: "collateralDecimals", type: "uint8" },
      { name: "feedDecimals", type: "uint8" },
      { name: "exists", type: "bool" },
    ],
  },
  {
    type: "function", name: "draws", stateMutability: "view",
    inputs: [{ name: "drawId", type: "bytes32" }],
    outputs: [
      { name: "facilityId", type: "bytes32" },
      { name: "borrower", type: "address" },
      { name: "token", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "principal", type: "uint256" },
      { name: "cured", type: "uint256" },
      { name: "start", type: "uint40" },
      { name: "maturity", type: "uint40" },
      { name: "state", type: "uint8" },
    ],
  },
  {
    type: "function", name: "collateralForDraw", stateMutability: "view",
    inputs: [{ name: "facilityId", type: "bytes32" }, { name: "amount", type: "uint256" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function", name: "isHealthy", stateMutability: "view",
    inputs: [{ name: "drawId", type: "bytes32" }],
    outputs: [{ name: "healthy", type: "bool" }, { name: "value", type: "uint256" }, { name: "required", type: "uint256" }],
  },
  { type: "function", name: "debtOf", stateMutability: "view", inputs: [{ name: "drawId", type: "bytes32" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "stateOf", stateMutability: "view", inputs: [{ name: "drawId", type: "bytes32" }], outputs: [{ type: "uint8" }] },
  { type: "function", name: "availableToDraw", stateMutability: "view", inputs: [{ name: "facilityId", type: "bytes32" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "outstandingOf", stateMutability: "view", inputs: [{ name: "facilityId", type: "bytes32" }], outputs: [{ type: "uint256" }] },
  {
    type: "event", name: "FacilityRegistered",
    inputs: [
      { name: "facilityId", type: "bytes32", indexed: true },
      { name: "lender", type: "address", indexed: true },
      { name: "collateralRatioBps", type: "uint256", indexed: false },
    ],
  },
  {
    type: "function", name: "draw", stateMutability: "nonpayable",
    inputs: [
      { name: "facilityId", type: "bytes32" },
      { name: "drawId", type: "bytes32" },
      { name: "amount", type: "uint256" },
      { name: "extraCollateral", type: "uint256" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function", name: "topUpCollateral", stateMutability: "nonpayable",
    inputs: [{ name: "drawId", type: "bytes32" }, { name: "amount", type: "uint256" }],
    outputs: [],
  },
  {
    type: "event", name: "Drawn",
    inputs: [
      { name: "facilityId", type: "bytes32", indexed: true },
      { name: "drawId", type: "bytes32", indexed: true },
      { name: "borrower", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
      { name: "collateral", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event", name: "DrawCured",
    inputs: [
      { name: "drawId", type: "bytes32", indexed: true },
      { name: "amountPulled", type: "uint256", indexed: false },
      { name: "fullClose", type: "bool", indexed: false },
    ],
  },
  {
    type: "event", name: "CollateralReleased",
    inputs: [
      { name: "drawId", type: "bytes32", indexed: true },
      { name: "borrower", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event", name: "AuctionArmed",
    inputs: [
      { name: "drawId", type: "bytes32", indexed: true },
      { name: "orderHash", type: "bytes32", indexed: false },
      { name: "target", type: "uint256", indexed: false },
    ],
  },
] as const;

export const routerAbi = [
  {
    type: "function", name: "hash", stateMutability: "view",
    inputs: [
      {
        name: "order", type: "tuple",
        components: [
          { name: "maker", type: "address" },
          { name: "traits", type: "uint256" },
          { name: "data", type: "bytes" },
        ],
      },
    ],
    outputs: [{ type: "bytes32" }],
  },
  {
    type: "function", name: "coveredAmount", stateMutability: "view",
    inputs: [{ name: "maker", type: "address" }, { name: "orderHash", type: "bytes32" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

export const erc20Abi = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ name: "a", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "allowance", stateMutability: "view", inputs: [{ name: "o", type: "address" }, { name: "s", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ name: "s", type: "address" }, { name: "v", type: "uint256" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
] as const;

export const oracleAbi = [
  { type: "function", name: "answer", stateMutability: "view", inputs: [], outputs: [{ type: "int256" }] },
] as const;

export const builderAbi = [
  {
    type: "function", name: "buildFacilityLeg", stateMutability: "pure",
    inputs: [
      {
        name: "t", type: "tuple",
        components: [
          { name: "maker", type: "address" },
          { name: "counterToken", type: "address" },
          { name: "pullToken", type: "address" },
          { name: "amount", type: "uint256" },
          { name: "salt", type: "uint256" },
        ],
      },
      { name: "taker", type: "address" },
    ],
    outputs: [
      {
        name: "order", type: "tuple",
        components: [
          { name: "maker", type: "address" },
          { name: "traits", type: "uint256" },
          { name: "data", type: "bytes" },
        ],
      },
      { name: "shipStrategy", type: "bytes" },
      { name: "tokens", type: "address[]" },
      { name: "amounts", type: "uint256[]" },
    ],
  },
] as const;

export const aquaAbi = [
  {
    type: "function", name: "ship", stateMutability: "nonpayable",
    inputs: [
      { name: "app", type: "address" },
      { name: "strategy", type: "bytes" },
      { name: "tokens", type: "address[]" },
      { name: "amounts", type: "uint256[]" },
    ],
    outputs: [{ type: "bytes32" }],
  },
] as const;

export const registerFacilityAbi = [
  {
    type: "function", name: "registerFacility", stateMutability: "nonpayable",
    inputs: [
      { name: "facilityId", type: "bytes32" },
      {
        name: "order", type: "tuple",
        components: [
          { name: "maker", type: "address" },
          { name: "traits", type: "uint256" },
          { name: "data", type: "bytes" },
        ],
      },
      {
        name: "p", type: "tuple",
        components: [
          { name: "borrower", type: "address" },
          { name: "loanToken", type: "address" },
          { name: "collateralToken", type: "address" },
          { name: "oracle", type: "address" },
          { name: "collateralRatioBps", type: "uint256" },
          { name: "maintenanceRatioBps", type: "uint256" },
          { name: "rateBps", type: "uint256" },
          { name: "termSeconds", type: "uint40" },
          { name: "auctionDuration", type: "uint16" },
          { name: "auctionDecay", type: "uint64" },
          { name: "commitment", type: "uint256" },
          { name: "availabilityEnd", type: "uint40" },
        ],
      },
    ],
    outputs: [],
  },
] as const;
