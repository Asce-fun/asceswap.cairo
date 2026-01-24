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
    use crate::helpers::signed_value::*;
    use crate::interfaces::asce_swap::IAsceSwap;
    use crate::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use crate::interfaces::rate_oracle::{IOracleAdapterDispatcher, IOracleAdapterDispatcherTrait};
    use crate::helpers::utils::*;
    // use crate::types::asce_swap::{
    //     LpPosition, Market, MarketParams, MarketStatus, ProtocolFees, RateIndex, RateType,SignedValue
    // };

    use crate::types::asce_swap::*;
    use crate::helpers::fixed_point::*;


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
        lp_positions: Map<(ContractAddress, u256), LpPosition>,
        active_swaps_count: Map<u256, u256>,
        active_swaps: Map<(u256, u256), u256>,
        
        accumulated_fees: Map<ContractAddress, u256>,
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
        LpCollateralSupplied: LpCollateralSupplied,
        LpCollateralWithdrawn: LpCollateralWithdrawn,
        SwapCreated: SwapCreated,
        SwapSettled: SwapSettled,
        SwapExitedEarly: SwapExitedEarly,
        SwapLiquidated: SwapLiquidated,
        RateIndexUpdated: RateIndexUpdated,
        ProtocolFeesUpdated: ProtocolFeesUpdated,
        ProtocolFeesWithdrawn: ProtocolFeesWithdrawn,
        TreasuryUpdated: TreasuryUpdated,
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

    #[derive(Drop, starknet::Event)]
    pub struct LpCollateralSupplied {
        #[key]
        pub lp: ContractAddress,
        #[key]
        pub market_id: u256,
        pub amount: u256,
        pub shares_minted: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct LpCollateralWithdrawn {
        #[key]
        pub lp: ContractAddress,
        #[key]
        pub market_id: u256,
        pub amount: u256,
        pub shares_burned: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SwapCreated {
        #[key]
        pub swap_id: u256,
        #[key]
        pub market_id: u256,
        pub buyer: ContractAddress,
        pub notional_amount: u256,
        pub fixed_rate: u256,
        pub collateral_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SwapSettled {
        #[key]
        pub swap_id: u256,
        pub owner: ContractAddress,
        pub pnl: SignedValue,
        pub twa_rate: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SwapExitedEarly {
        #[key]
        pub swap_id: u256,
        pub owner: ContractAddress,
        pub pnl: SignedValue,
        pub penalty: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SwapLiquidated {
        #[key]
        pub swap_id: u256,
        pub owner: ContractAddress,
        pub liquidator: ContractAddress,
        pub side: LiquidationSide,
        pub collateral_seized: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct RateIndexUpdated {
        #[key]
        pub market_id: u256,
        pub rate: u256,
        pub cumulative_rate_time: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ProtocolFeesUpdated {
        pub old_fees: ProtocolFees,
        pub new_fees: ProtocolFees,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ProtocolFeesWithdrawn {
        pub token: ContractAddress,
        pub amount: u256,
        pub recipient: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TreasuryUpdated {
        pub old_treasury: ContractAddress,
        pub new_treasury: ContractAddress,
    }

    #[constructor]
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

        fn supply_lp_collateral(ref self: ContractState, market_id: u256, amount: u256) -> u256 {
            self.security._renack_start();
            self._assert_not_paused();
            // Implementation goes here
            let mut market = self.markets.read(market_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_FOUND);
            let caller = get_caller_address();
            let this = get_contract_address();

            // Transfer tokens from LP
            let token = IERC20Dispatcher { contract_address: market.params.swap_token };
            let transfer_success = token.transfer_from(caller, this, amount);
            assert(transfer_success, Errors::TRANSFER_FAILED);

            // Calculate shares to mint (rounds DOWN - user gets fewer shares)
            let shares_to_mint = calculate_shares_to_mint(
                amount, market.total_lp_shares, market.total_lp_collateral,
            );
            // assert(shares_to_mint >= MIN_SHARES, Errors::BELOW_MIN_SHARES);

            // Update LP position
            let mut lp_position = self.lp_positions.read((caller, market_id));
            lp_position.shares += shares_to_mint;
            self.lp_positions.write((caller, market_id), lp_position);

            // Update market
            market.total_lp_shares += shares_to_mint;
            market.total_lp_collateral += amount;
            self.markets.write(market_id, market);

            self
                .emit(
                    LpCollateralSupplied {
                        lp: caller, market_id, amount, shares_minted: shares_to_mint,
                    },
                );

            self.security._renack_end();
            shares_to_mint
        }

        fn withdraw_lp_collateral(ref self: ContractState, market_id: u256, shares: u256) -> u256 {
            let mut market = self.markets.read(market_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_FOUND);
            assert(shares > 0, Errors::ZERO_AMOUNT);

            let caller = get_caller_address();
            let mut lp_position = self.lp_positions.read((caller, market_id));
            assert(lp_position.shares >= shares, Errors::INSUFFICIENT_SHARES);

            // Calculate collateral amount (rounds DOWN - user receives less)
            let collateral_amount = calculate_withdrawal_amount(
                shares, market.total_lp_shares, market.total_lp_collateral,
            );

            // Check available (not locked)
            let available_collateral = market.total_lp_collateral - market.locked_lp_collateral;
            assert(collateral_amount <= available_collateral, Errors::LOCKED_COLLATERAL);

            // Update LP position
            lp_position.shares -= shares;
            self.lp_positions.write((caller, market_id), lp_position);

            // Update market
            market.total_lp_shares -= shares;
            market.total_lp_collateral -= collateral_amount;
            self.markets.write(market_id, market);

            // Transfer tokens to LP
            let token = IERC20Dispatcher { contract_address: market.params.swap_token };
            let transfer_success = token.transfer(caller, collateral_amount);
            assert(transfer_success, Errors::TRANSFER_FAILED);

            self
                .emit(
                    LpCollateralWithdrawn {
                        lp: caller, market_id, amount: collateral_amount, shares_burned: shares,
                    },
                );

            collateral_amount
        }

        fn buy_swap(
            ref self: ContractState,
            market_id: u256,
            notional_amount: u256,
            collateral_amount: u256,
        ) -> u256 {
            self._assert_not_paused();

            let mut market = self.markets.read(market_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_FOUND);
            assert(notional_amount >= market.params.min_notional, Errors::BELOW_MIN_NOTIONAL);

            let caller = get_caller_address();

            // Update rate index
            self._update_rate_index(market_id);

            // Calculate swap rate
            let swap_rate = self._calculate_swap_rate(market_id, notional_amount);

            // Calculate required collateral (rounds UP - user posts more)
            let (required_buyer_collateral_usd, required_lp_collateral) = self
                ._calculate_collateral_requirements(@market, notional_amount, swap_rate);

            // Get collateral value in USD (rounds DOWN - conservative valuation)
            let collateral_value_usd = self._get_collateral_value_usd(@market, collateral_amount);
            assert(
                collateral_value_usd >= required_buyer_collateral_usd,
                Errors::INSUFFICIENT_COLLATERAL,
            );

            // Check LP pool has enough
            let available_lp = market.total_lp_collateral - market.locked_lp_collateral;
            assert(available_lp >= required_lp_collateral, Errors::INSUFFICIENT_LIQUIDITY);

            // Check utilization cap
            let new_locked = market.locked_lp_collateral + required_lp_collateral;
            let utilization = mul_div_up(new_locked, Constants::BPS, market.total_lp_collateral);
            assert(utilization <= Constants::MAX_UTILIZATION_BPS, Errors::EXCEEDS_MAX_UTILIZATION);

            // Calculate and collect swap fee (rounds UP - protocol gets more)
            let fee_amount = self._calculate_and_collect_swap_fee(@market, collateral_amount);
            let net_collateral = collateral_amount - fee_amount;

            // Transfer collateral from buyer
            let token = IERC20Dispatcher { contract_address: market.params.swap_token };
            let transfer_success = token
                .transfer_from(caller, get_contract_address(), collateral_amount);
            assert(transfer_success, Errors::TRANSFER_FAILED);

            // Create swap
            let swap_id = self.next_swap_id.read();
            self.next_swap_id.write(swap_id + 1);

            let rate_index = self.rate_indices.read(market_id);
            let current_time = get_block_timestamp();

            let swap = Swap {
                market_id,
                notional_amount,
                fixed_rate: swap_rate,
                buyer_collateral: net_collateral,
                lp_collateral: required_lp_collateral,
                required_collateral_usd: required_buyer_collateral_usd,
                start_time: current_time,
                expiration_time: current_time + market.params.swap_term,
                start_cumulative_rate_time: rate_index.cumulative_rate_time,
                is_settled: false,
                is_liquidated: false,
            };
            self.swaps.write(swap_id, swap);

            // Lock LP collateral
            market.locked_lp_collateral += required_lp_collateral;
            self.markets.write(market_id, market);

            // Add to active swaps
            self._add_active_swap(market_id, swap_id);

            // Mint NFT to buyer
            self.erc721.mint(caller, swap_id);

            self
                .emit(
                    SwapCreated {
                        swap_id,
                        market_id,
                        buyer: caller,
                        notional_amount,
                        fixed_rate: swap_rate,
                        collateral_amount: net_collateral,
                    },
                );

            swap_id
        }
        fn settle_swap(ref self: ContractState, swap_id: u256) {
            let mut swap = self.swaps.read(swap_id);
            assert(swap.notional_amount > 0, Errors::SWAP_NOT_FOUND);
            assert(!swap.is_settled && !swap.is_liquidated, Errors::SWAP_ALREADY_SETTLED);
            assert(get_block_timestamp() >= swap.expiration_time, Errors::SWAP_NOT_EXPIRED);

            let owner = self.erc721.owner_of(swap_id);
            let mut market = self.markets.read(swap.market_id);

            // Update rate index
            self._update_rate_index(swap.market_id);

            // Calculate TWA rate
            let twa_rate = self._calculate_twa(swap.market_id, @swap);

            // Calculate PnL
            let pnl = self._calculate_final_pnl(@market, @swap, twa_rate);

            // Execute settlement
            self._execute_settlement(ref market, ref swap, owner, pnl);

            // Mark as settled
            swap.is_settled = true;
            self.swaps.write(swap_id, swap);
            self.markets.write(swap.market_id, market);

            // Remove from active swaps
            self._remove_active_swap(swap.market_id, swap_id);

            // Burn NFT
            self.erc721.burn(swap_id);

            self.emit(SwapSettled { swap_id, owner, pnl, twa_rate });
        }

        fn exit_early(ref self: ContractState, swap_id: u256) {
            let mut swap = self.swaps.read(swap_id);
            assert(swap.notional_amount > 0, Errors::SWAP_NOT_FOUND);
            assert(!swap.is_settled && !swap.is_liquidated, Errors::SWAP_ALREADY_SETTLED);

            let current_time = get_block_timestamp();
            assert(current_time < swap.expiration_time, Errors::SWAP_EXPIRED);
            assert(current_time >= swap.start_time + Constants::MIN_HOLD_PERIOD, Errors::MIN_HOLD_PERIOD);

            let owner = self.erc721.owner_of(swap_id);
            let caller = get_caller_address();
            assert(caller == owner, Errors::NOT_SWAP_OWNER);

            let mut market = self.markets.read(swap.market_id);

            // Update rate index
            self._update_rate_index(swap.market_id);

            // Calculate current PnL
            let current_pnl = self._calculate_current_pnl(swap.market_id, @swap);

            // Apply early exit penalty
            let (final_pnl, penalty) = self._apply_early_exit_penalty(@market, current_pnl);

            // Execute settlement
            self._execute_settlement(ref market, ref swap, owner, final_pnl);

            // Mark as settled
            swap.is_settled = true;
            self.swaps.write(swap_id, swap);
            self.markets.write(swap.market_id, market);

            // Remove from active swaps
            self._remove_active_swap(swap.market_id, swap_id);

            // Burn NFT
            self.erc721.burn(swap_id);

            self.emit(SwapExitedEarly { swap_id, owner, pnl: final_pnl, penalty });
        }

        fn liquidate(ref self: ContractState, swap_id: u256) -> LiquidationSide {
            let mut swap = self.swaps.read(swap_id);
            assert(swap.notional_amount > 0, Errors::SWAP_NOT_FOUND);
            assert(!swap.is_settled && !swap.is_liquidated, Errors::SWAP_ALREADY_SETTLED);

            let owner = self.erc721.owner_of(swap_id);
            let liquidator = get_caller_address();
            let mut market = self.markets.read(swap.market_id);

            // Update rate index
            self._update_rate_index(swap.market_id);

            // Calculate current PnL
            let buyer_pnl = self._calculate_current_pnl(swap.market_id, @swap);

            // Check which side is liquidatable
            let (is_buyer_liquidatable, is_lp_liquidatable) = self
                ._check_liquidation_eligibility(@market, @swap, buyer_pnl);

            assert(is_buyer_liquidatable || is_lp_liquidatable, Errors::POSITION_HEALTHY);

            let side = if is_buyer_liquidatable {
                LiquidationSide::Buyer
            } else {
                LiquidationSide::Lp
            };

            // Execute liquidation
            let collateral_seized = self
                ._execute_liquidation(ref market, ref swap, owner, liquidator, side, buyer_pnl);

            // Mark as liquidated
            swap.is_liquidated = true;
            self.swaps.write(swap_id, swap);
            self.markets.write(swap.market_id, market);

            // Remove from active swaps
            self._remove_active_swap(swap.market_id, swap_id);

            // Burn NFT
            self.erc721.burn(swap_id);

            self.emit(SwapLiquidated { swap_id, owner, liquidator, side, collateral_seized });

            side
        }

        // ============ Batch Operations ============

        fn batch_settle(ref self: ContractState, swap_ids: Array<u256>) {
            assert(swap_ids.len() > 0, Errors::INVALID_SWAP_IDS);

            let mut i: u32 = 0;
            loop {
                if i >= swap_ids.len() {
                    break;
                }
                self.settle_swap(*swap_ids.at(i));
                i += 1;
            }
        }

        fn batch_liquidate(
            ref self: ContractState, swap_ids: Array<u256>,
        ) -> Array<LiquidationSide> {
            assert(swap_ids.len() > 0, Errors::INVALID_SWAP_IDS);

            let mut results: Array<LiquidationSide> = ArrayTrait::new();
            let mut i: u32 = 0;
            loop {
                if i >= swap_ids.len() {
                    break;
                }
                let side = self.liquidate(*swap_ids.at(i));
                results.append(side);
                i += 1;
            }

            results
        }

        // ============ Admin Functions ============

        fn set_protocol_fees(ref self: ContractState, fees: ProtocolFees) {
            // self.ownable.assert_only_owner();

            let old_fees = self.protocol_fees.read();
            self.protocol_fees.write(fees);

            self.emit(ProtocolFeesUpdated { old_fees, new_fees: fees });
        }

        fn set_treasury(ref self: ContractState, treasury: ContractAddress) {
            // self.ownable.assert_only_owner();
            assert(!treasury.is_zero(), Errors::INVALID_ADDRESS);

            let old_treasury = self.treasury.read();
            self.treasury.write(treasury);

            self.emit(TreasuryUpdated { old_treasury, new_treasury: treasury });
        }

        fn withdraw_protocol_fees(ref self: ContractState, token: ContractAddress, amount: u256) {
            // self.ownable.assert_only_owner();

            let accumulated = self.accumulated_fees.read(token);
            assert(amount <= accumulated, Errors::INSUFFICIENT_COLLATERAL);

            self.accumulated_fees.write(token, accumulated - amount);

            let treasury = self.treasury.read();
            let erc20 = IERC20Dispatcher { contract_address: token };
            let transfer_success = erc20.transfer(treasury, amount);
            assert(transfer_success, Errors::TRANSFER_FAILED);

            self.emit(ProtocolFeesWithdrawn { token, amount, recipient: treasury });
        }

        // ============ View Functions ============

        fn get_market(self: @ContractState, market_id: u256) -> Market {
            self.markets.read(market_id)
        }

        fn get_market_liquidity(self: @ContractState, market_id: u256) -> MarketLiquidity {
            let market = self.markets.read(market_id);

            let utilization_bps = if market.total_lp_collateral > 0 {
                mul_div_down(market.locked_lp_collateral, Constants::BPS, market.total_lp_collateral)
            } else {
                0
            };

            MarketLiquidity {
                total_collateral: market.total_lp_collateral,
                available_collateral: market.total_lp_collateral - market.locked_lp_collateral,
                utilization_bps,
            }
        }

        fn get_current_swap_rate(
            self: @ContractState, market_id: u256, notional_amount: u256,
        ) -> u256 {
            self._calculate_swap_rate(market_id, notional_amount)
        }

        fn get_swap(self: @ContractState, swap_id: u256) -> Swap {
            self.swaps.read(swap_id)
        }

        fn get_swap_pnl(self: @ContractState, swap_id: u256) -> SignedValue {
            let swap = self.swaps.read(swap_id);
            self._calculate_current_pnl(swap.market_id, @swap)
        }

        fn get_swap_health(self: @ContractState, swap_id: u256) -> u256 {
            let swap = self.swaps.read(swap_id);
            let market = self.markets.read(swap.market_id);
            let pnl = self._calculate_current_pnl(swap.market_id, @swap);

            self._calculate_buyer_health(@market, @swap, pnl)
        }

        fn is_liquidatable(self: @ContractState, swap_id: u256) -> bool {
            let swap = self.swaps.read(swap_id);
            let market = self.markets.read(swap.market_id);
            let pnl = self._calculate_current_pnl(swap.market_id, @swap);

            let (is_buyer_liq, is_lp_liq) = self
                ._check_liquidation_eligibility(@market, @swap, pnl);
            is_buyer_liq || is_lp_liq
        }

        fn get_lp_position(
            self: @ContractState, lp: ContractAddress, market_id: u256,
        ) -> LpPosition {
            self.lp_positions.read((lp, market_id))
        }

        fn get_lp_value(self: @ContractState, lp: ContractAddress, market_id: u256) -> u256 {
            let market = self.markets.read(market_id);
            let lp_position = self.lp_positions.read((lp, market_id));

            if market.total_lp_shares == 0 {
                return 0;
            }

            // Rounds DOWN - LP sees conservative value
            mul_div_down(market.total_lp_collateral, lp_position.shares, market.total_lp_shares)
        }

        fn get_protocol_fees(self: @ContractState) -> ProtocolFees {
            self.protocol_fees.read()
        }

        fn get_treasury(self: @ContractState) -> ContractAddress {
            self.treasury.read()
        }

        fn get_rate_index(self: @ContractState, market_id: u256) -> RateIndex {
            self.rate_indices.read(market_id)
        }

        fn is_protocol_paused(self: @ContractState) -> bool {
            self.protocol_paused.read()
        }

        fn get_next_market_id(self: @ContractState) -> u256 {
            self.next_market_id.read()
        }

        fn get_next_swap_id(self: @ContractState) -> u256 {
            self.next_swap_id.read()
        }
    }
    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _update_rate_index(ref self: ContractState, market_id: u256) {
            let market = self.markets.read(market_id);
            let mut rate_index = self.rate_indices.read(market_id);
            let current_time = get_block_timestamp();

            let time_delta = current_time - rate_index.last_update_time;
            if time_delta == 0 {
                return;
            }

            rate_index.cumulative_rate_time += rate_index.last_rate * time_delta.into();
            // Implementation goes here
            // Update to current rate
            rate_index
                .last_rate = self
                ._get_oracle_rate(
                    market.params.reference_rate_oracle, market.params.max_oracle_staleness,
                );
            rate_index.last_update_time = current_time;

            self.rate_indices.write(market_id, rate_index);

            self
                .emit(
                    RateIndexUpdated {
                        market_id,
                        rate: rate_index.last_rate,
                        cumulative_rate_time: rate_index.cumulative_rate_time,
                    },
                );
        }
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

        fn _calculate_swap_rate(
            self: @ContractState, market_id: u256, notional_amount: u256,
        ) -> u256 {
            let market = self.markets.read(market_id);

            let base_rate = self._calculate_base_swap_rate(market_id);

            let available = market.total_lp_collateral - market.locked_lp_collateral;
            let util_fee = calculate_utilization_fee(
                notional_amount,
                available,
                market.params.min_util_fee.into(),
                market.params.max_util_fee.into(),
            );

            base_rate + util_fee + market.params.fee_spread.into()
        }

        fn _calculate_twa(
            self: @ContractState, 
            market_id: u256, 
            swap: @Swap
        ) -> u256 {
            let rate_index = self.rate_indices.read(market_id);
            
            let current_time = get_block_timestamp();
            let time_since_last_update: u256 = (current_time - rate_index.last_update_time).into();
            let end_cumulative = rate_index.cumulative_rate_time + 
                (rate_index.last_rate * time_since_last_update);
            
            let duration: u256 = (*swap.expiration_time - *swap.start_time).into();
            
            if duration == 0 {
                return rate_index.last_rate;
            }
            
            div_down(end_cumulative - *swap.start_cumulative_rate_time, duration)
        }

        fn _calculate_base_swap_rate(self: @ContractState, market_id: u256) -> u256 {
            let market = self.markets.read(market_id);
            let paired_market = self.markets.read(market.paired_market_id);

            let oracle_rate = self
                ._get_oracle_rate(
                    market.params.reference_rate_oracle, market.params.max_oracle_staleness,
                );

            let this_available = market.total_lp_collateral - market.locked_lp_collateral;
            let paired_available = paired_market.total_lp_collateral
                - paired_market.locked_lp_collateral;
            let total_available = this_available + paired_available;

            if total_available == 0 {
                return oracle_rate;
            }

            let this_ratio = mul_div_down(this_available, Constants::BPS, total_available);
            let paired_ratio = mul_div_down(paired_available, Constants::BPS, total_available);

            let max_adj: u256 = market.params.max_rate_adjustment.into();

            if this_ratio > paired_ratio {
                let diff = this_ratio - paired_ratio;
                let adjustment = mul_div_down(diff, max_adj, Constants::BPS);

                if market.rate_type == RateType::Fixed {
                    if oracle_rate > adjustment {
                        oracle_rate - adjustment
                    } else {
                        0
                    }
                } else {
                    oracle_rate + adjustment
                }
            } else {
                let diff = paired_ratio - this_ratio;
                let adjustment = mul_div_down(diff, max_adj,Constants::BPS);

                if market.rate_type == RateType::Fixed {
                    oracle_rate + adjustment
                } else {
                    if oracle_rate > adjustment {
                        oracle_rate - adjustment
                    } else {
                        0
                    }
                }
            }
        }

        fn _get_collateral_value_usd(self: @ContractState, market: @Market, amount: u256) -> u256 {
            let token = IERC20Dispatcher { contract_address: *market.params.swap_token };
            let decimals = token.decimals();

            let price = self
                ._get_oracle_price(
                    *market.params.collateral_price_oracle, *market.params.max_oracle_staleness,
                );

            // Rounds DOWN - conservative collateral valuation
            calculate_usd_value(amount, price, decimals)
        }

        fn _calculate_collateral_requirements(
            self: @ContractState, market: @Market, notional_amount: u256, swap_rate: u256,
        ) -> (u256, u256) {
            let term_seconds: u256 = (*market.params.swap_term).into();
            let year_seconds: u256 = Constants::SECONDS_PER_YEAR.into();

            // Max exposure = notional × rate × term / year
            // Use mul_div_up for conservative estimate
            let max_exposure = mul_div_up(
                mul_div_up(notional_amount, swap_rate, Constants::BPS), term_seconds, year_seconds,
            );

            // Required collateral = max_exposure / threshold (rounds UP)
            let threshold: u256 = (*market.params.liquidation_threshold).into();
            let required_usd = calculate_required_collateral(max_exposure, threshold);

            // Convert USD to token amount for LP (rounds UP)
            let token = IERC20Dispatcher { contract_address: *market.params.swap_token };
            let decimals = token.decimals();
            let price = self
                ._get_oracle_price(
                    *market.params.collateral_price_oracle, *market.params.max_oracle_staleness,
                );

            let lp_tokens = calculate_token_amount_from_usd(required_usd, price, decimals);

            (required_usd, lp_tokens)
        }

        fn _calculate_current_pnl(
            self: @ContractState, market_id: u256, swap: @Swap,
        ) -> SignedValue {
            let market = self.markets.read(market_id);
            let rate_index = self.rate_indices.read(market_id);

            let current_time = get_block_timestamp();
            let elapsed: u256 = (current_time - *swap.start_time).into();

            if elapsed == 0 {
                return zero();
            }

            // Calculate current TWA
            let time_since_update: u256 = (current_time - rate_index.last_update_time).into();
            let current_cumulative = rate_index.cumulative_rate_time
                + (rate_index.last_rate * time_since_update);

            let twa = div_down(current_cumulative - *swap.start_cumulative_rate_time, elapsed);

            // Calculate payments
            let year_seconds: u256 = Constants::SECONDS_PER_YEAR.into();
            let fixed_payment = calculate_payment(
                *swap.notional_amount, *swap.fixed_rate, elapsed, year_seconds,
            );
            let floating_payment = calculate_payment(
                *swap.notional_amount, twa, elapsed, year_seconds,
            );

            // Buyer PnL based on market type
            if market.rate_type == RateType::Fixed {
                // Buyer pays fixed, receives floating
                safe_sub(floating_payment, fixed_payment)
            } else {
                // Buyer pays floating, receives fixed
                safe_sub(fixed_payment, floating_payment)
            }
        }

        fn _calculate_final_pnl(
            self: @ContractState, market: @Market, swap: @Swap, twa_rate: u256,
        ) -> SignedValue {
            let term_seconds: u256 = (*swap.expiration_time - *swap.start_time).into();
            let year_seconds: u256 = Constants::SECONDS_PER_YEAR.into();

            let fixed_payment = calculate_payment(
                *swap.notional_amount, *swap.fixed_rate, term_seconds, year_seconds,
            );
            let floating_payment = calculate_payment(
                *swap.notional_amount, twa_rate, term_seconds, year_seconds,
            );

            if *market.rate_type == RateType::Fixed {
                safe_sub(floating_payment, fixed_payment)
            } else {
                safe_sub(fixed_payment, floating_payment)
            }
        }

        fn _calculate_buyer_health(
            self: @ContractState, market: @Market, swap: @Swap, pnl: SignedValue,
        ) -> u256 {
            let collateral_value = self._get_collateral_value_usd(market, *swap.buyer_collateral);
            let remaining_value = to_u256_saturating(add_u256_to_signed(collateral_value, pnl));

            calculate_health_factor(remaining_value, *swap.required_collateral_usd)
        }

        fn _check_liquidation_eligibility(
            self: @ContractState, market: @Market, swap: @Swap, buyer_pnl: SignedValue,
        ) -> (bool, bool) {
            let threshold: u256 = (*market.params.liquidation_threshold).into();

            // Buyer health
            let buyer_health = self._calculate_buyer_health(market, swap, buyer_pnl);
            let buyer_liquidatable = buyer_health < threshold;

            // LP health (opposite PnL)
            let lp_pnl = negate(buyer_pnl);
            let lp_collateral_value = self._get_collateral_value_usd(market, *swap.lp_collateral);
            let lp_remaining = to_u256_saturating(add_u256_to_signed(lp_collateral_value, lp_pnl));
            let lp_health = calculate_health_factor(lp_remaining, *swap.required_collateral_usd);
            let lp_liquidatable = lp_health < threshold;

            (buyer_liquidatable, lp_liquidatable)
        }

        // ===== Settlement Execution =====

        fn _execute_settlement(
            ref self: ContractState,
            ref market: Market,
            ref swap: Swap,
            owner: ContractAddress,
            pnl: SignedValue,
        ) {
            let token = IERC20Dispatcher { contract_address: market.params.swap_token };

            if pnl.is_negative {
                // Buyer loses - LP wins
                // Round UP the loss (user loses more)
                let loss = min(pnl.value + 1, swap.buyer_collateral);
                let buyer_return = swap.buyer_collateral - loss;

                if buyer_return > 0 {
                    token.transfer(owner, buyer_return);
                }

                // LP pool gains
                market.total_lp_collateral += loss;
            } else {
                // Buyer wins - LP loses
                // Round DOWN the profit (user receives less)
                let profit = min(pnl.value, swap.lp_collateral);

                let buyer_return = swap.buyer_collateral + profit;
                token.transfer(owner, buyer_return);

                // LP pool loses
                market.total_lp_collateral -= profit;
            }

            // Unlock LP collateral
            market.locked_lp_collateral -= swap.lp_collateral;
        }

        fn _execute_liquidation(
            ref self: ContractState,
            ref market: Market,
            ref swap: Swap,
            owner: ContractAddress,
            liquidator: ContractAddress,
            side: LiquidationSide,
            buyer_pnl: SignedValue,
        ) -> u256 {
            let token = IERC20Dispatcher { contract_address: market.params.swap_token };
            let incentive_bps: u256 = market.params.liquidation_incentive.into();

            let collateral_seized = match side {
                LiquidationSide::Buyer => {
                    // Buyer is liquidated
                    // Round DOWN liquidator bonus (liquidator gets less)
                    let liquidator_reward = calculate_liquidation_bonus(
                        swap.buyer_collateral, incentive_bps,
                    );
                    let to_lp = swap.buyer_collateral - liquidator_reward;

                    token.transfer(liquidator, liquidator_reward);
                    market.total_lp_collateral += to_lp;

                    swap.buyer_collateral
                },
                LiquidationSide::Lp => {
                    // LP is liquidated
                    let liquidator_reward = calculate_liquidation_bonus(
                        swap.lp_collateral, incentive_bps,
                    );
                    let to_buyer = swap.lp_collateral - liquidator_reward;

                    token.transfer(liquidator, liquidator_reward);
                    token.transfer(owner, swap.buyer_collateral + to_buyer);

                    market.total_lp_collateral -= swap.lp_collateral;

                    swap.lp_collateral
                },
            };

            market.locked_lp_collateral -= swap.lp_collateral;

            collateral_seized
        }

        fn _apply_early_exit_penalty(
            self: @ContractState, market: @Market, current_pnl: SignedValue,
        ) -> (SignedValue, u256) {
            let early_exit_fee_bps: u256 = (*market.params.early_exit_fee).into();

            // Round UP penalty (user pays more)
            let penalty = calculate_fee(current_pnl.value, early_exit_fee_bps);

            if current_pnl.is_negative {
                // Losing: increase loss
                let new_loss = current_pnl.value + penalty;
                (negative(new_loss), penalty)
            } else {
                // Winning: reduce profit
                let new_profit = if current_pnl.value > penalty {
                    current_pnl.value - penalty
                } else {
                    0
                };
                (positive(new_profit), penalty)
            }
        }

        // ===== Fee Collection =====

        fn _calculate_and_collect_swap_fee(
            ref self: ContractState, market: @Market, collateral_amount: u256,
        ) -> u256 {
            let fees = self.protocol_fees.read();
            // Round UP fee (protocol gets more)
            let fee_amount = calculate_fee(collateral_amount, fees.swap_fee_bps.into());

            if fee_amount > 0 {
                self._accumulate_fee(*market.params.swap_token, fee_amount);
            }

            fee_amount
        }

        fn _accumulate_fee(ref self: ContractState, token: ContractAddress, amount: u256) {
            let current = self.accumulated_fees.read(token);
            self.accumulated_fees.write(token, current + amount);
        }

        // ===== Active Swaps Management =====

        fn _add_active_swap(ref self: ContractState, market_id: u256, swap_id: u256) {
            let count = self.active_swaps_count.read(market_id);
            self.active_swaps.write((market_id, count), swap_id);
            self.active_swaps_count.write(market_id, count + 1);
        }

        fn _remove_active_swap(ref self: ContractState, market_id: u256, swap_id: u256) {
            let count = self.active_swaps_count.read(market_id);
            if count == 0 {
                return;
            }

            let mut i: u256 = 0;
            loop {
                if i >= count {
                    break;
                }

                if self.active_swaps.read((market_id, i)) == swap_id {
                    let last_swap_id = self.active_swaps.read((market_id, count - 1));
                    self.active_swaps.write((market_id, i), last_swap_id);
                    self.active_swaps_count.write(market_id, count - 1);
                    break;
                }

                i += 1;
            }
        }
    }
}
