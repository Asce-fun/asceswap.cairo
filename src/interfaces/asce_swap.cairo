use starknet::ContractAddress;
use crate::types::asce_swap::{
    HealthStatus, LpPosition, MarketPair, MarketParams, PoolAnalytics, ProtocolConfig, Swap,
    SwapQuote, SwapSide,
};

#[starknet::interface]
pub trait IAsceSwap<TContractState> {
    /// Create a new market pair
    fn create_market_pair(
        ref self: TContractState,
        rate_oracle: ContractAddress,
        collateral_token: ContractAddress,
        curator: ContractAddress,
        params: MarketParams,
    ) -> felt252;

    /// Pause a market
    fn pause_market(ref self: TContractState, pair_id: felt252);

    ///Market Creation Process
    fn set_premission_less_flag(ref self: TContractState, flag: bool);

    /// Unpause a market
    fn unpause_market(ref self: TContractState, pair_id: felt252);

    /// Update market parameters
    fn update_market_params(ref self: TContractState, pair_id: felt252, params: MarketParams);

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

    /// Add collateral to an existing swap
    fn add_collateral(ref self: TContractState, swap_id: u256, amount: u256);

    /// Get market pair info
    fn get_market(self: @TContractState, pair_id: felt252) -> MarketPair;

    /// Get swap info
    fn get_swap(self: @TContractState, swap_id: u256) -> Swap;

    /// Get swap quote (preview rate and requirements)
    fn get_swap_quote(
        self: @TContractState, pair_id: felt252, side: SwapSide, notional: u256,
    ) -> SwapQuote;

    /// Get health status of a swap
    fn get_health_status(self: @TContractState, swap_id: u256) -> HealthStatus;

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
}
