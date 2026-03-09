#[starknet::contract]
pub mod PositionManager {
    use core::num::traits::Zero;
    use openzeppelin::interfaces::accesscontrol::{
        IAccessControlDispatcher, IAccessControlDispatcherTrait,
    };
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_token::erc721::ERC721Component;
    use openzeppelin_upgrades::UpgradeableComponent;
    use openzeppelin_upgrades::UpgradeableComponent::InternalTrait as UpgradeableInternalTrait;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ClassHash, ContractAddress, get_caller_address};
    use crate::helpers::errors::Errors;
    use crate::helpers::roles::Roles;
    use crate::interfaces::position_manager::IPositionManager;

    component!(path: ERC721Component, storage: erc721, event: ERC721Event);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    #[abi(embed_v0)]
    impl ERC721MixinImpl = ERC721Component::ERC721MixinImpl<ContractState>;
    impl ERC721InternalImpl = ERC721Component::InternalImpl<ContractState>;

    #[storage]
    pub struct Storage {
        #[substorage(v0)]
        erc721: ERC721Component::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        asceswap_address: ContractAddress,
        access_control: IAccessControlDispatcher,
        token_uris: Map<u256, ByteArray>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        ERC721Event: ERC721Component::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, access_registry: ContractAddress, asceswap: ContractAddress,
    ) {
        assert(!access_registry.is_zero(), Errors::ZERO_ADDRESS);
        self.erc721.initializer("AsceSwap Position", "ASCEWAP", "");
        self.asceswap_address.write(asceswap);
        self.access_control.write(IAccessControlDispatcher { contract_address: access_registry });
    }

    #[abi(embed_v0)]
    impl PositionManagerImpl of IPositionManager<ContractState> {
        fn mint(ref self: ContractState, to: ContractAddress, token_id: u256) {
            self._assert_asceswap();
            self.erc721.mint(to, token_id);
        }

        fn burn(ref self: ContractState, token_id: u256) {
            self._assert_asceswap();
            self.erc721.burn(token_id);
        }

        fn set_asceswap(ref self: ContractState, asceswap: ContractAddress) {
            self._assert_admin();
            self.asceswap_address.write(asceswap);
        }

        fn get_asceswap(self: @ContractState) -> ContractAddress {
            self.asceswap_address.read()
        }

        fn set_token_uri(ref self: ContractState, token_id: u256, uri: ByteArray) {
            // Only asceswap contract or admin can set URI
            let caller = get_caller_address();
            let is_asceswap = caller == self.asceswap_address.read();
            let is_admin = self.access_control.read().has_role(Roles::ADMIN_ROLE, caller);
            assert(is_asceswap || is_admin, Errors::UNAUTHORIZED);

            self.token_uris.write(token_id, uri);
        }

        fn get_token_uri(self: @ContractState, token_id: u256) -> ByteArray {
            self.token_uris.read(token_id)
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _assert_asceswap(self: @ContractState) {
            assert(get_caller_address() == self.asceswap_address.read(), Errors::UNAUTHORIZED);
        }

        fn _assert_admin(self: @ContractState) {
            let caller = get_caller_address();
            let access_control = self.access_control.read();
            assert(access_control.has_role(Roles::ADMIN_ROLE, caller), Errors::UNAUTHORIZED);
        }
    }

    fn upgrade_class_hash(ref self: ContractState, new_class_hash: ClassHash) {
        self._assert_admin();
        self.upgradeable.upgrade(new_class_hash);
    }

    impl ERC721HooksImpl of ERC721Component::ERC721HooksTrait<ContractState> {
        fn before_update(
            ref self: ERC721Component::ComponentState<ContractState>,
            to: ContractAddress,
            token_id: u256,
            auth: ContractAddress,
        ) {}

        fn after_update(
            ref self: ERC721Component::ComponentState<ContractState>,
            to: ContractAddress,
            token_id: u256,
            auth: ContractAddress,
        ) {}
    }
}
