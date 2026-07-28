# Midnight fork-test fixtures

Midnight is an off-chain order book with on-chain settlement: takeable offers
are signed intents served by the REST API, NOT on-chain state. A pinned fork
block therefore contains no offers by itself — the fixture is the pair
**(pinned block, API snapshot captured at the same wall-clock moment)**. As
long as the fork block's timestamp lies inside an offer's `[start, expiry]`
window, that offer fills on the fork forever (state and time are frozen), even
though it has long expired in real time.

## Files

- `midnight-book-49219332.json` — raw snapshot of
  `GET https://api.morpho.org/v0/midnight/books/{market_id}/asks/takeable-offers`
  and `.../bids/takeable-offers` for the Aug-28-2026 cbBTC/USDC market
  (`0x05959752…c84c`), captured 2026-07-28 together with Base block
  **49,219,332** (timestamp 1,785,228,011). The top ask (maker `0xd418…6ee4`,
  tick 4516) and the best in-window bid (maker `0x6c51…28b9`, tick 4508) are
  transcribed into `../MidnightForkBase.sol` for the tests.

## Regeneration (needed only if the pin ever moves)

1. Fetch both books:
   `curl https://api.morpho.org/v0/midnight/books/<market_id>/asks/takeable-offers`
   (and `bids/`) — pick a market from `GET /books` with usable depth.
2. Immediately record the chain head: `cast block latest --rpc-url <base-rpc>`
   (number + timestamp). Steps 1–2 must happen within the same minute.
3. Check every offer you intend to use satisfies
   `start <= blockTimestamp <= expiry`.
4. Commit the raw JSON here and update the constants in
   `../MidnightForkBase.sol`: `FORK_BLOCK`, market id/maturity, offer fields,
   `ratifier_data` blobs, and the tick prices
   (`price = 1e18 / (1 + e^(0.004987541511039073 * (3372 - tick)))`, rounded
   to 1e11 steps).

Offers go stale by design (short validity windows; makers can cancel or
un-ratify at any second) — never expect a fixture to fill at a block other
than the one it was captured with.
