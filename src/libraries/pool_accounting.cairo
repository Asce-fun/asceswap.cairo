// Pool Accounting Library
// Pure functions for collateral locking/unlocking and pool state transitions

pub mod PoolAccounting {
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
