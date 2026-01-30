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

#[cfg(tests)]
pub mod tests {
    #[test]
    fn test_calculate_payment_basic() {
        // 1000 notional, 500 bps (5%), 1 year = 50
        let payment = calculate_payment(1000, 500, 31536000);
        assert(payment == 50, 'payment 50');
    }

    #[test]
    fn test_calculate_payment_half_year() {
        // 1000 notional, 500 bps (5%), 6 months = 25
        let payment = calculate_payment(1000, 500, 15768000);
        assert(payment == 25, 'payment 25');
    }

    #[test]
    fn test_calculate_payment_30_days() {
        // 1000000 notional, 500 bps (5%), 30 days
        let payment = calculate_payment(1000000, 500, 2592000);
        assert(payment == 4109, 'payment 30 days');
    }

    #[test]
    fn test_calculate_payment_zero_rate() {
        let payment = calculate_payment(1000000, 0, 2592000);
        assert(payment == 0, 'zero rate');
    }

    #[test]
    fn test_calculate_required_margin() {
        let max_exposure = calculate_max_exposure(1000000, 500, 2592000);
        let margin = calculate_required_margin(1000000, 500, 2592000, 12000);
        let expected = mul_div_up(max_exposure, 12000, 10000);
        assert(margin == expected, 'margin calc');
    }

    #[test]
    fn test_time_adjusted_margin_full() {
        let margin = calculate_time_adjusted_margin(1000, 2592000, 2592000, 2000);
        assert(margin == 1000, 'full margin');
    }

    #[test]
    fn test_time_adjusted_margin_half() {
        let margin = calculate_time_adjusted_margin(1000, 1296000, 2592000, 0);
        assert(margin == 500, 'half margin');
    }

    #[test]
    fn test_time_adjusted_margin_floor() {
        let margin = calculate_time_adjusted_margin(1000, 259200, 2592000, 2000);
        assert(margin == 200, 'floor applies');
    }

    #[test]
    fn test_health_factor_healthy() {
        // remaining=1000, required=800 -> health = 12500 (125%)
        let health = calculate_health_factor(1000, 800);
        assert(health == 12500, 'health 125%');
    }

    #[test]
    fn test_health_factor_at_threshold() {
        // remaining=800, required=1000 -> health = 8000 (80%)
        let health = calculate_health_factor(800, 1000);
        assert(health == 8000, 'health 80%');
    }

    #[test]
    fn test_health_factor_zero_margin() {
        let health = calculate_health_factor(1000, 0);
        assert(health == 10000, '100% health');
    }

    #[test]
    fn test_shares_to_mint_first() {
        let shares = calculate_shares_to_mint(1000, 0, 0);
        assert(shares == 1000, 'first deposit');
    }

    #[test]
    fn test_shares_to_mint_proportional() {
        // 1000 shares, 2000 collateral, deposit 1000 -> 500 shares
        let shares = calculate_shares_to_mint(1000, 1000, 2000);
        assert(shares == 500, 'proportional');
    }

    #[test]
    fn test_withdrawal_amount() {
        // 500 shares / 1000 total, 2000 collateral -> 1000
        let amount = calculate_withdrawal_amount(500, 1000, 2000);
        assert(amount == 1000, 'withdrawal');
    }

    #[test]
    fn test_calculate_fee_basic() {
        // 1000 * 50 bps = 5
        let fee = calculate_fee(1000, 50);
        assert(fee == 5, 'fee 5');
    }

    #[test]
    fn test_calculate_fee_rounds_up() {
        // 999 * 50 / 10000 = 4.995 -> 5
        let fee = calculate_fee(999, 50);
        assert(fee == 5, 'fee rounds up');
    }
}
