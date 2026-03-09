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
    /// Set IPFS metadata URI for a specific token (admin or asceswap only)
    fn set_token_uri(ref self: TContractState, token_id: u256, uri: ByteArray);
    /// Get IPFS metadata URI for a token
    fn get_token_uri(self: @TContractState, token_id: u256) -> ByteArray;
}

#[starknet::interface]
pub trait IERC721Owner<TContractState> {
    fn owner_of(self: @TContractState, token_id: u256) -> ContractAddress;
}

