pub mod Constants {
    use starknet::{ContractAddress, contract_address_const};

    /// Basis points base (100% = 10000 bps)
    pub const BPS: u256 = 10_000;

    /// Precision for intermediate calculations (18 decimals)
    pub const PRECISION: u256 = 1_000_000_000_000_000_000;

    /// Seconds in a year (for annualized rate calculations)
    pub const SECONDS_PER_YEAR: u64 = 31_536_000;

    /// Minimum LP deposit amount
    pub const MIN_LP_DEPOSIT: u256 = 1_000;

    /// Minimum liquidation threshold (50%)
    pub const MIN_LIQUIDATION_THRESHOLD_BPS: u256 = 5_000;

    /// Maximum liquidation threshold (95%)
    pub const MAX_LIQUIDATION_THRESHOLD_BPS: u256 = 9_500;

    /// Minimum swap term (1 hour) — prevents flash swap attacks
    pub const MIN_SWAP_TERM_SECONDS: u64 = 3_600;

    /// Maximum fee (10%)
    pub const MAX_FEE_BPS: u256 = 1_000;

    pub const MIN_MARGIN_MULTIPLIER_BPS: u256 = 10000; // 100%

    pub const MAX_MARGIN_MULTIPLIER_BPS: u256 = 12500; //125%

    /// Minimum margin floor (5%) — prevents margin from decaying to zero near expiry
    pub const MIN_MARGIN_FLOOR_BPS: u256 = 500;

    /// Maximum total utilization across both sides (95%) — safety valve
    pub const MAX_TOTAL_UTILIZATION_CAP_BPS: u256 = 9_500;

    /// Demand spread curve — Tier 1 boundary (20% ratio)
    pub const DEMAND_SPREAD_TIER1_END_RATIO: u256 = 2_000;
    /// Demand spread curve — Tier 2 boundary (50% ratio)
    pub const DEMAND_SPREAD_TIER2_END_RATIO: u256 = 5_000;

    /// Demand spread curve — Tier 1 max spread (1% = 100 bps)
    pub const DEMAND_SPREAD_TIER1_END_SPREAD: u256 = 100;
    /// Demand spread curve — Tier 2 max spread (5% = 500 bps)
    pub const DEMAND_SPREAD_TIER2_END_SPREAD: u256 = 500;
    /// Demand spread curve — Tier 3 max spread / cap (30% = 3000 bps)
    pub const DEMAND_SPREAD_MAX_SPREAD: u256 = 3_000;

    /// Minimum demand_spread_factor (0.5x)
    pub const MIN_DEMAND_SPREAD_FACTOR: u256 = 5_000;
    /// Maximum demand_spread_factor (5x)
    pub const MAX_DEMAND_SPREAD_FACTOR: u256 = 50_000;

    /// Minimum oracle staleness window (60 seconds)
    pub const MIN_ORACLE_STALENESS_SECONDS: u64 = 60;


    pub fn USDC() -> ContractAddress {
        contract_address_const::<
            0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8,
        >()
    }

    pub const MARKET_CREATION_FEE: u256 = 0;
}
