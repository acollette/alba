import { createConfig } from "wagmi";
import { fallback, http } from "viem";
import { base, baseSepolia, foundry, hederaTestnet } from "wagmi/chains";
import { injected } from "wagmi/connectors";

export const wagmiConfig = createConfig({
  // base (8453) is the vault's launch chain; foundry (31337) doubles as the
  // local anvil target for vault development pre-deployment.
  chains: [baseSepolia, base, hederaTestnet, foundry],
  connectors: [injected()],
  transports: {
    // drpc first: sepolia.base.org rejects wider eth_getLogs ranges (policy changed
    // mid-hackathon), which silently emptied the book/timeline. Fallback keeps both.
    [baseSepolia.id]: fallback([http("https://base-sepolia.drpc.org"), http("https://sepolia.base.org")]),
    [base.id]: fallback([http("https://base.drpc.org"), http("https://mainnet.base.org")]),
    [hederaTestnet.id]: http("https://testnet.hashio.io/api"),
    [foundry.id]: http("http://127.0.0.1:8545"),
  },
});
