import { createConfig, http } from "wagmi";
import { baseSepolia, foundry } from "wagmi/chains";
import { injected } from "wagmi/connectors";

export const wagmiConfig = createConfig({
  chains: [baseSepolia, foundry],
  connectors: [injected()],
  transports: {
    [baseSepolia.id]: http("https://sepolia.base.org"),
    [foundry.id]: http("http://127.0.0.1:8545"),
  },
});
