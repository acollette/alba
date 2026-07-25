import { createConfig } from "wagmi";
import { fallback, http } from "viem";
import { baseSepolia, foundry, hederaTestnet } from "wagmi/chains";
import { injected } from "wagmi/connectors";

export const wagmiConfig = createConfig({
  chains: [baseSepolia, hederaTestnet, foundry],
  connectors: [injected()],
  transports: {
    // drpc first: sepolia.base.org rejects wider eth_getLogs ranges (policy changed
    // mid-hackathon), which silently emptied the book/timeline. Fallback keeps both.
    [baseSepolia.id]: fallback([http("https://base-sepolia.drpc.org"), http("https://sepolia.base.org")]),
    [hederaTestnet.id]: http("https://testnet.hashio.io/api"),
    [foundry.id]: http("http://127.0.0.1:8545"),
  },
});
