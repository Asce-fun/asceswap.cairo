/// # ERC6909 Component
/// The ERC6909 component provides an implementation of the Minimal Multi-Token standard described
/// in https://eips.ethereum.org/EIPS/eip-6909.
#[starknet::component]
pub mod ERC6909Component {
    use core::num::traits::{Bounded, Zero};
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_introspection::src5::SRC5Component::{
        InternalTrait as SRC5InternalTrait, SRC5Impl,
    };
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};
    use starknet::{ContractAddress, get_caller_address};
    use crate::interfaces::erc6909 as interface;

    #[storage]
    pub struct Storage {
        ERC6909_balances: Map<(ContractAddress, u256), u256>,
        ERC6909_allowances: Map<(ContractAddress, ContractAddress, u256), u256>,
        ERC6909_operators: Map<(ContractAddress, ContractAddress), bool>,
    }

    #[event]
    #[derive(Drop, PartialEq, starknet::Event)]
    pub enum Event {
        Transfer: Transfer,
        Approval: Approval,
        OperatorSet: OperatorSet,
    }

    /// Emitted when `id` tokens are moved from address `from` to address `to`.
    #[derive(Drop, PartialEq, starknet::Event)]
    pub struct Transfer {
        pub caller: ContractAddress,
        #[key]
        pub sender: ContractAddress,
        #[key]
        pub receiver: ContractAddress,
        #[key]
        pub id: u256,
        pub amount: u256,
    }

    /// Emitted when the allowance of a `spender` for an `owner` is set by a call
    /// to `approve` over `id`
    #[derive(Drop, PartialEq, starknet::Event)]
    pub struct Approval {
        #[key]
        pub owner: ContractAddress,
        #[key]
        pub spender: ContractAddress,
        #[key]
        pub id: u256,
        pub amount: u256,
    }

    /// Emitted when `account` enables or disables (`approved`) `spender` to manage
    /// all of its assets.
    #[derive(Drop, PartialEq, starknet::Event)]
    pub struct OperatorSet {
        #[key]
        pub owner: ContractAddress,
        #[key]
        pub spender: ContractAddress,
        pub approved: bool,
    }

    pub mod Errors {
        pub const INSUFFICIENT_BALANCE: felt252 = 'ERC6909: insufficient balance';
        pub const INSUFFICIENT_ALLOWANCE: felt252 = 'ERC6909: insufficient allowance';
        pub const INVALID_APPROVER: felt252 = 'ERC6909: invalid approver';
        pub const INVALID_RECEIVER: felt252 = 'ERC6909: invalid receiver';
        pub const INVALID_SENDER: felt252 = 'ERC6909: invalid sender';
        pub const INVALID_SPENDER: felt252 = 'ERC6909: invalid spender';
    }

    //
    // Hooks
    //

    pub trait ERC6909HooksTrait<TContractState> {
        fn before_update(
            ref self: ComponentState<TContractState>,
            from: ContractAddress,
            recipient: ContractAddress,
            id: u256,
            amount: u256,
        ) {}

        fn after_update(
            ref self: ComponentState<TContractState>,
            from: ContractAddress,
            recipient: ContractAddress,
            id: u256,
            amount: u256,
        ) {}
    }

    #[embeddable_as(ERC6909Impl)]
    impl ERC6909<
        TContractState,
        +HasComponent<TContractState>,
        +SRC5Component::HasComponent<TContractState>,
        +ERC6909HooksTrait<TContractState>,
        +Drop<TContractState>,
    > of interface::IERC6909<ComponentState<TContractState>> {
        fn balance_of(
            self: @ComponentState<TContractState>, owner: ContractAddress, id: u256,
        ) -> u256 {
            self.ERC6909_balances.read((owner, id))
        }

        fn allowance(
            self: @ComponentState<TContractState>,
            owner: ContractAddress,
            spender: ContractAddress,
            id: u256,
        ) -> u256 {
            self.ERC6909_allowances.read((owner, spender, id))
        }

        fn is_operator(
            self: @ComponentState<TContractState>, owner: ContractAddress, spender: ContractAddress,
        ) -> bool {
            self.ERC6909_operators.read((owner, spender))
        }

        fn transfer(
            ref self: ComponentState<TContractState>,
            receiver: ContractAddress,
            id: u256,
            amount: u256,
        ) -> bool {
            let caller = get_caller_address();
            self._transfer(caller, receiver, id, amount);
            true
        }

        fn transfer_from(
            ref self: ComponentState<TContractState>,
            sender: ContractAddress,
            receiver: ContractAddress,
            id: u256,
            amount: u256,
        ) -> bool {
            let caller = get_caller_address();
            if sender != caller && !self.is_operator(sender, caller) {
                self._spend_allowance(sender, caller, id, amount);
            }
            self._transfer(sender, receiver, id, amount);
            true
        }

        fn approve(
            ref self: ComponentState<TContractState>,
            spender: ContractAddress,
            id: u256,
            amount: u256,
        ) -> bool {
            let caller = get_caller_address();
            self._approve(caller, spender, id, amount);
            true
        }

        fn set_operator(
            ref self: ComponentState<TContractState>, spender: ContractAddress, approved: bool,
        ) -> bool {
            let caller = get_caller_address();
            self._set_operator(caller, spender, approved);
            true
        }
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState,
        +HasComponent<TContractState>,
        impl SRC5: SRC5Component::HasComponent<TContractState>,
        impl Hooks: ERC6909HooksTrait<TContractState>,
        +Drop<TContractState>,
    > of InternalTrait<TContractState> {
        fn initializer(ref self: ComponentState<TContractState>) {
            let mut src5_component = get_dep_component_mut!(ref self, SRC5);
            src5_component.register_interface(interface::IERC6909_ID);
        }

        fn mint(
            ref self: ComponentState<TContractState>,
            receiver: ContractAddress,
            id: u256,
            amount: u256,
        ) {
            assert(receiver.is_non_zero(), Errors::INVALID_RECEIVER);
            self.update(Zero::zero(), receiver, id, amount);
        }

        fn burn(
            ref self: ComponentState<TContractState>,
            account: ContractAddress,
            id: u256,
            amount: u256,
        ) {
            assert(account.is_non_zero(), Errors::INVALID_SENDER);
            self.update(account, Zero::zero(), id, amount);
        }

        fn update(
            ref self: ComponentState<TContractState>,
            sender: ContractAddress,
            receiver: ContractAddress,
            id: u256,
            amount: u256,
        ) {
            Hooks::before_update(ref self, sender, receiver, id, amount);

            if (sender.is_non_zero()) {
                let sender_balance = self.ERC6909_balances.read((sender, id));
                assert(sender_balance >= amount, Errors::INSUFFICIENT_BALANCE);
                self.ERC6909_balances.write((sender, id), sender_balance - amount);
            }

            if (receiver.is_non_zero()) {
                let receiver_balance = self.ERC6909_balances.read((receiver, id));
                self.ERC6909_balances.write((receiver, id), receiver_balance + amount);
            }

            self.emit(Transfer { caller: get_caller_address(), sender, receiver, id, amount });

            Hooks::after_update(ref self, sender, receiver, id, amount);
        }

        fn _set_operator(
            ref self: ComponentState<TContractState>,
            owner: ContractAddress,
            spender: ContractAddress,
            approved: bool,
        ) {
            assert(owner.is_non_zero(), Errors::INVALID_APPROVER);
            assert(spender.is_non_zero(), Errors::INVALID_SPENDER);
            self.ERC6909_operators.write((owner, spender), approved);
            self.emit(OperatorSet { owner, spender, approved });
        }

        fn _spend_allowance(
            ref self: ComponentState<TContractState>,
            owner: ContractAddress,
            spender: ContractAddress,
            id: u256,
            amount: u256,
        ) {
            let current_allowance = self.ERC6909_allowances.read((owner, spender, id));
            if current_allowance != Bounded::MAX {
                assert(current_allowance >= amount, Errors::INSUFFICIENT_ALLOWANCE);
                self.ERC6909_allowances.write((owner, spender, id), current_allowance - amount);
            }
        }

        fn _approve(
            ref self: ComponentState<TContractState>,
            owner: ContractAddress,
            spender: ContractAddress,
            id: u256,
            amount: u256,
        ) {
            assert(owner.is_non_zero(), Errors::INVALID_APPROVER);
            assert(spender.is_non_zero(), Errors::INVALID_SPENDER);
            self.ERC6909_allowances.write((owner, spender, id), amount);
            self.emit(Approval { owner, spender, id, amount });
        }

        fn _transfer(
            ref self: ComponentState<TContractState>,
            sender: ContractAddress,
            receiver: ContractAddress,
            id: u256,
            amount: u256,
        ) {
            assert(sender.is_non_zero(), Errors::INVALID_SENDER);
            assert(receiver.is_non_zero(), Errors::INVALID_RECEIVER);
            self.update(sender, receiver, id, amount);
        }
    }
}

/// An empty implementation of the ERC6909 hooks to be used in basic ERC6909 preset contracts.
pub impl ERC6909HooksEmptyImpl<
    TContractState,
> of ERC6909Component::ERC6909HooksTrait<TContractState> {}
