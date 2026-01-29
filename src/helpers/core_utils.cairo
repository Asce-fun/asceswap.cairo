use crate::helpers::constants::Constants;
use crate::helpers::fixed_point::*;
use crate::helpers::utils::max;


//DOMAIN-SPECIFIC CALCULATIONS

/// Calculate interest payment over a term
/// payment = notional × rate_bps × term_seconds / (SECONDS_PER_YEAR × BPS)
pub fn calculate_payment(notional: u256, rate_bps: u256, term_seconds: u64) -> u256 {
    // Intermediate: notional * rate_bps
    let rate_component = mul_div_down(notional, rate_bps, Constants::BPS);
    // Apply term fraction
    mul_div_down(rate_component, term_seconds.into(), Constants::SECONDS_PER_YEAR.into())
}

/// Calculate maximum exposure for a swap position
pub fn calculate_max_exposure(notional: u256, rate_bps: u256, term_seconds: u64) -> u256 {
    calculate_payment(notional, rate_bps, term_seconds)
}

/// Calculate required margin for a swap
/// required = max_exposure × initial_margin_multiplier / BPS
pub fn calculate_required_margin(
    notional: u256, rate_bps: u256, term_seconds: u64, initial_margin_multiplier_bps: u256,
) -> u256 {
    let max_exposure = calculate_max_exposure(notional, rate_bps, term_seconds);
    // Round UP - require more margin for safety
    mul_div_up(max_exposure, initial_margin_multiplier_bps, Constants::BPS)
}

/// Calculate time-adjusted margin requirement
/// As swap approaches expiration, required margin decreases (less time for adverse movement)
pub fn calculate_time_adjusted_margin(
    initial_margin: u256, remaining_seconds: u64, total_term_seconds: u64, min_floor_bps: u256,
) -> u256 {
    if remaining_seconds >= total_term_seconds {
        return initial_margin;
    }

    if total_term_seconds == 0 {
        return initial_margin;
    }

    // time_factor = remaining / total (in BPS for precision)
    let time_factor_bps = mul_div_down(
        remaining_seconds.into(), Constants::BPS, total_term_seconds.into(),
    );

    // Apply floor - never go below minimum
    let effective_factor = max(time_factor_bps, min_floor_bps);

    // adjusted = initial × factor / BPS
    mul_div_down(initial_margin, effective_factor, Constants::BPS)
}

/// Calculate health factor
/// health = remaining_value × BPS / required_margin
pub fn calculate_health_factor(remaining_value: u256, required_margin: u256) -> u256 {
    if required_margin == 0 {
        return Constants::BPS; // 100% if no requirement
    }
    // Round DOWN - health appears lower, triggers liquidation earlier (safer)
    mul_div_down(remaining_value, Constants::BPS, required_margin)
}

/// Calculate LP shares to mint (round DOWN - user gets less)
pub fn calculate_shares_to_mint(deposit: u256, total_shares: u256, total_collateral: u256) -> u256 {
    if total_shares == 0 || total_collateral == 0 {
        return deposit;
    }
    mul_div_down(deposit, total_shares, total_collateral)
}

/// Calculate collateral for LP withdrawal (round DOWN - user gets less)
pub fn calculate_withdrawal_amount(
    shares: u256, total_shares: u256, total_collateral: u256,
) -> u256 {
    if total_shares == 0 {
        return 0;
    }
    mul_div_down(shares, total_collateral, total_shares)
}

/// Calculate fee amount (round UP - protocol gets more)
pub fn calculate_fee(amount: u256, fee_bps: u256) -> u256 {
    mul_div_up(amount, fee_bps, Constants::BPS)
}
