
#[starknet::interface]
pub trait IRateOracle<TContractState> {
    fn get_rate(self: @TContractState, base_token: felt252, quote_token: felt252) -> felt252;
    fn decimals(self: @TContractState) -> u8;
}