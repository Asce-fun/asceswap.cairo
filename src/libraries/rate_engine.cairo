// Rate Engine Library
// Pure functions for rate index updates, TWA calculations, and swap rate calculations

pub mod RateEngine {
    use crate::helpers::constants::Constants;
    use crate::helpers::fixed_point::{div_down, mul_div_down, mul_div_up};
    use crate::helpers::utils::min_u64;
    use crate::types::asce_swap::{LpPool, MarketParams, RateIndex, Swap, SwapSide};

    /// Calculate interest payment over a term
    /// payment = notional × rate_bps × term_seconds / (SECONDS_PER_YEAR × BPS)
    pub fn calculate_payment(notional: u256, rate_bps: u256, term_seconds: u64) -> u256 {
        let numerator = notional * rate_bps * term_seconds.into();
        let denominator = Constants::BPS * Constants::SECONDS_PER_YEAR.into();
        numerator / denominator
    }


    /// Update rate index with new oracle value
    /// Returns (updated_index, clamped_rate)
    pub fn update_rate_index(
        rate_index: RateIndex, raw_rate: u256, current_time: u64, params: @MarketParams,
    ) -> (RateIndex, u256) {
        let mut updated = rate_index;

        // If first update, just initialize
        if updated.last_update_time == 0 {
            updated.last_update_time = current_time;
            updated.last_rate_bps = raw_rate;
            updated.cumulative_rate_time = 0;
            updated.last_valid_rate_bps = raw_rate;
            return (updated, raw_rate);
        }

        let time_delta: u256 = (current_time - updated.last_update_time).into();

        // No time passed, return current rate
        if time_delta == 0 {
            return (updated, updated.last_rate_bps);
        }

        // Accumulate: previous_rate * time_elapsed
        updated.cumulative_rate_time += updated.last_rate_bps * time_delta;

        // Apply rate change limit
        let last_valid = updated.last_valid_rate_bps;
        let max_change = mul_div_up(
            last_valid, *params.max_rate_change_per_update_bps, Constants::BPS,
        );

        let clamped_rate = if raw_rate > last_valid + max_change {
            last_valid + max_change
        } else if last_valid > max_change && raw_rate < last_valid - max_change {
            last_valid - max_change
        } else {
            raw_rate
        };

        // Update state
        updated.last_rate_bps = clamped_rate;
        updated.last_update_time = current_time;
        updated.last_valid_rate_bps = clamped_rate;

        (updated, clamped_rate)
    }

    /// Calculate cumulative rate at a specific timestamp
    pub fn calculate_cumulative_at(rate_index: @RateIndex, target_time: u64) -> u256 {
        let last_update = *rate_index.last_update_time;
        let last_rate = *rate_index.last_rate_bps;
        let base_cumulative = *rate_index.cumulative_rate_time;

        if target_time <= last_update {
            return base_cumulative;
        }

        // Extrapolate from last update to target time
        let time_delta: u256 = (target_time - last_update).into();
        base_cumulative + (last_rate * time_delta)
    }


    /// Calculate TWA rate for a swap (capped at expiration)
    pub fn calculate_twa(rate_index: @RateIndex, swap: @Swap, current_time: u64) -> u256 {
        let start_cumulative = *swap.start_cumulative_rate;
        let start_time = *swap.start_time;
        let expiration_time = *swap.expiration_time;

        // Cap at expiration - never include post-expiration rates
        let effective_end_time = min_u64(current_time, expiration_time);

        // Duration for TWA calculation
        if effective_end_time <= start_time {
            return *rate_index.last_rate_bps;
        }

        let duration: u256 = (effective_end_time - start_time).into();

        // Get cumulative at effective end time
        let end_cumulative = calculate_cumulative_at(rate_index, effective_end_time);

        // TWA = (end_cumulative - start_cumulative) / duration
        if end_cumulative >= start_cumulative {
            div_down(end_cumulative - start_cumulative, duration)
        } else {
            0
        }
    }

    /// Calculate swap rate with imbalance adjustment
    /// Returns (final_rate, adjustment_bps, is_positive)
    pub fn calculate_swap_rate(
        pool: @LpPool, params: @MarketParams, side: SwapSide, oracle_rate: u256,
    ) -> (u256, u256, bool) {
        let locked_fixed = *pool.locked_for_fixed;
        let locked_floating = *pool.locked_for_floating;
        let total_locked = locked_fixed + locked_floating;

        // Calculate adjustment
        let (adjustment_bps, is_positive) = if total_locked == 0 {
            (0_u256, true)
        } else {
            let imbalance_bps = if locked_fixed > locked_floating {
                mul_div_down(locked_fixed - locked_floating, Constants::BPS, total_locked)
            } else {
                mul_div_down(locked_floating - locked_fixed, Constants::BPS, total_locked)
            };

            let raw_adjustment = mul_div_down(
                imbalance_bps, *params.max_imbalance_adjustment_bps, Constants::BPS,
            );

            // Fixed crowded: Fixed pays more (positive), Floating pays less (negative)
            let is_fixed_crowded = locked_fixed > locked_floating;

            match side {
                SwapSide::Fixed => (raw_adjustment, is_fixed_crowded),
                SwapSide::Floating => (raw_adjustment, !is_fixed_crowded),
            }
        };

        // Apply adjustment
        let adjusted_rate = if is_positive {
            oracle_rate + adjustment_bps
        } else {
            if oracle_rate > adjustment_bps {
                oracle_rate - adjustment_bps
            } else {
                0
            }
        };

        // Add fee spread
        let final_rate = adjusted_rate + *params.fee_spread_bps;

        (final_rate, adjustment_bps, is_positive)
    }
}

#[cfg(test)]
mod tests {
    use crate::helpers::constants::Constants;
    use crate::types::asce_swap::{LpPool, MarketParams, RateIndex, SwapSide};
    use super::RateEngine;

    // Helper to create default MarketParams for testing
    fn default_market_params() -> MarketParams {
        MarketParams {
            liquidation_threshold_bps: 8000,
            initial_margin_multiplier_bps: 12000,
            min_margin_floor_bps: 2000,
            min_swap_term_seconds: 2592000, // 30 days
            max_swap_term_seconds: 2592000, // 30 days
            min_hold_period_seconds: 3600,
            swap_fee_bps: 50,
            early_exit_fee_bps: 100,
            liquidation_bonus_bps: 500,
            fee_spread_bps: 10, // 0.1%
            max_imbalance_adjustment_bps: 500, // max 5% adjustment
            max_utilization_bps: 8000,
            min_notional: 1000,
            max_notional_per_swap: 1000000000,
            max_oracle_staleness_seconds: 3600,
            max_rate_change_per_update_bps: 1000, // 10% max change
            min_rate_bps: 0,
            max_rate_bps: 100000,
            is_lp_permissioned: false,
        }
    }

    // Helper to create a balanced pool
    fn balanced_pool() -> LpPool {
        LpPool {
            total_collateral: 1000000,
            locked_for_fixed: 100000,
            locked_for_floating: 100000,
            total_shares: 1000000,
        }
    }

    // Helper to create an imbalanced pool (more fixed)
    fn fixed_heavy_pool() -> LpPool {
        LpPool {
            total_collateral: 1000000,
            locked_for_fixed: 200000,
            locked_for_floating: 50000,
            total_shares: 1000000,
        }
    }


    #[test]
    fn test_calculate_payment_basic() {
        // 1,000,000 notional at 5% (500 bps) for 1 year
        // Expected: 1,000,000 * 0.05 = 50,000
        let payment = RateEngine::calculate_payment(1000000, 500, Constants::SECONDS_PER_YEAR);
        assert(payment == 50000, 'payment 5% annual');
    }

    #[test]
    fn test_calculate_payment_half_year() {
        // 1,000,000 notional at 10% (1000 bps) for 6 months
        // Expected: 1,000,000 * 0.10 * 0.5 = 50,000
        let half_year: u64 = Constants::SECONDS_PER_YEAR / 2;
        let payment = RateEngine::calculate_payment(1000000, 1000, half_year);
        assert(payment == 50000, 'payment 10% half year');
    }

    #[test]
    fn test_calculate_payment_30_days() {
        // 1,000,000 notional at 10% (1000 bps) for 30 days
        let thirty_days: u64 = 2592000;
        let payment = RateEngine::calculate_payment(1000000, 1000, thirty_days);
        // Expected: 1,000,000 * 0.10 * (30/365) ≈ 8,219
        assert(payment > 8000 && payment < 8500, 'payment 30 days');
    }

    #[test]
    fn test_calculate_payment_zero_rate() {
        let payment = RateEngine::calculate_payment(1000000, 0, Constants::SECONDS_PER_YEAR);
        assert(payment == 0, 'zero rate = zero payment');
    }

    #[test]
    fn test_calculate_payment_zero_term() {
        let payment = RateEngine::calculate_payment(1000000, 500, 0);
        assert(payment == 0, 'zero term = zero payment');
    }

    #[test]
    fn test_calculate_cumulative_at_no_time_passed() {
        let rate_index = RateIndex {
            last_update_time: 1000,
            last_rate_bps: 500,
            cumulative_rate_time: 50000,
            last_valid_rate_bps: 500,
        };
        // Target time before or at last update - return base cumulative
        let cumulative = RateEngine::calculate_cumulative_at(@rate_index, 1000);
        assert(cumulative == 50000, 'no time passed');
    }

    #[test]
    fn test_calculate_cumulative_at_extrapolate() {
        let rate_index = RateIndex {
            last_update_time: 1000,
            last_rate_bps: 500,
            cumulative_rate_time: 50000,
            last_valid_rate_bps: 500,
        };
        // Target 100 seconds later: 50000 + (500 * 100) = 100000
        let cumulative = RateEngine::calculate_cumulative_at(@rate_index, 1100);
        assert(cumulative == 100000, 'extrapolated cumulative');
    }

    #[test]
    fn test_calculate_swap_rate_balanced_pool() {
        let pool = balanced_pool();
        let params = default_market_params();
        let oracle_rate: u256 = 500; // 5%

        // Balanced pool = no adjustment, just add fee spread
        let (final_rate, adjustment, _is_positive) = RateEngine::calculate_swap_rate(
            @pool, @params, SwapSide::Fixed, oracle_rate,
        );

        // No imbalance = 0 adjustment, final = oracle + fee_spread
        assert(adjustment == 0, 'no adjustment balanced');
        assert(final_rate == 510, 'oracle + fee spread');
    }

    #[test]
    fn test_calculate_swap_rate_empty_pool() {
        let pool = LpPool {
            total_collateral: 1000000,
            locked_for_fixed: 0,
            locked_for_floating: 0,
            total_shares: 1000000,
        };
        let params = default_market_params();
        let oracle_rate: u256 = 500;

        let (final_rate, adjustment, _) = RateEngine::calculate_swap_rate(
            @pool, @params, SwapSide::Fixed, oracle_rate,
        );

        assert(adjustment == 0, 'empty pool no adjustment');
        assert(final_rate == 510, 'empty pool rate');
    }

    #[test]
    fn test_calculate_swap_rate_fixed_crowded() {
        let pool = fixed_heavy_pool(); // More fixed than floating
        let params = default_market_params();
        let oracle_rate: u256 = 500;

        // Fixed side should pay MORE (positive adjustment)
        let (fixed_rate, _, fixed_positive) = RateEngine::calculate_swap_rate(
            @pool, @params, SwapSide::Fixed, oracle_rate,
        );

        // Floating side should pay LESS (negative adjustment)
        let (floating_rate, _, floating_positive) = RateEngine::calculate_swap_rate(
            @pool, @params, SwapSide::Floating, oracle_rate,
        );

        assert(fixed_positive == true, 'fixed pays more');
        assert(floating_positive == false, 'floating pays less');
        assert(fixed_rate > floating_rate, 'fixed > floating when crowded');
    }

    // ============ update_rate_index tests ============

    #[test]
    fn test_update_rate_index_first_update() {
        let rate_index = RateIndex {
            last_update_time: 0, last_rate_bps: 0, cumulative_rate_time: 0, last_valid_rate_bps: 0,
        };
        let params = default_market_params();

        let (updated, clamped_rate) = RateEngine::update_rate_index(rate_index, 500, 1000, @params);

        assert(updated.last_update_time == 1000, 'first update time');
        assert(updated.last_rate_bps == 500, 'first update rate');
        assert(updated.cumulative_rate_time == 0, 'first cumulative 0');
        assert(clamped_rate == 500, 'first rate not clamped');
    }

    #[test]
    fn test_update_rate_index_accumulates() {
        let rate_index = RateIndex {
            last_update_time: 1000,
            last_rate_bps: 500,
            cumulative_rate_time: 0,
            last_valid_rate_bps: 500,
        };
        let params = default_market_params();

        // Update 100 seconds later with same rate
        let (updated, _) = RateEngine::update_rate_index(rate_index, 500, 1100, @params);

        // Cumulative should be: 500 * 100 = 50000
        assert(updated.cumulative_rate_time == 50000, 'cumulative accumulated');
        assert(updated.last_update_time == 1100, 'time updated');
    }

    #[test]
    fn test_update_rate_index_clamps_large_increase() {
        let rate_index = RateIndex {
            last_update_time: 1000,
            last_rate_bps: 500,
            cumulative_rate_time: 0,
            last_valid_rate_bps: 500,
        };
        let params = default_market_params(); // max_rate_change = 10%

        // Try to jump from 500 to 1000 (100% increase) - should be clamped
        let (updated, clamped_rate) = RateEngine::update_rate_index(
            rate_index, 1000, 1100, @params,
        );

        // Max change = 500 * 10% = 50, so max allowed = 550
        assert(clamped_rate == 550, 'rate clamped up');
        assert(updated.last_rate_bps == 550, 'stored clamped rate');
    }

    #[test]
    fn test_update_rate_index_no_time_passed() {
        let rate_index = RateIndex {
            last_update_time: 1000,
            last_rate_bps: 500,
            cumulative_rate_time: 0,
            last_valid_rate_bps: 500,
        };
        let params = default_market_params();

        // Same timestamp - should return existing rate
        let (updated, clamped_rate) = RateEngine::update_rate_index(rate_index, 600, 1000, @params);

        assert(clamped_rate == 500, 'no change same time');
        assert(updated.cumulative_rate_time == 0, 'no accumulation');
    }
}
