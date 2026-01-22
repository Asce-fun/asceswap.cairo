#[starknet::contract]
pub mod Asceswap {
    use core::num::traits::Zero;
    use openzeppelin_access::ownable::OwnableComponent;
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_security::PausableComponent::{
        InternalTrait as PausableInternalTrait, PausableImpl,
    };
    use openzeppelin_security::ReentrancyGuardComponent::InternalTrait as ReentrancyGuardTrait;
    use openzeppelin_security::{PausableComponent, ReentrancyGuardComponent};
    use openzeppelin_token::erc721::{ERC721Component, ERC721HooksEmptyImpl};
    use openzeppelin_upgrades::UpgradeableComponent;

    // use openzeppelin_
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{
        ClassHash, ContractAddress, contract_address_const, get_block_timestamp, get_caller_address,
    };
    use crate::components::Security::SecurityComponent;
    use crate::helpers::constants::Constants;
    use crate::helpers::errors::Errors;
    use crate::interfaces::asce_swap::IAsceSwap;
    use crate::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use crate::interfaces::rate_oracle::{IOracleAdapterDispatcher, IOracleAdapterDispatcherTrait};
    use crate::types::asce_swap::{
        Market, MarketParams, MarketStatus, ProtocolFees, RateIndex, RateType,
    };


    #[abi(embed_v0)]
    impl SecurityImpl = SecurityComponent::SecurityImpl<ContractState>;
    impl SecurityInternalImpl = SecurityComponent::InternalImpl<ContractState>;
    impl ReentrancyGuardInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;


    component!(path: ERC721Component, storage: erc721, event: ERC721Event);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    component!(path: ReentrancyGuardComponent, storage: renack, event: ReentrancyGuardEvent);
    component!(path: SecurityComponent, storage: security, event: SecurityEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    #[abi(embed_v0)]
    impl ERC721MixinImpl = ERC721Component::ERC721MixinImpl<ContractState>;
    impl ERC721InternalImpl = ERC721Component::InternalImpl<ContractState>;


    #[storage]
    pub struct Storage {
        #[substorage(v0)]
        erc721: ERC721Component::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        #[substorage(v0)]
        renack: ReentrancyGuardComponent::Storage,
        #[substorage(v0)]
        security: SecurityComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        treasury: ContractAddress,
        protocol_fees: ProtocolFees,
        next_market_id: u256,
        next_swap_id: u256,
        permissioned_flag: bool,
        protocol_paused: bool,
        markets: Map<u256, Market>,
        rate_indices: Map<u256, RateIndex>,
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        #[flat]
        PausableEvent: PausableComponent::Event,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        #[flat]
        SecurityEvent: SecurityComponent::Event,
        #[flat]
        ERC721Event: ERC721Component::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        MarketPairCreated: MarketPairCreated,
        MarketPaused: MarketPaused,
        MarketUnpaused: MarketUnpaused,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MarketPairCreated {
        #[key]
        pub fixed_market_id: u256,
        #[key]
        pub floating_market_id: u256,
        pub reference_rate_oracle: ContractAddress,
        pub swap_token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MarketPaused {
        #[key]
        pub market_id: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MarketUnpaused {
        #[key]
        pub market_id: u256,
    }

    fn constructor(
        ref self: ContractState,
        access_registry: ContractAddress,
        treasury: ContractAddress,
        initial_fees: ProtocolFees,
    ) {
        self.erc721.initializer("AsceSwap Position", "ASCE-POS", "");
        self.treasury.write(treasury);
        self.security._set_access_control(access_registry);
        self.protocol_fees.write(initial_fees);
        self.next_market_id.write(1);
        self.next_swap_id.write(1);
        self.permissioned_flag.write(true);
    }

    #[abi(embed_v0)]
    impl AsceSwapImpl of IAsceSwap<ContractState> {
        // shouldn't market maker be allowed to specify how their markets can be : who can act as an
        // LP? what's in for them?
        //protocol fees on swaps goes to protocol treasury
        fn create_market_pair(
            ref self: ContractState, params: MarketParams, curator: ContractAddress,
        ) -> (u256, u256) {
            self.security._renack_start();
            if self.permissioned_flag.read() {
                self.security.assert_admin_role();
            }
            self._assert_not_paused();
            self._validate_market_params(params);
            assert(!curator.is_zero(), Errors::INVAID_ADDRESS);
            let market_creation_fee = self.protocol_fees.read().market_creation_fee;

            /// @notice: TODO: if the process permissionless we need to add an way to add roles and
            /// permissions for the respective markets

            //transfer the market creation fee to treasury
            if market_creation_fee > 0 {
                let caller = get_caller_address();
                let fee_token = IERC20Dispatcher {
                    contract_address: contract_address_const::<0>(),
                };
                let success = fee_token
                    .transfer_from(caller, self.treasury.read(), market_creation_fee);
                assert(success, Errors::TRANSFER_FAILED);
            }

            let fixed_market_id = self.next_market_id.read();
            let floating_market_id = fixed_market_id + 1;
            self.next_market_id.write(floating_market_id + 1);

            // Create fixed market
            let fixed_market = self._create_market(RateType::Fixed, floating_market_id);
            self.markets.write(fixed_market_id, fixed_market);

            // Create floating market
            let floating_market = self._create_market(RateType::Floating, fixed_market_id);
            self.markets.write(floating_market_id, floating_market);

            // let access_registry: IAccessExtra = self.security.get_access_control();
            // access_registry.set_role_admin(floating_market_id as felt252, curator);
            // access_registry.set_role_admin(floating_market_id as felt252, curator);

            // Initialize rate indices
            let current_rate = self
                ._get_oracle_rate(params.reference_rate_oracle, params.max_oracle_staleness);

            let current_time = get_block_timestamp();

            let rate_index = RateIndex {
                last_update_time: current_time, last_rate: current_rate, cumulative_rate_time: 0,
            };

            self.rate_indices.write(fixed_market_id, rate_index);
            self.rate_indices.write(floating_market_id, rate_index);

            self
                .emit(
                    MarketPairCreated {
                        fixed_market_id,
                        floating_market_id,
                        reference_rate_oracle: params.reference_rate_oracle,
                        swap_token: params.swap_token,
                    },
                );
            self.security._renack_end();
            (fixed_market_id, floating_market_id)
        }

        fn pause_market(ref self: ContractState, market_id: u256) {
            self.security.assert_admin_role();

            let mut market = self.markets.read(market_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_FOUND);
            market.status = MarketStatus::Paused;
            self.markets.write(market_id, market);

            self.emit(MarketPaused { market_id });
        }

        fn unpause_market(ref self: ContractState, market_id: u256) {
            self.security.assert_admin_role();

            let mut market = self.markets.read(market_id);
            assert(market.status == MarketStatus::Paused, Errors::MARKET_NOT_FOUND);
            market.status = MarketStatus::Active;
            self.markets.write(market_id, market);

            self.emit(MarketUnpaused { market_id });
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _assert_not_paused(self: @ContractState) {
            assert(!self.security.is_paused(), Errors::PROTOCOL_PAUSED);
        }

        fn _validate_market_params(self: @ContractState, params: MarketParams) {
            // Validate market parameters
            assert(!params.collateral_price_oracle.is_zero(), Errors::INVALID_ORACLE);
            assert(!params.reference_rate_oracle.is_zero(), Errors::INVALID_ORACLE);
            assert(!params.swap_token.is_zero(), Errors::INVALID_TOKEN);
            assert(
                params.liquidation_threshold >= 5000 && params.liquidation_threshold <= 9500,
                Errors::INVALID_THRESHOLD,
            );
            assert(
                params.swap_term >= Constants::MIN_SWAP_DURATION
                    && params.swap_term <= Constants::MAX_SWAP_DURATION,
                Errors::INVALID_TERM,
            );
            assert(params.max_util_fee <= 2000, Errors::INVALID_FEE);
        }

        fn _get_oracle_rate(
            self: @ContractState, oracle: ContractAddress, max_staleness: u64,
        ) -> u256 {
            let oracle_adapter = IOracleAdapterDispatcher { contract_address: oracle };
            let (rate, timestamp) = oracle_adapter.get_rate();
            let current_time = get_block_timestamp();
            assert(current_time - timestamp <= max_staleness, Errors::ORACLE_STALE);
            assert(rate > 0, Errors::ORACLE_INVALID_RATE);
            rate
        }

        fn _get_oracle_price(
            self: @ContractState, oracle: ContractAddress, max_staleness: u64,
        ) -> u256 {
            let oracle_adapter = IOracleAdapterDispatcher { contract_address: oracle };
            let (price, last_update) = oracle_adapter.get_price();

            let current_time = get_block_timestamp();
            assert(current_time - last_update <= max_staleness, Errors::ORACLE_STALE);
            assert(price > 0, Errors::ORACLE_INVALID_PRICE);

            price
        }

        fn _create_market(
            self: @ContractState, market_type: RateType, paired_market_id: u256,
        ) -> Market {
            Market {
                status: MarketStatus::Active,
                rate_type: market_type,
                paired_market_id: paired_market_id,
                params: Default::default(),
                total_lp_collateral: 0,
                locked_lp_collateral: 0,
                total_lp_shares: 0,
            }
        }
    }
}
