#[starknet::contract]
pub mod AccessRgistry {
    use openzeppelin::access::accesscontrol::accesscontrol::AccessControlComponent;

    // access control
    use openzeppelin::interfaces::accesscontrol::{
        IAccessControlDispatcher, IAccessControlDispatcherTrait,
    };

    // Upgradable
    use openzeppelin::interfaces::upgrades::IUpgradeable;
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin_upgrades::UpgradeableComponent;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ClassHash, ContractAddress, get_caller_address};
    use crate::helpers::roles::Roles;
    use crate::interfaces::access_registry::IAccessExtra;

    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);
    component!(path: AccessControlComponent, storage: accessControl, event: AccessControlEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    // internal impls
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;
    impl AccessControlInternalImpl = AccessControlComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl AccessControlImpl =
        AccessControlComponent::AccessControlImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        #[substorage(v0)]
        accessControl: AccessControlComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        initialized: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
    }

    /// @notice Initializer function required during for initial deployment of contract.
    /// @param superAdmin
    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress) {
        self.initialize(admin);
    }

    ////////////////////////////////
    /// External Functions/////////
    //////////////////////////////

    // Upgradable
    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.accessControl.assert_only_role(Roles::ADMIN_ROLE);
            self.upgradeable.upgrade(new_class_hash);
        }
    }

    #[abi(embed_v0)]
    impl AccessExtraImpl of IAccessExtra<ContractState> {
        fn initialize(ref self: ContractState, admin: ContractAddress) {
            assert(!self.initialized.read(), 'Initializable: is initialized');
            self.initialized.write(true);

            // Access control
            self.accessControl.initializer();

            // grant super admin role
            self.accessControl._grant_role(Roles::ADMIN_ROLE, admin);

            // set all roles admin as super admin
            self.accessControl.set_role_admin(Roles::ADMIN_ROLE, Roles::ADMIN_ROLE);
        }

        fn set_role_admin(ref self: ContractState, role: felt252, admin_role: felt252) {
            self.accessControl.assert_only_role(Roles::ADMIN_ROLE);
            self.accessControl.set_role_admin(role, admin_role);
        }
    }
}
