#[starknet::component]
pub mod SecurityComponent {
    use core::num::traits::Zero;

    // access control
    use openzeppelin::interfaces::accesscontrol::{
        IAccessControlDispatcher, IAccessControlDispatcherTrait,
    };
    use openzeppelin_security::PausableComponent::{
        InternalTrait as PausableInternalTrait, PausableImpl,
    };
    use openzeppelin_security::ReentrancyGuardComponent::InternalTrait as ReentrancyGuardTrait;
    use openzeppelin_security::{PausableComponent, ReentrancyGuardComponent};

    // standard security components
    use openzeppelin_upgrades::UpgradeableComponent;
    use openzeppelin_upgrades::UpgradeableComponent::InternalTrait as UpgradeableInternalTrait;
    use starknet::contract_address::contract_address_const;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ClassHash, ContractAddress, get_caller_address};
    use crate::helpers::roles::Roles;
    use crate::interfaces::security::ISecurity;


    pub mod Errors {
        pub const INVALID_PERMISSIONS: felt252 = 'Invalid permissions';
        pub const PAUSED: felt252 = 'Contract is paused';
        pub const INVALID_CALLDATA: felt252 = 'Invalid call data';
    }


    #[storage]
    pub struct Storage {
        accessControl: IAccessControlDispatcher,
    }

    #[embeddable_as(SecurityImpl)]
    impl Security<
        TContractState,
        +HasComponent<TContractState>,
        impl Upgradeable: UpgradeableComponent::HasComponent<TContractState>,
        impl Pausable: PausableComponent::HasComponent<TContractState>,
        impl RenAck: ReentrancyGuardComponent::HasComponent<TContractState>,
        +Drop<TContractState>,
    > of ISecurity<ComponentState<TContractState>> {
        fn upgrade_class_hash(ref self: ComponentState<TContractState>, new_class_hash: ClassHash) {
            self.assert_admin_role();
            let mut upgradeable = get_dep_component_mut!(ref self, Upgradeable);
            upgradeable.upgrade(new_class_hash);
        }

        fn pause(ref self: ComponentState<TContractState>) {
            self.assert_admin_role();
            let mut pausable = get_dep_component_mut!(ref self, Pausable);
            pausable.pause();
        }

        fn unpause(ref self: ComponentState<TContractState>) {
            self.assert_admin_role();
            let mut pausable = get_dep_component_mut!(ref self, Pausable);
            pausable.unpause();
        }

        fn is_paused(self: @ComponentState<TContractState>) -> bool {
            let pausable = get_dep_component!(self, Pausable);
            pausable.is_paused()
        }

        fn set_access_control(
            ref self: ComponentState<TContractState>, access_control: ContractAddress,
        ) {
            assert(!access_control.is_zero(), Errors::INVALID_CALLDATA);
            self.assert_admin_role();
            self._set_access_control(access_control);
        }

        fn get_access_control(self: @ComponentState<TContractState>) -> ContractAddress {
            let access_control = self.accessControl.read();
            access_control.contract_address
        }
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState,
        +HasComponent<TContractState>,
        impl Upgradeable: UpgradeableComponent::HasComponent<TContractState>,
        impl Pausable: PausableComponent::HasComponent<TContractState>,
        impl RenAck: ReentrancyGuardComponent::HasComponent<TContractState>,
        +Drop<TContractState>,
    > of InternalTrait<TContractState> {
        fn assert_admin_role(self: @ComponentState<TContractState>) {
            self.assert_role(Roles::ADMIN_ROLE);
        }


        fn assert_role(self: @ComponentState<TContractState>, role: felt252) {
            let caller = get_caller_address();
            let accessControl: IAccessControlDispatcher = self.accessControl.read();
            let hasRole = accessControl.has_role(role, caller);
            assert(hasRole, Errors::INVALID_PERMISSIONS);
        }

        /// Start re-entrancy lock
        fn _renack_start(ref self: ComponentState<TContractState>) {
            let mut renAck = get_dep_component_mut!(ref self, RenAck);
            renAck.start();
        }

        /// Stop re-entrancy lock
        fn _renack_end(ref self: ComponentState<TContractState>) {
            let mut renAck = get_dep_component_mut!(ref self, RenAck);
            renAck.end();
        }

        fn _set_access_control(
            ref self: ComponentState<TContractState>, accessControl: ContractAddress,
        ) {
            self.accessControl.write(IAccessControlDispatcher { contract_address: accessControl });
        }

        fn assert_not_paused(self: @ComponentState<TContractState>) {
            let pausable = get_dep_component!(self, Pausable);
            assert(!pausable.is_paused(), Errors::PAUSED);
        }
    }
}
