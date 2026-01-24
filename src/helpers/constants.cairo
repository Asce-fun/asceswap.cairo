pub mod Constants {
    use starknet::{ContractAddress, contract_address_const};

    /// Basis points base (100% = 10000 bps)
    pub const BPS: u256 = 10_000;

    /// Precision for intermediate calculations (18 decimals)
    pub const PRECISION: u256 = 1_000_000_000_000_000_000;

    /// Seconds in a year (for annualized rate calculations)
    pub const SECONDS_PER_YEAR: u64 = 31_536_000;

    /// Minimum shares burned on first LP deposit (prevents inflation attack)
    pub const MIN_BURNED_SHARES: u256 = 1_000;

    /// Minimum LP deposit amount
    pub const MIN_LP_DEPOSIT: u256 = 1_000;

    /// Default minimum first LP deposit
    pub const DEFAULT_MIN_FIRST_LP_DEPOSIT: u256 = 10_000;

    /// Minimum liquidation threshold (50%)
    pub const MIN_LIQUIDATION_THRESHOLD_BPS: u256 = 5_000;

    /// Maximum liquidation threshold (95%)
    pub const MAX_LIQUIDATION_THRESHOLD_BPS: u256 = 9_500;

    /// Minimum swap term (1 hour)
    pub const MIN_SWAP_TERM_SECONDS: u64 = 3_600;

    /// Maximum swap term (1 year)
    pub const MAX_SWAP_TERM_SECONDS: u64 = 31_536_000;

    /// Maximum fee (10%)
    pub const MAX_FEE_BPS: u256 = 1_000;

    /// Maximum rate bound (10000% APY)
    pub const MAX_RATE_BOUND_BPS: u256 = 1_000_000;

    /// Maximum utilization per side (80%)
    pub const MAX_UTILIZATION_CAP_BPS: u256 = 8_000;


    pub fn USDC() -> ContractAddress {
        contract_address_const::<
            0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8,
        >()
    }

    pub const MARKET_CREATION_FESS: u256 = 0;
}
