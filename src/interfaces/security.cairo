use starknet::{ClassHash, ContractAddress};

#[starknet::interface]
pub trait ISecurity<TState> {
    fn upgrade_class_hash(ref self: TState, new_class_hash: ClassHash);
    fn pause(ref self: TState);
    fn unpause(ref self: TState);
    fn is_paused(self: @TState) -> bool;
    fn set_access_control(ref self: TState, access_control: ContractAddress);
}
