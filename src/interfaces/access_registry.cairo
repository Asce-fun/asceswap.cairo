use starknet::ContractAddress;
#[starknet::interface]
pub trait IAccessExtra<TContractState> {
    fn set_role_admin(ref self: TContractState, role: felt252, admin_role: felt252);
    fn initialize(ref self: TContractState, admin: ContractAddress);
    fn set_role_from_admin(ref self: TContractState, role: felt252, owner: ContractAddress);
}
