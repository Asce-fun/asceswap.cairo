use starknet::ContractAddress;
use crate::types::asce_swap::{
    HealthStatus, LpAnalytics, LpPosition, MarketPair, MarketParams, PoolAnalytics, ProtocolConfig,
    ScenarioResult, Swap, SwapAnalytics, SwapQuote, SwapSide, UserDashboard, UserLpSummary,
    UserSwapSummary,
};

#[starknet::interface]
pub trait IAsceSwap<TContractState> {
    /// Create a new market pair with initial liquidity
    fn create_market_pair(
        ref self: TContractState,
        rate_oracle: ContractAddress,
        collateral_token: ContractAddress,
        curator: ContractAddress,
        params: MarketParams,
        initial_liquidity_amount: u256,
    ) -> (felt252, u256);

    /// Pause a market
    fn pause_market(ref self: TContractState, pair_id: felt252);

    ///Market Creation Process
    fn set_premission_less_flag(ref self: TContractState, flag: bool);

    /// Unpause a market
    fn unpause_market(ref self: TContractState, pair_id: felt252);


    /// Update protocol config
    fn update_protocol_config(ref self: TContractState, config: ProtocolConfig);

    /// Withdraw accumulated protocol fees
    fn withdraw_protocol_fees(
        ref self: TContractState, token: ContractAddress, amount: u256, recipient: ContractAddress,
    );

    /// Deposit collateral to LP pool
    fn supply_lp_collateral(ref self: TContractState, pair_id: felt252, amount: u256) -> u256;

    /// Withdraw collateral from LP pool
    fn withdraw_lp_collateral(ref self: TContractState, pair_id: felt252, shares: u256) -> u256;

    /// Buy a new swap position
    fn buy_swap(
        ref self: TContractState,
        pair_id: felt252,
        side: SwapSide,
        notional: u256,
        collateral: u256,
        max_rate_bps: u256,
    ) -> u256;

    /// Settle an expired swap
    fn settle_swap(ref self: TContractState, swap_id: u256);

    /// Early exit from a swap (before expiration)
    fn early_exit(ref self: TContractState, swap_id: u256);

    /// Liquidate an unhealthy position
    fn liquidate(ref self: TContractState, swap_id: u256);

    /// Get market pair info
    fn get_market(self: @TContractState, pair_id: felt252) -> MarketPair;

    /// Get swap info
    fn get_swap(self: @TContractState, swap_id: u256) -> Swap;

    /// Get swap quote (preview rate and requirements)
    fn get_swap_quote(
        self: @TContractState, pair_id: felt252, side: SwapSide, notional: u256,
    ) -> SwapQuote;

    fn balance_of_lp(self: @TContractState, lp: ContractAddress, pair_id: felt252) -> u256;

    fn is_cooldown_met(self: @TContractState, lp: ContractAddress, pair_id: felt252) -> bool;

    /// Get health status of a swap
    fn get_health_status(self: @TContractState, swap_id: u256) -> HealthStatus;

    fn exchange_rate_for_lp(self: @TContractState, pair_id: felt252) -> u256;
    fn convert_to_shares_for_lp(self: @TContractState, assets: u256, pair_id: felt252) -> u256;
    fn convert_to_assets_for_lp(self: @TContractState, shares: u256, pair_id: felt252) -> u256;


    fn preview_deposit_for_lp(self: @TContractState, assets: u256, pair_id: felt252) -> u256;
    fn preview_withdraw_for_lp(self: @TContractState, assets: u256, pair_id: felt252) -> u256;

    /// Get LP position
    fn get_lp_position(self: @TContractState, lp: ContractAddress, pair_id: felt252) -> LpPosition;

    /// Get pool analytics
    fn get_pool_analytics(self: @TContractState, pair_id: felt252) -> PoolAnalytics;

    /// Get current TWA rate for a swap
    fn get_current_twa(self: @TContractState, swap_id: u256) -> u256;

    /// Get protocol config
    fn get_protocol_config(self: @TContractState) -> ProtocolConfig;

    /// Get next swap ID
    fn get_next_swap_id(self: @TContractState) -> u256;


    /// Get comprehensive swap analytics (for frontend dashboard)
    fn get_swap_analytics(self: @TContractState, swap_id: u256) -> SwapAnalytics;

    /// Get LP position analytics
    fn get_lp_analytics(
        self: @TContractState, lp: ContractAddress, pair_id: felt252,
    ) -> LpAnalytics;

    /// Preview PnL at different rate scenarios
    /// Returns projected PnL if rate goes to each of the provided rates
    fn preview_swap_scenarios(
        self: @TContractState, swap_id: u256, rate_scenarios_bps: Span<u256>,
    ) -> Span<ScenarioResult>;

    /// Get breakeven rate for a swap (the rate at which PnL = 0)
    fn get_breakeven_rate(self: @TContractState, swap_id: u256) -> u256;

    /// Get summary of multiple swaps (pass swap IDs from indexer/events)
    fn get_user_swaps_summary(self: @TContractState, swap_ids: Span<u256>) -> Span<UserSwapSummary>;

    /// Get aggregated dashboard stats from provided swap IDs and market IDs
    fn get_user_dashboard(
        self: @TContractState,
        user: ContractAddress,
        swap_ids: Span<u256>,
        lp_pair_ids: Span<felt252>,
    ) -> UserDashboard;

    /// Get LP summary across multiple markets
    fn get_user_lp_summary(
        self: @TContractState, user: ContractAddress, pair_ids: Span<felt252>,
    ) -> Span<UserLpSummary>;

    // ============================================================
    // TODO [MAINNET]: Replace with off-chain indexer
    // These use on-chain arrays which don't scale well.
    // ============================================================
    /// Get all swap IDs owned by a user
    fn get_user_swap_ids(self: @TContractState, user: ContractAddress) -> Span<u256>;

    /// Get all LP pair IDs where user has a position
    fn get_user_lp_pair_ids(self: @TContractState, user: ContractAddress) -> Span<felt252>;

    /// Get count of user's swaps
    fn get_user_swap_count(self: @TContractState, user: ContractAddress) -> u32;

    /// Get count of user's LP positions
    fn get_user_lp_count(self: @TContractState, user: ContractAddress) -> u32;
    fn poke_rate_index(ref self: TContractState, pair_id: felt252);

    /// Whitelist a token for use as collateral
    fn whitelist_token(ref self: TContractState, token: ContractAddress);

    /// Remove a token from whitelist
    fn de_whitelist_token(ref self: TContractState, token: ContractAddress);

    /// Check if a token is whitelisted
    fn is_token_whitelisted(self: @TContractState, token: ContractAddress) -> bool;
}
