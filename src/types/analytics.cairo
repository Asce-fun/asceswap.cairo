use starknet::ContractAddress;
use crate::types::asce_swap::{
    MarketStatus, SignedValue, SwapSide, SwapStatus, UserLpSummary, UserSwapSummary,
};

// ============================================================
// Dashboard Page Data (Single call for entire dashboard)
// ============================================================

/// Complete data for user dashboard page
#[derive(Drop, Serde)]
pub struct DashboardPageData {
    // User identity
    pub user: ContractAddress,
    // Portfolio Overview
    pub total_portfolio_value: u256,
    pub total_collateral_at_risk: u256,
    pub total_unrealized_pnl: SignedValue,
    // Swap Positions Summary
    pub total_swaps: u32,
    pub active_swaps: u32,
    pub fixed_positions: u32,
    pub floating_positions: u32,
    pub total_notional_exposure: u256,
    pub avg_health_factor_bps: u256,
    pub positions_at_risk: u32, // health factor < 150%
    // LP Positions Summary
    pub total_lp_value: u256,
    pub total_lp_positions: u32,
    pub total_lp_share_percentage_bps: u256, // Avg across markets
    // Detailed positions (capped for gas efficiency)
    pub swap_positions: Span<UserSwapSummary>,
    pub lp_positions: Span<UserLpSummary>,
    // Alerts
    pub has_liquidatable_positions: bool,
    pub has_expiring_soon: bool, // Within 24h
    pub expiring_soon_count: u32,
}

// ============================================================
// LP Page Data (Single call for LP providers view)
// ============================================================

/// Market info for LP page listing
#[derive(Drop, Copy, Serde)]
pub struct MarketForLp {
    pub pair_id: felt252,
    pub status: MarketStatus,
    pub collateral_token: ContractAddress,
    pub decimals: u8,
    // Pool metrics
    pub total_tvl: u256,
    pub available_liquidity: u256,
    pub utilization_bps: u256,
    // Rate info
    pub current_rate_bps: u256,
    pub fee_spread_bps: u256,
    // Risk metrics
    pub net_exposure: SignedValue, // LP's net position
    pub active_swaps: u256,
    // User's position in this market (if any)
    pub user_shares: u256,
    pub user_share_value: u256,
    pub user_can_withdraw: bool,
}

/// Complete data for LP page
#[derive(Drop, Serde)]
pub struct LpPageData {
    pub user: ContractAddress,
    // User's LP Overview
    pub total_lp_value: u256,
    pub total_positions: u32,
    pub weighted_avg_utilization_bps: u256,
    // Available markets for LP
    pub markets: Span<MarketForLp>,
    // Global protocol stats
    pub total_protocol_tvl: u256,
    pub total_active_markets: u32,
}

/// User's LP positions summary (auto-fetched, only markets where user has LP)
#[derive(Drop, Serde)]
pub struct UserLpPositions {
    pub user: ContractAddress,
    pub total_lp_value: u256,
    pub total_positions: u32,
    pub positions: Span<MarketForLp>,
}

// ============================================================
// Markets Page Data (Single call for trading view)
// ============================================================

/// Market info for trading page
#[derive(Drop, Copy, Serde)]
pub struct MarketForTrading {
    pub pair_id: felt252,
    pub status: MarketStatus,
    pub collateral_token: ContractAddress,
    pub decimals: u8,
    // Current rates
    pub current_oracle_rate_bps: u256,
    pub fixed_side_rate_bps: u256, // What you'd get for Fixed
    pub floating_side_rate_bps: u256, // What you'd get for Floating
    // Liquidity info
    pub available_for_fixed: u256,
    pub available_for_floating: u256,
    pub total_liquidity: u256,
    // Market activity
    pub total_swaps_created: u256,
    pub active_swap_count: u256,
    // Term info
    pub swap_term_seconds: u64,
    pub min_notional: u256,
    pub max_notional_per_swap: u256,
    // Fee info
    pub swap_fee_bps: u256,
    pub early_exit_fee_bps: u256,
}

/// Complete data for markets/trading page
#[derive(Drop, Serde)]
pub struct MarketsPageData {
    pub markets: Span<MarketForTrading>,
    pub total_markets: u32,
    pub active_markets: u32,
    pub total_protocol_tvl: u256,
    pub total_active_swaps: u256,
}

// ============================================================
// Single Swap Detail Page
// ============================================================

/// Complete data for viewing a single swap position
#[derive(Drop, Serde)]
pub struct SwapDetailData {
    // Basic info
    pub swap_id: u256,
    pub pair_id: felt252,
    pub owner: ContractAddress,
    pub side: SwapSide,
    pub status: SwapStatus,
    // Position size
    pub notional: u256,
    pub collateral: u256,
    pub leverage_x100: u256,
    // Rates
    pub fixed_rate_bps: u256,
    pub current_floating_rate_bps: u256,
    pub spread_bps: SignedValue, // floating - fixed
    // PnL
    pub current_pnl: SignedValue,
    pub projected_pnl_at_expiry: SignedValue,
    pub breakeven_rate_bps: u256,
    // Health
    pub health_factor_bps: u256,
    pub required_margin: u256,
    pub is_liquidatable: bool,
    // Time
    pub start_time: u64,
    pub expiration_time: u64,
    pub elapsed_seconds: u64,
    pub remaining_seconds: u64,
    pub progress_bps: u256,
    // Exit scenarios
    pub early_exit_fee: u256,
    pub early_exit_payout: u256, // What you'd get if you exit now
    // Market context
    pub market_utilization_bps: u256,
    pub market_tvl: u256,
}

// ============================================================
// Batch Scenario Analysis
// ============================================================

/// Scenario result with more context
#[derive(Drop, Copy, Serde)]
pub struct DetailedScenario {
    pub rate_bps: u256,
    pub pnl: SignedValue,
    pub payout: u256, // Actual collateral returned
    pub return_percentage_bps: SignedValue // ROI in bps
}

/// Batch scenario analysis for a swap
#[derive(Drop, Serde)]
pub struct SwapScenarioAnalysis {
    pub swap_id: u256,
    pub current_rate_bps: u256,
    pub fixed_rate_bps: u256,
    pub breakeven_rate_bps: u256,
    pub scenarios: Span<DetailedScenario>,
}
