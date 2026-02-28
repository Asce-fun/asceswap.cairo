# Mainnet Spec — Post-Indexer Cleanup

Items to address before mainnet once an indexer is in place.

## Remove on-chain counters (after indexer)

- **`total_swaps_created`** — Vanity counter on `MarketPair`. Only used by analytics for display. Adds gas to every `markets.write()` (swap creation, settlement, early exit, liquidation). Replace with indexer query over `SwapCreated` events.

- **`active_swap_count`** — Also display-only, but harder to compute without iterating all swaps. Remove once the indexer can track active vs settled/liquidated swap counts per market.

**Files affected:** `src/types/asce_swap.cairo` (struct field), `src/asceswap.cairo` (increment/decrement), `src/components/MarketManager.cairo` (init to 0), `src/analytics.cairo` + `src/types/analytics.cairo` (reads).
