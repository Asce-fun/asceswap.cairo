use starknet::ContractAddress;
use crate::types::analytics::{
    DashboardPageData, LpPageData, MarketsPageData, SwapDetailData, SwapScenarioAnalysis,
    UserLpPositions,
};

#[starknet::interface]
pub trait IAnalytics<TContractState> {
    // ============================================================
    // Page-Level Aggregation (Single call per page)
    // ============================================================

    /// Get complete user dashboard with automatic ID discovery
    /// Just pass the user address - fetches all swap IDs and LP positions automatically
    /// This is the primary function for user dashboard
    fn get_user_dashboard_full(self: @TContractState, user: ContractAddress) -> DashboardPageData;

    /// Get all data needed for user dashboard page (with explicit IDs)
    /// Use this if you already have the IDs from an indexer
    fn get_dashboard_page(
        self: @TContractState,
        user: ContractAddress,
        swap_ids: Span<u256>,
        lp_pair_ids: Span<felt252>,
    ) -> DashboardPageData;

    /// Get all data needed for LP page
    /// Shows all markets where user can provide liquidity
    fn get_lp_page(
        self: @TContractState, user: ContractAddress, market_pair_ids: Span<felt252>,
    ) -> LpPageData;

    /// Get user's LP positions automatically (only markets where user has LP)
    /// Just pass the user address - fetches LP pair IDs automatically
    fn get_user_lp_positions(self: @TContractState, user: ContractAddress) -> UserLpPositions;

    /// Get all data needed for markets/trading page
    /// Shows all available markets for opening swaps
    fn get_markets_page(self: @TContractState, market_pair_ids: Span<felt252>) -> MarketsPageData;

    // ============================================================
    // Detail Views
    // ============================================================

    /// Get complete data for a single swap position detail page
    fn get_swap_detail(self: @TContractState, swap_id: u256) -> SwapDetailData;

    /// Get scenario analysis for a swap with custom rate points
    fn get_swap_scenarios(
        self: @TContractState, swap_id: u256, rate_scenarios_bps: Span<u256>,
    ) -> SwapScenarioAnalysis;

    // ============================================================
    // Protocol Stats (for landing page / overview)
    // ============================================================

    /// Get protocol-wide statistics
    fn get_protocol_stats(
        self: @TContractState, market_pair_ids: Span<felt252>,
    ) -> (u256, u256, u32, u32); // (total_tvl, total_volume, active_markets, active_swaps)
}
