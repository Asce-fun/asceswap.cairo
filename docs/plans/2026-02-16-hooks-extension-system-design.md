# AsceSwap Hook/Extension System — Design Document

**Date:** 2026-02-16
**Status:** Approved
**Authors:** AsceSwap Core Team

---

## 1. Overview

Add a hook/extension system to AsceSwap that lets external contracts inject custom logic at specific points in the protocol's lifecycle. The design follows Ekubo Protocol's battle-tested extension pattern (void-return hooks with re-entry) as the foundation, extended with Uniswap V4-inspired custom execution capabilities for advanced use cases like ZK dark pools and custom pricing.

### Design Principles

1. **Market isolation** — a buggy/malicious hook on Market A can never affect Market B
2. **Immutability** — hooks are set at market creation, never changed
3. **Core safety** — settlement, health, and margin logic are never delegated
4. **Zero overhead** — markets with no extension behave identically to today
5. **Permissionless** — anyone can deploy an extension and create markets with it

---

## 2. Research Basis

| Protocol | Pattern | Audit Status |
|----------|---------|-------------|
| **Ekubo** (StarkNet) | `IExtension` trait, `CallPoints` struct (8 bools), void returns, re-entry with auto-skip | 15 weeks Nethermind + Plainshift |
| **Uniswap V4** (EVM) | `IHooks` interface, address-encoded flags, `BeforeSwapDelta` return values | Cyfrin, Certora, Trail of Bits |
| **Haiko** (StarkNet) | `ISolverHooks` with `quote()` replacing AMM pricing | N/A |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Hook power | Ekubo-style (void) + custom execution mode | Proven foundation + V4 expressiveness where needed |
| Hooks per market | One | Simpler, matches Ekubo/V4. Compose internally. |
| Hook points | Full lifecycle (8) + 2 custom execution flags | Complete coverage from day one |
| Mutability | Immutable | Set at market creation, never changes |
| Fund access | Reserve-based with core enforcement | Core controls all transfers, per-market caps |
| POC scope | Core infrastructure + simple example hook | Yield strategy hook is a separate project |

---

## 3. CallPoints

10 flags controlling which hook functions are active for an extension.

```cairo
#[derive(Copy, Drop, Serde, starknet::Store, Default)]
struct CallPoints {
    before_swap_open: bool,
    after_swap_open: bool,
    before_settlement: bool,
    after_settlement: bool,
    before_lp_deposit: bool,
    after_lp_deposit: bool,
    before_lp_withdraw: bool,
    after_lp_withdraw: bool,
    custom_swap_execution: bool,
    custom_lp_execution: bool,
}
```

**Rules:**
- Extension calls `core.set_call_points(call_points)` once during its constructor
- Immutable after registration — cannot be changed
- The core checks flags before every external call to avoid unnecessary gas
- Default is all-false (no hooks fire)

---

## 4. IExtension Interface

What hook developers implement.

```cairo
#[starknet::interface]
trait IExtension<TContractState> {
    // ── Lifecycle hooks (void returns, Ekubo-style) ──

    fn before_swap_open(
        ref self: TContractState,
        caller: ContractAddress,
        pair_id: felt252,
        params: SwapOpenParams,
    );
    fn after_swap_open(
        ref self: TContractState,
        caller: ContractAddress,
        pair_id: felt252,
        swap_id: u256,
        params: SwapOpenParams,
    );
    fn before_settlement(
        ref self: TContractState,
        caller: ContractAddress,
        pair_id: felt252,
        swap_id: u256,
        settlement_type: SettlementType,
    );
    fn after_settlement(
        ref self: TContractState,
        caller: ContractAddress,
        pair_id: felt252,
        swap_id: u256,
        result: SettlementResult,
    );
    fn before_lp_deposit(
        ref self: TContractState,
        caller: ContractAddress,
        pair_id: felt252,
        amount: u256,
    );
    fn after_lp_deposit(
        ref self: TContractState,
        caller: ContractAddress,
        pair_id: felt252,
        amount: u256,
        shares: u256,
    );
    fn before_lp_withdraw(
        ref self: TContractState,
        caller: ContractAddress,
        pair_id: felt252,
        shares: u256,
    );
    fn after_lp_withdraw(
        ref self: TContractState,
        caller: ContractAddress,
        pair_id: felt252,
        shares: u256,
        amount: u256,
    );

    // ── Custom execution (V4-inspired, core bypass) ──

    fn execute_swap(
        ref self: TContractState,
        caller: ContractAddress,
        pair_id: felt252,
        params: SwapOpenParams,
    );
    fn execute_lp_deposit(
        ref self: TContractState,
        caller: ContractAddress,
        pair_id: felt252,
        amount: u256,
    );
    fn execute_lp_withdraw(
        ref self: TContractState,
        caller: ContractAddress,
        pair_id: felt252,
        shares: u256,
    );
}
```

**`caller`** is the actual user who initiated the action, not the extension.

**`SwapOpenParams`:**
```cairo
#[derive(Copy, Drop, Serde)]
struct SwapOpenParams {
    buyer: ContractAddress,
    side: SwapSide,
    notional: u256,
    collateral: u256,
    max_rate_bps: u256,
}
```

---

## 5. New Core Functions

### 5.1 Extension Registration

```cairo
fn set_call_points(ref self: ContractState, call_points: CallPoints);
```

- Callable only by the extension contract itself
- One-time only — reverts if already registered
- Stores `extension_call_points[caller] = call_points`
- Sets `extension_registered[caller] = true`

### 5.2 Extension Fund Access

```cairo
fn withdraw_to_extension(ref self: ContractState, pair_id: felt252, amount: u256);
fn receive_from_extension(ref self: ContractState, pair_id: felt252, amount: u256);
```

**`withdraw_to_extension` enforcement:**
1. `caller` must be the extension attached to this market
2. `amount ≤ total_collateral - locked_for_fixed - locked_for_floating - deployed_to_extension`
3. Core transfers tokens to extension
4. Core increments `deployed_to_extension[pair_id] += amount`

**`receive_from_extension` enforcement:**
1. `caller` must be the extension attached to this market
2. Core does `transferFrom(extension, core, amount)`
3. Core decrements `deployed_to_extension[pair_id] -= amount`

### 5.3 Custom Execution Credits

```cairo
fn credit_swap(
    ref self: ContractState,
    pair_id: felt252,
    buyer: ContractAddress,
    side: SwapSide,
    notional: u256,
    fixed_rate_bps: u256,
    buyer_collateral: u256,
    lp_collateral_to_lock: u256,
) -> u256; // returns swap_id

fn credit_lp_deposit(
    ref self: ContractState,
    pair_id: felt252,
    depositor: ContractAddress,
    amount: u256,
    shares_to_mint: u256,
) -> u256; // returns shares

fn credit_lp_withdraw(
    ref self: ContractState,
    pair_id: felt252,
    lp: ContractAddress,
    shares_to_burn: u256,
    amount_to_return: u256,
) -> u256; // returns amount
```

**`credit_swap` enforcement:**
- Caller must be the extension attached to this market
- `custom_swap_execution` flag must be set
- Notional within `[min_notional, max_notional_per_swap]`
- LP pool has enough available liquidity for `lp_collateral_to_lock`
- Utilization cap not exceeded
- `fixed_rate_bps` within `[min_rate_bps, max_rate_bps]`
- Core creates Swap struct, locks LP collateral, mints NFT

**`credit_lp_deposit` enforcement:**
- Caller must be the extension attached to this market
- `custom_lp_execution` flag must be set
- `shares_to_mint > 0`
- Core updates pool state (`total_shares += shares`, `total_collateral += amount`)

**`credit_lp_withdraw` enforcement:**
- Caller must be the extension attached to this market
- `custom_lp_execution` flag must be set
- LP owns `shares_to_burn`
- `amount_to_return ≤ available_liquidity`
- Core updates pool state, transfers tokens to LP

---

## 6. Core Dispatch Logic

### 6.1 Re-entry Safety (Ekubo pattern)

```cairo
fn get_call_points(
    self: @ContractState,
    extension: ContractAddress,
    caller: ContractAddress,
) -> CallPoints {
    if extension.is_zero() {
        return CallPoints::default(); // no extension
    }
    if extension == caller {
        return CallPoints::default(); // extension is caller → skip hooks
    }
    self.extension_call_points.read(extension)
}
```

When the extension re-enters the core (e.g., calling `withdraw_to_extension` from within `after_lp_deposit`), hooks are automatically skipped because `extension == caller`. This prevents infinite recursion.

### 6.2 Standard Flow (lifecycle hooks only)

```
buy_swap(pair_id, side, notional, collateral, max_rate)
  │
  ├─ Read call_points for market's extension
  ├─ if before_swap_open: call extension.before_swap_open(user, pair_id, params)
  │    └─ Extension can validate, log, or revert to block
  │
  ├─ Core logic: rate calc, margin validation, pool lock, NFT mint
  │
  └─ if after_swap_open: call extension.after_swap_open(user, pair_id, swap_id, params)
       └─ Extension can log, update state, re-enter core
```

### 6.3 Custom Swap Execution Flow

```
buy_swap(pair_id, side, notional, collateral, max_rate)
  │
  ├─ Read call_points → custom_swap_execution == true
  ├─ Core validates: collateral transferred, market active, basic bounds
  │   (does NOT calculate rate, does NOT lock pool, does NOT create swap)
  │
  └─ Core calls extension.execute_swap(user, pair_id, params)
       │
       ├─ Extension: custom logic (ZK proof, custom pricing, batch auction)
       │
       └─ Extension calls core.credit_swap(pair_id, buyer, side, ...)
            ├─ Core validates invariants (bounds, utilization, liquidity, isolation)
            ├─ Core locks LP collateral
            ├─ Core creates Swap struct
            ├─ Core mints NFT
            └─ Returns swap_id
```

### 6.4 Custom LP Execution Flow

```
supply_lp_collateral(pair_id, amount)
  │
  ├─ Read call_points → custom_lp_execution == true
  ├─ Core validates: collateral transferred, market active
  │
  └─ Core calls extension.execute_lp_deposit(user, pair_id, amount)
       │
       ├─ Extension: custom logic (auto-deploy to yield, custom share calc)
       │
       └─ Extension calls core.credit_lp_deposit(pair_id, user, amount, shares)
            ├─ Core validates pool consistency
            └─ Core updates state
```

### 6.5 Settlement (never delegated)

```
settle_swap(swap_id)
  │
  ├─ if before_settlement: call extension.before_settlement(...)
  ├─ Core: TWA calculation, PnL, payout (ALWAYS core logic)
  └─ if after_settlement: call extension.after_settlement(...)
```

Settlement, health calculation, and liquidation are **never** delegated to extensions. A trader can always trust that settlement math is the audited core logic, regardless of what hook is attached.

---

## 7. Market Isolation

### The Guarantee

A buggy or malicious extension on Market A can never affect Market B's funds or state.

### How It's Enforced

1. **Per-market pools**: Each `MarketPair` has its own `LpPool` with separate accounting
2. **Extension-to-market binding**: `withdraw_to_extension` and `credit_*` functions validate `caller == market.extension`
3. **Per-market deployed tracking**: `deployed_to_extension[pair_id]` tracks each market's external deployments independently
4. **Available liquidity includes deployed funds**:
   ```
   available = total_collateral - locked_for_fixed - locked_for_floating - deployed_to_extension
   ```
5. **Core does all token transfers**: Extensions never call `transfer` on the collateral token directly from the core's balance. The core transfers to/from the extension.

### Worst Case

If an extension is malicious and drains its market's idle funds via `withdraw_to_extension`:
- Only that market's idle liquidity is lost
- Locked collateral for active swaps is NOT accessible to the extension
- Other markets are completely unaffected
- Active swaps in the affected market can still settle (their collateral is locked, not deployed)

---

## 8. Modified Existing Types

### MarketPair

```cairo
struct MarketPair {
    pair_id: felt252,
    status: MarketStatus,
    rate_oracle: ContractAddress,
    curator: ContractAddress,
    collateral_token: ContractAddress,
    decimals: u8,
    params: MarketParams,
    pool: LpPool,
    rate_index: RateIndex,
    total_swaps_created: u256,
    active_swap_count: u256,
    extension: ContractAddress,    // NEW — zero = no hook
}
```

### create_market_pair

```cairo
fn create_market_pair(
    rate_oracle: ContractAddress,
    collateral_token: ContractAddress,
    curator: ContractAddress,
    params: MarketParams,
    initial_liquidity_amount: u256,
    extension: ContractAddress,    // NEW — zero = no hook
) -> (felt252, u256)
```

Validation: if `extension != zero`, it must be registered.

### Available Liquidity

All functions that check available liquidity now subtract `deployed_to_extension`:

```
available = total_collateral - locked_for_fixed - locked_for_floating - deployed_to_extension[pair_id]
```

This affects: LP withdrawal, new swap validation, utilization calculation.

---

## 9. New Storage

```cairo
// Extension registration
extension_call_points: Map<ContractAddress, CallPoints>,
extension_registered: Map<ContractAddress, bool>,

// Per-market external deployment tracking
deployed_to_extension: Map<felt252, u256>,
```

---

## 10. Extension Developer Boilerplate

```cairo
#[starknet::contract]
mod MyExtension {
    use starknet::{ContractAddress, get_caller_address};

    #[storage]
    struct Storage {
        core: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, core: ContractAddress) {
        self.core.write(core);

        // Register call points — one time, immutable
        IAsceSwapDispatcher { contract_address: core }
            .set_call_points(CallPoints {
                before_swap_open: true,
                after_swap_open: false,
                before_settlement: false,
                after_settlement: false,
                before_lp_deposit: false,
                after_lp_deposit: false,
                before_lp_withdraw: false,
                after_lp_withdraw: false,
                custom_swap_execution: false,
                custom_lp_execution: false,
            });
    }

    fn assert_only_core(self: @ContractState) {
        assert(get_caller_address() == self.core.read(), 'Only core');
    }

    #[abi(embed_v0)]
    impl ExtensionImpl of IExtension<ContractState> {
        fn before_swap_open(
            ref self: ContractState,
            caller: ContractAddress,
            pair_id: felt252,
            params: SwapOpenParams,
        ) {
            self.assert_only_core();
            // Custom logic here
        }

        // Unused hooks should panic
        fn after_swap_open(...) { panic!("Not used"); }
        fn before_settlement(...) { panic!("Not used"); }
        // ... etc
    }
}
```

---

## 11. Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `src/interfaces/extension.cairo` | **CREATE** | `IExtension` trait definition |
| `src/types/extension.cairo` | **CREATE** | `CallPoints`, `SwapOpenParams` types |
| `src/components/ExtensionManager.cairo` | **CREATE** | Dispatch logic, call_points storage, fund access, credit functions |
| `src/asceswap.cairo` | **MODIFY** | Integrate ExtensionManager component, add `set_call_points`, `withdraw_to_extension`, `receive_from_extension`, `credit_swap`, `credit_lp_deposit`, `credit_lp_withdraw` |
| `src/types/asce_swap.cairo` | **MODIFY** | Add `extension: ContractAddress` to `MarketPair` |
| `src/interfaces/asce_swap.cairo` | **MODIFY** | Add new functions to `IAsceSwap` trait |
| `src/components/LiquidityManager.cairo` | **MODIFY** | Account for `deployed_to_extension` in available liquidity |
| `src/components/SwapManager.cairo` | **MODIFY** | Account for `deployed_to_extension` in utilization checks |
| `src/components/MarketManager.cairo` | **MODIFY** | Add extension validation in `create_market_pair` |
| `src/mocks.cairo` | **MODIFY** | Add `MockExtension` (simple logger) and `MockCustomExtension` (custom execution) |
| `tests/test_extension.cairo` | **CREATE** | Integration tests for all extension flows |
| `src/lib.cairo` | **MODIFY** | Register new modules |

---

## 12. What Does NOT Change

- **Settlement engine** — TWA, PnL, payouts: untouched
- **Health calculator** — margin, health factor, liquidation: untouched
- **Rate engine** — for non-custom markets: untouched
- **Pool accounting library** — share math: untouched
- **ERC721 mechanics** — NFT mint/burn/transfer: untouched
- **AccessRegistry** — role management: untouched
- **Analytics component** — dashboard queries: untouched
- **Existing tests** — all 90 tests continue to pass (extension = zero)
- **Markets with no extension** — zero overhead, identical to today

---

## 13. Security Considerations

| Risk | Mitigation |
|------|-----------|
| Extension reverts block core operation | Extension is part of market identity — users opt in |
| Extension consumes excessive gas | Gas limits on external calls; users evaluate before joining |
| Extension re-enters core in loop | `extension == caller` check skips hooks automatically |
| Extension accesses other market's funds | `caller == market.extension` enforced on all fund access |
| Extension manipulates settlement | Settlement is never delegated — always core logic |
| Mutable extension behavior | CallPoints are immutable after registration |
| Extension upgraded to malicious code | Extensions should be non-upgradeable (documented best practice) |
| Credit functions called by non-extension | Caller validation: must be market's registered extension |

---

## 14. Testing Strategy

### Unit Tests
- CallPoints registration (once-only, immutable)
- `get_call_points` with zero extension, with registered extension, with extension-as-caller (re-entry skip)
- `withdraw_to_extension` / `receive_from_extension` with per-market caps
- `credit_swap` / `credit_lp_deposit` / `credit_lp_withdraw` invariant checks
- Available liquidity calculation with deployed funds

### Integration Tests
- Full lifecycle with lifecycle hooks (before/after on swap, settlement, LP)
- Full lifecycle with custom swap execution
- Full lifecycle with custom LP execution
- Market isolation: two markets, one with buggy extension, verify other is unaffected
- Re-entry: extension calls `withdraw_to_extension` from `after_lp_deposit`
- Extension that reverts: verify market-scoped impact only
- Zero-extension markets: verify no behavioral change from today

### Mock Contracts
- `MockExtension`: logs all hook calls, verifies caller is core
- `MockCustomSwapExtension`: implements custom rate logic via `execute_swap` + `credit_swap`
- `MockCustomLpExtension`: implements custom share logic via `execute_lp_deposit` + `credit_lp_deposit`
- `MockYieldExtension`: uses `withdraw_to_extension` / `receive_from_extension` in after-hooks
