// Pool Accounting Library
// Pure functions for share calculations, collateral locking/unlocking, and pool state transitions

use crate::helpers::core_utils::{calculate_shares_to_mint, calculate_withdrawal_amount};
use crate::helpers::signed_value::apply_pnl;
use crate::types::asce_swap::{LpPool, SignedValue, SwapSide};

/// Calculate shares to mint for a deposit
/// Returns shares to mint
pub fn calc_shares_to_mint(amount: u256, total_shares: u256, total_collateral: u256) -> u256 {
    calculate_shares_to_mint(amount, total_shares, total_collateral)
}

/// Calculate withdrawal amount for shares
pub fn calc_withdrawal_amount(shares: u256, total_shares: u256, total_collateral: u256) -> u256 {
    calculate_withdrawal_amount(shares, total_shares, total_collateral)
}

/// Unlock collateral for a side
pub fn unlock_collateral(pool: LpPool, side: SwapSide, amount: u256) -> LpPool {
    let mut updated = pool;
    match side {
        SwapSide::Fixed => { updated.locked_for_fixed = updated.locked_for_fixed - amount; },
        SwapSide::Floating => {
            updated.locked_for_floating = updated.locked_for_floating - amount;
        },
    }
    updated
}

/// Lock collateral for a side
pub fn lock_collateral(pool: LpPool, side: SwapSide, amount: u256) -> LpPool {
    let mut updated = pool;
    match side {
        SwapSide::Fixed => { updated.locked_for_fixed = updated.locked_for_fixed + amount; },
        SwapSide::Floating => {
            updated.locked_for_floating = updated.locked_for_floating + amount;
        },
    }
    updated
}

/// Apply LP delta (gain/loss) to pool
pub fn apply_lp_delta(pool: LpPool, delta: SignedValue) -> LpPool {
    let mut updated = pool;
    updated.total_collateral = apply_pnl(pool.total_collateral, delta);
    updated
}

/// Calculate available liquidity in pool
pub fn calculate_available_liquidity(pool: @LpPool) -> u256 {
    *pool.total_collateral - *pool.locked_for_fixed - *pool.locked_for_floating
}
