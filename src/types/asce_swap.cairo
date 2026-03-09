use starknet::ContractAddress;
#[derive(Drop, Copy, Serde, starknet::Store, PartialEq, Debug)]
pub enum SwapSide {
    #[default]
    Fixed,
    Floating,
}

#[derive(Drop, Copy, Serde, starknet::Store, PartialEq, Debug)]
pub enum SwapStatus {
    #[default]
    Uninitialized,
    Active,
    Settled,
    ExitedEarly,
}

#[derive(Drop, Copy, Serde, starknet::Store, PartialEq, Debug)]
pub enum MarketStatus {
    Active,
    Paused,
    #[default]
    Closed,
}

///Signed Value Representation for PnL calculations
#[derive(Drop, Copy, Serde, starknet::Store, PartialEq, Debug)]
pub struct SignedValue {
    pub value: u256,
    pub is_negative: bool,
}


/// Market parameters set at creation time
#[derive(Drop, Copy, Serde, Debug, starknet::Store)]
pub struct MarketParams {
    ///Risk Parameters
    pub initial_margin_multiplier_bps: u256, // e.g., 12000 = 120% of max exposure
    pub min_margin_floor_bps: u256, // e.g., 2000 = 20% minimum at expiry
    ///Term Parameter
    pub min_swap_term_seconds: u64, // Min Duration for a swaps
    pub max_swap_term_seconds: u64, // Max duration for a swap
    pub min_hold_period_seconds: u64, // Before early exit allowed
    /// Fee Parameters (in BPS)
    pub swap_fee_bps: u256,
    pub max_early_exit_fee_bps: u256, // Fee at start of term (e.g. 300 = 3%)
    pub min_early_exit_fee_bps: u256, // Fee near expiry (e.g. 25 = 0.25%)
    ///Rate Parameters
    pub base_fee_spread_bps: u256, // Minimum spread on all trades (LP's base edge)
    pub demand_spread_factor: u256, // Capacity scaling factor (higher = more tolerant of imbalance)
    pub max_total_utilization_bps: u256, // Hard ceiling safety valve (e.g., 9000 = 90%)
    ///Bounds
    pub min_notional_per_swap: u256,
    pub max_oracle_staleness_seconds: u64,
    pub max_rate_change_per_update_bps: u256, // Rate change limit
    //Lp type
    pub is_lp_permissioned: bool // is Lp provisiong open 
}


#[derive(Drop, Copy, Serde, Debug, starknet::Store)]
pub struct LpPool {
    pub total_collateral: u256,
    pub locked_for_fixed: u256,
    pub locked_for_floating: u256,
    pub total_shares: u256,
}

#[derive(Drop, Copy, Serde, starknet::Store, Debug)]
///Rate Tracking for TWA calculation
pub struct RateIndex {
    pub last_update_time: u64,
    pub last_rate_bps: u256, // Rate in basis points
    pub cumulative_rate_time: u256, // Σ(rate × seconds)
    pub last_valid_rate_bps: u256 // For rate change limiting
}

/// A market pair combines both directions of a rate swap
#[derive(Drop, Copy, Serde, starknet::Store, Debug)]
pub struct MarketPair {
    pub pair_id: felt252,
    pub status: MarketStatus,
    // Oracle addresses
    pub rate_oracle: ContractAddress,
    //curator address
    pub curator: ContractAddress,
    // Collateral token
    pub collateral_token: ContractAddress,
    pub decimals: u8,
    // Parameters
    pub params: MarketParams,
    // Pool state
    pub pool: LpPool,
    // Rate index
    pub rate_index: RateIndex,
    // Counters
    pub total_swaps_created: u256,
    pub active_swap_count: u256,
    pub extension: ContractAddress,
}


/// Individual swap position
#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct Swap {
    pub swap_id: u256,
    pub pair_id: felt252,
    // pub owner: ContractAddress,
    pub side: SwapSide,
    pub status: SwapStatus,
    // Position details (all in collateral token units)
    pub notional: u256,
    pub fixed_rate_bps: u256,
    pub buyer_collateral: u256,
    pub lp_collateral_locked: u256,
    pub initial_required_margin: u256, // Margin requirement at creation
    // Timing
    pub start_time: u64,
    pub expiration_time: u64,
    // TWA tracking
    pub start_cumulative_rate: u256,
}


/// Protocol-wide configuration
#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct ProtocolConfig {
    pub treasury: ContractAddress,
    pub protocol_fee_share_bps: u256, // % of collected fees to treasury
    pub market_creation_fees: u256,
    pub fee_token: ContractAddress,
}


/// Swap rate quote
#[derive(Drop, Copy, Serde)]
pub struct SwapQuote {
    pub base_rate_bps: u256,
    pub imbalance_adjustment_bps: u256,
    pub adjustment_is_positive: bool,
    pub fee_spread_bps: u256,
    pub final_rate_bps: u256,
    pub required_collateral: u256,
    pub lp_collateral_to_lock: u256,
    pub current_utilization_bps: u256,
    pub demand_spread_bps: u256,
}


/// Health status of a swap
#[derive(Drop, Copy, Serde)]
pub struct HealthStatus {
    pub current_pnl: SignedValue,
    pub buyer_remaining_value: u256,
    pub required_margin: u256,
    pub health_factor_bps: u256,
    pub time_to_expiry_seconds: u64,
}


/// LP pool analytics
#[derive(Drop, Copy, Serde)]
pub struct PoolAnalytics {
    pub total_value: u256,
    pub available_liquidity: u256,
    pub utilization_fixed_bps: u256,
    pub utilization_floating_bps: u256,
    pub net_exposure_notional: SignedValue,
}

/// Settlement type for swap closure
#[derive(Drop, Copy, Serde, PartialEq)]
pub enum SettlementType {
    #[default]
    Normal, // settle_swap at expiration
    EarlyExit, // early_exit with penalty
}

/// Result of a settlement operation
#[derive(Drop, Copy, Serde)]
pub struct SettlementResult {
    pub buyer_payout: u256,
    pub lp_delta: SignedValue,
    pub penalty: u256, // 0 for non-early-exit
    pub twa_rate_bps: u256,
    pub pnl: SignedValue,
}


/// Comprehensive swap analytics for frontend display
#[derive(Drop, Copy, Serde)]
pub struct SwapAnalytics {
    // Current state
    pub current_pnl: SignedValue, // Current PnL in collateral units
    pub current_floating_rate_bps: u256, // Current oracle rate
    pub fixed_rate_bps: u256, // Locked fixed rate (profit threshold)
    pub current_spread_bps: SignedValue, // floating - fixed (positive = in profit for Fixed side)
    // Yield metrics
    pub leverage_x100: u256, // Leverage ratio * 100 (e.g., 833 = 8.33x)
    pub yield_term_bps: SignedValue, // Current yield for the term (annualized)
    pub current_return: SignedValue, // Current $ return (same as current_pnl)
    // Position info
    pub notional: u256,
    pub collateral: u256,
    pub health_factor_bps: u256,
    // Time info
    pub elapsed_seconds: u64,
    pub remaining_seconds: u64,
    pub progress_bps: u256, // 0-10000 (0-100%)
    // Projections at expiry (if rate stays same)
    pub projected_pnl_at_expiry: SignedValue,
}

/// LP position analytics
#[derive(Drop, Copy, Serde)]
pub struct LpAnalytics {
    // Position value
    pub shares: u256,
    pub share_value: u256, // Current value in collateral
    pub share_percentage_bps: u256, // Your % of pool (in bps)
    // Pool exposure
    pub pool_tvl: u256,
    pub available_liquidity: u256,
    pub utilization_bps: u256, // Total utilization
    // Risk exposure from active swaps
    pub net_exposure: SignedValue, // + means pool is net short (swappers winning)
    pub your_exposure: SignedValue, // Your share of net exposure
    // Status
    pub max_withdrawable: u256 // How much can be withdrawn now
}

/// Scenario projection for what-if analysis
#[derive(Drop, Copy, Serde)]
pub struct ScenarioResult {
    pub rate_bps: u256, // The hypothetical rate
    pub pnl: SignedValue, // PnL at this rate
    pub is_profitable: bool,
}


/// User's swap position summary (for dashboard)
#[derive(Drop, Copy, Serde)]
pub struct UserSwapSummary {
    pub swap_id: u256,
    pub pair_id: felt252,
    pub side: SwapSide,
    pub status: SwapStatus,
    pub notional: u256,
    pub collateral: u256,
    pub current_pnl: SignedValue,
    pub health_factor_bps: u256,
    pub progress_bps: u256, // 0-10000
    pub remaining_seconds: u64,
}

/// Aggregated user dashboard stats
#[derive(Drop, Copy, Serde)]
pub struct UserDashboard {
    // Swap positions
    pub total_swaps: u32,
    pub active_swaps: u32,
    pub total_notional: u256, // Sum of all active notional
    pub total_collateral_locked: u256, // Sum of all collateral in swaps
    pub total_unrealized_pnl: SignedValue, // Sum of all current PnL
    // LP positions
    pub total_lp_value: u256, // Sum of all LP share values
    pub total_lp_positions: u32, // Number of markets with LP
    // Combined
    pub total_portfolio_value: u256 // Collateral + LP value (adjusted for PnL)
}

/// LP position summary per market
#[derive(Drop, Copy, Serde)]
pub struct UserLpSummary {
    pub pair_id: felt252,
    pub shares: u256,
    pub share_value: u256,
    pub share_percentage_bps: u256,
    pub utilization_bps: u256,
}

