// Health Calculator Library
// Pure functions for health factor calculation, liquidation eligibility, and margin adjustments

use crate::helpers::core_utils::{calculate_health_factor, calculate_time_adjusted_margin};
use crate::helpers::signed_value::apply_pnl;
use crate::types::asce_swap::{HealthStatus, MarketParams, RateIndex, SignedValue, Swap};

/// Calculate full health status for a swap
pub fn calculate_health_status(
    swap: @Swap,
    rate_index: @RateIndex,
    params: @MarketParams,
    current_time: u64,
    current_pnl: SignedValue,
) -> HealthStatus {
    // Calculate remaining value
    let buyer_remaining = apply_pnl(*swap.buyer_collateral, current_pnl);

    // Calculate time-adjusted margin requirement
    let remaining_time = if *swap.expiration_time > current_time {
        *swap.expiration_time - current_time
    } else {
        0
    };
    let total_term = *swap.expiration_time - *swap.start_time;

    let adjusted_margin = calculate_time_adjusted_margin(
        *swap.initial_required_margin, remaining_time, total_term, *params.min_margin_floor_bps,
    );

    // Calculate health factor
    let health_factor = calculate_health_factor(buyer_remaining, adjusted_margin);

    // Check if liquidatable
    let is_liquidatable = health_factor < *params.liquidation_threshold_bps;

    HealthStatus {
        current_pnl,
        buyer_remaining_value: buyer_remaining,
        required_margin: adjusted_margin,
        health_factor_bps: health_factor,
        is_liquidatable,
        time_to_expiry_seconds: remaining_time,
    }
}

/// Check if position is liquidatable
pub fn is_liquidatable(health_factor_bps: u256, threshold_bps: u256) -> bool {
    health_factor_bps < threshold_bps
}

/// Calculate time-adjusted margin requirement
pub fn calculate_adjusted_margin(
    initial_margin: u256, remaining_time: u64, total_term: u64, min_floor_bps: u256,
) -> u256 {
    calculate_time_adjusted_margin(initial_margin, remaining_time, total_term, min_floor_bps)
}
