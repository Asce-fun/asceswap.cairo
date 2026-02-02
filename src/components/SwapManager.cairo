#[starknet::component]
pub mod SwapManagerComponent {
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp};
    use crate::helpers::constants::Constants;
    use crate::helpers::errors::Errors;
    use crate::helpers::fixed_point::mul_div_up;
    use crate::helpers::signed_value::apply_pnl;
    use crate::helpers::utils::Utils;
    use crate::libraries::health_calculator::HealthCal;
    use crate::libraries::rate_engine::RateEngine;
    use crate::libraries::settlement_engine::SettlementEngine;
    use crate::types::asce_swap::{
        HealthStatus, LpPool, MarketPair, MarketParams, RateIndex, SettlementResult, SettlementType,
        SignedValue, Swap, SwapQuote, SwapSide, SwapStatus,
    };

    #[storage]
    pub struct Storage {
        swaps: Map<u256, Swap>,
        next_swap_id: u256,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        SwapCreated: SwapCreated,
        SwapSettled: SwapSettled,
        SwapExitedEarly: SwapExitedEarly,
        SwapLiquidated: SwapLiquidated,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SwapCreated {
        #[key]
        pub swap_id: u256,
        #[key]
        pub pair_id: felt252,
        #[key]
        pub buyer: ContractAddress,
        pub side: SwapSide,
        pub notional: u256,
        pub fixed_rate_bps: u256,
        pub buyer_collateral: u256,
        pub lp_collateral_locked: u256,
        pub expiration_time: u64,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SwapSettled {
        #[key]
        pub swap_id: u256,
        #[key]
        pub pair_id: felt252,
        #[key]
        pub owner: ContractAddress,
        pub twa_rate_bps: u256,
        pub pnl: SignedValue,
        pub buyer_payout: u256,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SwapExitedEarly {
        #[key]
        pub swap_id: u256,
        #[key]
        pub pair_id: felt252,
        #[key]
        pub owner: ContractAddress,
        pub twa_rate_bps: u256,
        pub pnl: SignedValue,
        pub penalty: u256,
        pub buyer_payout: u256,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SwapLiquidated {
        #[key]
        pub swap_id: u256,
        #[key]
        pub pair_id: felt252,
        #[key]
        pub owner: ContractAddress,
        pub liquidator: ContractAddress,
        pub health_factor_bps: u256,
        pub liquidator_bonus: u256,
        pub remaining_to_pool: u256,
        pub timestamp: u64,
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>, +Drop<TContractState>,
    > of InternalTrait<TContractState> {
        /// Initialize swap manager
        fn initializer(ref self: ComponentState<TContractState>) {
            self.next_swap_id.write(1);
        }

        /// Get next swap id
        fn get_next_swap_id(self: @ComponentState<TContractState>) -> u256 {
            self.next_swap_id.read()
        }

        /// Buy a swap - creates swap record and returns info for NFT minting
        /// Returns (swap_id, updated_pool, lp_fee_portion, protocol_portion)
        fn buy_swap(
            ref self: ComponentState<TContractState>,
            pair_id: felt252,
            side: SwapSide,
            notional: u256,
            collateral: u256,
            max_rate_bps: u256,
            caller: ContractAddress,
            market: @MarketPair,
            oracle_rate: u256,
            protocol_fee_share_bps: u256,
        ) -> (u256, LpPool, u256, u256) {
            // Validate
            assert(notional >= *market.params.min_notional, Errors::BELOW_MIN_NOTIONAL);
            assert(notional <= *market.params.max_notional_per_swap, Errors::ABOVE_MAX_NOTIONAL);
            //@audit: shouldn't collateral amount be a factor of notional amount ?
            assert(collateral > 0, Errors::ZERO_AMOUNT);

            let current_time = get_block_timestamp();

            // Calculate swap rate (base + imbalance + feeSpread)
            let (final_rate, _adjustment, _is_positive) = RateEngine::calculate_swap_rate(
                market.pool, market.params, side, oracle_rate,
            );

            // Slippage check
            assert(final_rate <= max_rate_bps, Errors::RATE_EXCEEDS_MAX);

            // Calculate requirements
            let term_seconds = *market.params.swap_term_seconds;
            // total margin required to lock (notional * rate * terms * buffer)
            let required_margin = HealthCal::calculate_required_margin(
                notional, final_rate, term_seconds, *market.params.initial_margin_multiplier_bps,
            );

            // LP must lock same amount
            let lp_collateral_needed = required_margin;

            // Calculate fees
            let swap_fee = Utils::calculate_fee(collateral, *market.params.swap_fee_bps);
            let protocol_portion = Utils::calculate_fee(swap_fee, protocol_fee_share_bps);
            let lp_fee_portion = swap_fee - protocol_portion;
            let net_collateral = collateral - swap_fee;

            assert(net_collateral >= required_margin, Errors::INSUFFICIENT_COLLATERAL);

            // Check pool has enough available
            let mut pool = *market.pool;
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
                utilization <= *market.params.max_utilization_bps, Errors::EXCEEDS_MAX_UTILIZATION,
            );

            // Create swap
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
                start_cumulative_rate: (*market.rate_index).cumulative_rate_time,
            };

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

            // Transfer collateral - done by main contract

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
                        timestamp: current_time,
                    },
                );

            (swap_id, pool, lp_fee_portion, protocol_portion)
        }

        /// Settle a swap at expiration
        /// Returns (updated_pool, settlement_result)
        /// Accepts swap by value to avoid redundant storage read (caller already has it)
        fn settle_swap(
            ref self: ComponentState<TContractState>,
            swap_id: u256,
            swap: Swap,
            owner: ContractAddress,
            market: @MarketPair,
        ) -> (LpPool, SettlementResult) {
            // is swap active
            assert(swap.status == SwapStatus::Active, Errors::SWAP_NOT_ACTIVE);

            let current_time = get_block_timestamp();
            assert(current_time >= swap.expiration_time, Errors::SWAP_NOT_EXPIRED);

            // Process settlement using SettlementEngine (pass snapshot)
            let result = SettlementEngine::process_settlement(
                @swap, market.rate_index, market.params, SettlementType::Normal, current_time,
            );

            // Update pool
            let pool = SettlementEngine::finalize_pool_state(*market.pool, @swap, result.lp_delta);

            // Update swap status and write back
            let mut swap = swap; // shadow as mutable
            swap.status = SwapStatus::Settled;
            self.swaps.write(swap_id, swap);

            self
                .emit(
                    SwapSettled {
                        swap_id,
                        pair_id: swap.pair_id,
                        owner,
                        twa_rate_bps: result.twa_rate_bps,
                        pnl: result.pnl,
                        buyer_payout: result.buyer_payout,
                        timestamp: current_time,
                    },
                );

            (pool, result)
        }

        /// Early exit a swap
        /// Returns (updated_pool, settlement_result)
        /// Accepts swap by value to avoid redundant storage read
        fn early_exit(
            ref self: ComponentState<TContractState>,
            swap_id: u256,
            swap: Swap,
            caller: ContractAddress,
            owner: ContractAddress,
            market: @MarketPair,
        ) -> (LpPool, SettlementResult) {
            // Validate swap (no storage read needed)
            assert(swap.status == SwapStatus::Active, Errors::SWAP_NOT_ACTIVE);
            assert(caller == owner, Errors::NOT_SWAP_OWNER);

            let current_time = get_block_timestamp();
            assert(current_time < swap.expiration_time, Errors::SWAP_EXPIRED);
            assert(
                current_time >= swap.start_time + (*market.params).min_hold_period_seconds,
                Errors::MIN_HOLD_PERIOD,
            );

            // Process settlement using SettlementEngine (pass snapshot)
            let result = SettlementEngine::process_settlement(
                @swap, market.rate_index, market.params, SettlementType::EarlyExit, current_time,
            );

            // Update pool (use snapshot)
            let pool = SettlementEngine::finalize_pool_state(*market.pool, @swap, result.lp_delta);

            // Update swap status and write back
            let mut swap = swap;
            swap.status = SwapStatus::ExitedEarly;
            self.swaps.write(swap_id, swap);

            self
                .emit(
                    SwapExitedEarly {
                        swap_id,
                        pair_id: swap.pair_id,
                        owner,
                        twa_rate_bps: result.twa_rate_bps,
                        pnl: result.pnl,
                        penalty: result.penalty,
                        buyer_payout: result.buyer_payout,
                        timestamp: current_time,
                    },
                );

            (pool, result)
        }

        /// Liquidate an unhealthy swap
        /// Returns (updated_pool, settlement_result, health_status)
        /// Accepts swap by value to avoid redundant storage read
        fn liquidate(
            ref self: ComponentState<TContractState>,
            swap_id: u256,
            swap: Swap,
            liquidator: ContractAddress,
            owner: ContractAddress,
            market: @MarketPair,
        ) -> (LpPool, SettlementResult, HealthStatus) {
            // Validate swap (no storage read needed)
            assert(swap.status == SwapStatus::Active, Errors::SWAP_NOT_ACTIVE);

            let current_time = get_block_timestamp();
            assert(current_time < swap.expiration_time, Errors::SWAP_EXPIRED_USE_SETTLE);

            // Check health (use snapshot)
            let health_status = self.calculate_health_status(@swap, market, current_time);
            assert(health_status.is_liquidatable, Errors::HEALTHY_POSITION);

            // Process settlement using SettlementEngine (pass snapshot)
            let result = SettlementEngine::process_settlement(
                @swap, market.rate_index, market.params, SettlementType::Liquidation, current_time,
            );

            // Update pool (use snapshot)
            let pool = SettlementEngine::finalize_pool_state(*market.pool, @swap, result.lp_delta);

            let remaining_to_pool = result.lp_delta.value;

            // Update swap status and write back
            let mut swap = swap;
            swap.status = SwapStatus::Liquidated;
            self.swaps.write(swap_id, swap);

            self
                .emit(
                    SwapLiquidated {
                        swap_id,
                        pair_id: swap.pair_id,
                        owner,
                        liquidator,
                        health_factor_bps: health_status.health_factor_bps,
                        liquidator_bonus: result.liquidator_bonus,
                        remaining_to_pool,
                        timestamp: current_time,
                    },
                );

            (pool, result, health_status)
        }

        /// Get a swap
        fn get_swap(self: @ComponentState<TContractState>, swap_id: u256) -> Swap {
            self.swaps.read(swap_id)
        }

        /// Get swap quote
        fn get_swap_quote(
            self: @ComponentState<TContractState>,
            pool: @LpPool,
            params: @MarketParams,
            side: SwapSide,
            notional: u256,
            oracle_rate: u256,
        ) -> SwapQuote {
            let (final_rate, adjustment, is_positive) = RateEngine::calculate_swap_rate(
                pool, params, side, oracle_rate,
            );

            let required_collateral = HealthCal::calculate_required_margin(
                notional,
                final_rate,
                *params.swap_term_seconds,
                *params.initial_margin_multiplier_bps,
            );

            SwapQuote {
                base_rate_bps: oracle_rate,
                imbalance_adjustment_bps: adjustment,
                adjustment_is_positive: is_positive,
                fee_spread_bps: *params.fee_spread_bps,
                final_rate_bps: final_rate,
                required_collateral,
                lp_collateral_to_lock: required_collateral,
            }
        }

        /// Get health status for a swap
        fn get_health_status(
            self: @ComponentState<TContractState>, swap_id: u256, market: @MarketPair,
        ) -> HealthStatus {
            let swap = self.swaps.read(swap_id);
            self.calculate_health_status(@swap, market, get_block_timestamp())
        }

        /// Calculate health status of a swap
        fn calculate_health_status(
            self: @ComponentState<TContractState>,
            swap: @Swap,
            market: @MarketPair,
            current_time: u64,
        ) -> HealthStatus {
            // Calculate current PnL using SettlementEngine
            let twa = RateEngine::calculate_twa(market.rate_index, swap, current_time);
            let current_pnl = if current_time >= *swap.expiration_time {
                SettlementEngine::calculate_pnl(swap, twa)
            } else {
                SettlementEngine::calculate_pnl_partial(swap, twa, current_time)
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

            let adjusted_margin = HealthCal::calculate_time_adjusted_margin(
                *swap.initial_required_margin,
                remaining_time,
                total_term,
                *market.params.min_margin_floor_bps,
            );

            // Calculate health factor
            let health_factor = HealthCal::calculate_health_factor(
                buyer_remaining, adjusted_margin,
            );

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

        /// Get current TWA for a swap
        fn get_current_twa(
            self: @ComponentState<TContractState>, swap_id: u256, rate_index: @RateIndex,
        ) -> u256 {
            let swap = self.swaps.read(swap_id);
            RateEngine::calculate_twa(rate_index, @swap, get_block_timestamp())
        }
    }
}
