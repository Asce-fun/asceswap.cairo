use starknet::ContractAddress;
use crate::types::asce_swap::{SettlementResult, SettlementType};
use crate::types::extension::{LiquidityParams, MarketCreationParams, SwapOpenParams};

#[starknet::interface]
pub trait IExtension<TContractState> {
    fn before_market_creation(
        ref self: TContractState, caller: ContractAddress, creation_params: MarketCreationParams,
    );

    fn after_market_creation(
        ref self: TContractState,
        caller: ContractAddress,
        pair_id: felt252,
        creation_params: MarketCreationParams,
        shares_minted: u256,
    );

    fn before_swap_open(
        ref self: TContractState, caller: ContractAddress, pair_id: felt252, params: SwapOpenParams,
    );

    fn after_swap_open(
        ref self: TContractState,
        caller: ContractAddress,
        pair_id: felt252,
        params: SwapOpenParams,
        swap_id: u256,
    );

    fn before_swap_close(
        ref self: TContractState,
        caller: ContractAddress,
        pair_id: felt252,
        swap_id: u256,
        settlement_type: SettlementType,
    );

    fn after_swap_close(
        ref self: TContractState,
        caller: ContractAddress,
        pair_id: felt252,
        swap_id: u256,
        settlement_type: SettlementType,
        settlement_result: SettlementResult,
    );

    fn before_add_liquidity(
        ref self: TContractState,
        caller: ContractAddress,
        pair_id: felt252,
        params: LiquidityParams,
    );

    fn after_add_liquidity(
        ref self: TContractState,
        caller: ContractAddress,
        pair_id: felt252,
        params: LiquidityParams,
    );

    fn before_remove_liquidity(
        ref self: TContractState,
        caller: ContractAddress,
        pair_id: felt252,
        params: LiquidityParams,
    );

    fn after_remove_liquidity(
        ref self: TContractState,
        caller: ContractAddress,
        pair_id: felt252,
        params: LiquidityParams,
    );
}
