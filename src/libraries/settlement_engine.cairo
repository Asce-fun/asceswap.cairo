// Settlement Engine Component
// Handles all swap closure logic: settle, early_exit, and liquidation
// Eliminates code redundancy by providing unified settlement processing
pub mod SettlementEngine {
    use crate::helpers::signed_value::{negative, positive, safe_sub};
    use crate::helpers::utils::Utils;
    use crate::libraries::pool_accounting::PoolAccounting;
    use crate::libraries::rate_engine::RateEngine;
    use crate::types::asce_swap::{
        LpPool, MarketParams, RateIndex, SettlementResult, SettlementType, SignedValue, Swap,
        SwapSide,
    };


    /// Calculate PnL for a swap at expiration (full term)
    pub fn calculate_pnl(swap: @Swap, twa_rate_bps: u256) -> SignedValue {
        let notional = *swap.notional;
        let fixed_rate = *swap.fixed_rate_bps;
        let term_seconds = *swap.expiration_time - *swap.start_time;

        // Calculate payments
        let fixed_payment = RateEngine::calculate_payment(notional, fixed_rate, term_seconds);
        let floating_payment = RateEngine::calculate_payment(notional, twa_rate_bps, term_seconds);

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
    pub fn calculate_pnl_partial(
        swap: @Swap, twa_rate_bps: u256, current_time: u64,
    ) -> SignedValue {
        let notional = *swap.notional;
        let fixed_rate = *swap.fixed_rate_bps;
        let elapsed_seconds = current_time - *swap.start_time;

        // Calculate pro-rated payments based on elapsed time
        let fixed_payment = RateEngine::calculate_payment(notional, fixed_rate, elapsed_seconds);
        let floating_payment = RateEngine::calculate_payment(
            notional, twa_rate_bps, elapsed_seconds,
        );

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
            let buyer_loss = Utils::min(pnl.value, buyer_collateral);
            let buyer_payout = buyer_collateral - buyer_loss;
            let lp_gain = positive(buyer_loss);
            (buyer_payout, lp_gain)
        } else {
            // Buyer wins, LP loses
            let buyer_profit = Utils::min(pnl.value, lp_collateral);
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
        let twa_rate = RateEngine::calculate_twa(rate_index, swap, current_time);

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
                let penalty = Utils::calculate_fee(
                    *swap.initial_required_margin, *params.early_exit_fee_bps,
                );
                let adjusted = apply_early_exit_penalty(base_pnl, penalty);
                (adjusted, penalty, 0_u256)
            },
            SettlementType::Liquidation => {
                // For liquidation, buyer loses everything
                // Liquidator gets bonus, rest goes to pool
                let bonus = Utils::calculate_fee(
                    *swap.initial_required_margin, *params.liquidation_bonus_bps,
                );
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
            buyer_payout,
            lp_delta,
            liquidator_bonus,
            penalty,
            twa_rate_bps: twa_rate,
            pnl: base_pnl,
        }
    }

    /// Update pool state after settlement (unlock collateral, apply delta, decrement count)
    pub fn finalize_pool_state(pool: LpPool, swap: @Swap, lp_delta: SignedValue) -> LpPool {
        // Unlock collateral
        let mut updated = PoolAccounting::unlock_collateral(
            pool, *swap.side, *swap.lp_collateral_locked,
        );

        // Apply LP delta
        updated = PoolAccounting::apply_lp_delta(updated, lp_delta);

        updated
    }
}

#[cfg(test)]
mod tests {
    use crate::helpers::constants::Constants;
    use crate::helpers::signed_value::{negative, positive};
    use crate::types::asce_swap::{LpPool, Swap, SwapSide, SwapStatus};
    use super::SettlementEngine;

    // Helper to create a basic swap for testing
    fn create_test_swap(side: SwapSide, fixed_rate: u256) -> Swap {
        Swap {
            swap_id: 1,
            pair_id: 1,
            side,
            status: SwapStatus::Active,
            notional: 1000000, // 1M notional
            fixed_rate_bps: fixed_rate,
            buyer_collateral: 50000,
            lp_collateral_locked: 50000,
            initial_required_margin: 50000,
            start_time: 0,
            expiration_time: Constants::SECONDS_PER_YEAR, // 1 year term
            start_cumulative_rate: 0,
        }
    }

    // ============ calculate_pnl tests ============

    #[test]
    fn test_calculate_pnl_fixed_side_profit() {
        // Fixed side: pays fixed, receives floating
        // If floating > fixed, buyer profits
        let swap = create_test_swap(SwapSide::Fixed, 500); // 5% fixed rate

        // TWA rate = 7% (700 bps) > fixed 5%
        // Fixed payment = 1M * 5% = 50,000
        // Floating payment = 1M * 7% = 70,000
        // PnL = 70,000 - 50,000 = +20,000 (profit)
        let pnl = SettlementEngine::calculate_pnl(@swap, 700);

        assert(pnl.is_negative == false, 'should be profit');
        assert(pnl.value == 20000, 'profit 20000');
    }

    #[test]
    fn test_calculate_pnl_fixed_side_loss() {
        // Fixed side: pays fixed, receives floating
        // If floating < fixed, buyer loses
        let swap = create_test_swap(SwapSide::Fixed, 700); // 7% fixed rate

        // TWA rate = 5% (500 bps) < fixed 7%
        // Fixed payment = 70,000
        // Floating payment = 50,000
        // PnL = 50,000 - 70,000 = -20,000 (loss)
        let pnl = SettlementEngine::calculate_pnl(@swap, 500);

        assert(pnl.is_negative == true, 'should be loss');
        assert(pnl.value == 20000, 'loss 20000');
    }

    #[test]
    fn test_calculate_pnl_floating_side_profit() {
        // Floating side: pays floating, receives fixed
        // If fixed > floating, buyer profits
        let swap = create_test_swap(SwapSide::Floating, 700); // 7% fixed rate

        // TWA rate = 5% (500 bps)
        // Floating payment = 50,000
        // Fixed payment = 70,000
        // PnL = 70,000 - 50,000 = +20,000 (profit)
        let pnl = SettlementEngine::calculate_pnl(@swap, 500);

        assert(pnl.is_negative == false, 'should be profit');
        assert(pnl.value == 20000, 'profit 20000');
    }

    #[test]
    fn test_calculate_pnl_floating_side_loss() {
        // Floating side: pays floating, receives fixed
        // If floating > fixed, buyer loses
        let swap = create_test_swap(SwapSide::Floating, 500); // 5% fixed rate

        // TWA rate = 7% (700 bps)
        // Floating payment = 70,000
        // Fixed payment = 50,000
        // PnL = 50,000 - 70,000 = -20,000 (loss)
        let pnl = SettlementEngine::calculate_pnl(@swap, 700);

        assert(pnl.is_negative == true, 'should be loss');
        assert(pnl.value == 20000, 'loss 20000');
    }

    #[test]
    fn test_calculate_pnl_breakeven() {
        // Fixed rate = TWA rate = no profit/loss
        let swap = create_test_swap(SwapSide::Fixed, 500);

        let pnl = SettlementEngine::calculate_pnl(@swap, 500);

        assert(pnl.value == 0, 'breakeven');
    }

    // ============ calculate_pnl_partial tests ============

    #[test]
    fn test_calculate_pnl_partial_half_term() {
        let mut swap = create_test_swap(SwapSide::Fixed, 500);
        swap.start_time = 0;
        swap.expiration_time = Constants::SECONDS_PER_YEAR;

        // Exit at 6 months
        let current_time = Constants::SECONDS_PER_YEAR / 2;

        // TWA = 7%, half year
        // Fixed payment = 1M * 5% * 0.5 = 25,000
        // Floating payment = 1M * 7% * 0.5 = 35,000
        // PnL = 35,000 - 25,000 = +10,000
        let pnl = SettlementEngine::calculate_pnl_partial(@swap, 700, current_time);

        assert(pnl.is_negative == false, 'should profit');
        assert(pnl.value == 10000, 'half term profit');
    }


    #[test]
    fn test_settlement_payouts_buyer_profit() {
        let swap = create_test_swap(SwapSide::Fixed, 500);
        let pnl = positive(20000); // Buyer profits 20k

        let (buyer_payout, lp_delta) = SettlementEngine::calculate_settlement_payouts(@swap, pnl);

        // Buyer gets collateral + profit = 50000 + 20000 = 70000
        assert(buyer_payout == 70000, 'buyer gets 70k');
        // LP loses 20000
        assert(lp_delta.is_negative == true, 'lp loses');
        assert(lp_delta.value == 20000, 'lp loses 20k');
    }

    #[test]
    fn test_settlement_payouts_buyer_loss() {
        let swap = create_test_swap(SwapSide::Fixed, 500);
        let pnl = negative(20000); // Buyer loses 20k

        let (buyer_payout, lp_delta) = SettlementEngine::calculate_settlement_payouts(@swap, pnl);

        // Buyer gets collateral - loss = 50000 - 20000 = 30000
        assert(buyer_payout == 30000, 'buyer gets 30k');
        // LP gains 20000
        assert(lp_delta.is_negative == false, 'lp gains');
        assert(lp_delta.value == 20000, 'lp gains 20k');
    }

    #[test]
    fn test_settlement_payouts_buyer_total_loss() {
        let swap = create_test_swap(SwapSide::Fixed, 500);
        // Loss exceeds buyer collateral (60k > 50k)
        let pnl = negative(60000);

        let (buyer_payout, lp_delta) = SettlementEngine::calculate_settlement_payouts(@swap, pnl);

        // Buyer loses everything, capped at collateral
        assert(buyer_payout == 0, 'buyer wiped out');
        // LP gains only buyer's collateral (capped)
        assert(lp_delta.value == 50000, 'lp gains 50k max');
    }

    #[test]
    fn test_settlement_payouts_buyer_profit_capped() {
        let swap = create_test_swap(SwapSide::Fixed, 500);
        // Profit exceeds LP collateral (60k > 50k)
        let pnl = positive(60000);

        let (buyer_payout, lp_delta) = SettlementEngine::calculate_settlement_payouts(@swap, pnl);

        // Buyer profit capped at LP collateral
        // buyer_payout = 50000 + 50000 = 100000
        assert(buyer_payout == 100000, 'buyer gets 100k');
        // LP loses all their collateral
        assert(lp_delta.value == 50000, 'lp loses 50k max');
    }


    #[test]
    fn test_early_exit_penalty_on_profit() {
        // Profit 20000, penalty 5000 -> net profit 15000
        let pnl = positive(20000);
        let adjusted = SettlementEngine::apply_early_exit_penalty(pnl, 5000);

        assert(adjusted.is_negative == false, 'still profit');
        assert(adjusted.value == 15000, 'reduced profit');
    }

    #[test]
    fn test_early_exit_penalty_on_loss() {
        // Loss 20000, penalty 5000 -> loss 25000
        let pnl = negative(20000);
        let adjusted = SettlementEngine::apply_early_exit_penalty(pnl, 5000);

        assert(adjusted.is_negative == true, 'still loss');
        assert(adjusted.value == 25000, 'increased loss');
    }

    #[test]
    fn test_early_exit_penalty_flips_to_loss() {
        // Profit 3000, penalty 5000 -> loss 2000
        let pnl = positive(3000);
        let adjusted = SettlementEngine::apply_early_exit_penalty(pnl, 5000);

        assert(adjusted.is_negative == true, 'flipped to loss');
        assert(adjusted.value == 2000, 'net loss 2000');
    }

    #[test]
    fn test_early_exit_penalty_exact_match() {
        // Profit = penalty -> zero
        let pnl = positive(5000);
        let adjusted = SettlementEngine::apply_early_exit_penalty(pnl, 5000);

        assert(adjusted.is_negative == false, 'zero is positive');
        assert(adjusted.value == 0, 'exactly zero');
    }


    #[test]
    fn test_finalize_pool_state_fixed_swap_lp_wins() {
        let pool = LpPool {
            total_collateral: 1000000,
            locked_for_fixed: 50000,
            locked_for_floating: 25000,
            total_shares: 1000000,
        };
        let swap = create_test_swap(SwapSide::Fixed, 500);
        let lp_delta = positive(20000); // LP gains

        let updated = SettlementEngine::finalize_pool_state(pool, @swap, lp_delta);

        // Fixed collateral unlocked: 50000 - 50000 = 0
        assert(updated.locked_for_fixed == 0, 'fixed unlocked');
        // Floating unchanged
        assert(updated.locked_for_floating == 25000, 'floating unchanged');
        // Total increased by LP gain
        assert(updated.total_collateral == 1020000, 'collateral increased');
    }

    #[test]
    fn test_finalize_pool_state_floating_swap_lp_loses() {
        let pool = LpPool {
            total_collateral: 1000000,
            locked_for_fixed: 25000,
            locked_for_floating: 50000,
            total_shares: 1000000,
        };
        let mut swap = create_test_swap(SwapSide::Floating, 500);
        swap.lp_collateral_locked = 50000;
        let lp_delta = negative(20000); // LP loses

        let updated = SettlementEngine::finalize_pool_state(pool, @swap, lp_delta);

        // Floating unlocked
        assert(updated.locked_for_floating == 0, 'floating unlocked');
        // Fixed unchanged
        assert(updated.locked_for_fixed == 25000, 'fixed unchanged');
        // Total decreased by LP loss
        assert(updated.total_collateral == 980000, 'collateral decreased');
    }
}
