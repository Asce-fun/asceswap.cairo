// Rate Engine Library
// Pure functions for rate index updates, TWA calculations, and swap rate calculations

use crate::helpers::constants::Constants;
use crate::helpers::fixed_point::{div_down, mul_div_down, mul_div_up};
use crate::helpers::utils::min_u64;
use crate::types::asce_swap::{LpPool, MarketParams, RateIndex, Swap, SwapSide};

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
    let max_change = mul_div_up(last_valid, *params.max_rate_change_per_update_bps, Constants::BPS);

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
