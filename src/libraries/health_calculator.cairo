// Health Calculator Library
// Pure functions for health factor calculation, liquidation eligibility, and margin adjustments

pub mod HealthCal {
    use crate::helpers::constants::Constants;
    use crate::helpers::fixed_point::*;
    use crate::helpers::signed_value::apply_pnl;
    use crate::helpers::utils::Utils;
    use crate::libraries::rate_engine::RateEngine;
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

    pub fn calculate_health_factor(remaining_value: u256, required_margin: u256) -> u256 {
        if required_margin == 0 {
            return Constants::BPS; // 100% if no requirement
        }
        // Round DOWN - health appears lower, triggers liquidation earlier (safer)
        mul_div_down(remaining_value, Constants::BPS, required_margin)
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
        let effective_factor = Utils::max(time_factor_bps, min_floor_bps);

        // adjusted = initial × factor / BPS
        mul_div_down(initial_margin, effective_factor, Constants::BPS)
    }
    /// Calculate required margin for a swap
    /// Uses max(rate, min_margin_rate_bps) to prevent tiny margins on low-rate markets
    /// required = max_exposure × initial_margin_multiplier / BPS
    pub fn calculate_required_margin(
        notional: u256,
        rate_bps: u256,
        term_seconds: u64,
        initial_margin_multiplier_bps: u256,
        min_margin_rate_bps: u256,
    ) -> u256 {
        let effective_rate = Utils::max(rate_bps, min_margin_rate_bps);
        let max_exposure = calculate_max_exposure(notional, effective_rate, term_seconds);
        // Round UP - require more margin for safety
        mul_div_up(max_exposure, initial_margin_multiplier_bps, Constants::BPS)
    }
    /// Calculate maximum exposure for a swap position
    pub fn calculate_max_exposure(notional: u256, rate_bps: u256, term_seconds: u64) -> u256 {
        RateEngine::calculate_payment(notional, rate_bps, term_seconds)
    }
}

#[cfg(test)]
mod tests {
    use crate::helpers::constants::Constants;
    use super::HealthCal;

    // ============ calculate_health_factor tests ============

    #[test]
    fn test_health_factor_healthy() {
        // remaining=1000, required=800 -> health = 12500 (125%)
        let health = HealthCal::calculate_health_factor(1000, 800);
        assert(health == 12500, 'health 125%');
    }

    #[test]
    fn test_health_factor_exactly_100() {
        // remaining=1000, required=1000 -> health = 10000 (100%)
        let health = HealthCal::calculate_health_factor(1000, 1000);
        assert(health == 10000, 'health 100%');
    }

    #[test]
    fn test_health_factor_unhealthy() {
        // remaining=800, required=1000 -> health = 8000 (80%)
        let health = HealthCal::calculate_health_factor(800, 1000);
        assert(health == 8000, 'health 80%');
    }

    #[test]
    fn test_health_factor_critical() {
        // remaining=500, required=1000 -> health = 5000 (50%)
        let health = HealthCal::calculate_health_factor(500, 1000);
        assert(health == 5000, 'health 50%');
    }

    #[test]
    fn test_health_factor_zero_remaining() {
        // remaining=0, required=1000 -> health = 0
        let health = HealthCal::calculate_health_factor(0, 1000);
        assert(health == 0, 'health 0%');
    }

    #[test]
    fn test_health_factor_zero_margin() {
        // No margin required = 100% health (BPS)
        let health = HealthCal::calculate_health_factor(1000, 0);
        assert(health == Constants::BPS, '100% health');
    }

    // ============ calculate_time_adjusted_margin tests ============

    #[test]
    fn test_time_adjusted_margin_full_term() {
        // Full term remaining = full margin
        let margin = HealthCal::calculate_time_adjusted_margin(1000, 2592000, 2592000, 2000);
        assert(margin == 1000, 'full margin');
    }

    #[test]
    fn test_time_adjusted_margin_half_term() {
        // Half term remaining, no floor = half margin
        let margin = HealthCal::calculate_time_adjusted_margin(1000, 1296000, 2592000, 0);
        assert(margin == 500, 'half margin');
    }

    #[test]
    fn test_time_adjusted_margin_quarter_term() {
        // Quarter term remaining, no floor = quarter margin
        let margin = HealthCal::calculate_time_adjusted_margin(1000, 648000, 2592000, 0);
        assert(margin == 250, 'quarter margin');
    }

    #[test]
    fn test_time_adjusted_margin_floor_applies() {
        // 10% remaining but 20% floor = 20% margin
        let margin = HealthCal::calculate_time_adjusted_margin(1000, 259200, 2592000, 2000);
        assert(margin == 200, 'floor applies');
    }

    #[test]
    fn test_time_adjusted_margin_zero_remaining() {
        // Zero remaining, 20% floor = 20% margin
        let margin = HealthCal::calculate_time_adjusted_margin(1000, 0, 2592000, 2000);
        assert(margin == 200, 'zero remaining floor');
    }

    #[test]
    fn test_time_adjusted_margin_over_term() {
        // Remaining > total (shouldn't happen but edge case)
        let margin = HealthCal::calculate_time_adjusted_margin(1000, 3000000, 2592000, 2000);
        assert(margin == 1000, 'over term = full');
    }

    #[test]
    fn test_time_adjusted_margin_zero_term() {
        // Edge case: zero total term
        let margin = HealthCal::calculate_time_adjusted_margin(1000, 100, 0, 2000);
        assert(margin == 1000, 'zero term = full');
    }


    #[test]
    fn test_is_liquidatable_true() {
        // Health 7000 (70%) < threshold 8000 (80%) = liquidatable
        let result = HealthCal::is_liquidatable(7000, 8000);
        assert(result == true, 'should be liquidatable');
    }

    #[test]
    fn test_is_liquidatable_false() {
        // Health 9000 (90%) > threshold 8000 (80%) = safe
        let result = HealthCal::is_liquidatable(9000, 8000);
        assert(result == false, 'should be safe');
    }

    #[test]
    fn test_is_liquidatable_at_threshold() {
        // Health 8000 = threshold 8000 = NOT liquidatable (must be strictly less)
        let result = HealthCal::is_liquidatable(8000, 8000);
        assert(result == false, 'at threshold safe');
    }

    // ============ calculate_required_margin tests ============

    #[test]
    fn test_calculate_required_margin_basic() {
        // 1,000,000 notional, 5% rate, 1 year, 110% multiplier, no floor
        // max_exposure = 50,000
        // required = 50,000 * 1.1 = 55,000
        let margin = HealthCal::calculate_required_margin(
            1000000, 500, Constants::SECONDS_PER_YEAR, 11000, 0,
        );
        assert(margin == 55000, 'basic margin');
    }

    #[test]
    fn test_calculate_required_margin_30_days() {
        // 1,000,000 notional, 10% rate, 30 days, 110% multiplier, no floor
        let thirty_days: u64 = 2592000;
        let margin = HealthCal::calculate_required_margin(1000000, 1000, thirty_days, 11000, 0);
        // max_exposure ≈ 8,219, required ≈ 9,041
        assert(margin > 8500 && margin < 9500, 'margin 30 days');
    }

    #[test]
    fn test_calculate_required_margin_high_multiplier() {
        // Same as basic but 110% multiplier (max allowed), no floor
        let margin = HealthCal::calculate_required_margin(
            1000000, 500, Constants::SECONDS_PER_YEAR, 11000, 0,
        );
        // 50,000 * 1.1 = 55,000
        assert(margin == 55000, 'high multiplier');
    }

    #[test]
    fn test_calculate_required_margin_floor_no_effect() {
        // Rate 5% (500) > floor 2% (200) → floor doesn't bind
        let margin_with_floor = HealthCal::calculate_required_margin(
            1000000, 500, Constants::SECONDS_PER_YEAR, 11000, 200,
        );
        let margin_without_floor = HealthCal::calculate_required_margin(
            1000000, 500, Constants::SECONDS_PER_YEAR, 11000, 0,
        );
        assert(margin_with_floor == margin_without_floor, 'floor no effect');
    }

    #[test]
    fn test_calculate_required_margin_floor_binds() {
        // Rate 0.35% (35) < floor 2% (200) → margin calculated on 2%
        // Without floor: 1M * 0.35% * 1yr * 1.1 = 3,850
        // With floor:    1M * 2%    * 1yr * 1.1 = 22,000
        let margin_low_rate = HealthCal::calculate_required_margin(
            1000000, 35, Constants::SECONDS_PER_YEAR, 11000, 200,
        );
        let margin_at_floor = HealthCal::calculate_required_margin(
            1000000, 200, Constants::SECONDS_PER_YEAR, 11000, 0,
        );
        assert(margin_low_rate == margin_at_floor, 'floor binds');
    }

    #[test]
    fn test_calculate_required_margin_zero_rate_with_floor() {
        // Rate 0% but floor 2% → margin still calculated on 2%
        let margin = HealthCal::calculate_required_margin(
            1000000, 0, Constants::SECONDS_PER_YEAR, 11000, 200,
        );
        // 1M * 2% * 1yr * 1.1 = 22,000
        assert(margin == 22000, 'zero rate floor');
    }

    #[test]
    fn test_calculate_max_exposure() {
        // Just delegates to RateEngine::calculate_payment
        let exposure = HealthCal::calculate_max_exposure(1000000, 500, Constants::SECONDS_PER_YEAR);
        assert(exposure == 50000, 'max exposure');
    }
}
