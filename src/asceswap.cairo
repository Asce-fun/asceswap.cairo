#[starknet::contract]
pub mod Asceswap {
    use core::num::traits::Zero;
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_security::ReentrancyGuardComponent::InternalTrait as ReentrancyGuardInternalTrait;
    use openzeppelin_security::{PausableComponent, ReentrancyGuardComponent};
    use openzeppelin_token::erc721::{ERC721Component, ERC721HooksEmptyImpl};
    use openzeppelin_upgrades::UpgradeableComponent;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use crate::components::LiquidityManager::LiquidityManagerComponent;
    use crate::components::MarketManager::MarketManagerComponent;
    use crate::components::Security::SecurityComponent;
    use crate::components::SwapManager::SwapManagerComponent;
    use crate::helpers::constants::Constants;
    use crate::helpers::errors::Errors;
    use crate::interfaces::asce_swap::IAsceSwap;
    use crate::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use crate::types::asce_swap::{
        HealthStatus, LpPosition, MarketPair, MarketParams, MarketStatus, PoolAnalytics,
        ProtocolConfig, Swap, SwapQuote, SwapSide,
    };

    // Component declarations
    component!(path: ERC721Component, storage: erc721, event: ERC721Event);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    component!(path: ReentrancyGuardComponent, storage: reentrancy, event: ReentrancyGuardEvent);
    component!(path: SecurityComponent, storage: security, event: SecurityEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: MarketManagerComponent, storage: market_manager, event: MarketManagerEvent);
    component!(
        path: LiquidityManagerComponent, storage: liquidity_manager, event: LiquidityManagerEvent,
    );
    component!(path: SwapManagerComponent, storage: swap_manager, event: SwapManagerEvent);

    // Embeddable implementations
    #[abi(embed_v0)]
    impl SecurityImpl = SecurityComponent::SecurityImpl<ContractState>;
    impl SecurityInternalImpl = SecurityComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl ERC721MixinImpl = ERC721Component::ERC721MixinImpl<ContractState>;
    impl ERC721InternalImpl = ERC721Component::InternalImpl<ContractState>;

    // Component internal implementations
    impl MarketManagerInternalImpl = MarketManagerComponent::InternalImpl<ContractState>;
    impl LiquidityManagerInternalImpl = LiquidityManagerComponent::InternalImpl<ContractState>;
    impl SwapManagerInternalImpl = SwapManagerComponent::InternalImpl<ContractState>;

    #[storage]
    pub struct Storage {
        // OpenZeppelin components
        #[substorage(v0)]
        erc721: ERC721Component::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        #[substorage(v0)]
        reentrancy: ReentrancyGuardComponent::Storage,
        #[substorage(v0)]
        security: SecurityComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        // Custom components
        #[substorage(v0)]
        market_manager: MarketManagerComponent::Storage,
        #[substorage(v0)]
        liquidity_manager: LiquidityManagerComponent::Storage,
        #[substorage(v0)]
        swap_manager: SwapManagerComponent::Storage,
        // Protocol-level storage (stays in main contract)
        protocol_config: ProtocolConfig,
        permissioned_flag: bool,
        protocol_fees: Map<ContractAddress, u256>,
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
        #[flat]
        MarketManagerEvent: MarketManagerComponent::Event,
        #[flat]
        LiquidityManagerEvent: LiquidityManagerComponent::Event,
        #[flat]
        SwapManagerEvent: SwapManagerComponent::Event,
        FlagSetted: FlagSetted,
        ProtocolFeesWithdrawn: ProtocolFeesWithdrawn,
        ProtocolConfigUpdated: ProtocolConfigUpdated,
        RateIndexUpdated: RateIndexUpdated,
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

    #[derive(Drop, starknet::Event)]
    pub struct ProtocolConfigUpdated {
        pub config: ProtocolConfig,
    }

    #[derive(Drop, starknet::Event)]
    pub struct RateIndexUpdated {
        #[key]
        pub pair_id: felt252,
        pub new_rate_bps: u256,
        pub cumulative_rate_time: u256,
        pub timestamp: u64,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, access_registry: ContractAddress, treasury: ContractAddress,
    ) {
        // Initialize ERC721
        self.erc721.initializer("AsceSwap V2 Position", "ASCE-V2", "");

        // Initialize protocol config
        let config = ProtocolConfig {
            treasury,
            protocol_fee_share_bps: 2000, // 20% of fees to protocol
            min_first_lp_deposit: Constants::DEFAULT_MIN_FIRST_LP_DEPOSIT,
            burned_shares_amount: Constants::MIN_BURNED_SHARES,
            market_creation_fees: Constants::MARKET_CREATION_FEE,
        };
        self.protocol_config.write(config);

        // Initialize components
        self.market_manager.initializer();
        self.swap_manager.initializer();

        // Set access control
        self.security._set_access_control(access_registry);
    }

    #[abi(embed_v0)]
    impl AsceSwapImpl of IAsceSwap<ContractState> {
        // ==================== MARKET OPERATIONS ====================

        fn create_market_pair(
            ref self: ContractState,
            rate_oracle: ContractAddress,
            collateral_token: ContractAddress,
            curator: ContractAddress,
            params: MarketParams,
        ) -> felt252 {
            // Reentrancy guard
            self.reentrancy.start();
            self._assert_not_paused();

            // Validations
            assert(!rate_oracle.is_zero(), Errors::ZERO_ADDRESS);
            assert(!collateral_token.is_zero(), Errors::ZERO_ADDRESS);
            assert(!curator.is_zero(), Errors::ZERO_ADDRESS);

            self.market_manager.validate_market_params(@params);
            self._validate_permission_call();

            // Get oracle rate
            let (initial_rate, rate_timestamp) = self.market_manager.get_oracle_rate(rate_oracle);
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

            // Create market via component
            let pair_id = self
                .market_manager
                .create_market_pair(
                    rate_oracle,
                    collateral_token,
                    curator,
                    params,
                    initial_rate,
                    current_time,
                    decimals,
                );

            // Handle LP permissioning
            if params.is_lp_permissioned {
                self.security.set_role_from_admin(pair_id, curator);
            }

            // Deduct market creation fees
            self._deduct_market_creation_fees();

            self.reentrancy.end();
            pair_id
        }

        fn pause_market(ref self: ContractState, pair_id: felt252) {
            self.security.assert_admin_role();
            self.market_manager.pause_market(pair_id);
        }

        fn unpause_market(ref self: ContractState, pair_id: felt252) {
            self.security.assert_admin_role();
            self.market_manager.unpause_market(pair_id);
        }

        // ==================== LP OPERATIONS ====================

        fn supply_lp_collateral(ref self: ContractState, pair_id: felt252, amount: u256) -> u256 {
            self.reentrancy.start();
            self._assert_not_paused();

            let market = self.market_manager.get_market(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);

            self._validate_lp_call(pair_id, market.params.is_lp_permissioned);

            let caller = get_caller_address();
            let config = self.protocol_config.read();

            let (shares, updated_pool) = self
                .liquidity_manager
                .supply_lp_collateral(
                    pair_id, amount, caller, market.pool, @config, market.collateral_token,
                );

            // Update market with new pool state
            let mut updated_market = market;
            updated_market.pool = updated_pool;
            self.market_manager.write_market(pair_id, updated_market);

            self.reentrancy.end();
            shares
        }

        fn withdraw_lp_collateral(ref self: ContractState, pair_id: felt252, shares: u256) -> u256 {
            self.reentrancy.start();
            self._assert_not_paused();

            let market = self.market_manager.get_market(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);

            let caller = get_caller_address();

            let (amount, updated_pool) = self
                .liquidity_manager
                .withdraw_lp_collateral(
                    pair_id, shares, caller, market.pool, market.collateral_token,
                );

            // Update market with new pool state
            let mut updated_market = market;
            updated_market.pool = updated_pool;
            self.market_manager.write_market(pair_id, updated_market);

            self.reentrancy.end();
            amount
        }

        // ==================== SWAP OPERATIONS ====================

        fn buy_swap(
            ref self: ContractState,
            pair_id: felt252,
            side: SwapSide,
            notional: u256,
            collateral: u256,
            max_rate_bps: u256,
        ) -> u256 {
            self.reentrancy.start();
            self._assert_not_paused();

            let mut market = self.market_manager.get_market(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);

            let caller = get_caller_address();
            let current_time = get_block_timestamp();

            // Update rate index
            let oracle_rate = self.market_manager.update_rate_index(ref market, current_time);

            // Emit rate update event
            self
                .emit(
                    RateIndexUpdated {
                        pair_id,
                        new_rate_bps: oracle_rate,
                        cumulative_rate_time: market.rate_index.cumulative_rate_time,
                        timestamp: current_time,
                    },
                );

            let config = self.protocol_config.read();

            // Execute swap via component
            let (swap_id, updated_pool, _lp_fee, protocol_portion) = self
                .swap_manager
                .buy_swap(
                    pair_id,
                    side,
                    notional,
                    collateral,
                    max_rate_bps,
                    caller,
                    @market,
                    oracle_rate,
                    config.protocol_fee_share_bps,
                );

            // Transfer collateral (main contract handles transfers)
            let token = IERC20Dispatcher { contract_address: market.collateral_token };
            let success = token.transfer_from(caller, get_contract_address(), collateral);
            assert(success, Errors::TRANSFER_FROM_FAILED);

            // Mint NFT
            self.erc721.mint(caller, swap_id);

            // Track protocol fees
            let current_protocol_fees = self.protocol_fees.read(market.collateral_token);
            self
                .protocol_fees
                .write(market.collateral_token, current_protocol_fees + protocol_portion);

            // Update market state
            market.pool = updated_pool;
            market.total_swaps_created = market.total_swaps_created + 1;
            market.active_swap_count = market.active_swap_count + 1;
            self.market_manager.write_market(pair_id, market);

            self.reentrancy.end();
            swap_id
        }

        fn settle_swap(ref self: ContractState, swap_id: u256) {
            self.reentrancy.start();
            self._assert_not_paused();

            let swap = self.swap_manager.get_swap(swap_id);
            let mut market = self.market_manager.get_market(swap.pair_id);
            let owner = self.erc721.owner_of(swap_id);
            let current_time = get_block_timestamp();

            // Update rate index
            self.market_manager.update_rate_index(ref market, current_time);

            // Settle via component
            let (updated_pool, result) = self.swap_manager.settle_swap(swap_id, owner, @market);

            // Burn NFT
            self.erc721.burn(swap_id);

            // Transfer payout
            if result.buyer_payout > 0 {
                let token = IERC20Dispatcher { contract_address: market.collateral_token };
                let success = token.transfer(owner, result.buyer_payout);
                assert(success, Errors::TRANSFER_FAILED);
            }

            // Update market state
            market.pool = updated_pool;
            market.active_swap_count = market.active_swap_count - 1;
            self.market_manager.write_market(swap.pair_id, market);

            self.reentrancy.end();
        }

        fn early_exit(ref self: ContractState, swap_id: u256) {
            self.reentrancy.start();
            self._assert_not_paused();

            let swap = self.swap_manager.get_swap(swap_id);
            let mut market = self.market_manager.get_market(swap.pair_id);
            let caller = get_caller_address();
            let owner = self.erc721.owner_of(swap_id);
            let current_time = get_block_timestamp();

            // Update rate index
            self.market_manager.update_rate_index(ref market, current_time);

            // Early exit via component
            let (updated_pool, result) = self
                .swap_manager
                .early_exit(swap_id, caller, owner, @market);

            // Burn NFT
            self.erc721.burn(swap_id);

            // Transfer payout
            if result.buyer_payout > 0 {
                let token = IERC20Dispatcher { contract_address: market.collateral_token };
                let success = token.transfer(owner, result.buyer_payout);
                assert(success, Errors::TRANSFER_FAILED);
            }

            // Update market state
            market.pool = updated_pool;
            market.active_swap_count = market.active_swap_count - 1;
            self.market_manager.write_market(swap.pair_id, market);

            self.reentrancy.end();
        }

        fn liquidate(ref self: ContractState, swap_id: u256) {
            self.reentrancy.start();
            self._assert_not_paused();

            let swap = self.swap_manager.get_swap(swap_id);
            let mut market = self.market_manager.get_market(swap.pair_id);
            let liquidator = get_caller_address();
            let owner = self.erc721.owner_of(swap_id);
            let current_time = get_block_timestamp();

            // Update rate index
            self.market_manager.update_rate_index(ref market, current_time);

            // Liquidate via component
            let (updated_pool, result, _health_status) = self
                .swap_manager
                .liquidate(swap_id, liquidator, owner, @market);

            // Burn NFT
            self.erc721.burn(swap_id);

            // Transfer liquidator bonus
            if result.liquidator_bonus > 0 {
                let token = IERC20Dispatcher { contract_address: market.collateral_token };
                let success = token.transfer(liquidator, result.liquidator_bonus);
                assert(success, Errors::TRANSFER_FAILED);
            }

            // Update market state
            market.pool = updated_pool;
            market.active_swap_count = market.active_swap_count - 1;
            self.market_manager.write_market(swap.pair_id, market);

            self.reentrancy.end();
        }

        // ==================== VIEW FUNCTIONS ====================

        fn get_market(self: @ContractState, pair_id: felt252) -> MarketPair {
            self.market_manager.get_market(pair_id)
        }

        fn get_swap(self: @ContractState, swap_id: u256) -> Swap {
            self.swap_manager.get_swap(swap_id)
        }

        fn get_swap_quote(
            self: @ContractState, pair_id: felt252, side: SwapSide, notional: u256,
        ) -> SwapQuote {
            let market = self.market_manager.get_market(pair_id);
            let (oracle_rate, _) = self.market_manager.get_oracle_rate(market.rate_oracle);
            self
                .swap_manager
                .get_swap_quote(@market.pool, @market.params, side, notional, oracle_rate)
        }

        fn get_health_status(self: @ContractState, swap_id: u256) -> HealthStatus {
            let swap = self.swap_manager.get_swap(swap_id);
            let market = self.market_manager.get_market(swap.pair_id);
            self.swap_manager.get_health_status(swap_id, @market)
        }

        fn get_lp_position(
            self: @ContractState, lp: ContractAddress, pair_id: felt252,
        ) -> LpPosition {
            self.liquidity_manager.get_lp_position(lp, pair_id)
        }

        fn get_pool_analytics(self: @ContractState, pair_id: felt252) -> PoolAnalytics {
            let market = self.market_manager.get_market(pair_id);
            self.liquidity_manager.get_pool_analytics(@market.pool)
        }

        fn get_current_twa(self: @ContractState, swap_id: u256) -> u256 {
            let swap = self.swap_manager.get_swap(swap_id);
            let market = self.market_manager.get_market(swap.pair_id);
            self.swap_manager.get_current_twa(swap_id, @market.rate_index)
        }

        fn get_protocol_config(self: @ContractState) -> ProtocolConfig {
            self.protocol_config.read()
        }

        fn get_next_swap_id(self: @ContractState) -> u256 {
            self.swap_manager.get_next_swap_id()
        }

        // ==================== ADMIN FUNCTIONS ====================

        fn set_premission_less_flag(ref self: ContractState, flag: bool) {
            self.security.assert_admin_role();
            self.permissioned_flag.write(flag);
            self.emit(FlagSetted { flag });
        }

        fn update_protocol_config(ref self: ContractState, config: ProtocolConfig) {
            self.security.assert_admin_role();
            assert(!config.treasury.is_zero(), Errors::ZERO_ADDRESS);
            assert(config.protocol_fee_share_bps <= (Constants::BPS / 5), Errors::INVALID_PARAMS);
            assert(
                config.burned_shares_amount >= Constants::MIN_BURNED_SHARES, Errors::INVALID_PARAMS,
            );
            assert(
                config.min_first_lp_deposit >= Constants::MIN_LP_DEPOSIT, Errors::INVALID_PARAMS,
            );
            self.protocol_config.write(config);
            self.emit(ProtocolConfigUpdated { config });
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

    // ==================== INTERNAL FUNCTIONS ====================

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _assert_not_paused(self: @ContractState) {
            assert(!self.security.is_paused(), Errors::PROTOCOL_PAUSED);
        }

        fn _validate_permission_call(self: @ContractState) {
            if self.permissioned_flag.read() {
                self.security.assert_admin_role();
            }
        }

        fn _validate_lp_call(self: @ContractState, pair_id: felt252, is_permissioned: bool) {
            if is_permissioned {
                self.security.assert_role(pair_id);
            }
        }

        fn _deduct_market_creation_fees(ref self: ContractState) {
            let protocol_config = self.protocol_config.read();
            if protocol_config.market_creation_fees > 0 {
                let caller = get_caller_address();
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
