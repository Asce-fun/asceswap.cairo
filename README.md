# AsceSwap

On-chain interest rate swap protocol on StarkNet. Positions are ERC721 NFTs.

Users bet on whether a reference rate (e.g., lending APY, treasury yield) will go up or down. LPs provide collateral and earn fees. Settlement uses time-weighted average rates.

---

## Architecture

```
                    ┌──────────────────────┐
                    │   Analytics Contract  │  ← Single-call page data
                    └──────────┬───────────┘
                               │ (dispatcher calls)
                    ┌──────────▼───────────┐
                    │   AsceSwap (Main)     │  ← Core protocol logic
                    │                      │
                    │  ┌────────────────┐  │
                    │  │ MarketManager  │  │  Market creation & lifecycle
                    │  │ SwapManager    │  │  Swap CRUD & settlement
                    │  │ LiquidityMgr   │  │  LP deposits & withdrawals
                    │  │ Security       │  │  Roles, pause, reentrancy
                    │  └────────────────┘  │
                    │                      │
                    │  ┌────────────────┐  │
                    │  │ Libraries      │  │
                    │  │  RateEngine    │  │  TWA, rate calculation
                    │  │  Settlement    │  │  PnL, payouts
                    │  │  HealthCalc    │  │  Margins, liquidation
                    │  │  PoolAcctg     │  │  LP shares, locking
                    │  └────────────────┘  │
                    └──────────┬───────────┘
                               │
             ┌─────────────────┼──────────────────┐
             │                 │                  │
     ┌───────▼──────┐ ┌───────▼──────┐ ┌─────────▼────────┐
     │ ERC721 (OZ)  │ │ Oracle       │ │ AccessRegistry    │
     │ Swap NFTs    │ │ Adapter      │ │ Role management   │
     └──────────────┘ └──────────────┘ └──────────────────┘
```

---

## How It Works

### Swap Lifecycle

```
1. LP deposits collateral into market pool
2. Buyer calls buy_swap(pair_id, side, notional, collateral, max_rate)
3. Rate engine calculates: oracle_rate + imbalance_adj + fee_spread = final_rate
4. Required margin computed, LP collateral locked, NFT minted
5. During term: health monitored, can early_exit() or get liquidated
6. At expiry: settle_swap() calculates TWA rate, distributes PnL
```

### Fixed vs Floating

| Side | You're Betting | You Profit When | You Lose When |
|------|---------------|-----------------|---------------|
| **Fixed (UP)** | Rates will rise | TWA > your fixed rate | TWA < your fixed rate |
| **Floating (DOWN)** | Rates will fall | TWA < your fixed rate | TWA > your fixed rate |

### PnL Calculation

```rust
fixed_payment  = notional x fixed_rate x term / year
float_payment  = notional x TWA_rate   x term / year

Fixed buyer PnL  = float_payment - fixed_payment
Float buyer PnL  = fixed_payment - float_payment
```

### Rate Engine

```rust
final_rate = oracle_rate + imbalance_adjustment + fee_spread

Imbalance adjustment:
- If more collateral locked on fixed side -> fixed rate increases
- Discourages one-sided markets, incentivizes balance

Rate clamping:
- Oracle rate changes capped at max_rate_change_per_update_bps per update
- Prevents oracle manipulation attacks
```

### Time-Weighted Average (TWA)

```rust
TWA = (cumulative_rate_at_end - cumulative_rate_at_start) / duration
Where cumulative_rate accumulates: rate_bps x seconds_elapsed
This ensures fair settlement regardless of rate volatility timing.
```

### Health & Liquidation

```rust
required_margin = notional x rate x (term / year) x multiplier

Time-adjusted margin decreases as expiry approaches:
  adjusted = margin x max(remaining_time / total_time, floor)

health_factor = remaining_collateral / adjusted_margin x 10000

Liquidatable when health_factor < liquidation_threshold_bps
Liquidator gets bonus, buyer loses remaining collateral.
```

### LP Mechanics

```rust
First deposit:  shares = deposit - burned_amount (inflation protection)
Later deposits: shares = deposit x total_shares / total_collateral

Withdrawal (after cooldown):
  collateral = shares x total_collateral / total_shares

LP earns: swap fees (entry fee split)
LP risks: losing collateral when swap buyers profit
```

---

## Build & Test

```bash
# Build
scarb build

# Test (90 tests)
scarb test

# Format
scarb fmt
```
