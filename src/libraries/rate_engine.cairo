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

        if target_time == last_update {
            return base_cumulative;
        }

        if target_time < last_update {
            // Backward interpolation: subtract excess post-target accumulation
            let excess: u256 = last_rate * (last_update - target_time).into();
            if base_cumulative >= excess {
                return base_cumulative - excess;
            }
            return 0;
        }

        // Forward extrapolation
        let time_delta: u256 = (target_time - last_update).into();
        base_cumulative + (last_rate * time_delta)
    }


    /// Calculate TWA rate for a swap (capped at expiration)
    pub fn calculate_twa(rate_index: @RateIndex, swap: @Swap, current_time: u64) -> u256 {
        let start_cumulative = *swap.start_cumulative_rate;
        let start_time = *swap.start_time;
        let expiration_time = *swap.expiration_time;

        // Cap at expiration - never include post-expiration rates
        //@audit - why do we need the min_u64 here? shouldn't effective_end_time = expiration_time always?
        let effective_end_time = min_u64(current_time, expiration_time);

        // Duration for TWA calculation
        //@audit: I beleive this condition will never be reached
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

    /// Apply the three-tier piecewise linear curve.
    /// Maps ratio (BPS) to spread (BPS) with accelerating slopes.
    fn apply_demand_curve(ratio: u256) -> u256 {
        if ratio <= Constants::DEMAND_SPREAD_TIER1_END_RATIO {
            // Tier 1: 0→2000 ratio maps to 0→100 spread
            if ratio == 0 {
                return 0;
            }
            mul_div_down(
                ratio,
                Constants::DEMAND_SPREAD_TIER1_END_SPREAD,
                Constants::DEMAND_SPREAD_TIER1_END_RATIO,
            )
        } else if ratio <= Constants::DEMAND_SPREAD_TIER2_END_RATIO {
            // Tier 2: 2000→5000 ratio maps to 100→500 spread
            let excess = ratio - Constants::DEMAND_SPREAD_TIER1_END_RATIO;
            let range = Constants::DEMAND_SPREAD_TIER2_END_RATIO
                - Constants::DEMAND_SPREAD_TIER1_END_RATIO;
            let spread_range = Constants::DEMAND_SPREAD_TIER2_END_SPREAD
                - Constants::DEMAND_SPREAD_TIER1_END_SPREAD;
            Constants::DEMAND_SPREAD_TIER1_END_SPREAD + mul_div_down(excess, spread_range, range)
        } else if ratio <= Constants::BPS {
            // Tier 3: 5000→10000 ratio maps to 500→3000 spread
            let excess = ratio - Constants::DEMAND_SPREAD_TIER2_END_RATIO;
            let range = Constants::BPS - Constants::DEMAND_SPREAD_TIER2_END_RATIO;
            let spread_range = Constants::DEMAND_SPREAD_MAX_SPREAD
                - Constants::DEMAND_SPREAD_TIER2_END_SPREAD;
            Constants::DEMAND_SPREAD_TIER2_END_SPREAD + mul_div_down(excess, spread_range, range)
        } else {
            // Cap: ratio > 100% → max spread
            Constants::DEMAND_SPREAD_MAX_SPREAD
        }
    }

    /// Calculate the demand spread for a given side.
    /// Only the crowded side pays a demand spread. The underweight side pays zero.
    /// The spread is driven by directional imbalance relative to available liquidity.
    pub fn calculate_demand_spread(pool: @LpPool, params: @MarketParams, side: SwapSide) -> u256 {
        let locked_fixed = *pool.locked_for_fixed;
        let locked_floating = *pool.locked_for_floating;
        let total_collateral = *pool.total_collateral;

        // No locks or no collateral → no demand spread
        if total_collateral == 0 || (locked_fixed == 0 && locked_floating == 0) {
            return 0;
        }

        // Determine if this side is crowded
        let is_crowded = match side {
            SwapSide::Fixed => locked_fixed > locked_floating,
            SwapSide::Floating => locked_floating > locked_fixed,
        };

        // Underweight or balanced side → no demand spread
        if !is_crowded {
            return 0;
        }

        // Calculate directional imbalance (in collateral units)
        let imbalance = if locked_fixed > locked_floating {
            locked_fixed - locked_floating
        } else {
            locked_floating - locked_fixed
        };

        // Available liquidity (free LP capital)
        let available = total_collateral - locked_fixed - locked_floating;

        // Edge case: no available liquidity → max spread
        if available == 0 {
            return Constants::DEMAND_SPREAD_MAX_SPREAD;
        }

        // ratio = imbalance × BPS / (available × demand_spread_factor / BPS)
        //       = imbalance × BPS × BPS / (available × demand_spread_factor)
        let capacity = available * *params.demand_spread_factor / Constants::BPS;
        if capacity == 0 {
            return Constants::DEMAND_SPREAD_MAX_SPREAD;
        }
        let ratio = mul_div_down(imbalance, Constants::BPS, capacity);

        // Apply piecewise curve
        apply_demand_curve(ratio)
    }

    /// Calculate swap rate with averaged demand spread.
    /// Uses a two-pass approach: computes spread before and after the trade's estimated
    /// impact on the pool, then averages them so trades partially internalize their own
    /// impact.
    /// Returns (final_rate, averaged_demand_spread, is_crowded_side)
    pub fn calculate_swap_rate(
        pool: @LpPool, params: @MarketParams, side: SwapSide, oracle_rate: u256, notional: u256,
    ) -> (u256, u256, bool) {
        // Pre-trade spread 
        let spread_before = calculate_demand_spread(pool, params, side);

        // Simulate post-trade state
        // Estimate LP collateral that would be locked using the pre-trade spread
        let tentative_rate = oracle_rate + spread_before + *params.base_fee_spread_bps;
        let tentative_exposure = calculate_payment(
            notional, tentative_rate, *params.max_swap_term_seconds,
        );
        let tentative_margin = mul_div_up(
            tentative_exposure, *params.initial_margin_multiplier_bps, Constants::BPS,
        );

        // Construct simulated pool with the trade's estimated impact
        let mut simulated_pool = *pool;
        let available = simulated_pool.total_collateral
            - simulated_pool.locked_for_fixed
            - simulated_pool.locked_for_floating;

        // Cap the simulated margin to available liquidity (can't lock more than exists)
        let capped_margin = if tentative_margin > available {
            available
        } else {
            tentative_margin
        };

        match side {
            SwapSide::Fixed => { simulated_pool.locked_for_fixed += capped_margin; },
            SwapSide::Floating => { simulated_pool.locked_for_floating += capped_margin; },
        }

        // Post-trade spread
        let spread_after = calculate_demand_spread(@simulated_pool, params, side);

        //Average the two spreads
        let final_demand_spread = (spread_before + spread_after) / 2;

        // Determine if this side is crowded (pre-trade state for display)
        let is_crowded = match side {
            SwapSide::Fixed => *pool.locked_for_fixed > *pool.locked_for_floating,
            SwapSide::Floating => *pool.locked_for_floating > *pool.locked_for_fixed,
        };

        let final_rate = oracle_rate + final_demand_spread + *params.base_fee_spread_bps;

        (final_rate, final_demand_spread, is_crowded)
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
            initial_margin_multiplier_bps: 12000,
            min_margin_floor_bps: 2000,
            min_swap_term_seconds: 86400, // 1 day
            max_swap_term_seconds: 2592000, // 30 days
            min_hold_period_seconds: 3600,
            swap_fee_bps: 50,
            max_early_exit_fee_bps: 300,
            min_early_exit_fee_bps: 25,
            base_fee_spread_bps: 10, // 0.1% base LP edge
            demand_spread_factor: 10000, // 1x scaling (neutral)
            max_total_utilization_bps: 9000, // 90% combined cap
            min_notional_per_swap: 1000,
            max_oracle_staleness_seconds: 3600,
            max_rate_change_per_update_bps: 1000, // 10% max change
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
    fn test_calculate_cumulative_at_backward_interpolation() {
        let rate_index = RateIndex {
            last_update_time: 1100,
            last_rate_bps: 500,
            cumulative_rate_time: 100000,
            last_valid_rate_bps: 500,
        };
        // excess = 500 * (1100 - 1050) = 25000
        // result = 100000 - 25000 = 75000
        let cumulative = RateEngine::calculate_cumulative_at(@rate_index, 1050);
        assert(cumulative == 75000, 'backward interpolation');
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
        let notional: u256 = 100000; // Small notional

        // Balanced pool = no demand spread, just add base fee spread
        let (final_rate, demand_spread, _is_crowded) = RateEngine::calculate_swap_rate(
            @pool, @params, SwapSide::Fixed, oracle_rate, notional,
        );

        // Balanced = 0 demand spread, final = oracle + base_fee_spread
        assert(demand_spread == 0, 'no demand spread balanced');
        assert(final_rate == 510, 'oracle + base spread');
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
        let notional: u256 = 100000;

        let (final_rate, demand_spread, _) = RateEngine::calculate_swap_rate(
            @pool, @params, SwapSide::Fixed, oracle_rate, notional,
        );

        // Empty pool = 0 demand spread
        assert(demand_spread == 0, 'empty pool no demand spread');
        assert(final_rate == 510, 'empty pool rate');
    }

    #[test]
    fn test_calculate_swap_rate_fixed_crowded() {
        let pool = fixed_heavy_pool(); // More fixed than floating
        let params = default_market_params();
        let oracle_rate: u256 = 500;
        let notional: u256 = 100000;

        // Fixed side is crowded — should pay demand spread
        let (fixed_rate, fixed_spread, fixed_crowded) = RateEngine::calculate_swap_rate(
            @pool, @params, SwapSide::Fixed, oracle_rate, notional,
        );

        // Floating side is underweight — no demand spread
        let (floating_rate, floating_spread, floating_crowded) = RateEngine::calculate_swap_rate(
            @pool, @params, SwapSide::Floating, oracle_rate, notional,
        );

        assert(fixed_crowded == true, 'fixed is crowded');
        assert(floating_crowded == false, 'floating not crowded');
        assert(fixed_spread > 0, 'fixed pays demand spread');
        assert(floating_spread == 0, 'floating no demand spread');
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

    // ============ Demand Spread Tests ============

    #[test]
    fn test_demand_spread_empty_pool() {
        let pool = LpPool {
            total_collateral: 1000000,
            locked_for_fixed: 0,
            locked_for_floating: 0,
            total_shares: 1000000,
        };
        let params = default_market_params();

        // No locks → no demand spread for either side
        let spread_fixed = RateEngine::calculate_demand_spread(@pool, @params, SwapSide::Fixed);
        let spread_float = RateEngine::calculate_demand_spread(@pool, @params, SwapSide::Floating);
        assert(spread_fixed == 0, 'empty: no fixed spread');
        assert(spread_float == 0, 'empty: no float spread');
    }

    #[test]
    fn test_demand_spread_balanced_pool() {
        let pool = balanced_pool(); // 100k fixed, 100k floating, 1M total
        let params = default_market_params();

        // Balanced = no imbalance → no demand spread for either side
        let spread_fixed = RateEngine::calculate_demand_spread(@pool, @params, SwapSide::Fixed);
        let spread_float = RateEngine::calculate_demand_spread(@pool, @params, SwapSide::Floating);
        assert(spread_fixed == 0, 'balanced: no fixed spread');
        assert(spread_float == 0, 'balanced: no float spread');
    }

    #[test]
    fn test_demand_spread_crowded_side_only() {
        let pool = fixed_heavy_pool(); // 200k fixed, 50k floating, 1M total
        let params = default_market_params();

        // Fixed is crowded → pays demand spread
        let spread_fixed = RateEngine::calculate_demand_spread(@pool, @params, SwapSide::Fixed);
        // Floating is underweight → no demand spread
        let spread_float = RateEngine::calculate_demand_spread(@pool, @params, SwapSide::Floating);

        assert(spread_fixed > 0, 'crowded side pays');
        assert(spread_float == 0, 'underweight side free');
    }

    #[test]
    fn test_demand_spread_tier1() {
        // Small imbalance in tier 1 (ratio < 20%)
        // imbalance = 50k, available = 750k, capacity = 750k (factor=10000=1x)
        // ratio = 50000 * 10000 / 750000 = 666 bps (6.66%)
        // Tier 1: ratio 666 → spread = 666 * 100 / 2000 = 33 bps
        let pool = fixed_heavy_pool(); // 200k fixed, 50k floating, 1M total
        let params = default_market_params();

        let spread = RateEngine::calculate_demand_spread(@pool, @params, SwapSide::Fixed);

        // imbalance = 150000, available = 750000, capacity = 750000
        // ratio = 150000 * 10000 / 750000 = 2000 bps (exactly tier1 end)
        // spread = 2000 * 100 / 2000 = 100 bps
        assert(spread == 100, 'tier1 end = 100bps');
    }

    #[test]
    fn test_demand_spread_increases_with_imbalance() {
        let params = default_market_params();

        // Low imbalance: 120k fixed, 100k floating, 1M total
        let pool_low = LpPool {
            total_collateral: 1000000,
            locked_for_fixed: 120000,
            locked_for_floating: 100000,
            total_shares: 1000000,
        };

        // High imbalance: 300k fixed, 50k floating, 1M total
        let pool_high = LpPool {
            total_collateral: 1000000,
            locked_for_fixed: 300000,
            locked_for_floating: 50000,
            total_shares: 1000000,
        };

        let spread_low = RateEngine::calculate_demand_spread(@pool_low, @params, SwapSide::Fixed);
        let spread_high = RateEngine::calculate_demand_spread(@pool_high, @params, SwapSide::Fixed);

        assert(spread_high > spread_low, 'higher imbalance = more spread');
    }

    #[test]
    fn test_demand_spread_no_available_liquidity() {
        // All liquidity locked → max spread
        let pool = LpPool {
            total_collateral: 1000000,
            locked_for_fixed: 600000,
            locked_for_floating: 400000,
            total_shares: 1000000,
        };
        let params = default_market_params();

        let spread = RateEngine::calculate_demand_spread(@pool, @params, SwapSide::Fixed);
        assert(spread == Constants::DEMAND_SPREAD_MAX_SPREAD, 'no liquidity = max spread');
    }

    #[test]
    fn test_demand_spread_factor_sensitivity() {
        let pool = fixed_heavy_pool(); // 200k fixed, 50k floating, 1M total

        // Low factor (5000 = 0.5x) → more sensitive to imbalance
        let mut params_sensitive = default_market_params();
        params_sensitive.demand_spread_factor = 5000;

        // High factor (20000 = 2x) → more tolerant of imbalance
        let mut params_tolerant = default_market_params();
        params_tolerant.demand_spread_factor = 20000;

        let spread_sensitive = RateEngine::calculate_demand_spread(
            @pool, @params_sensitive, SwapSide::Fixed,
        );
        let spread_tolerant = RateEngine::calculate_demand_spread(
            @pool, @params_tolerant, SwapSide::Fixed,
        );

        assert(spread_sensitive > spread_tolerant, 'low factor = higher spread');
    }

    // ============ Average Pricing Tests ============

    #[test]
    fn test_average_pricing_small_trade_minimal_impact() {
        // Small notional relative to pool → spread_before ≈ spread_after → average ≈
        // pre-trade
        let pool = fixed_heavy_pool(); // 200k fixed, 50k floating, 1M total
        let params = default_market_params();
        let oracle_rate: u256 = 500;

        // Small trade
        let (_rate_small, spread_small, _) = RateEngine::calculate_swap_rate(
            @pool, @params, SwapSide::Fixed, oracle_rate, 1000 // tiny notional
        );

        // The rate should be close to oracle + pre-trade spread + base
        let pre_trade_spread = RateEngine::calculate_demand_spread(@pool, @params, SwapSide::Fixed);

        // Small trades should have averaged spread very close to pre-trade spread
        assert(spread_small <= pre_trade_spread + 1, 'small trade: ~pre spread');
    }

    #[test]
    fn test_average_pricing_large_trade_higher_spread() {
        // Large notional → spread_after > spread_before → average > pre-trade
        let pool = fixed_heavy_pool();
        let params = default_market_params();
        let oracle_rate: u256 = 500;

        let (rate_small, spread_small, _) = RateEngine::calculate_swap_rate(
            @pool, @params, SwapSide::Fixed, oracle_rate, 1000,
        );
        let (rate_large, spread_large, _) = RateEngine::calculate_swap_rate(
            @pool, @params, SwapSide::Fixed, oracle_rate, 500000,
        );

        // Larger trade should pay more spread due to average pricing
        assert(spread_large >= spread_small, 'large trade >= small spread');
        assert(rate_large >= rate_small, 'large trade >= small rate');
    }

    #[test]
    fn test_underweight_side_pays_only_base() {
        // Floating is underweight in fixed_heavy_pool
        let pool = fixed_heavy_pool();
        let params = default_market_params();
        let oracle_rate: u256 = 500;

        let (rate, _demand_spread, is_crowded) = RateEngine::calculate_swap_rate(
            @pool, @params, SwapSide::Floating, oracle_rate, 100000,
        );

        // Underweight side: no demand spread, only base
        assert(is_crowded == false, 'floating not crowded');
        // The demand spread should be 0 or very small (post-trade might create small imbalance)
        // final_rate = oracle + 0 + base = 510
        assert(rate >= 510, 'at least oracle + base');
    }

    #[test]
    fn test_zero_collateral_pool() {
        let pool = LpPool {
            total_collateral: 0, locked_for_fixed: 0, locked_for_floating: 0, total_shares: 0,
        };
        let params = default_market_params();

        let spread = RateEngine::calculate_demand_spread(@pool, @params, SwapSide::Fixed);
        assert(spread == 0, 'zero collateral = no spread');
    }
}
