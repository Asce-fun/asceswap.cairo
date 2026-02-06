// Pool Accounting Library
// Pure functions for share calculations, collateral locking/unlocking, and pool state transitions

pub mod PoolAccounting {
    use crate::helpers::fixed_point::mul_div_down;
    use crate::helpers::signed_value::apply_pnl;
    use crate::types::asce_swap::{LpPool, SignedValue, SwapSide};

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

    /// Calculate LP shares to mint (round DOWN - user gets less)
    pub fn calculate_shares_to_mint(
        deposit: u256, total_shares: u256, total_collateral: u256,
    ) -> u256 {
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
}


#[cfg(test)]
mod tests {
    use crate::helpers::signed_value::{negative, positive};
    use crate::types::asce_swap::{LpPool, SwapSide};
    use super::PoolAccounting;

    // Helper to create a basic pool
    fn basic_pool() -> LpPool {
        LpPool {
            total_collateral: 1000000,
            locked_for_fixed: 100000,
            locked_for_floating: 50000,
            total_shares: 1000000,
        }
    }

    #[test]
    fn test_shares_to_mint_first_deposit() {
        // First deposit: 1:1 ratio
        let shares = PoolAccounting::calculate_shares_to_mint(1000, 0, 0);
        assert(shares == 1000, 'first deposit 1:1');
    }

    #[test]
    fn test_shares_to_mint_proportional() {
        // Pool has 1000 shares, 2000 collateral (2:1 ratio)
        // Deposit 1000 collateral -> get 500 shares
        let shares = PoolAccounting::calculate_shares_to_mint(1000, 1000, 2000);
        assert(shares == 500, 'proportional shares');
    }

    #[test]
    fn test_shares_to_mint_equal_ratio() {
        // Pool has 1000 shares, 1000 collateral (1:1)
        // Deposit 500 -> get 500
        let shares = PoolAccounting::calculate_shares_to_mint(500, 1000, 1000);
        assert(shares == 500, 'equal ratio');
    }

    #[test]
    fn test_shares_to_mint_profitable_pool() {
        // Pool has 1000 shares, 1500 collateral (pool made profit)
        // Deposit 1500 -> get 1000 shares
        let shares = PoolAccounting::calculate_shares_to_mint(1500, 1000, 1500);
        assert(shares == 1000, 'profitable pool');
    }


    #[test]
    fn test_withdrawal_amount_proportional() {
        // 500 shares out of 1000 total, 2000 collateral
        // Should get 1000 collateral
        let amount = PoolAccounting::calculate_withdrawal_amount(500, 1000, 2000);
        assert(amount == 1000, 'withdrawal proportional');
    }

    #[test]
    fn test_withdrawal_amount_all_shares() {
        // Withdraw all shares
        let amount = PoolAccounting::calculate_withdrawal_amount(1000, 1000, 2000);
        assert(amount == 2000, 'withdraw all');
    }

    #[test]
    fn test_withdrawal_amount_zero_shares() {
        // Zero shares = zero withdrawal
        let amount = PoolAccounting::calculate_withdrawal_amount(0, 1000, 2000);
        assert(amount == 0, 'zero shares');
    }

    #[test]
    fn test_withdrawal_amount_empty_pool() {
        // Edge case: no shares in pool
        let amount = PoolAccounting::calculate_withdrawal_amount(100, 0, 2000);
        assert(amount == 0, 'empty pool');
    }


    #[test]
    fn test_lock_collateral_fixed() {
        let pool = basic_pool();
        let updated = PoolAccounting::lock_collateral(pool, SwapSide::Fixed, 50000);

        assert(updated.locked_for_fixed == 150000, 'fixed locked increased');
        assert(updated.locked_for_floating == 50000, 'floating unchanged');
        assert(updated.total_collateral == 1000000, 'total unchanged');
    }

    #[test]
    fn test_lock_collateral_floating() {
        let pool = basic_pool();
        let updated = PoolAccounting::lock_collateral(pool, SwapSide::Floating, 50000);

        assert(updated.locked_for_fixed == 100000, 'fixed unchanged');
        assert(updated.locked_for_floating == 100000, 'floating increased');
    }


    #[test]
    fn test_unlock_collateral_fixed() {
        let pool = basic_pool();
        let updated = PoolAccounting::unlock_collateral(pool, SwapSide::Fixed, 50000);

        assert(updated.locked_for_fixed == 50000, 'fixed unlocked');
        assert(updated.locked_for_floating == 50000, 'floating unchanged');
    }

    #[test]
    fn test_unlock_collateral_floating() {
        let pool = basic_pool();
        let updated = PoolAccounting::unlock_collateral(pool, SwapSide::Floating, 25000);

        assert(updated.locked_for_fixed == 100000, 'fixed unchanged');
        assert(updated.locked_for_floating == 25000, 'floating unlocked');
    }


    #[test]
    fn test_apply_lp_delta_positive() {
        let pool = basic_pool();
        let delta = positive(50000); // LP gains 50000

        let updated = PoolAccounting::apply_lp_delta(pool, delta);

        assert(updated.total_collateral == 1050000, 'collateral increased');
    }

    #[test]
    fn test_apply_lp_delta_negative() {
        let pool = basic_pool();
        let delta = negative(50000); // LP loses 50000

        let updated = PoolAccounting::apply_lp_delta(pool, delta);

        assert(updated.total_collateral == 950000, 'collateral decreased');
    }

    #[test]
    fn test_apply_lp_delta_zero() {
        let pool = basic_pool();
        let delta = positive(0);

        let updated = PoolAccounting::apply_lp_delta(pool, delta);

        assert(updated.total_collateral == 1000000, 'unchanged');
    }


    #[test]
    fn test_calculate_available_liquidity() {
        let pool = basic_pool();
        // 1,000,000 - 100,000 - 50,000 = 850,000
        let available = PoolAccounting::calculate_available_liquidity(@pool);
        assert(available == 850000, 'available liquidity');
    }

    #[test]
    fn test_calculate_available_liquidity_nothing_locked() {
        let pool = LpPool {
            total_collateral: 500000,
            locked_for_fixed: 0,
            locked_for_floating: 0,
            total_shares: 500000,
        };
        let available = PoolAccounting::calculate_available_liquidity(@pool);
        assert(available == 500000, 'all available');
    }

    #[test]
    fn test_calculate_available_liquidity_all_locked() {
        let pool = LpPool {
            total_collateral: 500000,
            locked_for_fixed: 250000,
            locked_for_floating: 250000,
            total_shares: 500000,
        };
        let available = PoolAccounting::calculate_available_liquidity(@pool);
        assert(available == 0, 'none available');
    }
}

