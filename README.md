```
PS: This is the latest version of AsceSwap with a better design. The current frontend depicts the previous version, which was just a prototype.
```

# AsceSwap

On-chain interest rate swap protocol on StarkNet. Trade fixed vs floating rates against an LP pool. Positions are ERC721 NFTs, LP shares are ERC6909 with an ERC4626 vault interface.

## Architecture

```
                    ┌──────────────────────┐
                    │   Analytics Contract  │  Single-call page data
                    └──────────┬───────────┘
                               │ dispatcher calls
                    ┌──────────▼───────────┐
                    │   AsceSwap (Main)     │  Core protocol
                    │                      │
                    │  ┌────────────────┐  │
                    │  │ MarketManager  │  │  Market creation & params
                    │  │ SwapManager    │  │  Swap lifecycle & settlement
                    │  │ LiquidityMgr   │  │  LP deposits & withdrawals
                    │  │ Security       │  │  Roles, pause, reentrancy
                    │  │ Analytics      │  │  Dashboard & position data
                    │  │ ERC6909        │  │  LP share token
                    │  └────────────────┘  │
                    │                      │
                    │  ┌────────────────┐  │
                    │  │ Libraries      │  │
                    │  │  RateEngine    │  │  TWA, pricing, demand curve
                    │  │  Settlement    │  │  PnL, payouts, exit fees
                    │  │  HealthCalc    │  │  Margins, health factor
                    │  │  PoolAcctg     │  │  Share math, locking
                    │  └────────────────┘  │
                    └──────────┬───────────┘
                               │
             ┌─────────────────┼──────────────────┐
             │                 │                  │
     ┌───────▼──────┐ ┌───────▼──────┐ ┌─────────▼────────┐
     │ PositionMgr  │ │ Rate Oracle  │ │ AccessRegistry    │
     │ ERC721 NFTs  │ │ External     │ │ Role management   │
     └──────────────┘ └──────────────┘ └──────────────────┘
```

## Core Concepts

### Markets

A market pair is defined by a collateral token, a rate oracle, and a set of curator-configured parameters. Each market has its own LP pool. Markets can be permissioned (whitelisted LPs only) or open.

### Swap Lifecycle

```
buy_swap() ──► Active ──► settle_swap() ──► claim()
                 │
                 └──► early_exit() ──► claim()
```

1. **Buy**: Buyer specifies side (Fixed/Floating), notional, collateral, max acceptable rate, and term. Rate engine calculates the final rate. Required margin is computed, LP collateral is locked, and an NFT is minted.
2. **Active**: Position accrues PnL based on TWA rate vs locked fixed rate. Health factor is tracked for informational purposes.
3. **Settle**: After expiry, anyone can call `settle_swap()`. TWA rate determines final PnL. Payouts are stored (CEI pattern).
4. **Early Exit**: Before expiry (after min hold period), the buyer can exit with a time-decaying penalty.
5. **Claim**: NFT owner calls `claim()` to receive the payout and burn the NFT.

### Fixed vs Floating

| Side | Betting On | Profits When | Loses When |
|------|-----------|-------------|------------|
| **Fixed** | Rates rise | TWA > fixed rate | TWA < fixed rate |
| **Floating** | Rates fall | TWA < fixed rate | TWA > fixed rate |

PnL is always bounded by posted collateral on both sides. No bad debt can occur.

```
fixed_payment  = notional * fixed_rate * term / year
float_payment  = notional * TWA_rate  * term / year

Fixed buyer PnL  = float_payment - fixed_payment
Float buyer PnL  = fixed_payment - float_payment

buyer_payout = min(buyer_collateral + profit, buyer_collateral + lp_locked)
             = max(buyer_collateral - loss, 0)
```

## Rate Engine

### Swap Pricing

```
final_rate = oracle_rate + demand_spread + base_fee_spread
```

- **Oracle rate**: Current reference rate from external oracle, clamped per update to prevent manipulation.
- **Base fee spread**: Minimum spread on all trades — the LP's guaranteed edge.
- **Demand spread**: Dynamic spread based on pool imbalance (see below).

### Demand Spread Curve

Only the crowded side (more collateral locked) pays a demand spread. The underweight side pays zero. This incentivizes pool balance.

```
imbalance = |locked_fixed - locked_floating|
capacity  = available_liquidity * demand_spread_factor / BPS
ratio     = imbalance / capacity

Ratio → Spread (3-tier piecewise curve):
  0-20%  ratio  →  0-1%   spread   (gentle)
  20-50% ratio  →  1-5%   spread   (moderate)
  50-100% ratio →  5-30%  spread   (aggressive)
```

The `demand_spread_factor` parameter controls sensitivity. Higher factor = larger capacity bucket = more tolerant of imbalance. Lower factor = tighter = spreads rise faster.

**Two-pass pricing**: The engine computes spread before and after the trade's estimated impact, then averages them. This means larger trades partially internalize their own price impact.

### Time-Weighted Average (TWA)

Settlement uses TWA rates, not spot rates:

```
cumulative_rate accumulates: rate_bps * seconds_elapsed
TWA = (cumulative_at_end - cumulative_at_start) / duration
```

Rate index updates are clamped by `max_rate_change_per_update_bps` to limit oracle manipulation.

## Settlement

### Normal Settlement (at expiry)

PnL is calculated using TWA rate over the full term. Both sides' losses are capped at their posted collateral.

### Early Exit

A time-decaying fee penalizes early exits. The fee decays linearly from `max_early_exit_fee_bps` at term start to `min_early_exit_fee_bps` near expiry:

```
fee_bps = max_fee - (elapsed / total_term) * (max_fee - min_fee)
penalty = initial_required_margin * fee_bps / BPS
```

Exiting 1 day after opening costs significantly more than exiting 1 day before expiry. A minimum hold period must pass before early exit is allowed.

### No Liquidation

Payoffs are bounded by posted collateral on both sides — no bad debt can occur. There is no forced liquidation. Health factor is calculated and exposed for frontend dashboards but does not trigger any on-chain action.

## Liquidity Provision

LP shares follow the ERC4626 vault pattern (deposit/mint/withdraw/redeem) using ERC6909 multi-token shares (one token ID per market).

```
First deposit:  shares = deposit - burned_amount (inflation attack protection)
Later deposits: shares = deposit * total_shares / total_collateral

Withdrawal: assets = shares * total_collateral / total_shares
```

LPs earn swap entry fees. LPs risk losing collateral when swap buyers profit.

A `max_total_utilization_bps` cap prevents the pool from being fully locked.

## Market Parameters

| Parameter | Description |
|-----------|-------------|
| `initial_margin_multiplier_bps` | Margin multiplier on max exposure (e.g., 12000 = 120%) |
| `min_margin_floor_bps` | Minimum margin ratio as swap approaches expiry |
| `min/max_swap_term_seconds` | Allowed swap duration range |
| `min_hold_period_seconds` | Time before early exit is allowed |
| `swap_fee_bps` | Entry fee on swap creation |
| `max_early_exit_fee_bps` | Exit penalty at term start |
| `min_early_exit_fee_bps` | Exit penalty near expiry |
| `base_fee_spread_bps` | LP's minimum rate edge |
| `demand_spread_factor` | Imbalance sensitivity (higher = more tolerant) |
| `max_total_utilization_bps` | Hard cap on pool utilization |
| `min_notional_per_swap` | Minimum swap size |
| `max_oracle_staleness_seconds` | Oracle freshness requirement |
| `max_rate_change_per_update_bps` | Rate clamping per oracle update |
| `is_lp_permissioned` | Whether LP deposits require whitelist |

## Repository Structure

```
src/
├── asceswap.cairo              # Main contract entry point
├── analytics.cairo             # Analytics wrapper contract
├── position_manager.cairo      # ERC721 position NFTs
├── accessregistry.cairo        # Role-based access control
│
├── components/
│   ├── MarketManager.cairo     # Market creation, params, oracle
│   ├── SwapManager.cairo       # Swap buy, settle, early exit, claim
│   ├── LiquidityManager.cairo  # ERC4626 vault (deposit/withdraw)
│   ├── Analytics.cairo         # Dashboard & position analytics
│   ├── ERC6909.cairo           # Multi-token LP shares
│   └── Security.cairo          # Pause, reentrancy, roles
│
├── libraries/
│   ├── rate_engine.cairo       # TWA, pricing, demand curve
│   ├── settlement_engine.cairo # PnL, payouts, exit fees
│   ├── health_calculator.cairo # Margin & health factor
│   └── pool_accounting.cairo   # Share math, locking
│
├── interfaces/                 # All trait definitions
├── types/                      # Structs, enums, type definitions
├── helpers/                    # Constants, errors, fixed-point math, utils
└── mock/                       # Test mocks (oracle, token)
```

## Build & Test

```bash
scarb build        # Compile contracts
snforge test       # Run test suite (110 tests)
scarb fmt          # Format code
```

