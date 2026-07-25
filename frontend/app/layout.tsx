import type { Metadata } from "next";
import "./globals.css";
import { Providers } from "./providers";

export const metadata: Metadata = {
  title: "Alba — committed credit, settled by schedule",
  description:
    "Revolving credit facilities as SwapVM programs: Aqua settlement, Hedera-scheduled maturities, continuous margining with cure-first liquidation.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
