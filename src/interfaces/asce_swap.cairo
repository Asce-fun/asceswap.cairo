use starknet::ContractAddress;
use crate::types::asce_swap::{
    HealthStatus, LpAnalytics, MarketPair, MarketParams, PoolAnalytics, ProtocolConfig,
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


    /// Deposit assets into a market pool, mint shares to receiver
    fn deposit(
        ref self: TContractState, pair_id: felt252, assets: u256, receiver: ContractAddress,
    ) -> u256;

    /// Mint exact shares, pull required assets from caller
    fn mint(
        ref self: TContractState, pair_id: felt252, shares: u256, receiver: ContractAddress,
    ) -> u256;

    /// Redeem shares from a market pool, send assets to receiver
    fn redeem(
        ref self: TContractState, pair_id: felt252, shares: u256, receiver: ContractAddress,
    ) -> u256;

    /// Withdraw exact assets, burn required shares from caller
    fn withdraw(
        ref self: TContractState, pair_id: felt252, assets: u256, receiver: ContractAddress,
    ) -> u256;

    /// Total assets held by the vault for a market
    fn total_assets(self: @TContractState, pair_id: felt252) -> u256;

    /// Exchange rate for LP shares
    fn exchange_rate(self: @TContractState, pair_id: felt252) -> u256;

    /// Convert assets to shares
    fn convert_to_shares(self: @TContractState, pair_id: felt252, assets: u256) -> u256;

    /// Convert shares to assets
    fn convert_to_assets(self: @TContractState, pair_id: felt252, shares: u256) -> u256;

    /// Preview deposit: how many shares for a given deposit
    fn preview_deposit(self: @TContractState, pair_id: felt252, assets: u256) -> u256;

    /// Preview mint: how many assets needed to mint exact shares (rounds up)
    fn preview_mint(self: @TContractState, pair_id: felt252, shares: u256) -> u256;

    /// Preview redeem: how many assets for burning shares
    fn preview_redeem(self: @TContractState, pair_id: felt252, shares: u256) -> u256;

    /// Preview withdraw: how many shares needed to withdraw exact assets (rounds up)
    fn preview_withdraw(self: @TContractState, pair_id: felt252, assets: u256) -> u256;

    /// Max deposit (no hard cap)
    fn max_deposit(self: @TContractState, pair_id: felt252) -> u256;

    /// Max mint (no hard cap)
    fn max_mint(self: @TContractState, pair_id: felt252) -> u256;

    /// Max assets owner can withdraw
    fn max_withdraw(self: @TContractState, owner: ContractAddress, pair_id: felt252) -> u256;

    /// Max shares owner can redeem
    fn max_redeem(self: @TContractState, owner: ContractAddress, pair_id: felt252) -> u256;

    /// Buy a new swap position (caller pays, receiver gets the position NFT)
    fn buy_swap(
        ref self: TContractState,
        pair_id: felt252,
        side: SwapSide,
        notional: u256,
        collateral: u256,
        max_rate_bps: u256,
        swap_term: u64,
        receiver: ContractAddress,
    ) -> u256;

    /// Settle an expired swap
    fn settle_swap(ref self: TContractState, swap_id: u256);

    /// Claim payout from a settled swap (NFT owner only)
    fn claim(ref self: TContractState, swap_id: u256);

    /// Early exit from a swap (before expiration)
    fn early_exit(ref self: TContractState, swap_id: u256);

    // === Market Views ===

    /// Get market pair info
    fn get_market(self: @TContractState, pair_id: felt252) -> MarketPair;

    /// Get swap info
    fn get_swap(self: @TContractState, swap_id: u256) -> Swap;

    /// Get swap quote (preview rate and requirements for a given term)
    fn get_swap_quote(
        self: @TContractState, pair_id: felt252, side: SwapSide, notional: u256, swap_term: u64,
    ) -> SwapQuote;

    /// Get health status of a swap
    fn get_health_status(self: @TContractState, swap_id: u256) -> HealthStatus;

    /// Get pool analytics
    fn get_pool_analytics(self: @TContractState, pair_id: felt252) -> PoolAnalytics;

    /// Get current TWA rate for a swap
    fn get_current_twa(self: @TContractState, swap_id: u256) -> u256;

    /// Get protocol config
    fn get_protocol_config(self: @TContractState) -> ProtocolConfig;

    /// Get next swap ID
    fn get_next_swap_id(self: @TContractState) -> u256;

    // === Analytics ===

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

    fn poke_rate_index(ref self: TContractState, pair_id: felt252);

    /// Whitelist a token for use as collateral
    fn whitelist_token(ref self: TContractState, token: ContractAddress);

    /// Remove a token from whitelist
    fn de_whitelist_token(ref self: TContractState, token: ContractAddress);

    /// Check if a token is whitelisted
    fn is_token_whitelisted(self: @TContractState, token: ContractAddress) -> bool;
}
