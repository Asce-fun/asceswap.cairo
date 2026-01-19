use crate::helpers::constants::{BPS, PRICE_PRECISION};
use crate::helpers::fixed_point::{div_down, div_up, mul_div_down, mul_div_up};
use crate::helpers::utils::pow10;


/// Calculate shares to mint for LP deposit
/// Rounds DOWN - user receives fewer shares (protocol favored)
pub fn calculate_shares_to_mint(
    deposit_amount: u256, total_shares: u256, total_collateral: u256,
) -> u256 {
    if total_shares == 0 || total_collateral == 0 {
        return deposit_amount; // First depositor: 1:1
    }
    // shares = (amount * total_shares) / total_collateral
    // Round DOWN - user gets fewer shares
    mul_div_down(deposit_amount, total_shares, total_collateral)
}

/// Calculate collateral to return for LP withdrawal
/// Rounds DOWN - user receives less collateral (protocol favored)
pub fn calculate_withdrawal_amount(
    shares_to_burn: u256, total_shares: u256, total_collateral: u256,
) -> u256 {
    if total_shares == 0 {
        return 0;
    }
    // amount = (shares * total_collateral) / total_shares
    // Round DOWN - user receives less
    mul_div_down(shares_to_burn, total_collateral, total_shares)
}

/// Calculate required collateral for a swap
/// Rounds UP - user must post more collateral (protocol favored)
pub fn calculate_required_collateral(max_exposure: u256, liquidation_threshold_bps: u256) -> u256 {
    if max_exposure == 0 {
        return 0;
    }
    // required = (max_exposure * BPS) / threshold
    // Round UP - user posts more
    mul_div_up(max_exposure, BPS, liquidation_threshold_bps)
}

/// Calculate fee amount
/// Rounds UP - user pays more fees (protocol favored)
pub fn calculate_fee(base_amount: u256, fee_bps: u256) -> u256 {
    if fee_bps == 0 {
        return 0;
    }
    // fee = (amount * fee_bps) / BPS
    // Round UP - more fees collected
    mul_div_up(base_amount, fee_bps, BPS)
}

/// Calculate payment amount (for fixed or floating leg)
/// Rounds DOWN for profit scenarios, UP for loss scenarios
/// This is a neutral calculation - caller decides context
pub fn calculate_payment(
    notional: u256, rate_bps: u256, term_seconds: u256, seconds_per_year: u256,
) -> u256 {
    // payment = notional * rate * term / year / BPS
    // Use mul_div_down as base calculation
    mul_div_down(mul_div_down(notional, rate_bps, BPS), term_seconds, seconds_per_year)
}

/// Calculate profit payout to user
/// Rounds DOWN - user receives less profit (protocol favored)
pub fn calculate_profit_payout(floating_payment: u256, fixed_payment: u256) -> u256 {
    if floating_payment > fixed_payment {
        floating_payment - fixed_payment
    } else {
        0
    }
}

/// Calculate loss to deduct from user
/// Rounds UP - user loses more (protocol favored)
pub fn calculate_loss_deduction(fixed_payment: u256, floating_payment: u256) -> u256 {
    if fixed_payment > floating_payment {
        // Add 1 to round up the loss
        let base_loss = fixed_payment - floating_payment;
        base_loss + 1 // Round UP
    } else {
        0
    }
}

/// Calculate liquidation bonus for liquidator
/// Rounds DOWN - liquidator receives less (prevents over-extraction)
pub fn calculate_liquidation_bonus(collateral_seized: u256, bonus_bps: u256) -> u256 {
    // bonus = (collateral * bonus_bps) / BPS
    // Round DOWN - liquidator gets less
    mul_div_down(collateral_seized, bonus_bps, BPS)
}

/// Calculate health factor
/// Rounds DOWN - makes liquidation trigger sooner (protocol favored)
pub fn calculate_health_factor(remaining_value: u256, required_collateral: u256) -> u256 {
    if required_collateral == 0 {
        return BPS; // 100% health if no requirement
    }
    // health = (remaining * BPS) / required
    // Round DOWN - health appears lower, liquidation triggers earlier
    mul_div_down(remaining_value, BPS, required_collateral)
}

/// Calculate utilization fee (exponential curve)
/// Rounds UP - user pays more fees (protocol favored)
pub fn calculate_utilization_fee(
    notional_amount: u256, available_liquidity: u256, min_fee_bps: u256, max_fee_bps: u256,
) -> u256 {
    if available_liquidity == 0 {
        return max_fee_bps;
    }

    // utilization = notional / available (in BPS)
    let utilization = mul_div_up(notional_amount, BPS, available_liquidity);

    // Exponential curve: fee = min + (max - min) × util²
    let fee_range = max_fee_bps - min_fee_bps;
    let util_squared = mul_div_up(utilization, utilization, BPS);

    // Round UP - user pays more
    min_fee_bps + mul_div_up(fee_range, util_squared, BPS)
}


/// Normalize token amount to 18 decimals
/// Rounds DOWN for consistency
pub fn normalize_to_18_decimals(amount: u256, token_decimals: u8) -> u256 {
    if token_decimals < 18 {
        amount * pow10((18 - token_decimals).into())
    } else if token_decimals > 18 {
        div_down(amount, pow10((token_decimals - 18).into()))
    } else {
        amount
    }
}

/// Convert from 18 decimals to token decimals
/// Rounds based on direction parameter
pub fn denormalize_from_18_decimals(amount_18: u256, token_decimals: u8, round_up: bool) -> u256 {
    if token_decimals < 18 {
        let divisor = pow10((18 - token_decimals).into());
        if round_up {
            div_up(amount_18, divisor)
        } else {
            div_down(amount_18, divisor)
        }
    } else if token_decimals > 18 {
        amount_18 * pow10((token_decimals - 18).into())
    } else {
        amount_18
    }
}

/// Convert token amount to USD value
/// Rounds DOWN - value appears lower (conservative for collateral valuation)
pub fn calculate_usd_value(
    token_amount: u256, price: u256, // 8 decimals
    token_decimals: u8,
) -> u256 {
    // Normalize to 18 decimals
    let normalized = normalize_to_18_decimals(token_amount, token_decimals);

    // value = (amount * price) / 10^8
    // Round DOWN - collateral value is lower, more conservative
    mul_div_down(normalized, price, PRICE_PRECISION)
}

/// Convert USD value to token amount
/// Rounds UP - user needs more tokens (protocol favored)
pub fn calculate_token_amount_from_usd(
    usd_value: u256, // 18 decimals
    price: u256, // 8 decimals
    token_decimals: u8,
) -> u256 {
    if price == 0 {
        return 0;
    }

    // amount_18 = (usd * 10^8) / price
    // Round UP - user needs more tokens
    let amount_18 = mul_div_up(usd_value, PRICE_PRECISION, price);

    // Convert from 18 decimals to token decimals, round UP
    denormalize_from_18_decimals(amount_18, token_decimals, true)
}
