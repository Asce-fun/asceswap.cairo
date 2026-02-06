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
    use crate::helpers::signed_value::{negative, positive};
    use crate::interfaces::asce_swap::IAsceSwap;
    use crate::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use crate::types::asce_swap::{
        HealthStatus, LpAnalytics, LpPosition, MarketPair, MarketParams, MarketStatus,
        PoolAnalytics, ProtocolConfig, ScenarioResult, SignedValue, Swap, SwapAnalytics, SwapQuote,
        SwapSide, SwapStatus, UserDashboard, UserLpSummary, UserSwapSummary,
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
        // ============================================================
        // TODO [MAINNET]: Replace with off-chain indexer (Apibara)
        // This pattern works for MVP but doesn't scale to 1000s of positions.
        // For testnet only. Use events + indexer in production.
        // ============================================================
        // User swap tracking: (user, index) -> swap_id
        user_swap_ids: Map<(ContractAddress, u32), u256>,
        user_swap_count: Map<ContractAddress, u32>,
        // User LP tracking: (user, index) -> pair_id
        user_lp_pairs: Map<(ContractAddress, u32), felt252>,
        user_lp_count: Map<ContractAddress, u32>,
        // Track if user already has LP in a pair (to avoid duplicates)
        user_has_lp_in_pair: Map<(ContractAddress, felt252), bool>,
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

            self._validate_permission_call();

            // Validations
            assert(!rate_oracle.is_zero(), Errors::ZERO_ADDRESS);
            assert(!collateral_token.is_zero(), Errors::ZERO_ADDRESS);
            assert(!curator.is_zero(), Errors::ZERO_ADDRESS);

            let pair_id = self
                .market_manager
                ._create_market_pair(rate_oracle, collateral_token, curator, params);

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
            self.market_manager._pause_market(pair_id);
        }

        fn unpause_market(ref self: ContractState, pair_id: felt252) {
            self.security.assert_admin_role();
            self.market_manager._unpause_market(pair_id);
        }

        //LP OPERATIONS

        fn supply_lp_collateral(ref self: ContractState, pair_id: felt252, amount: u256) -> u256 {
            self.reentrancy.start();
            self._assert_not_paused();

            let market = self.market_manager._get_market(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);

            self._validate_lp_call(pair_id, market.params.is_lp_permissioned);

            let caller = get_caller_address();
            let config = self.protocol_config.read();

            let (shares, updated_pool) = self
                .liquidity_manager
                ._supply_lp_collateral(
                    pair_id, amount, caller, market.pool, @config, market.collateral_token,
                );

            // Update market with new pool state
            let mut updated_market = market;
            updated_market.pool = updated_pool;
            self.market_manager._write_market(pair_id, updated_market);

            // TODO [MAINNET]: Remove - use indexer instead
            // Track user's LP pairs (only if first deposit to this pair)
            if !self.user_has_lp_in_pair.read((caller, pair_id)) {
                let lp_index = self.user_lp_count.read(caller);
                self.user_lp_pairs.write((caller, lp_index), pair_id);
                self.user_lp_count.write(caller, lp_index + 1);
                self.user_has_lp_in_pair.write((caller, pair_id), true);
            }

            self.reentrancy.end();
            shares
        }

        fn withdraw_lp_collateral(ref self: ContractState, pair_id: felt252, shares: u256) -> u256 {
            self.reentrancy.start();
            self._assert_not_paused();

            let market = self.market_manager._get_market(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);

            let caller = get_caller_address();

            let (amount, updated_pool) = self
                .liquidity_manager
                ._withdraw_lp_collateral(
                    pair_id, shares, caller, market.pool, market.collateral_token,
                );

            // Update market with new pool state
            let mut updated_market = market;
            updated_market.pool = updated_pool;
            self.market_manager._write_market(pair_id, updated_market);

            self.reentrancy.end();
            amount
        }

        //SWAP OPERATIONS

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

            let mut market = self.market_manager._get_market(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);

            let caller = get_caller_address();
            let current_time = get_block_timestamp();

            // Update rate index
            let oracle_rate = self.market_manager._update_rate_index(ref market, current_time);

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
            self.market_manager._write_market(pair_id, market);

            // TODO [MAINNET]: Remove - use indexer instead
            // Track user's swap IDs (for enumeration)
            let swap_index = self.user_swap_count.read(caller);
            self.user_swap_ids.write((caller, swap_index), swap_id);
            self.user_swap_count.write(caller, swap_index + 1);

            self.reentrancy.end();
            swap_id
        }

        fn settle_swap(ref self: ContractState, swap_id: u256) {
            self.reentrancy.start();
            self._assert_not_paused();

            // Read swap once here
            let swap = self.swap_manager.get_swap(swap_id);
            let pair_id = swap.pair_id; // extract before move
            let mut market = self.market_manager._get_market(pair_id);
            let owner = self.erc721.owner_of(swap_id);
            let current_time = get_block_timestamp();

            // Update rate index
            self.market_manager._update_rate_index(ref market, current_time);

            //call settlement for swap
            let (updated_pool, result) = self
                .swap_manager
                .settle_swap(swap_id, swap, owner, @market);

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
            self.market_manager._write_market(pair_id, market);

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
            let owner = self.erc721.owner_of(swap_id);
            let current_time = get_block_timestamp();

            // Update rate index
            self.market_manager._update_rate_index(ref market, current_time);

            // Early exit via component (pass swap by value - saves 1 storage read)
            let (updated_pool, result) = self
                .swap_manager
                .early_exit(swap_id, swap, caller, owner, @market);

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
            self.market_manager._write_market(pair_id, market);

            self.reentrancy.end();
        }

        fn liquidate(ref self: ContractState, swap_id: u256) {
            self.reentrancy.start();
            self._assert_not_paused();

            // Read swap once here (component won't read again)
            let swap = self.swap_manager.get_swap(swap_id);
            let pair_id = swap.pair_id; // extract before move
            let mut market = self.market_manager._get_market(pair_id);
            let liquidator = get_caller_address();
            let owner = self.erc721.owner_of(swap_id);
            let current_time = get_block_timestamp();

            // Update rate index
            self.market_manager._update_rate_index(ref market, current_time);

            // Liquidate via component (pass swap by value - saves 1 storage read)
            let (updated_pool, result, _health_status) = self
                .swap_manager
                .liquidate(swap_id, swap, liquidator, owner, @market);

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
            self.market_manager._write_market(pair_id, market);

            self.reentrancy.end();
        }

        fn get_market(self: @ContractState, pair_id: felt252) -> MarketPair {
            self.market_manager._get_market(pair_id)
        }

        fn get_swap(self: @ContractState, swap_id: u256) -> Swap {
            self.swap_manager.get_swap(swap_id)
        }

        fn get_swap_quote(
            self: @ContractState, pair_id: felt252, side: SwapSide, notional: u256,
        ) -> SwapQuote {
            let market = self.market_manager._get_market(pair_id);
            let (oracle_rate, _) = self.market_manager._get_oracle_rate(market.rate_oracle);
            self
                .swap_manager
                .get_swap_quote(@market.pool, @market.params, side, notional, oracle_rate)
        }

        fn get_health_status(self: @ContractState, swap_id: u256) -> HealthStatus {
            let swap = self.swap_manager.get_swap(swap_id);
            let market = self.market_manager._get_market(swap.pair_id);
            self.swap_manager.get_health_status(swap_id, @market)
        }

        fn get_lp_position(
            self: @ContractState, lp: ContractAddress, pair_id: felt252,
        ) -> LpPosition {
            self.liquidity_manager._get_lp_position(lp, pair_id)
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
            self.emit(FlagSetted { flag });
        }


        fn exchange_rate_for_lp(self: @ContractState, pair_id: felt252) -> u256 {
            let market = self.market_manager._get_market(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);
            self.liquidity_manager._exchange_rate(@market.pool)
        }

        fn convert_to_shares_for_lp(self: @ContractState, assets: u256, pair_id: felt252) -> u256 {
            let market = self.market_manager._get_market(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);
            self.liquidity_manager._convert_to_shares(assets, @market.pool)
        }

        fn convert_to_assets_for_lp(self: @ContractState, assets: u256, pair_id: felt252) -> u256 {
            let market = self.market_manager._get_market(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);
            self.liquidity_manager._convert_to_assets(assets, @market.pool)
        }

        fn preview_deposit_for_lp(self: @ContractState, assets: u256, pair_id: felt252) -> u256 {
            let market = self.market_manager._get_market(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);
            let config = self.protocol_config.read();
            self.liquidity_manager._preview_deposit(assets, @market.pool, @config)
        }

        fn preview_withdraw_for_lp(self: @ContractState, assets: u256, pair_id: felt252) -> u256 {
            let market = self.market_manager._get_market(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);
            self.liquidity_manager._preview_withdraw(assets, @market.pool)
        }

        /// Check if cooldown period has passed for an LP
        fn is_cooldown_met(self: @ContractState, lp: ContractAddress, pair_id: felt252) -> bool {
            self.liquidity_manager._is_cooldown_met(lp, pair_id)
        }
        /// Get LP's share balance
        fn balance_of_lp(self: @ContractState, lp: ContractAddress, pair_id: felt252) -> u256 {
            self.liquidity_manager._balance_of(lp, pair_id)
        }

        // ============== Analytics Functions ==============

        fn get_swap_analytics(self: @ContractState, swap_id: u256) -> SwapAnalytics {
            let swap = self.swap_manager.get_swap(swap_id);
            let market = self.market_manager._get_market(swap.pair_id);
            let health = self.swap_manager.get_health_status(swap_id, @market);
            let current_time = get_block_timestamp();

            // Get current floating rate from oracle
            let (current_floating_rate_bps, _) = self
                .market_manager
                ._get_oracle_rate(market.rate_oracle);

            // Calculate spread: floating - fixed
            let current_spread_bps = if current_floating_rate_bps >= swap.fixed_rate_bps {
                positive(current_floating_rate_bps - swap.fixed_rate_bps)
            } else {
                negative(swap.fixed_rate_bps - current_floating_rate_bps)
            };

            // Calculate leverage: notional / collateral * 100
            let leverage_x100 = if swap.buyer_collateral > 0 {
                (swap.notional * 100) / swap.buyer_collateral
            } else {
                0
            };

            // Time calculations
            let term_seconds = swap.expiration_time - swap.start_time;
            let elapsed_seconds = if current_time > swap.start_time {
                if current_time > swap.expiration_time {
                    term_seconds
                } else {
                    current_time - swap.start_time
                }
            } else {
                0
            };
            let remaining_seconds = if current_time < swap.expiration_time {
                swap.expiration_time - current_time
            } else {
                0
            };

            // Progress in bps (0-10000)
            let progress_bps = if term_seconds > 0 {
                (elapsed_seconds.into() * Constants::BPS) / term_seconds.into()
            } else {
                0
            };

            // Calculate yield (annualized based on current spread and leverage)
            // yield_term = spread * leverage * (365 / term_days)
            let term_days = term_seconds / 86400;
            let yield_term_bps = if term_days > 0 && swap.buyer_collateral > 0 {
                // yield = spread_bps * leverage * (365 / term_days)
                // This gives annualized yield in bps
                let spread_value = current_spread_bps.value;
                let annualization_factor = 365_u256 / term_days.into();
                let yield_value = (spread_value * leverage_x100 * annualization_factor) / 100;

                // Adjust sign based on swap side
                match swap.side {
                    SwapSide::Fixed => {
                        // Fixed side profits when floating > fixed (positive spread)
                        if current_spread_bps.is_negative {
                            negative(yield_value)
                        } else {
                            positive(yield_value)
                        }
                    },
                    SwapSide::Floating => {
                        // Floating side profits when floating < fixed (negative spread)
                        if current_spread_bps.is_negative {
                            positive(yield_value)
                        } else {
                            negative(yield_value)
                        }
                    },
                }
            } else {
                positive(0)
            };

            // Projected PnL at expiry if rate stays the same
            let projected_pnl_at_expiry = self
                ._calculate_projected_pnl(@swap, current_floating_rate_bps, swap.expiration_time);

            SwapAnalytics {
                current_pnl: health.current_pnl,
                current_floating_rate_bps,
                fixed_rate_bps: swap.fixed_rate_bps,
                current_spread_bps,
                leverage_x100,
                yield_term_bps,
                current_return: health.current_pnl,
                notional: swap.notional,
                collateral: swap.buyer_collateral,
                health_factor_bps: health.health_factor_bps,
                is_liquidatable: health.is_liquidatable,
                elapsed_seconds,
                remaining_seconds,
                progress_bps,
                projected_pnl_at_expiry,
            }
        }

        fn get_lp_analytics(
            self: @ContractState, lp: ContractAddress, pair_id: felt252,
        ) -> LpAnalytics {
            let market = self.market_manager._get_market(pair_id);
            let lp_position = self.liquidity_manager._get_lp_position(lp, pair_id);
            let pool_analytics = self.liquidity_manager._get_pool_analytics(@market.pool);

            // Calculate share value
            let share_value = self
                .liquidity_manager
                ._convert_to_assets(lp_position.shares, @market.pool);

            // Calculate share percentage (in bps)
            let share_percentage_bps = if market.pool.total_shares > 0 {
                (lp_position.shares * Constants::BPS) / market.pool.total_shares
            } else {
                0
            };

            // Calculate total utilization
            let total_locked = market.pool.locked_for_fixed + market.pool.locked_for_floating;
            let utilization_bps = if market.pool.total_collateral > 0 {
                (total_locked * Constants::BPS) / market.pool.total_collateral
            } else {
                0
            };

            // Calculate your share of the net exposure
            let your_exposure = if share_percentage_bps > 0 {
                let exposure_value = (pool_analytics.net_exposure_notional.value
                    * share_percentage_bps)
                    / Constants::BPS;
                if pool_analytics.net_exposure_notional.is_negative {
                    negative(exposure_value)
                } else {
                    positive(exposure_value)
                }
            } else {
                positive(0)
            };

            // Check withdrawal capability
            let can_withdraw = self.liquidity_manager._is_cooldown_met(lp, pair_id);
            let max_withdrawable = if can_withdraw {
                // Max is lesser of: share value or available liquidity
                if share_value < pool_analytics.available_liquidity {
                    share_value
                } else {
                    pool_analytics.available_liquidity
                }
            } else {
                0
            };

            LpAnalytics {
                shares: lp_position.shares,
                share_value,
                share_percentage_bps,
                pool_tvl: pool_analytics.total_value,
                available_liquidity: pool_analytics.available_liquidity,
                utilization_bps,
                net_exposure: pool_analytics.net_exposure_notional,
                your_exposure,
                can_withdraw,
                max_withdrawable,
            }
        }

        fn preview_swap_scenarios(
            self: @ContractState, swap_id: u256, rate_scenarios_bps: Span<u256>,
        ) -> Span<ScenarioResult> {
            let swap = self.swap_manager.get_swap(swap_id);
            let mut results: Array<ScenarioResult> = array![];

            for rate_bps in rate_scenarios_bps {
                let pnl = self._calculate_projected_pnl(@swap, *rate_bps, swap.expiration_time);
                let is_profitable = !pnl.is_negative && pnl.value > 0;

                results.append(ScenarioResult { rate_bps: *rate_bps, pnl, is_profitable });
            }

            results.span()
        }

        fn get_breakeven_rate(self: @ContractState, swap_id: u256) -> u256 {
            let swap = self.swap_manager.get_swap(swap_id);
            // Breakeven is simply the fixed rate for both sides
            // For Fixed side: profitable when floating > fixed
            // For Floating side: profitable when floating < fixed
            // Breakeven is when floating == fixed
            swap.fixed_rate_bps
        }

        // ============== User Dashboard Functions ==============

        fn get_user_swaps_summary(
            self: @ContractState, swap_ids: Span<u256>,
        ) -> Span<UserSwapSummary> {
            let mut summaries: Array<UserSwapSummary> = array![];
            let current_time = get_block_timestamp();

            for swap_id in swap_ids {
                let swap = self.swap_manager.get_swap(*swap_id);
                let market = self.market_manager._get_market(swap.pair_id);
                let health = self.swap_manager.get_health_status(*swap_id, @market);

                // Calculate progress
                let term_seconds = swap.expiration_time - swap.start_time;
                let elapsed = if current_time > swap.start_time {
                    if current_time > swap.expiration_time {
                        term_seconds
                    } else {
                        current_time - swap.start_time
                    }
                } else {
                    0
                };
                let progress_bps = if term_seconds > 0 {
                    (elapsed.into() * Constants::BPS) / term_seconds.into()
                } else {
                    0
                };

                let remaining_seconds = if current_time < swap.expiration_time {
                    swap.expiration_time - current_time
                } else {
                    0
                };

                summaries
                    .append(
                        UserSwapSummary {
                            swap_id: *swap_id,
                            pair_id: swap.pair_id,
                            side: swap.side,
                            status: swap.status,
                            notional: swap.notional,
                            collateral: swap.buyer_collateral,
                            current_pnl: health.current_pnl,
                            health_factor_bps: health.health_factor_bps,
                            progress_bps,
                            remaining_seconds,
                        },
                    );
            }

            summaries.span()
        }

        fn get_user_dashboard(
            self: @ContractState,
            user: ContractAddress,
            swap_ids: Span<u256>,
            lp_pair_ids: Span<felt252>,
        ) -> UserDashboard {
            let mut total_swaps: u32 = 0;
            let mut active_swaps: u32 = 0;
            let mut total_notional: u256 = 0;
            let mut total_collateral_locked: u256 = 0;
            let mut total_pnl_value: u256 = 0;
            let mut total_pnl_negative: bool = false;

            // Process swaps
            for swap_id in swap_ids {
                let swap = self.swap_manager.get_swap(*swap_id);
                let market = self.market_manager._get_market(swap.pair_id);
                let health = self.swap_manager.get_health_status(*swap_id, @market);

                total_swaps += 1;

                if swap.status == SwapStatus::Active {
                    active_swaps += 1;
                    total_notional += swap.notional;
                    total_collateral_locked += swap.buyer_collateral;

                    // Aggregate PnL (simplified - just track magnitude)
                    if health.current_pnl.is_negative {
                        if total_pnl_value >= health.current_pnl.value {
                            total_pnl_value -= health.current_pnl.value;
                        } else {
                            total_pnl_value = health.current_pnl.value - total_pnl_value;
                            total_pnl_negative = true;
                        }
                    } else {
                        if total_pnl_negative {
                            if total_pnl_value >= health.current_pnl.value {
                                total_pnl_value -= health.current_pnl.value;
                            } else {
                                total_pnl_value = health.current_pnl.value - total_pnl_value;
                                total_pnl_negative = false;
                            }
                        } else {
                            total_pnl_value += health.current_pnl.value;
                        }
                    }
                }
            }

            // Process LP positions
            let mut total_lp_value: u256 = 0;
            let mut total_lp_positions: u32 = 0;

            for pair_id in lp_pair_ids {
                let lp_position = self.liquidity_manager._get_lp_position(user, *pair_id);
                if lp_position.shares > 0 {
                    let market = self.market_manager._get_market(*pair_id);
                    let share_value = self
                        .liquidity_manager
                        ._convert_to_assets(lp_position.shares, @market.pool);
                    total_lp_value += share_value;
                    total_lp_positions += 1;
                }
            }

            // Calculate total portfolio value
            let total_portfolio_value = if total_pnl_negative {
                if total_collateral_locked >= total_pnl_value {
                    total_collateral_locked - total_pnl_value + total_lp_value
                } else {
                    total_lp_value
                }
            } else {
                total_collateral_locked + total_pnl_value + total_lp_value
            };

            UserDashboard {
                total_swaps,
                active_swaps,
                total_notional,
                total_collateral_locked,
                total_unrealized_pnl: if total_pnl_negative {
                    negative(total_pnl_value)
                } else {
                    positive(total_pnl_value)
                },
                total_lp_value,
                total_lp_positions,
                total_portfolio_value,
            }
        }

        fn get_user_lp_summary(
            self: @ContractState, user: ContractAddress, pair_ids: Span<felt252>,
        ) -> Span<UserLpSummary> {
            let mut summaries: Array<UserLpSummary> = array![];

            for pair_id in pair_ids {
                let lp_position = self.liquidity_manager._get_lp_position(user, *pair_id);

                if lp_position.shares > 0 {
                    let market = self.market_manager._get_market(*pair_id);
                    let share_value = self
                        .liquidity_manager
                        ._convert_to_assets(lp_position.shares, @market.pool);

                    let share_percentage_bps = if market.pool.total_shares > 0 {
                        (lp_position.shares * Constants::BPS) / market.pool.total_shares
                    } else {
                        0
                    };

                    let total_locked = market.pool.locked_for_fixed
                        + market.pool.locked_for_floating;
                    let utilization_bps = if market.pool.total_collateral > 0 {
                        (total_locked * Constants::BPS) / market.pool.total_collateral
                    } else {
                        0
                    };

                    let can_withdraw = self.liquidity_manager._is_cooldown_met(user, *pair_id);

                    summaries
                        .append(
                            UserLpSummary {
                                pair_id: *pair_id,
                                shares: lp_position.shares,
                                share_value,
                                share_percentage_bps,
                                utilization_bps,
                                can_withdraw,
                            },
                        );
                }
            }

            summaries.span()
        }

        // ============================================================
        // TODO [MAINNET]: Replace with off-chain indexer (Apibara)
        // These functions iterate through on-chain arrays - O(n) reads.
        // For testnet/MVP only.
        // ============================================================

        fn get_user_swap_ids(self: @ContractState, user: ContractAddress) -> Span<u256> {
            let count = self.user_swap_count.read(user);
            let mut swap_ids: Array<u256> = array![];

            let mut i: u32 = 0;
            while i < count {
                let swap_id = self.user_swap_ids.read((user, i));
                // Only include if user still owns it (handles transfers)
                let owner = self.erc721.owner_of(swap_id);
                if owner == user {
                    swap_ids.append(swap_id);
                }
                i += 1;
            }

            swap_ids.span()
        }

        fn get_user_lp_pair_ids(self: @ContractState, user: ContractAddress) -> Span<felt252> {
            let count = self.user_lp_count.read(user);
            let mut pair_ids: Array<felt252> = array![];

            let mut i: u32 = 0;
            while i < count {
                let pair_id = self.user_lp_pairs.read((user, i));
                // Only include if user still has shares
                let position = self.liquidity_manager._get_lp_position(user, pair_id);
                if position.shares > 0 {
                    pair_ids.append(pair_id);
                }
                i += 1;
            }

            pair_ids.span()
        }

        fn get_user_swap_count(self: @ContractState, user: ContractAddress) -> u32 {
            // Returns raw count (may include transferred swaps)
            // Use get_user_swap_ids for accurate count
            self.user_swap_count.read(user)
        }

        fn get_user_lp_count(self: @ContractState, user: ContractAddress) -> u32 {
            // Returns raw count (may include withdrawn positions)
            // Use get_user_lp_pair_ids for accurate count
            self.user_lp_count.read(user)
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

        /// Calculate projected PnL for a swap at a given rate and time
        fn _calculate_projected_pnl(
            self: @ContractState, swap: @Swap, projected_rate_bps: u256, at_time: u64,
        ) -> SignedValue {
            let notional = *swap.notional;
            let fixed_rate = *swap.fixed_rate_bps;
            let term_seconds = at_time - *swap.start_time;

            // Calculate payments using rate engine formula
            // payment = notional * rate_bps * term_seconds / (BPS * SECONDS_PER_YEAR)
            let seconds_per_year: u256 = 31536000; // 365 days

            let fixed_payment = (notional * fixed_rate * term_seconds.into())
                / (Constants::BPS * seconds_per_year);
            let floating_payment = (notional * projected_rate_bps * term_seconds.into())
                / (Constants::BPS * seconds_per_year);

            // PnL depends on swap side
            match *swap.side {
                SwapSide::Fixed => {
                    // Fixed side: pays fixed, receives floating
                    // Profit when floating > fixed
                    if floating_payment >= fixed_payment {
                        positive(floating_payment - fixed_payment)
                    } else {
                        negative(fixed_payment - floating_payment)
                    }
                },
                SwapSide::Floating => {
                    // Floating side: pays floating, receives fixed
                    // Profit when fixed > floating
                    if fixed_payment >= floating_payment {
                        positive(fixed_payment - floating_payment)
                    } else {
                        negative(floating_payment - fixed_payment)
                    }
                },
            }
        }
    }
}
