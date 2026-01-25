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
        get_contract_address,
    };
    use crate::components::Security::SecurityComponent;
    use crate::helpers::constants::Constants;
    use crate::helpers::core_utils::*;
    use crate::helpers::errors::Errors;
    use crate::helpers::fixed_point::*;
    use crate::helpers::signed_value::*;
    use crate::helpers::utils::*;
    use crate::interfaces::asce_swap::IAsceSwap;
    use crate::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use crate::interfaces::rate_oracle::{IOracleAdapterDispatcher, IOracleAdapterDispatcherTrait};
    use crate::types::asce_swap::*;
    // use crate::types::asce_swap::{
    //     LpPosition, Market, MarketParams, MarketStatus, ProtocolFees, RateIndex,
    //     RateType,SignedValue
    // };

    use crate::types::asce_swap::{LpPool, MarketPair, MarketStatus, ProtocolConfig, RateIndex};


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
        // protocol config
        protocol_config: ProtocolConfig,
        permissioned_flag: bool,
        // Market count
        next_pair_id: felt252,
        // Next swap ID
        next_swap_id: u256,
        markets: Map<felt252, MarketPair>,
        protocol_fees: Map<ContractAddress, u256>,
        // LP positions: (lp_address, pair_id) -> LpPosition
        lp_positions: Map<(ContractAddress, felt252), LpPosition>,
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
        FlagSetted: FlagSetted,
        ProtocolFeesWithdrawn: ProtocolFeesWithdrawn,
        LpDeposited: LpDeposited,
    }

    #[derive(Drop, starknet::Event)]
    pub struct LpDeposited {
        #[key]
        pub lp: ContractAddress,
        #[key]
        pub pair_id: felt252,
        pub amount: u256,
        pub shares_minted: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MarketPairCreated {
        #[key]
        pub pair_id: felt252,
        pub rate_oracle: ContractAddress,
        pub collateral_token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MarketPaused {
        #[key]
        pub pair_id: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MarketUnpaused {
        #[key]
        pub pair_id: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FlagSetted {
        pub flag: bool,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ProtocolFeesWithdrawn {
        pub token: ContractAddress,
        pub amount: u256,
        pub recipient: ContractAddress,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, access_registry: ContractAddress, treasury: ContractAddress,
    ) {
        self.erc721.initializer("AsceSwap V2 Position", "ASCE-V2", "");

        // Initialize protocol config
        let config = ProtocolConfig {
            treasury,
            protocol_fee_share_bps: 2000, // 20% of fees to protocol
            min_first_lp_deposit: Constants::DEFAULT_MIN_FIRST_LP_DEPOSIT,
            burned_shares_amount: Constants::MIN_BURNED_SHARES,
            market_creation_fees: Constants::MARKET_CREATION_FESS,
        };

        self.protocol_config.write(config);

        self.next_pair_id.write(1);
        self.next_swap_id.write(1);
    }

    #[abi(embed_v0)]
    impl AsceSwapImpl of IAsceSwap<ContractState> {
        fn create_market_pair(
            ref self: ContractState,
            rate_oracle: ContractAddress,
            collateral_token: ContractAddress,
            curator: ContractAddress,
            params: MarketParams,
        ) -> felt252 {
            self.security._renack_start();
            self._assert_not_paused();

            assert(!rate_oracle.is_zero(), Errors::ZERO_ADDRESS);
            assert(!collateral_token.is_zero(), Errors::ZERO_ADDRESS);
            assert(!curator.is_zero(), Errors::ZERO_ADDRESS);

            // Validate params
            self._validate_market_params(params);
            self._validate_permission_call();

            //validate orale is working and store the inital rate
            let (initial_rate, rate_timestamp) = self._get_oracle_rate(rate_oracle);

            let current_time = get_block_timestamp();

            assert(
                current_time - rate_timestamp <= params.max_oracle_staleness_seconds,
                Errors::ORACLE_STALE,
            );

            assert(
                initial_rate >= params.min_rate_bps && initial_rate <= params.max_rate_bps,
                Errors::RATE_OUT_OF_BOUNDS,
            );

            // Get token decimals
            let token = IERC20Dispatcher { contract_address: collateral_token };
            let decimals = token.decimals();

            let pair_id = self.next_pair_id.read();
            self.next_pair_id.write(pair_id + 1);

            let market = MarketPair {
                pair_id,
                status: MarketStatus::Active,
                rate_oracle,
                curator,
                collateral_token,
                decimals,
                params,
                pool: LpPool {
                    total_collateral: 0,
                    locked_for_fixed: 0,
                    locked_for_floating: 0,
                    total_shares: 0,
                    insurance_fund: 0,
                },
                rate_index: RateIndex {
                    last_update_time: current_time,
                    last_rate_bps: initial_rate,
                    cumulative_rate_time: 0,
                    last_valid_rate_bps: initial_rate,
                },
                total_swaps_created: 0,
                active_swap_count: 0,
            };

            if params.is_lp_open {
                self.security.set_role_from_admin(pair_id, curator);
            }

            self.markets.write(pair_id, market);

            self._deduct_market_creation_fees();

            self.emit(MarketPairCreated { pair_id, rate_oracle, collateral_token });
            self.security._renack_end();
            pair_id
        }

        fn pause_market(ref self: ContractState, pair_id: felt252) {
            self.security.assert_admin_role();
            let mut market = self.markets.read(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);
            market.status = MarketStatus::Paused;
            self.markets.write(pair_id, market);
            self.emit(MarketPaused { pair_id });
        }

        fn unpause_market(ref self: ContractState, pair_id: felt252) {
            self.security.assert_admin_role();
            let mut market = self.markets.read(pair_id);
            assert(market.status == MarketStatus::Paused, Errors::MARKET_NOT_ACTIVE);
            market.status = MarketStatus::Active;
            self.markets.write(pair_id, market);
            self.emit(MarketUnpaused { pair_id });
        }

        fn supply_lp_collateral(ref self: ContractState, pair_id: felt252, amount: u256) -> u256 {
            self.security._renack_start();
            self._assert_not_paused();
            assert(amount >= Constants::MIN_LP_DEPOSIT, Errors::BELOW_MIN_DEPOSIT);
            let mut market = self.markets.read(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);

            self._validate_lp_call(pair_id, market.params.is_lp_open);

            let caller = get_caller_address();
            let mut pool = market.pool;
            let config = self.protocol_config.read();

            let shares_to_mint = if pool.total_shares == 0 {
                // First deposit - apply inflation protection
                assert(amount >= config.min_first_lp_deposit, Errors::FIRST_DEPOSIT_TOO_SMALL);

                // Shares = amount - burned
                let shares = amount - config.burned_shares_amount;

                // Total shares includes burned (owned by no one)
                pool.total_shares = amount;
                pool.total_collateral = amount;

                shares
            } else {
                // Normal proportional calculation
                let shares = calculate_shares_to_mint(
                    amount, pool.total_shares, pool.total_collateral,
                );

                pool.total_shares = pool.total_shares + shares;
                pool.total_collateral = pool.total_collateral + amount;

                shares
            };

            let mut position = self.lp_positions.read((caller, pair_id));
            position.shares = position.shares + shares_to_mint;
            position.last_deposit_time = get_block_timestamp();
            self.lp_positions.write((caller, pair_id), position);

            market.pool = pool;
            self.markets.write(pair_id, market);

            let token = IERC20Dispatcher { contract_address: market.collateral_token };
            let success = token.transfer_from(caller, get_contract_address(), amount);
            assert(success, Errors::TRANSFER_FROM_FAILED);

            self.emit(LpDeposited { lp: caller, pair_id, amount, shares_minted: shares_to_mint });

            shares_to_mint
        }

        ///Market Creation Process
        fn set_premission_less_flag(ref self: ContractState, flag: bool) {
            self.security.assert_admin_role();
            self.permissioned_flag.write(flag);
            self.emit(FlagSetted { flag });
        }

        fn update_protocol_config(ref self: ContractState, config: ProtocolConfig) {
            self.security.assert_admin_role();
            assert(!config.treasury.is_zero(), Errors::ZERO_ADDRESS);
            self.protocol_config.write(config);
        }

        fn withdraw_protocol_fees(
            ref self: ContractState,
            token: ContractAddress,
            amount: u256,
            recipient: ContractAddress,
        ) {
            self.security.assert_admin_role();
            assert(!recipient.is_zero(), Errors::ZERO_ADDRESS);

            let available = self.protocol_fees.read(token);
            assert(amount <= available, Errors::INSUFFICIENT_COLLATERAL);

            self.protocol_fees.write(token, available - amount);

            let token_contract = IERC20Dispatcher { contract_address: token };
            let success = token_contract.transfer(recipient, amount);
            assert(success, Errors::TRANSFER_FAILED);

            self.emit(ProtocolFeesWithdrawn { token, amount, recipient });
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _assert_not_paused(self: @ContractState) {
            assert(!self.security.is_paused(), Errors::PROTOCOL_PAUSED);
        }

        fn _validate_market_params(self: @ContractState, params: MarketParams) {
            assert(
                params.liquidation_threshold_bps >= Constants::MIN_LIQUIDATION_THRESHOLD_BPS
                    && params.liquidation_threshold_bps <= Constants::MAX_LIQUIDATION_THRESHOLD_BPS,
                Errors::INVALID_PARAMS,
            );
            assert(
                params.swap_term_seconds >= Constants::MIN_SWAP_TERM_SECONDS
                    && params.swap_term_seconds <= Constants::MAX_SWAP_TERM_SECONDS,
                Errors::INVALID_PARAMS,
            );
            assert(params.swap_fee_bps <= Constants::MAX_FEE_BPS, Errors::INVALID_PARAMS);
            assert(params.early_exit_fee_bps <= Constants::MAX_FEE_BPS, Errors::INVALID_PARAMS);
            assert(params.liquidation_bonus_bps <= Constants::MAX_FEE_BPS, Errors::INVALID_PARAMS);
            assert(params.max_rate_bps <= Constants::MAX_RATE_BOUND_BPS, Errors::INVALID_PARAMS);
            assert(
                params.max_utilization_bps <= Constants::MAX_UTILIZATION_CAP_BPS,
                Errors::INVALID_PARAMS,
            );
            assert(params.min_notional > 0, Errors::INVALID_PARAMS);
            assert(params.max_notional_per_swap >= params.min_notional, Errors::INVALID_PARAMS);
        }

        fn _validate_permission_call(self: @ContractState) {
            if self.permissioned_flag.read() {
                self.security.assert_admin_role();
            }
        }

        fn _validate_lp_call(self: @ContractState, pair_id: felt252, is_open: bool) {
            if is_open {
                self.security.assert_role(pair_id);
            }
        }

        // Get oracle rate
        fn _get_oracle_rate(self: @ContractState, oracle: ContractAddress) -> (u256, u64) {
            let oracle_adapter = IOracleAdapterDispatcher { contract_address: oracle };
            oracle_adapter.get_rate()
        }

        fn _deduct_market_creation_fees(ref self: ContractState) {
            let protocol_config = self.protocol_config.read();
            if protocol_config.market_creation_fees > 0 {
                let caller = get_caller_address();
                // can develop safe modude for transfer and approval
                let fee_token = IERC20Dispatcher { contract_address: Constants::USDC() };
                let success = fee_token
                    .transfer_from(
                        caller, protocol_config.treasury, protocol_config.market_creation_fees,
                    );
                assert(success, Errors::TRANSFER_FAILED);
            }
        }
    }
}
