/// Basis points denominator (1 bps = 0.01%)
pub const BPS: u256 = 10_000;

/// 18 decimal precision for internal USD calculations
pub const PRECISION: u256 = 1_000_000_000_000_000_000; // 1e18

/// Oracle price precision (8 decimals like Chainlink/Pragma)
pub const PRICE_PRECISION: u256 = 100_000_000; // 1e8

/// Seconds in a year (365 days)
pub const SECONDS_PER_YEAR: u64 = 31_536_000;

/// Maximum utilization ratio (90% = 9000 bps)
pub const MAX_UTILIZATION_BPS: u256 = 9_000;

/// Minimum swap duration (1 day)
pub const MIN_SWAP_DURATION: u64 = 86_400;

/// Maximum swap duration (365 days)
pub const MAX_SWAP_DURATION: u64 = 31_536_000;

/// Minimum LP deposit to prevent dust attacks
pub const MIN_LP_DEPOSIT: u256 = 1_000_000; // Adjust based on token decimals

/// Minimum shares to prevent rounding attacks
pub const MIN_SHARES: u256 = 1_000;

/// Minimum notional to ensure liquidation is economical
pub const MIN_NOTIONAL_USD: u256 = 1_000_000_000_000_000_000_000; // $1000 in 18 decimals

/// Minimum collateral per swap
pub const MIN_COLLATERAL_USD: u256 = 10_000_000_000_000_000_000; // $10 in 18 decimals

/// Minimum hold period before early exit (1 day)
pub const MIN_HOLD_PERIOD: u64 = 86_400;
