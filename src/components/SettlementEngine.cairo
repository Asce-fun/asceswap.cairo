// Settlement Engine Component
// Handles all swap closure logic: settle, early_exit, and liquidation
// Eliminates code redundancy by providing unified settlement processing

use crate::helpers::core_utils::{calculate_fee, calculate_payment};
use crate::helpers::signed_value::{negative, positive, safe_sub};
use crate::helpers::utils::min;
use crate::libraries::{pool_accounting, rate_engine};
use crate::types::asce_swap::{
    LpPool, MarketParams, RateIndex, SettlementResult, SettlementType, SignedValue, Swap, SwapSide,
};

/// Calculate PnL for a swap at expiration (full term)
pub fn calculate_pnl(swap: @Swap, twa_rate_bps: u256) -> SignedValue {
    let notional = *swap.notional;
    let fixed_rate = *swap.fixed_rate_bps;
    let term_seconds = *swap.expiration_time - *swap.start_time;

    // Calculate payments
    let fixed_payment = calculate_payment(notional, fixed_rate, term_seconds);
    let floating_payment = calculate_payment(notional, twa_rate_bps, term_seconds);

    // PnL depends on swap side
    match *swap.side {
        SwapSide::Fixed => {
            // Buyer pays fixed, receives floating
            safe_sub(floating_payment, fixed_payment)
        },
        SwapSide::Floating => {
            // Buyer pays floating, receives fixed
            safe_sub(fixed_payment, floating_payment)
        },
    }
}

/// Calculate partial PnL for early exit (pro-rated)
pub fn calculate_pnl_partial(swap: @Swap, twa_rate_bps: u256, current_time: u64) -> SignedValue {
    let notional = *swap.notional;
    let fixed_rate = *swap.fixed_rate_bps;
    let elapsed_seconds = current_time - *swap.start_time;

    // Calculate pro-rated payments based on elapsed time
    let fixed_payment = calculate_payment(notional, fixed_rate, elapsed_seconds);
    let floating_payment = calculate_payment(notional, twa_rate_bps, elapsed_seconds);

    match *swap.side {
        SwapSide::Fixed => safe_sub(floating_payment, fixed_payment),
        SwapSide::Floating => safe_sub(fixed_payment, floating_payment),
    }
}

/// Calculate settlement payouts based on PnL
pub fn calculate_settlement_payouts(swap: @Swap, pnl: SignedValue) -> (u256, SignedValue) {
    let buyer_collateral = *swap.buyer_collateral;
    let lp_collateral = *swap.lp_collateral_locked;

    if pnl.is_negative {
        // Buyer loses, LP wins
        let buyer_loss = min(pnl.value, buyer_collateral);
        let buyer_payout = buyer_collateral - buyer_loss;
        let lp_gain = positive(buyer_loss);
        (buyer_payout, lp_gain)
    } else {
        // Buyer wins, LP loses
        let buyer_profit = min(pnl.value, lp_collateral);
        let buyer_payout = buyer_collateral + buyer_profit;
        let lp_loss = negative(buyer_profit);
        (buyer_payout, lp_loss)
    }
}

/// Apply early exit penalty to PnL
pub fn apply_early_exit_penalty(pnl: SignedValue, penalty: u256) -> SignedValue {
    if pnl.is_negative {
        // Loss increases by penalty
        negative(pnl.value + penalty)
    } else if pnl.value >= penalty {
        // Profit reduced by penalty
        positive(pnl.value - penalty)
    } else {
        // Profit less than penalty = net loss
        negative(penalty - pnl.value)
    }
}

/// Process a complete settlement for any settlement type
/// Returns the settlement result with all payouts calculated
pub fn process_settlement(
    swap: @Swap,
    rate_index: @RateIndex,
    params: @MarketParams,
    settlement_type: SettlementType,
    current_time: u64,
) -> SettlementResult {
    // Calculate TWA rate
    let twa_rate = rate_engine::calculate_twa(rate_index, swap, current_time);

    // Calculate base PnL based on settlement type
    let base_pnl = match settlement_type {
        SettlementType::Normal => calculate_pnl(swap, twa_rate),
        SettlementType::EarlyExit => calculate_pnl_partial(swap, twa_rate, current_time),
        SettlementType::Liquidation => calculate_pnl_partial(swap, twa_rate, current_time),
    };

    // Apply settlement-specific adjustments
    let (adjusted_pnl, penalty, liquidator_bonus) = match settlement_type {
        SettlementType::Normal => { (base_pnl, 0_u256, 0_u256) },
        SettlementType::EarlyExit => {
            let penalty = calculate_fee(*swap.buyer_collateral, *params.early_exit_fee_bps);
            let adjusted = apply_early_exit_penalty(base_pnl, penalty);
            (adjusted, penalty, 0_u256)
        },
        SettlementType::Liquidation => {
            // For liquidation, buyer loses everything
            // Liquidator gets bonus, rest goes to pool
            let bonus = calculate_fee(*swap.buyer_collateral, *params.liquidation_bonus_bps);
            // Use the base PnL but the payout calculation will be different
            (base_pnl, 0_u256, bonus)
        },
    };

    // Calculate payouts
    let (buyer_payout, lp_delta) = if settlement_type == SettlementType::Liquidation {
        // Liquidation: buyer gets nothing, pool gets remainder after liquidator bonus
        let remaining_to_pool = if *swap.buyer_collateral > liquidator_bonus {
            *swap.buyer_collateral - liquidator_bonus
        } else {
            0
        };
        (0_u256, positive(remaining_to_pool))
    } else {
        calculate_settlement_payouts(swap, adjusted_pnl)
    };

    SettlementResult {
        buyer_payout, lp_delta, liquidator_bonus, penalty, twa_rate_bps: twa_rate, pnl: base_pnl,
    }
}

/// Update pool state after settlement (unlock collateral, apply delta, decrement count)
pub fn finalize_pool_state(pool: LpPool, swap: @Swap, lp_delta: SignedValue) -> LpPool {
    // Unlock collateral
    let mut updated = pool_accounting::unlock_collateral(
        pool, *swap.side, *swap.lp_collateral_locked,
    );

    // Apply LP delta
    updated = pool_accounting::apply_lp_delta(updated, lp_delta);

    updated
}
