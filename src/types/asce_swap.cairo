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
    Liquidated,
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
    pub liquidation_threshold_bps: u256,
    pub initial_margin_multiplier_bps: u256, // e.g., 12000 = 120% of max exposure
    pub min_margin_floor_bps: u256, // e.g., 2000 = 20% minimum at expiry
    ///Term Parameter
    pub swap_term_seconds: u64, // Duration of swaps
    pub min_hold_period_seconds: u64, // Before early exit allowed
    /// Fee Parameters (in BPS)
    pub swap_fee_bps: u256, // On collateral at entry
    pub early_exit_fee_bps: u256, // Penalty for early exit
    pub liquidation_bonus_bps: u256, // Incentive for liquidators
    ///Rate Parameters
    pub fee_spread_bps: u256,
    pub max_imbalance_adjustment_bps: u256,
    pub max_utilization_bps: u256,
    ///Bounds
    pub min_notional: u256,
    pub max_notional_per_swap: u256,
    pub max_oracle_staleness_seconds: u64,
    pub max_rate_change_per_update_bps: u256, // Rate change limit
    pub min_rate_bps: u256, // Floor (can be 0)
    pub max_rate_bps: u256, // Ceiling (e.g., 1000000 = 10000%)
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


/// LP position for a specific market pair
#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct LpPosition {
    pub shares: u256,
    pub last_deposit_time: u64,
}


/// Protocol-wide configuration
#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct ProtocolConfig {
    pub treasury: ContractAddress,
    pub protocol_fee_share_bps: u256, // % of collected fees to treasury
    pub min_first_lp_deposit: u256, // Minimum for first LP
    pub burned_shares_amount: u256, // Shares burned on first deposit
    pub market_creation_fees: u256,
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
}


/// Health status of a swap
#[derive(Drop, Copy, Serde)]
pub struct HealthStatus {
    pub current_pnl: SignedValue,
    pub buyer_remaining_value: u256,
    pub required_margin: u256,
    pub health_factor_bps: u256,
    pub is_liquidatable: bool,
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
    // pub insurance_fund_value: u256,
}

