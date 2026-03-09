#[starknet::contract]
pub mod Asceswap {
    use core::num::traits::Zero;
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_security::ReentrancyGuardComponent::InternalTrait as ReentrancyGuardInternalTrait;
    use openzeppelin_security::{PausableComponent, ReentrancyGuardComponent};
    use openzeppelin_upgrades::UpgradeableComponent;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use crate::components::Analytics::AnalyticsComponent;
    use crate::components::ERC6909::ERC6909Component;
    use crate::components::ExtensionManager::ExtensionManagerComponent;
    use crate::components::LiquidityManager::LiquidityManagerComponent;
    use crate::components::MarketManager::MarketManagerComponent;
    use crate::components::Security::SecurityComponent;
    use crate::components::SwapManager::SwapManagerComponent;
    use crate::helpers::constants::Constants;
    use crate::helpers::errors::Errors;
    use crate::helpers::safe_erc20::SafeERC20;
    use crate::interfaces::asce_swap::IAsceSwap;
    use crate::interfaces::position_manager::{
        IPositionManagerDispatcher, IPositionManagerDispatcherTrait,IERC721OwnerDispatcher, IERC721OwnerDispatcherTrait,
    };
    use crate::types::asce_swap::{
        HealthStatus, LpAnalytics, LpPool, MarketPair, MarketParams, MarketStatus, PoolAnalytics,
        ProtocolConfig, ScenarioResult, Swap, SwapAnalytics, SwapQuote, SwapSide,
        UserDashboard, UserLpSummary, UserSwapSummary,
    };
    use crate::types::asce_swap::SettlementType;
    use crate::types::extension::{CallPoints, LiquidityParams, MarketCreationParams, SwapOpenParams};

    // Component declarations
    component!(path: ERC6909Component, storage: erc6909, event: ERC6909Event);
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
    component!(path: AnalyticsComponent, storage: analytics, event: AnalyticsEvent);
    component!(
        path: ExtensionManagerComponent,
        storage: extension_manager,
        event: ExtensionManagerEvent,
    );

    // Embeddable implementations
    #[abi(embed_v0)]
    impl SecurityImpl = SecurityComponent::SecurityImpl<ContractState>;
    impl SecurityInternalImpl = SecurityComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl ERC6909Impl = ERC6909Component::ERC6909Impl<ContractState>;
    impl ERC6909InternalImpl = ERC6909Component::InternalImpl<ContractState>;

    // Component internal implementations
    impl MarketManagerInternalImpl = MarketManagerComponent::InternalImpl<ContractState>;
    impl LiquidityManagerInternalImpl = LiquidityManagerComponent::InternalImpl<ContractState>;
    impl SwapManagerInternalImpl = SwapManagerComponent::InternalImpl<ContractState>;
    impl AnalyticsInternalImpl = AnalyticsComponent::InternalImpl<ContractState>;
    impl ExtensionManagerInternalImpl = ExtensionManagerComponent::InternalImpl<ContractState>;

    #[storage]
    pub struct Storage {
        // OpenZeppelin components
        #[substorage(v0)]
        erc6909: ERC6909Component::Storage,
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
        #[substorage(v0)]
        analytics: AnalyticsComponent::Storage,
        #[substorage(v0)]
        extension_manager: ExtensionManagerComponent::Storage,
        // Protocol-level storage (stays in main contract)
        protocol_config: ProtocolConfig,
        permissioned_flag: bool,
        protocol_fees: Map<ContractAddress, u256>,
        // External PositionManager contract (ERC721 NFTs)
        position_manager: IPositionManagerDispatcher,
        token_whitelisted: Map<ContractAddress, bool>,
        // Two-step settle/claim: swap_id → payout + 1 (sentinel: 0 = not settled)
        claim_amounts: Map<u256, u256>,
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
        ERC6909Event: ERC6909Component::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        MarketManagerEvent: MarketManagerComponent::Event,
        #[flat]
        LiquidityManagerEvent: LiquidityManagerComponent::Event,
        #[flat]
        SwapManagerEvent: SwapManagerComponent::Event,
        AnalyticsEvent: AnalyticsComponent::Event,
        #[flat]
        ExtensionManagerEvent: ExtensionManagerComponent::Event,
        FlagSet: FlagSet,
        ProtocolFeesWithdrawn: ProtocolFeesWithdrawn,
        ProtocolConfigUpdated: ProtocolConfigUpdated,
        TokenWhitelisted: TokenWhitelisted,
        TokenDeWhitelisted: TokenDeWhitelisted,
        SwapClaimed: SwapClaimed,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FlagSet {
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
    pub struct TokenWhitelisted {
        #[key]
        pub token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TokenDeWhitelisted {
        #[key]
        pub token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SwapClaimed {
        #[key]
        pub swap_id: u256,
        pub owner: ContractAddress,
        pub amount: u256,
        pub timestamp: u64,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        access_registry: ContractAddress,
        treasury: ContractAddress,
        position_manager: ContractAddress,
    ) {
        assert(!treasury.is_zero(), Errors::ZERO_ADDRESS);
        assert(!access_registry.is_zero(), Errors::ZERO_ADDRESS);
        assert(!position_manager.is_zero(), Errors::ZERO_ADDRESS);

        // Store PositionManager dispatcher
        self
            .position_manager
            .write(IPositionManagerDispatcher { contract_address: position_manager });

        // Initialize ERC6909 (LP share tokens)
        self.erc6909.initializer();

        // Initialize protocol config
        let config = ProtocolConfig {
            treasury,
            protocol_fee_share_bps: 2000, // 20% of fees to protocol
            market_creation_fees: Constants::MARKET_CREATION_FEE,
            fee_token: Constants::USDC(),
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
        fn create_market_pair(
            ref self: ContractState,
            rate_oracle: ContractAddress,
            collateral_token: ContractAddress,
            curator: ContractAddress,
            params: MarketParams,
            initial_liquidity_amount: u256,
            extension: ContractAddress,
        ) -> (felt252, u256) {
            // Reentrancy guard
            self.reentrancy.start();
            self._assert_not_paused();

            self._validate_permission_call();

            // Validations
            assert(!rate_oracle.is_zero(), Errors::ZERO_ADDRESS);
            assert(!collateral_token.is_zero(), Errors::ZERO_ADDRESS);
            assert(self.token_whitelisted.read(collateral_token), Errors::TOKEN_NOT_WHITELISTED);
            assert(!curator.is_zero(), Errors::ZERO_ADDRESS);

            // Validate extension is registered (if non-zero)
            if !extension.is_zero() {
                assert(
                    self.extension_manager.is_extension_registered(extension),
                    Errors::EXTENSION_NOT_REGISTERED,
                );
            }

            let caller = get_caller_address();

            // Build creation params for hook dispatch
            let creation_params = MarketCreationParams {
                rate_oracle,
                collateral_token,
                curator,
                params,
                initial_liquidity: initial_liquidity_amount,
            };

            // Dispatch before_market_creation hook
            self
                .extension_manager
                ._dispatch_before_market_creation(extension, caller, creation_params);

            let pair_id = self
                .market_manager
                ._create_market_pair(rate_oracle, collateral_token, curator, params, extension);

            // Handle LP permissioning
            if params.is_lp_permissioned {
                self.security.set_role_from_admin(pair_id, curator);
            }

            // Deduct market creation fees
            self._deduct_market_creation_fees();

            // Supply initial liquidity
            let pool = LpPool {
                total_collateral: 0, locked_for_fixed: 0, locked_for_floating: 0, total_shares: 0,
            };

            let (shares, updated_pool) = self
                .liquidity_manager
                ._deposit(
                    pair_id, initial_liquidity_amount, caller, caller, pool, collateral_token,
                );

            // Update market with new pool state
            let mut updated_market = self.market_manager._get_market(pair_id);
            updated_market.pool = updated_pool;
            self.market_manager._write_market(pair_id, updated_market);

            // Dispatch after_market_creation hook
            self
                .extension_manager
                ._dispatch_after_market_creation(
                    extension, caller, pair_id, creation_params, shares,
                );

            self.reentrancy.end();
            (pair_id, shares)
        }

        fn pause_market(ref self: ContractState, pair_id: felt252) {
            self.security.assert_admin_role();
            self.market_manager._pause_market(pair_id);
        }

        fn unpause_market(ref self: ContractState, pair_id: felt252) {
            self.security.assert_admin_role();
            self.market_manager._unpause_market(pair_id);
        }

        fn deposit(
            ref self: ContractState, pair_id: felt252, assets: u256, receiver: ContractAddress,
        ) -> u256 {
            self.reentrancy.start();
            self._assert_not_paused();

            let market = self.market_manager._get_market(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);

            self._validate_lp_call(pair_id, market.params.is_lp_permissioned);

            let caller = get_caller_address();

            // Dispatch before add liquidity hook
            let preview_shares = self.liquidity_manager._preview_deposit(assets, @market.pool);
            let before_params = LiquidityParams { assets, shares: preview_shares, receiver };
            self
                .extension_manager
                ._dispatch_before_add_liquidity(
                    market.extension, caller, pair_id, before_params,
                );

            let (shares, updated_pool) = self
                .liquidity_manager
                ._deposit(pair_id, assets, caller, receiver, market.pool, market.collateral_token);

            // Update market with new pool state
            let mut updated_market = market;
            updated_market.pool = updated_pool;
            self.market_manager._write_market(pair_id, updated_market);

            // Dispatch after add liquidity hook
            let after_params = LiquidityParams { assets, shares, receiver };
            self
                .extension_manager
                ._dispatch_after_add_liquidity(
                    market.extension, caller, pair_id, after_params,
                );

            self.reentrancy.end();
            shares
        }

        fn mint(
            ref self: ContractState, pair_id: felt252, shares: u256, receiver: ContractAddress,
        ) -> u256 {
            self.reentrancy.start();
            self._assert_not_paused();

            let market = self.market_manager._get_market(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);

            self._validate_lp_call(pair_id, market.params.is_lp_permissioned);

            let caller = get_caller_address();

            // Dispatch before add liquidity hook
            let preview_assets = self.liquidity_manager._preview_mint(shares, @market.pool);
            let before_params = LiquidityParams { assets: preview_assets, shares, receiver };
            self
                .extension_manager
                ._dispatch_before_add_liquidity(
                    market.extension, caller, pair_id, before_params,
                );

            let (assets, updated_pool) = self
                .liquidity_manager
                ._mint(pair_id, shares, caller, receiver, market.pool, market.collateral_token);

            // Update market with new pool state
            let mut updated_market = market;
            updated_market.pool = updated_pool;
            self.market_manager._write_market(pair_id, updated_market);

            // Dispatch after add liquidity hook
            let after_params = LiquidityParams { assets, shares, receiver };
            self
                .extension_manager
                ._dispatch_after_add_liquidity(
                    market.extension, caller, pair_id, after_params,
                );

            self.reentrancy.end();
            assets
        }

        fn redeem(
            ref self: ContractState, pair_id: felt252, shares: u256, receiver: ContractAddress,
        ) -> u256 {
            self.reentrancy.start();
            self._assert_not_paused();

            let market = self.market_manager._get_market(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);

            let caller = get_caller_address();

            // Dispatch before remove liquidity hook
            let preview_assets = self.liquidity_manager._preview_redeem(shares, @market.pool);
            let before_params = LiquidityParams { assets: preview_assets, shares, receiver };
            self
                .extension_manager
                ._dispatch_before_remove_liquidity(
                    market.extension, caller, pair_id, before_params,
                );

            let (assets, updated_pool) = self
                .liquidity_manager
                ._redeem(pair_id, shares, caller, receiver, market.pool, market.collateral_token);

            // Update market with new pool state
            let mut updated_market = market;
            updated_market.pool = updated_pool;
            self.market_manager._write_market(pair_id, updated_market);

            // Dispatch after remove liquidity hook
            let after_params = LiquidityParams { assets, shares, receiver };
            self
                .extension_manager
                ._dispatch_after_remove_liquidity(
                    market.extension, caller, pair_id, after_params,
                );

            self.reentrancy.end();
            assets
        }

        fn withdraw(
            ref self: ContractState, pair_id: felt252, assets: u256, receiver: ContractAddress,
        ) -> u256 {
            self.reentrancy.start();
            self._assert_not_paused();

            let market = self.market_manager._get_market(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);

            let caller = get_caller_address();

            // Dispatch before remove liquidity hook
            let preview_shares = self.liquidity_manager._preview_withdraw(assets, @market.pool);
            let before_params = LiquidityParams { assets, shares: preview_shares, receiver };
            self
                .extension_manager
                ._dispatch_before_remove_liquidity(
                    market.extension, caller, pair_id, before_params,
                );

            let (shares, updated_pool) = self
                .liquidity_manager
                ._withdraw(pair_id, assets, caller, receiver, market.pool, market.collateral_token);

            // Update market with new pool state
            let mut updated_market = market;
            updated_market.pool = updated_pool;
            self.market_manager._write_market(pair_id, updated_market);

            // Dispatch after remove liquidity hook
            let after_params = LiquidityParams { assets, shares, receiver };
            self
                .extension_manager
                ._dispatch_after_remove_liquidity(
                    market.extension, caller, pair_id, after_params,
                );

            self.reentrancy.end();
            shares
        }

        fn buy_swap(
            ref self: ContractState,
            pair_id: felt252,
            side: SwapSide,
            notional: u256,
            collateral: u256,
            max_rate_bps: u256,
            swap_term: u64,
            receiver: ContractAddress,
        ) -> u256 {
            self.reentrancy.start();
            self._assert_not_paused();

            let mut market = self.market_manager._get_market(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);

            let caller = get_caller_address();
            assert(!receiver.is_zero(), Errors::ZERO_ADDRESS);
            let current_time = get_block_timestamp();

            // Update rate index (event emitted inside MarketManager)
            let oracle_rate = self.market_manager._update_rate_index(ref market, current_time);

            // Build swap open params and dispatch before hook
            let swap_open_params = SwapOpenParams {
                side, notional, collateral, max_rate_bps, swap_term, receiver,
            };
            self
                .extension_manager
                ._dispatch_before_swap_open(market.extension, caller, pair_id, swap_open_params);

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
                    swap_term,
                    receiver,
                    @market,
                    oracle_rate,
                    config.protocol_fee_share_bps,
                );

            // Transfer collateral
            SafeERC20::strict_transfer_from(
                market.collateral_token, caller, get_contract_address(), collateral,
            );

            // Mint NFT via PositionManager (to receiver, not caller)
            self.position_manager.read().mint(receiver, swap_id);

            // Track protocol fees
            let current_protocol_fees = self.protocol_fees.read(market.collateral_token);
            self
                .protocol_fees
                .write(market.collateral_token, current_protocol_fees + protocol_portion);

            // Update market state
            market.pool = updated_pool;
            market.total_swaps_created = market.total_swaps_created + 1;
            market.active_swap_count = market.active_swap_count + 1;
            self.market_manager._write_market(pair_id, market);

            // Dispatch after swap open hook
            self
                .extension_manager
                ._dispatch_after_swap_open(
                    market.extension, caller, pair_id, swap_open_params, swap_id,
                );

            self.reentrancy.end();
            swap_id
        }

        fn settle_swap(ref self: ContractState, swap_id: u256) {
            self.reentrancy.start();
            self._assert_not_paused();

            let swap = self.swap_manager.get_swap(swap_id);
            let pair_id = swap.pair_id;
            let mut market = self.market_manager._get_market(pair_id);
            let caller = get_caller_address();

            // Dispatch before swap close hook
            self
                .extension_manager
                ._dispatch_before_swap_close(
                    market.extension, caller, pair_id, swap_id, SettlementType::Normal,
                );

            // Settle so TWA uses pre-update cumulative
            let (updated_pool, result) = self
                .swap_manager
                .settle_swap(swap_id, swap, @market);

            // NOW update rate index (for other active swaps)
            let current_time = get_block_timestamp();
            self.market_manager._update_rate_index(ref market, current_time);

            // Store payout for claim (sentinel: stored = payout + 1, so 0 = "not settled")
            self.claim_amounts.write(swap_id, result.buyer_payout + 1);

            // Update market state
            market.pool = updated_pool;
            market.active_swap_count = market.active_swap_count - 1;
            self.market_manager._write_market(pair_id, market);

            // Dispatch after swap close hook
            self
                .extension_manager
                ._dispatch_after_swap_close(
                    market.extension, caller, pair_id, swap_id, SettlementType::Normal, result,
                );

            self.reentrancy.end();
        }

        fn claim(ref self: ContractState, swap_id: u256) {
            self.reentrancy.start();
            self._assert_not_paused();

            // Only NFT owner can claim
            let position_manager = IERC721OwnerDispatcher {
                contract_address: self.position_manager.read().contract_address,
            };
            let owner = position_manager.owner_of(swap_id);
            assert(owner == get_caller_address(), Errors::UNAUTHORIZED);

            // Read and validate claim
            let stored = self.claim_amounts.read(swap_id);
            assert(stored > 0, Errors::NOTHING_TO_CLAIM);

            // CEI: clear claim before external calls
            self.claim_amounts.write(swap_id, 0);
            let payout = stored - 1; // Undo sentinel

            // Burn NFT
            self.position_manager.read().burn(swap_id);

            // Transfer payout (safe_transfer skips if amount == 0)
            let swap = self.swap_manager.get_swap(swap_id);
            let market = self.market_manager._get_market(swap.pair_id);
            SafeERC20::safe_transfer(market.collateral_token, owner, payout);

            self.emit(SwapClaimed {
                swap_id,
                owner,
                amount: payout,
                timestamp: get_block_timestamp(),
            });

            self.reentrancy.end();
        }

        fn early_exit(ref self: ContractState, swap_id: u256) {
            self.reentrancy.start();
            self._assert_not_paused();

            // Read swap once here (component won't read again)
            let swap = self.swap_manager.get_swap(swap_id);
            let pair_id = swap.pair_id; // extract before move
            let mut market = self.market_manager._get_market(pair_id);
            let caller = get_caller_address();
            let position_manager = IERC721OwnerDispatcher{contract_address: self.position_manager.read().contract_address};
            let owner = position_manager.owner_of(swap_id);
            let current_time = get_block_timestamp();

            // Update rate index
            self.market_manager._update_rate_index(ref market, current_time);

            // Dispatch before swap close hook
            self
                .extension_manager
                ._dispatch_before_swap_close(
                    market.extension, caller, pair_id, swap_id, SettlementType::EarlyExit,
                );

            // Early exit via component (pass swap by value - saves 1 storage read)
            let (updated_pool, result) = self
                .swap_manager
                .early_exit(swap_id, swap, caller, owner, @market);

            // Burn NFT via PositionManager
            self.position_manager.read().burn(swap_id);

            // Transfer payout
            SafeERC20::safe_transfer(market.collateral_token, owner, result.buyer_payout);

            // Update market state
            market.pool = updated_pool;
            market.active_swap_count = market.active_swap_count - 1;
            self.market_manager._write_market(pair_id, market);

            // Dispatch after swap close hook
            self
                .extension_manager
                ._dispatch_after_swap_close(
                    market.extension, caller, pair_id, swap_id, SettlementType::EarlyExit, result,
                );

            self.reentrancy.end();
        }

        fn get_market(self: @ContractState, pair_id: felt252) -> MarketPair {
            self.market_manager._get_market(pair_id)
        }

        fn get_swap(self: @ContractState, swap_id: u256) -> Swap {
            self.swap_manager.get_swap(swap_id)
        }

        fn get_swap_quote(
            self: @ContractState,
            pair_id: felt252,
            side: SwapSide,
            notional: u256,
            swap_term: u64,
        ) -> SwapQuote {
            let market = self.market_manager._get_market(pair_id);
            let (oracle_rate, _) = self.market_manager._get_oracle_rate(market.rate_oracle);
            self
                .swap_manager
                .get_swap_quote(
                    @market.pool, @market.params, side, notional, oracle_rate, swap_term,
                )
        }

        fn get_health_status(self: @ContractState, swap_id: u256) -> HealthStatus {
            let swap = self.swap_manager.get_swap(swap_id);
            let market = self.market_manager._get_market(swap.pair_id);
            self.swap_manager.get_health_status(swap_id, @market)
        }

        fn get_pool_analytics(self: @ContractState, pair_id: felt252) -> PoolAnalytics {
            let market = self.market_manager._get_market(pair_id);
            self.liquidity_manager._get_pool_analytics(@market.pool)
        }

        fn get_current_twa(self: @ContractState, swap_id: u256) -> u256 {
            let swap = self.swap_manager.get_swap(swap_id);
            let market = self.market_manager._get_market(swap.pair_id);
            self.swap_manager.get_current_twa(swap_id, @market.rate_index)
        }

        fn get_protocol_config(self: @ContractState) -> ProtocolConfig {
            self.protocol_config.read()
        }

        fn get_next_swap_id(self: @ContractState) -> u256 {
            self.swap_manager.get_next_swap_id()
        }

        fn set_premission_less_flag(ref self: ContractState, flag: bool) {
            self.security.assert_admin_role();
            self.permissioned_flag.write(flag);
            self.emit(FlagSet { flag });
        }

        fn whitelist_token(ref self: ContractState, token: ContractAddress) {
            self.security.assert_admin_role();
            assert(!token.is_zero(), Errors::ZERO_ADDRESS);
            self.token_whitelisted.write(token, true);
            self.emit(TokenWhitelisted { token });
        }

        fn de_whitelist_token(ref self: ContractState, token: ContractAddress) {
            self.security.assert_admin_role();
            assert(self.token_whitelisted.read(token), Errors::TOKEN_NOT_WHITELISTED);
            self.token_whitelisted.write(token, false);
            self.emit(TokenDeWhitelisted { token });
        }

        fn is_token_whitelisted(self: @ContractState, token: ContractAddress) -> bool {
            self.token_whitelisted.read(token)
        }

        fn total_assets(self: @ContractState, pair_id: felt252) -> u256 {
            let market = self.market_manager._get_market(pair_id);
            self.liquidity_manager._total_assets(@market.pool)
        }

        fn exchange_rate(self: @ContractState, pair_id: felt252) -> u256 {
            let market = self.market_manager._get_market(pair_id);
            self.liquidity_manager._exchange_rate(@market.pool)
        }

        fn convert_to_shares(self: @ContractState, pair_id: felt252, assets: u256) -> u256 {
            let market = self.market_manager._get_market(pair_id);
            self.liquidity_manager._convert_to_shares(assets, @market.pool)
        }

        fn convert_to_assets(self: @ContractState, pair_id: felt252, shares: u256) -> u256 {
            let market = self.market_manager._get_market(pair_id);
            self.liquidity_manager._convert_to_assets(shares, @market.pool)
        }

        fn preview_deposit(self: @ContractState, pair_id: felt252, assets: u256) -> u256 {
            let market = self.market_manager._get_market(pair_id);
            self.liquidity_manager._preview_deposit(assets, @market.pool)
        }

        fn preview_mint(self: @ContractState, pair_id: felt252, shares: u256) -> u256 {
            let market = self.market_manager._get_market(pair_id);
            self.liquidity_manager._preview_mint(shares, @market.pool)
        }

        fn preview_redeem(self: @ContractState, pair_id: felt252, shares: u256) -> u256 {
            let market = self.market_manager._get_market(pair_id);
            self.liquidity_manager._preview_redeem(shares, @market.pool)
        }

        fn preview_withdraw(self: @ContractState, pair_id: felt252, assets: u256) -> u256 {
            let market = self.market_manager._get_market(pair_id);
            self.liquidity_manager._preview_withdraw(assets, @market.pool)
        }

        fn max_deposit(self: @ContractState, pair_id: felt252) -> u256 {
            self.liquidity_manager._max_deposit()
        }

        fn max_mint(self: @ContractState, pair_id: felt252) -> u256 {
            self.liquidity_manager._max_mint()
        }

        fn max_withdraw(self: @ContractState, owner: ContractAddress, pair_id: felt252) -> u256 {
            let market = self.market_manager._get_market(pair_id);
            self.liquidity_manager._max_withdraw(owner, pair_id, @market.pool)
        }

        fn max_redeem(self: @ContractState, owner: ContractAddress, pair_id: felt252) -> u256 {
            let market = self.market_manager._get_market(pair_id);
            self.liquidity_manager._max_redeem(owner, pair_id, @market.pool)
        }

        fn get_swap_analytics(self: @ContractState, swap_id: u256) -> SwapAnalytics {
            self.analytics._get_swap_analytics(swap_id)
        }

        fn get_lp_analytics(
            self: @ContractState, lp: ContractAddress, pair_id: felt252,
        ) -> LpAnalytics {
            self.analytics._get_lp_analytics(lp, pair_id)
        }

        fn preview_swap_scenarios(
            self: @ContractState, swap_id: u256, rate_scenarios_bps: Span<u256>,
        ) -> Span<ScenarioResult> {
            self.analytics._preview_swap_scenarios(swap_id, rate_scenarios_bps)
        }

        fn get_breakeven_rate(self: @ContractState, swap_id: u256) -> u256 {
            self.analytics._get_breakeven_rate(swap_id)
        }

        fn set_call_points(ref self: ContractState, call_points: CallPoints) {
            self.reentrancy.start();
            self.extension_manager.set_call_points(call_points);
            self.reentrancy.end();
        }

        fn withdraw_to_extension(ref self: ContractState, pair_id: felt252, amount: u256) {
            self.reentrancy.start();
            let caller = get_caller_address();
            let market = self.market_manager._get_market(pair_id);
            assert(market.extension == caller, Errors::NOT_MARKET_EXTENSION);

            SafeERC20::safe_transfer(market.collateral_token, caller, amount);

            self.reentrancy.end();
        }

        fn receive_from_extension(ref self: ContractState, pair_id: felt252, amount: u256) {
            self.reentrancy.start();
            let caller = get_caller_address();
            let market = self.market_manager._get_market(pair_id);
            assert(market.extension == caller, Errors::NOT_MARKET_EXTENSION);

            SafeERC20::strict_transfer_from(
                market.collateral_token, caller, get_contract_address(), amount,
            );

            self.reentrancy.end();
        }

        fn poke_rate_index(ref self: ContractState, pair_id: felt252) {
            self.reentrancy.start();
            self._assert_not_paused();
            let mut market = self.market_manager._get_market(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);
            let current_time = get_block_timestamp();

            // Event emitted inside MarketManager
            self.market_manager._update_rate_index(ref market, current_time);

            self.market_manager._write_market(pair_id, market);

            self.reentrancy.end()
        }

        fn get_user_swaps_summary(
            self: @ContractState, swap_ids: Span<u256>,
        ) -> Span<UserSwapSummary> {
            self.analytics._get_user_swaps_summary(swap_ids)
        }

        fn get_user_dashboard(
            self: @ContractState,
            user: ContractAddress,
            swap_ids: Span<u256>,
            lp_pair_ids: Span<felt252>,
        ) -> UserDashboard {
            self.analytics._get_user_dashboard(user, swap_ids, lp_pair_ids)
        }

        fn get_user_lp_summary(
            self: @ContractState, user: ContractAddress, pair_ids: Span<felt252>,
        ) -> Span<UserLpSummary> {
            self.analytics._get_user_lp_summary(user, pair_ids)
        }

        fn update_protocol_config(ref self: ContractState, config: ProtocolConfig) {
            self.security.assert_admin_role();
            assert(!config.fee_token.is_zero(), Errors::ZERO_ADDRESS);
            assert(!config.treasury.is_zero(), Errors::ZERO_ADDRESS);
            assert(config.protocol_fee_share_bps <= (Constants::BPS / 5), Errors::INVALID_PARAMS);
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

            SafeERC20::strict_transfer(token, recipient, amount);

            self.emit(ProtocolFeesWithdrawn { token, amount, recipient });
        }
    }


    impl ERC6909HooksImpl of ERC6909Component::ERC6909HooksTrait<ContractState> {
        fn before_update(
            ref self: ERC6909Component::ComponentState<ContractState>,
            from: ContractAddress,
            recipient: ContractAddress,
            id: u256,
            amount: u256,
        ) {}
        fn after_update(
            ref self: ERC6909Component::ComponentState<ContractState>,
            from: ContractAddress,
            recipient: ContractAddress,
            id: u256,
            amount: u256,
        ) {}
    }


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
                let fee_token_addr = protocol_config.fee_token;
                SafeERC20::strict_transfer_from(
                    fee_token_addr,
                    caller,
                    get_contract_address(),
                    protocol_config.market_creation_fees,
                );

                // Track in protocol_fees
                let current = self.protocol_fees.read(fee_token_addr);
                self
                    .protocol_fees
                    .write(fee_token_addr, current + protocol_config.market_creation_fees);
            }
        }
    }
}
