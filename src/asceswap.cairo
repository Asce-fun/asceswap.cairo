#[starknet::contract]
pub mod Asceswap {
    use core::num::traits::Zero;
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
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
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
        swaps: Map<u256, Swap>,
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
        LpWithdrawn: LpWithdrawn,
        SwapCreated: SwapCreated,
        RateIndexUpdated: RateIndexUpdated,
        SwapSettled: SwapSettled,
        SwapExitedEarly: SwapExitedEarly,
        SwapLiquidated: SwapLiquidated,
        ProtocolConfigUpdated: ProtocolConfigUpdated,
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

    #[derive(Drop, starknet::Event)]
    pub struct LpWithdrawn {
        #[key]
        pub lp: ContractAddress,
        #[key]
        pub pair_id: felt252,
        pub shares_burned: u256,
        pub amount_received: u256,
    }


    #[derive(Drop, starknet::Event)]
    pub struct SwapCreated {
        #[key]
        pub swap_id: u256,
        #[key]
        pub pair_id: felt252,
        pub buyer: ContractAddress,
        pub side: SwapSide,
        pub notional: u256,
        pub fixed_rate_bps: u256,
        pub buyer_collateral: u256,
        pub lp_collateral_locked: u256,
        pub expiration_time: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct RateIndexUpdated {
        #[key]
        pub pair_id: felt252,
        pub new_rate_bps: u256,
        pub cumulative_rate_time: u256,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SwapSettled {
        #[key]
        pub swap_id: u256,
        pub owner: ContractAddress,
        pub twa_rate_bps: u256,
        pub pnl: SignedValue,
        pub buyer_payout: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SwapExitedEarly {
        #[key]
        pub swap_id: u256,
        pub owner: ContractAddress,
        pub twa_rate_bps: u256,
        pub pnl: SignedValue,
        pub penalty: u256,
        pub buyer_payout: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SwapLiquidated {
        #[key]
        pub swap_id: u256,
        pub liquidator: ContractAddress,
        pub owner: ContractAddress,
        pub health_factor_bps: u256,
        pub liquidator_bonus: u256,
        pub remaining_to_pool: u256,
    }
    #[derive(Drop, starknet::Event)]
    pub struct ProtocolConfigUpdated {
        pub config: ProtocolConfig,
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
            market_creation_fees: Constants::MARKET_CREATION_FEE,
        };

        self.protocol_config.write(config);

        self.next_pair_id.write(1);
        self.next_swap_id.write(1);
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
            self.security._renack_start();
            self._assert_not_paused();

            assert(!rate_oracle.is_zero(), Errors::ZERO_ADDRESS);
            assert(!collateral_token.is_zero(), Errors::ZERO_ADDRESS);
            assert(!curator.is_zero(), Errors::ZERO_ADDRESS);

            // Validate params
            self._validate_market_params(@params);
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

            if params.is_lp_permissioned {
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

        //receiver params should be helpful in case any external protocol use this as intermediatory
        fn supply_lp_collateral(ref self: ContractState, pair_id: felt252, amount: u256) -> u256 {
            self.security._renack_start();
            self._assert_not_paused();
            assert(amount >= Constants::MIN_LP_DEPOSIT, Errors::BELOW_MIN_DEPOSIT);
            let mut market = self.markets.read(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);

            self._validate_lp_call(pair_id, market.params.is_lp_permissioned);

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

            self.security._renack_end();

            shares_to_mint
        }

        fn withdraw_lp_collateral(ref self: ContractState, pair_id: felt252, shares: u256) -> u256 {
            self.security._renack_start();
            self._assert_not_paused();
            let mut market = self.markets.read(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);
            let caller = get_caller_address();
            let mut position = self.lp_positions.read((caller, pair_id));
            assert(position.shares >= shares, Errors::INSUFFICIENT_SHARES);
            let current_time = get_block_timestamp();
            assert(
                current_time >= position.last_deposit_time + Constants::MIN_LP_COOLDOWN_SECONDS,
                Errors::LP_COOLDOWN_NOT_MET,
            );

            let mut pool = market.pool;

            // Calculate withdrawal amount
            let withdrawal_amount = calculate_withdrawal_amount(
                shares, pool.total_shares, pool.total_collateral,
            );

            // Check available liquidity (not locked)
            let available = pool.total_collateral
                - pool.locked_for_fixed
                - pool.locked_for_floating;
            assert(withdrawal_amount <= available, Errors::EXCEEDS_AVAILABLE_LIQUIDITY);

            position.shares = position.shares - shares;
            self.lp_positions.write((caller, pair_id), position);

            pool.total_shares = pool.total_shares - shares;
            pool.total_collateral = pool.total_collateral - withdrawal_amount;
            market.pool = pool;
            self.markets.write(pair_id, market);

            let token = IERC20Dispatcher { contract_address: market.collateral_token };
            let success = token.transfer(caller, withdrawal_amount);
            assert(success, Errors::TRANSFER_FAILED);

            self
                .emit(
                    LpWithdrawn {
                        lp: caller,
                        pair_id,
                        shares_burned: shares,
                        amount_received: withdrawal_amount,
                    },
                );

            self.security._renack_end();

            withdrawal_amount
        }

        // Buiying a Swap
        fn buy_swap(
            ref self: ContractState,
            pair_id: felt252,
            side: SwapSide,
            notional: u256,
            collateral: u256,
            max_rate_bps: u256,
        ) -> u256 {
            self.security._renack_start();
            self._assert_not_paused();
            let mut market = self.markets.read(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);
            assert(notional >= market.params.min_notional, Errors::BELOW_MIN_NOTIONAL);
            assert(notional <= market.params.max_notional_per_swap, Errors::ABOVE_MAX_NOTIONAL);
            assert(collateral > 0, Errors::ZERO_AMOUNT);

            let caller = get_caller_address();
            let current_time = get_block_timestamp();

            //UPDATE RATE INDEX
            let oracle_rate = self._update_rate_index(ref market, current_time);
            //CALCULATE SWAP RATE
            let (final_rate, _adjustment, _is_positive) = self
                ._calculate_swap_rate(@market, side, oracle_rate);

            // Slippage check
            assert(final_rate <= max_rate_bps, Errors::RATE_EXCEEDS_MAX);

            // CALCULATE REQUIREMENTS
            let term_seconds = market.params.swap_term_seconds;
            let required_margin = calculate_required_margin(
                notional, final_rate, term_seconds, market.params.initial_margin_multiplier_bps,
            );

            // LP must lock same amount
            let lp_collateral_needed = required_margin;

            //  CALCULATE Fees
            let swap_fee = calculate_fee(collateral, market.params.swap_fee_bps);
            // let insurance_portion = calculate_fee(swap_fee, market.params.insurance_share_bps);
            let protocol_portion = calculate_fee(
                swap_fee, self.protocol_config.read().protocol_fee_share_bps,
            );
            let lp_fee_portion = swap_fee - protocol_portion;
            let net_collateral = collateral - swap_fee;

            assert(net_collateral >= required_margin, Errors::INSUFFICIENT_COLLATERAL);

            // Check pool has enough available
            let mut pool = market.pool;
            let available = pool.total_collateral
                - pool.locked_for_fixed
                - pool.locked_for_floating;
            assert(available >= lp_collateral_needed, Errors::INSUFFICIENT_LIQUIDITY);

            // Check utilization cap
            let locked_for_side = match side {
                SwapSide::Fixed => pool.locked_for_fixed,
                SwapSide::Floating => pool.locked_for_floating,
            };
            let new_locked = locked_for_side + lp_collateral_needed;
            let utilization = mul_div_up(new_locked, Constants::BPS, pool.total_collateral);
            assert(
                utilization <= market.params.max_utilization_bps, Errors::EXCEEDS_MAX_UTILIZATION,
            );

            // CREATE SWAP
            let swap_id = self.next_swap_id.read();
            self.next_swap_id.write(swap_id + 1);

            let swap = Swap {
                swap_id,
                pair_id,
                side,
                status: SwapStatus::Active,
                notional,
                fixed_rate_bps: final_rate,
                buyer_collateral: net_collateral,
                lp_collateral_locked: lp_collateral_needed,
                initial_required_margin: required_margin,
                start_time: current_time,
                expiration_time: current_time + term_seconds,
                start_cumulative_rate: market.rate_index.cumulative_rate_time,
            };

            // EFFECTS
            self.swaps.write(swap_id, swap);

            // Lock LP collateral for appropriate side
            match side {
                SwapSide::Fixed => {
                    pool.locked_for_fixed = pool.locked_for_fixed + lp_collateral_needed;
                },
                SwapSide::Floating => {
                    pool.locked_for_floating = pool.locked_for_floating + lp_collateral_needed;
                },
            }

            pool.total_collateral = pool.total_collateral + lp_fee_portion;

            market.pool = pool;
            market.total_swaps_created = market.total_swaps_created + 1;
            market.active_swap_count = market.active_swap_count + 1;
            self.markets.write(pair_id, market);

            // Track protocol fees
            let current_protocol_fees = self.protocol_fees.read(market.collateral_token);
            self
                .protocol_fees
                .write(market.collateral_token, current_protocol_fees + protocol_portion);

            let token = IERC20Dispatcher { contract_address: market.collateral_token };
            let success = token.transfer_from(caller, get_contract_address(), collateral);
            assert(success, Errors::TRANSFER_FROM_FAILED);

            // Mint NFT
            self.erc721.mint(caller, swap_id);

            // EMIT
            self
                .emit(
                    SwapCreated {
                        swap_id,
                        pair_id,
                        buyer: caller,
                        side,
                        notional,
                        fixed_rate_bps: final_rate,
                        buyer_collateral: net_collateral,
                        lp_collateral_locked: lp_collateral_needed,
                        expiration_time: current_time + term_seconds,
                    },
                );

            self.security._renack_end();
            swap_id
        }


        fn settle_swap(ref self: ContractState, swap_id: u256) {
            self.security._renack_start();
            self._assert_not_paused();
            /// CHECKS
            let mut swap = self.swaps.read(swap_id);
            assert(swap.status == SwapStatus::Active, Errors::SWAP_NOT_ACTIVE);

            let current_time = get_block_timestamp();
            assert(current_time >= swap.expiration_time, Errors::SWAP_NOT_EXPIRED);

            let owner = self.erc721.owner_of(swap_id);
            let mut market = self.markets.read(swap.pair_id);

            //UPDATE RATE INDEX
            self._update_rate_index(ref market, current_time);

            //CALCULATE TWA (capped at expiration)
            let twa_rate = self._calculate_twa(@market.rate_index, @swap, current_time);

            /// CALCULATE PNL
            let pnl = self._calculate_pnl(@swap, twa_rate);

            /// calculate payouts
            let (buyer_payout, lp_delta) = self._calculate_settlement_payouts(@swap, pnl);

            /// (before transfers!)
            swap.status = SwapStatus::Settled;
            self.swaps.write(swap_id, swap);

            // Update pool
            let mut pool = market.pool;

            // Unlock LP collateral
            match swap.side {
                SwapSide::Fixed => {
                    pool.locked_for_fixed = pool.locked_for_fixed - swap.lp_collateral_locked;
                },
                SwapSide::Floating => {
                    pool.locked_for_floating = pool.locked_for_floating - swap.lp_collateral_locked;
                },
            }

            // Apply LP gain/loss
            if lp_delta.is_negative {
                pool.total_collateral = pool.total_collateral - lp_delta.value;
            } else {
                pool.total_collateral = pool.total_collateral + lp_delta.value;
            }

            market.pool = pool;
            market.active_swap_count = market.active_swap_count - 1;
            self.markets.write(swap.pair_id, market);

            // Burn NFT
            self.erc721.burn(swap_id);

            if buyer_payout > 0 {
                let token = IERC20Dispatcher { contract_address: market.collateral_token };
                let success = token.transfer(owner, buyer_payout);
                assert(success, Errors::TRANSFER_FAILED);
            }

            self.emit(SwapSettled { swap_id, owner, twa_rate_bps: twa_rate, pnl, buyer_payout });

            self.security._renack_end()
        }

        fn early_exit(ref self: ContractState, swap_id: u256) {
            self.security._renack_start();
            self._assert_not_paused();

            let mut swap = self.swaps.read(swap_id);
            assert(swap.status == SwapStatus::Active, Errors::SWAP_NOT_ACTIVE);

            let caller = get_caller_address();
            let owner = self.erc721.owner_of(swap_id);
            assert(caller == owner, Errors::NOT_SWAP_OWNER);

            let current_time = get_block_timestamp();
            assert(current_time < swap.expiration_time, Errors::SWAP_EXPIRED);

            let mut market = self.markets.read(swap.pair_id);
            assert(
                current_time >= swap.start_time + market.params.min_hold_period_seconds,
                Errors::MIN_HOLD_PERIOD,
            );

            // UPDATE RATE INDEX
            self._update_rate_index(ref market, current_time);

            // === CALCULATE CURRENT TWA ===
            let twa_rate = self._calculate_twa(@market.rate_index, @swap, current_time);

            // CALCULATE PNL
            let pnl = self._calculate_pnl_partial(@swap, twa_rate, current_time);

            //  APPLY EARLY EXIT PENALTY
            let penalty = calculate_fee(swap.buyer_collateral, market.params.early_exit_fee_bps);
            let adjusted_pnl = if pnl.is_negative {
                // Loss increases by penalty
                negative(pnl.value + penalty)
            } else if pnl.value >= penalty {
                // Profit reduced by penalty
                positive(pnl.value - penalty)
            } else {
                // Profit less than penalty = net loss
                negative(penalty - pnl.value)
            };

            let (buyer_payout, lp_delta) = self._calculate_settlement_payouts(@swap, adjusted_pnl);

            swap.status = SwapStatus::ExitedEarly;
            self.swaps.write(swap_id, swap);

            let mut pool = market.pool;

            // Unlock LP collateral
            match swap.side {
                SwapSide::Fixed => {
                    pool.locked_for_fixed = pool.locked_for_fixed - swap.lp_collateral_locked;
                },
                SwapSide::Floating => {
                    pool.locked_for_floating = pool.locked_for_floating - swap.lp_collateral_locked;
                },
            }

            // Apply LP gain/loss
            if lp_delta.is_negative {
                pool.total_collateral = pool.total_collateral - lp_delta.value;
            } else {
                pool.total_collateral = pool.total_collateral + lp_delta.value;
            }

            market.pool = pool;
            market.active_swap_count = market.active_swap_count - 1;
            self.markets.write(swap.pair_id, market);

            // Burn NFT
            self.erc721.burn(swap_id);

            if buyer_payout > 0 {
                let token = IERC20Dispatcher { contract_address: market.collateral_token };
                let success = token.transfer(owner, buyer_payout);
                assert(success, Errors::TRANSFER_FAILED);
            }

            self
                .emit(
                    SwapExitedEarly {
                        swap_id, owner, twa_rate_bps: twa_rate, pnl, penalty, buyer_payout,
                    },
                );

            self.security._renack_end();
        }

        fn liquidate(ref self: ContractState, swap_id: u256) {
            self.security._renack_start();
            self._assert_not_paused();

            let mut swap = self.swaps.read(swap_id);
            assert(swap.status == SwapStatus::Active, Errors::SWAP_NOT_ACTIVE);

            let current_time = get_block_timestamp();

            assert(current_time < swap.expiration_time, Errors::SWAP_EXPIRED_USE_SETTLE);
            let liquidator = get_caller_address();
            let owner = self.erc721.owner_of(swap_id);
            let mut market = self.markets.read(swap.pair_id);

            // UPDATE RATE
            self._update_rate_index(ref market, current_time);

            // CHECK HEALTH
            let health_status = self._calculate_health_status(@swap, @market, current_time);
            assert(health_status.is_liquidatable, Errors::HEALTHY_POSITION);

            // CALCULATE LIQUIDATION AMOUNTS
            let liquidator_bonus = calculate_fee(
                swap.buyer_collateral, market.params.liquidation_bonus_bps,
            );
            let remaining_to_pool = if swap.buyer_collateral > liquidator_bonus {
                swap.buyer_collateral - liquidator_bonus
            } else {
                0
            };

            swap.status = SwapStatus::Liquidated;
            self.swaps.write(swap_id, swap);

            let mut pool = market.pool;

            // Unlock LP collateral
            match swap.side {
                SwapSide::Fixed => {
                    pool.locked_for_fixed = pool.locked_for_fixed - swap.lp_collateral_locked;
                },
                SwapSide::Floating => {
                    pool.locked_for_floating = pool.locked_for_floating - swap.lp_collateral_locked;
                },
            }

            // LP receives remaining buyer collateral
            pool.total_collateral = pool.total_collateral + remaining_to_pool;

            market.pool = pool;
            market.active_swap_count = market.active_swap_count - 1;
            self.markets.write(swap.pair_id, market);

            // Burn NFT
            self.erc721.burn(swap_id);

            let token = IERC20Dispatcher { contract_address: market.collateral_token };
            if liquidator_bonus > 0 {
                let success = token.transfer(liquidator, liquidator_bonus);
                assert(success, Errors::TRANSFER_FAILED);
            }

            self
                .emit(
                    SwapLiquidated {
                        swap_id,
                        liquidator,
                        owner,
                        health_factor_bps: health_status.health_factor_bps,
                        liquidator_bonus,
                        remaining_to_pool,
                    },
                );

            self.security._renack_end();
        }

        //                          VIEW FUNCTIONS

        fn get_market(self: @ContractState, pair_id: felt252) -> MarketPair {
            self.markets.read(pair_id)
        }

        fn get_swap(self: @ContractState, swap_id: u256) -> Swap {
            self.swaps.read(swap_id)
        }

        fn get_swap_quote(
            self: @ContractState, pair_id: felt252, side: SwapSide, notional: u256,
        ) -> SwapQuote {
            let market = self.markets.read(pair_id);
            let (oracle_rate, _) = self._get_oracle_rate(market.rate_oracle);
            let (final_rate, adjustment, is_positive) = self
                ._calculate_swap_rate(@market, side, oracle_rate);

            let required_collateral = calculate_required_margin(
                notional,
                final_rate,
                market.params.swap_term_seconds,
                market.params.initial_margin_multiplier_bps,
            );

            SwapQuote {
                base_rate_bps: oracle_rate,
                imbalance_adjustment_bps: adjustment,
                adjustment_is_positive: is_positive,
                fee_spread_bps: market.params.fee_spread_bps,
                final_rate_bps: final_rate,
                required_collateral,
                lp_collateral_to_lock: required_collateral,
            }
        }

        fn get_health_status(self: @ContractState, swap_id: u256) -> HealthStatus {
            let swap = self.swaps.read(swap_id);
            let market = self.markets.read(swap.pair_id);
            self._calculate_health_status(@swap, @market, get_block_timestamp())
        }

        fn get_lp_position(
            self: @ContractState, lp: ContractAddress, pair_id: felt252,
        ) -> LpPosition {
            self.lp_positions.read((lp, pair_id))
        }

        fn get_pool_analytics(self: @ContractState, pair_id: felt252) -> PoolAnalytics {
            let market = self.markets.read(pair_id);
            let pool = market.pool;

            let available = pool.total_collateral
                - pool.locked_for_fixed
                - pool.locked_for_floating;

            let util_fixed = if pool.total_collateral > 0 {
                mul_div_down(pool.locked_for_fixed, Constants::BPS, pool.total_collateral)
            } else {
                0
            };

            let util_floating = if pool.total_collateral > 0 {
                mul_div_down(pool.locked_for_floating, Constants::BPS, pool.total_collateral)
            } else {
                0
            };

            // Net exposure: positive = more fixed (LP is net short rate)
            let net_exposure = if pool.locked_for_fixed >= pool.locked_for_floating {
                positive(pool.locked_for_fixed - pool.locked_for_floating)
            } else {
                negative(pool.locked_for_floating - pool.locked_for_fixed)
            };

            PoolAnalytics {
                total_value: pool.total_collateral,
                available_liquidity: available,
                utilization_fixed_bps: util_fixed,
                utilization_floating_bps: util_floating,
                net_exposure_notional: net_exposure,
            }
        }

        fn get_current_twa(self: @ContractState, swap_id: u256) -> u256 {
            let swap = self.swaps.read(swap_id);
            let market = self.markets.read(swap.pair_id);
            self._calculate_twa(@market.rate_index, @swap, get_block_timestamp())
        }

        fn get_protocol_config(self: @ContractState) -> ProtocolConfig {
            self.protocol_config.read()
        }

        fn get_next_swap_id(self: @ContractState) -> u256 {
            self.next_swap_id.read()
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
            assert(
                config.protocol_fee_share_bps <= (Constants::BPS / 5), Errors::INVALID_PARAMS,
            ); // Max 20%
            assert(
                config.burned_shares_amount >= Constants::MIN_BURNED_SHARES, Errors::INVALID_PARAMS,
            );
            assert(
                config.min_first_lp_deposit >= Constants::MIN_LP_DEPOSIT, Errors::INVALID_PARAMS,
            );
            self.protocol_config.write(config);
            self.emit(ProtocolConfigUpdated { config }); // Also emit event
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

        fn _validate_market_params(self: @ContractState, params: @MarketParams) {
            assert(
                *params.liquidation_threshold_bps >= Constants::MIN_LIQUIDATION_THRESHOLD_BPS
                    && *params
                        .liquidation_threshold_bps <= Constants::MAX_LIQUIDATION_THRESHOLD_BPS,
                Errors::INVALID_PARAMS,
            );
            assert(
                *params.swap_term_seconds >= Constants::MIN_SWAP_TERM_SECONDS
                    && *params.swap_term_seconds <= Constants::MAX_SWAP_TERM_SECONDS,
                Errors::INVALID_PARAMS,
            );
            assert(*params.swap_fee_bps <= Constants::MAX_FEE_BPS, Errors::INVALID_PARAMS);
            assert(*params.early_exit_fee_bps <= Constants::MAX_FEE_BPS, Errors::INVALID_PARAMS);
            assert(*params.liquidation_bonus_bps <= Constants::MAX_FEE_BPS, Errors::INVALID_PARAMS);
            assert(*params.max_rate_bps <= Constants::MAX_RATE_BOUND_BPS, Errors::INVALID_PARAMS);
            assert(
                *params.max_utilization_bps <= Constants::MAX_UTILIZATION_CAP_BPS,
                Errors::INVALID_PARAMS,
            );
            assert(*params.min_notional > 0, Errors::INVALID_PARAMS);
            assert(*params.max_notional_per_swap >= *params.min_notional, Errors::INVALID_PARAMS);
            assert(*params.min_margin_floor_bps <= Constants::BPS, Errors::INVALID_PARAMS);
            assert(
                *params.initial_margin_multiplier_bps >= Constants::MIN_MARGIN_MULTIPLIER_BPS,
                Errors::INVALID_PARAMS,
            );
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

        /// Update rate index with latest oracle value and safety checks
        fn _update_rate_index(
            ref self: ContractState, ref market: MarketPair, current_time: u64,
        ) -> u256 {
            let (raw_rate, rate_timestamp) = self._get_oracle_rate(market.rate_oracle);

            // Check staleness
            assert(
                current_time - rate_timestamp <= market.params.max_oracle_staleness_seconds,
                Errors::ORACLE_STALE,
            );

            // Check bounds
            assert(
                raw_rate >= market.params.min_rate_bps && raw_rate <= market.params.max_rate_bps,
                Errors::RATE_OUT_OF_BOUNDS,
            );

            let mut rate_index = market.rate_index;

            // If first update, just initialize
            if rate_index.last_update_time == 0 {
                rate_index.last_update_time = current_time;
                rate_index.last_rate_bps = raw_rate;
                rate_index.cumulative_rate_time = 0;
                rate_index.last_valid_rate_bps = raw_rate;
                market.rate_index = rate_index;

                self
                    .emit(
                        RateIndexUpdated {
                            pair_id: market.pair_id,
                            new_rate_bps: raw_rate,
                            cumulative_rate_time: 0,
                            timestamp: current_time,
                        },
                    );

                return raw_rate;
            }

            let time_delta: u256 = (current_time - rate_index.last_update_time).into();

            // No time passed, return current rate
            if time_delta == 0 {
                return rate_index.last_rate_bps;
            }

            // Accumulate: previous_rate × time_elapsed
            rate_index.cumulative_rate_time += rate_index.last_rate_bps * time_delta;

            // Apply rate change limit
            let last_valid = rate_index.last_valid_rate_bps;
            let max_change = mul_div_up(
                last_valid, market.params.max_rate_change_per_update_bps, Constants::BPS,
            );

            let clamped_rate = if raw_rate > last_valid + max_change {
                last_valid + max_change
            } else if last_valid > max_change && raw_rate < last_valid - max_change {
                last_valid - max_change
            } else {
                raw_rate
            };

            // Update state
            rate_index.last_rate_bps = clamped_rate;
            rate_index.last_update_time = current_time;
            rate_index.last_valid_rate_bps = clamped_rate;

            market.rate_index = rate_index;

            self
                .emit(
                    RateIndexUpdated {
                        pair_id: market.pair_id,
                        new_rate_bps: clamped_rate,
                        cumulative_rate_time: rate_index.cumulative_rate_time,
                        timestamp: current_time,
                    },
                );

            clamped_rate
        }
        /// Calculate swap rate with imbalance adjustment
        fn _calculate_swap_rate(
            self: @ContractState, market: @MarketPair, side: SwapSide, oracle_rate: u256,
        ) -> (u256, u256, bool) {
            let pool = market.pool;
            let params = market.params;

            let locked_fixed = *pool.locked_for_fixed;
            let locked_floating = *pool.locked_for_floating;
            let total_locked = locked_fixed + locked_floating;

            // Calculate adjustment
            let (adjustment_bps, is_positive) = if total_locked == 0 {
                (0_u256, true)
            } else {
                let imbalance_bps = if locked_fixed > locked_floating {
                    mul_div_down(locked_fixed - locked_floating, Constants::BPS, total_locked)
                } else {
                    mul_div_down(locked_floating - locked_fixed, Constants::BPS, total_locked)
                };

                let raw_adjustment = mul_div_down(
                    imbalance_bps, *params.max_imbalance_adjustment_bps, Constants::BPS,
                );

                // Fixed crowded: Fixed pays more (positive), Floating pays less (negative)
                let is_fixed_crowded = locked_fixed > locked_floating;

                match side {
                    SwapSide::Fixed => (raw_adjustment, is_fixed_crowded),
                    SwapSide::Floating => (raw_adjustment, !is_fixed_crowded),
                }
            };

            // Apply adjustment
            let adjusted_rate = if is_positive {
                oracle_rate + adjustment_bps
            } else {
                if oracle_rate > adjustment_bps {
                    oracle_rate - adjustment_bps
                } else {
                    0
                }
            };

            // Add fee spread
            let final_rate = adjusted_rate + *params.fee_spread_bps;

            (final_rate, adjustment_bps, is_positive)
        }

        /// Calculate cumulative rate at a specific timestamp
        fn _calculate_cumulative_at(
            self: @ContractState, rate_index: @RateIndex, target_time: u64,
        ) -> u256 {
            let last_update = *rate_index.last_update_time;
            let last_rate = *rate_index.last_rate_bps;
            let base_cumulative = *rate_index.cumulative_rate_time;

            if target_time <= last_update {
                return base_cumulative;
            }

            // Extrapolate from last update to target time
            let time_delta: u256 = (target_time - last_update).into();
            base_cumulative + (last_rate * time_delta)
        }


        /// Calculate TWA rate for a swap (capped at expiration)
        fn _calculate_twa(
            self: @ContractState, rate_index: @RateIndex, swap: @Swap, current_time: u64,
        ) -> u256 {
            let start_cumulative = *swap.start_cumulative_rate;
            let start_time = *swap.start_time;
            let expiration_time = *swap.expiration_time;

            // Cap at expiration - never include post-expiration rates
            let effective_end_time = min_u64(current_time, expiration_time);

            // Duration for TWA calculation
            if effective_end_time <= start_time {
                return *rate_index.last_rate_bps;
            }

            let duration: u256 = (effective_end_time - start_time).into();

            // Get cumulative at effective end time
            let end_cumulative = self._calculate_cumulative_at(rate_index, effective_end_time);

            // TWA = (end_cumulative - start_cumulative) / duration
            if end_cumulative >= start_cumulative {
                div_down(end_cumulative - start_cumulative, duration)
            } else {
                0
            }
        }


        /// Calculate PnL for a swap at expiration
        fn _calculate_pnl(self: @ContractState, swap: @Swap, twa_rate_bps: u256) -> SignedValue {
            let notional = *swap.notional;
            let fixed_rate = *swap.fixed_rate_bps;
            let term_seconds = *swap.expiration_time - *swap.start_time;

            // Calculate payments
            let fixed_payment = calculate_payment(notional, fixed_rate, term_seconds);
            let floating_payment = calculate_payment(notional, twa_rate_bps, term_seconds);

            // PnL depends on swap side
            match *swap.side {
                SwapSide::Fixed => {
                    // Buyer pays fixed, receives floating
                    safe_sub(floating_payment, fixed_payment)
                },
                SwapSide::Floating => {
                    // Buyer pays floating, receives fixed
                    safe_sub(fixed_payment, floating_payment)
                },
            }
        }

        /// Calculate partial PnL for early exit (pro-rated)
        fn _calculate_pnl_partial(
            self: @ContractState, swap: @Swap, twa_rate_bps: u256, current_time: u64,
        ) -> SignedValue {
            let notional = *swap.notional;
            let fixed_rate = *swap.fixed_rate_bps;
            let elapsed_seconds = current_time - *swap.start_time;

            // Calculate pro-rated payments based on elapsed time
            let fixed_payment = calculate_payment(notional, fixed_rate, elapsed_seconds);
            let floating_payment = calculate_payment(notional, twa_rate_bps, elapsed_seconds);

            match *swap.side {
                SwapSide::Fixed => safe_sub(floating_payment, fixed_payment),
                SwapSide::Floating => safe_sub(fixed_payment, floating_payment),
            }
        }

        /// Calculate settlement payouts
        fn _calculate_settlement_payouts(
            self: @ContractState, swap: @Swap, pnl: SignedValue,
        ) -> (u256, SignedValue) {
            let buyer_collateral = *swap.buyer_collateral;
            let lp_collateral = *swap.lp_collateral_locked;

            if pnl.is_negative {
                // Buyer loses, LP wins
                let buyer_loss = min(pnl.value, buyer_collateral);
                let buyer_payout = buyer_collateral - buyer_loss;
                let lp_gain = positive(buyer_loss);
                (buyer_payout, lp_gain)
            } else {
                // Buyer wins, LP loses
                let buyer_profit = min(pnl.value, lp_collateral);
                let buyer_payout = buyer_collateral + buyer_profit;
                let lp_loss = negative(buyer_profit);
                (buyer_payout, lp_loss)
            }
        }

        /// Calculate health status of a swap
        fn _calculate_health_status(
            self: @ContractState, swap: @Swap, market: @MarketPair, current_time: u64,
        ) -> HealthStatus {
            // Calculate current PnL
            let twa = self._calculate_twa(market.rate_index, swap, current_time);
            let current_pnl = if current_time >= *swap.expiration_time {
                self._calculate_pnl(swap, twa)
            } else {
                self._calculate_pnl_partial(swap, twa, current_time)
            };

            // Calculate remaining value
            let buyer_remaining = apply_pnl(*swap.buyer_collateral, current_pnl);

            // Calculate time-adjusted margin requirement
            let remaining_time = if *swap.expiration_time > current_time {
                *swap.expiration_time - current_time
            } else {
                0
            };
            let total_term = *swap.expiration_time - *swap.start_time;

            let adjusted_margin = calculate_time_adjusted_margin(
                *swap.initial_required_margin,
                remaining_time,
                total_term,
                *market.params.min_margin_floor_bps,
            );

            // Calculate health factor
            let health_factor = calculate_health_factor(buyer_remaining, adjusted_margin);

            // Check if liquidatable
            let is_liquidatable = health_factor < *market.params.liquidation_threshold_bps;

            HealthStatus {
                current_pnl,
                buyer_remaining_value: buyer_remaining,
                required_margin: adjusted_margin,
                health_factor_bps: health_factor,
                is_liquidatable,
                time_to_expiry_seconds: remaining_time,
            }
        }
    }
}
