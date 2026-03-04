use starknet::ContractAddress;

#[starknet::interface]
pub trait IPositionManager<TContractState> {
    /// Mint a position NFT (only callable by authorized Asceswap contract)
    fn mint(ref self: TContractState, to: ContractAddress, token_id: u256);
    /// Burn a position NFT (only callable by authorized Asceswap contract)
    fn burn(ref self: TContractState, token_id: u256);
    /// Set the authorized Asceswap contract (admin only)
    fn set_asceswap(ref self: TContractState, asceswap: ContractAddress);
    /// Get the authorized Asceswap contract
    fn get_asceswap(self: @TContractState) -> ContractAddress;
}

#[starknet::interface]
pub trait IERC721Owner<TContractState> {
    fn owner_of(self: @TContractState, token_id: u256) -> ContractAddress;
}


