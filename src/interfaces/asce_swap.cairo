use starknet::{ClassHash, ContractAddress};
use crate::types::asce_swap::{
    LiquidationSide, LpPosition, Market, MarketLiquidity, MarketParams, ProtocolFees, RateIndex,
    SignedValue, Swap,
};

/// AsceSwap protocol interface
#[starknet::interface]
pub trait IAsceSwap<TContractState> {
    /// Create a paired market (fixed + floating)
    fn create_market_pair(
        ref self: TContractState, params: MarketParams, curator: ContractAddress,
    ) -> (u256, u256); // (fixed_market_id, floating_market_id)

    /// Pause a market
    fn pause_market(ref self: TContractState, market_id: u256);

    /// Unpause a market
    fn unpause_market(ref self: TContractState, market_id: u256);


    /// Supply collateral as LP
    fn supply_lp_collateral(
        ref self: TContractState, market_id: u256, amount: u256,
    ) -> u256; // shares minted

    /// Withdraw LP collateral
    fn withdraw_lp_collateral(
        ref self: TContractState, market_id: u256, shares: u256,
    ) -> u256; // amount withdrawn


    /// Buy a swap position (mints NFT)
    fn buy_swap(
        ref self: TContractState, market_id: u256, notional_amount: u256, collateral_amount: u256,
    ) -> u256; // swap_id (also NFT token_id)

    /// Settle an expired swap
    fn settle_swap(ref self: TContractState, swap_id: u256);

    /// Exit a swap early (with penalty)
    fn exit_early(ref self: TContractState, swap_id: u256);

    /// Liquidate an unhealthy position
    fn liquidate(ref self: TContractState, swap_id: u256) -> LiquidationSide;


    /// Batch settle multiple expired swaps
    fn batch_settle(ref self: TContractState, swap_ids: Array<u256>);

    /// Batch liquidate multiple positions
    fn batch_liquidate(ref self: TContractState, swap_ids: Array<u256>) -> Array<LiquidationSide>;


    /// Set protocol fees
    fn set_protocol_fees(ref self: TContractState, fees: ProtocolFees);

    /// Set treasury address
    fn set_treasury(ref self: TContractState, treasury: ContractAddress);

    /// Withdraw accumulated protocol fees
    fn withdraw_protocol_fees(ref self: TContractState, token: ContractAddress, amount: u256);

    /// Get market details
    fn get_market(self: @TContractState, market_id: u256) -> Market;

    /// Get market liquidity info
    fn get_market_liquidity(self: @TContractState, market_id: u256) -> MarketLiquidity;

    /// Get current swap rate for a given notional
    fn get_current_swap_rate(self: @TContractState, market_id: u256, notional_amount: u256) -> u256;

    /// Get swap details
    fn get_swap(self: @TContractState, swap_id: u256) -> Swap;

    /// Get swap PnL
    fn get_swap_pnl(self: @TContractState, swap_id: u256) -> SignedValue;

    /// Get swap health factor (bps, e.g., 8500 = 85%)
    fn get_swap_health(self: @TContractState, swap_id: u256) -> u256;

    /// Check if swap is liquidatable
    fn is_liquidatable(self: @TContractState, swap_id: u256) -> bool;

    /// Get LP position
    fn get_lp_position(self: @TContractState, lp: ContractAddress, market_id: u256) -> LpPosition;

    /// Get LP position value in USD
    fn get_lp_value(self: @TContractState, lp: ContractAddress, market_id: u256) -> u256;

    /// Get protocol fees config
    fn get_protocol_fees(self: @TContractState) -> ProtocolFees;

    /// Get treasury address
    fn get_treasury(self: @TContractState) -> ContractAddress;

    /// Get rate index for a market
    fn get_rate_index(self: @TContractState, market_id: u256) -> RateIndex;

    /// Check if protocol is paused
    fn is_protocol_paused(self: @TContractState) -> bool;

    /// Get next market ID
    fn get_next_market_id(self: @TContractState) -> u256;

    /// Get next swap ID
    fn get_next_swap_id(self: @TContractState) -> u256;

}
