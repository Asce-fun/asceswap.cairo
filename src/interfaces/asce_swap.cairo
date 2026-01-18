use crate::types::asce_swap::{Market, MarketParams, Swap};

#[starknet::interface]
pub trait IAsceSwap<TContractState> {
    // (u256, u256) = (market_id1, market_id2) = (fixed,float)
    fn create_market_pair(ref self: TContractState, params: MarketParams) -> (u256, u256);

    fn pause_market(ref self: TContractState, market_id: u256);

    fn unpause_market(ref self: TContractState, market_id: u256);

    //LP functions
    fn supply_lp_collateral(ref self: TContractState, market_id: u256, amount: u256);

    fn withdraw_lp_collateral(ref self: TContractState, market_id: u256, shares: u256);

    //swap functions
    fn open_swap(ref self: TContractState, market_id: u256, notional_amount: u256) -> u256;

    fn settle_swap(ref self: TContractState, swap_id: u256);
}
