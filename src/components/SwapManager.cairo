#[starknet::component]
pub mod SwapManagerComponent {
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp};
    use crate::components::SettlementEngine;
    use crate::helpers::constants::Constants;
    use crate::helpers::core_utils::{
        calculate_fee, calculate_health_factor, calculate_required_margin,
        calculate_time_adjusted_margin,
    };
    use crate::helpers::errors::Errors;
    use crate::helpers::fixed_point::{div_down, mul_div_down, mul_div_up};
    use crate::helpers::signed_value::apply_pnl;
    use crate::helpers::utils::min_u64;
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
        pub buyer: ContractAddress,
        pub side: SwapSide,
        pub notional: u256,
        pub fixed_rate_bps: u256,
        pub buyer_collateral: u256,
        pub lp_collateral_locked: u256,
        pub expiration_time: u64,
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
            assert(collateral > 0, Errors::ZERO_AMOUNT);

            let current_time = get_block_timestamp();

            // Calculate swap rate
            let (final_rate, _adjustment, _is_positive) = self
                .calculate_swap_rate(market.pool, market.params, side, oracle_rate);

            // Slippage check
            assert(final_rate <= max_rate_bps, Errors::RATE_EXCEEDS_MAX);

            // Calculate requirements
            let term_seconds = *market.params.swap_term_seconds;
            let required_margin = calculate_required_margin(
                notional, final_rate, term_seconds, *market.params.initial_margin_multiplier_bps,
            );

            // LP must lock same amount
            let lp_collateral_needed = required_margin;

            // Calculate fees
            let swap_fee = calculate_fee(collateral, *market.params.swap_fee_bps);
            let protocol_portion = calculate_fee(swap_fee, protocol_fee_share_bps);
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
                    },
                );

            (swap_id, pool, lp_fee_portion, protocol_portion)
        }

        /// Settle a swap at expiration
        /// Returns (updated_pool, settlement_result, owner)
        fn settle_swap(
            ref self: ComponentState<TContractState>,
            swap_id: u256,
            owner: ContractAddress,
            market: @MarketPair,
        ) -> (LpPool, SettlementResult) {
            let mut swap = self.swaps.read(swap_id);
            assert(swap.status == SwapStatus::Active, Errors::SWAP_NOT_ACTIVE);

            let current_time = get_block_timestamp();
            assert(current_time >= swap.expiration_time, Errors::SWAP_NOT_EXPIRED);

            // Process settlement using SettlementEngine
            let result = SettlementEngine::process_settlement(
                @swap, market.rate_index, market.params, SettlementType::Normal, current_time,
            );

            // Update swap status
            swap.status = SwapStatus::Settled;
            self.swaps.write(swap_id, swap);

            // Update pool
            let pool = SettlementEngine::finalize_pool_state(*market.pool, @swap, result.lp_delta);

            self
                .emit(
                    SwapSettled {
                        swap_id,
                        owner,
                        twa_rate_bps: result.twa_rate_bps,
                        pnl: result.pnl,
                        buyer_payout: result.buyer_payout,
                    },
                );

            (pool, result)
        }

        /// Early exit a swap
        /// Returns (updated_pool, settlement_result)
        fn early_exit(
            ref self: ComponentState<TContractState>,
            swap_id: u256,
            caller: ContractAddress,
            owner: ContractAddress,
            market: @MarketPair,
        ) -> (LpPool, SettlementResult) {
            let mut swap = self.swaps.read(swap_id);
            assert(swap.status == SwapStatus::Active, Errors::SWAP_NOT_ACTIVE);
            assert(caller == owner, Errors::NOT_SWAP_OWNER);

            let current_time = get_block_timestamp();
            assert(current_time < swap.expiration_time, Errors::SWAP_EXPIRED);
            assert(
                current_time >= swap.start_time + (*market.params).min_hold_period_seconds,
                Errors::MIN_HOLD_PERIOD,
            );

            // Process settlement using SettlementEngine
            let result = SettlementEngine::process_settlement(
                @swap, market.rate_index, market.params, SettlementType::EarlyExit, current_time,
            );

            // Update swap status
            swap.status = SwapStatus::ExitedEarly;
            self.swaps.write(swap_id, swap);

            // Update pool
            let pool = SettlementEngine::finalize_pool_state(*market.pool, @swap, result.lp_delta);

            self
                .emit(
                    SwapExitedEarly {
                        swap_id,
                        owner,
                        twa_rate_bps: result.twa_rate_bps,
                        pnl: result.pnl,
                        penalty: result.penalty,
                        buyer_payout: result.buyer_payout,
                    },
                );

            (pool, result)
        }

        /// Liquidate an unhealthy swap
        /// Returns (updated_pool, settlement_result, health_status)
        fn liquidate(
            ref self: ComponentState<TContractState>,
            swap_id: u256,
            liquidator: ContractAddress,
            owner: ContractAddress,
            market: @MarketPair,
        ) -> (LpPool, SettlementResult, HealthStatus) {
            let mut swap = self.swaps.read(swap_id);
            assert(swap.status == SwapStatus::Active, Errors::SWAP_NOT_ACTIVE);

            let current_time = get_block_timestamp();
            assert(current_time < swap.expiration_time, Errors::SWAP_EXPIRED_USE_SETTLE);

            // Check health
            let health_status = self.calculate_health_status(@swap, market, current_time);
            assert(health_status.is_liquidatable, Errors::HEALTHY_POSITION);

            // Process settlement using SettlementEngine
            let result = SettlementEngine::process_settlement(
                @swap, market.rate_index, market.params, SettlementType::Liquidation, current_time,
            );

            // Update swap status
            swap.status = SwapStatus::Liquidated;
            self.swaps.write(swap_id, swap);

            // Update pool
            let pool = SettlementEngine::finalize_pool_state(*market.pool, @swap, result.lp_delta);

            let remaining_to_pool = result.lp_delta.value;

            self
                .emit(
                    SwapLiquidated {
                        swap_id,
                        liquidator,
                        owner,
                        health_factor_bps: health_status.health_factor_bps,
                        liquidator_bonus: result.liquidator_bonus,
                        remaining_to_pool,
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
            let (final_rate, adjustment, is_positive) = self
                .calculate_swap_rate(pool, params, side, oracle_rate);

            let required_collateral = calculate_required_margin(
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
            let twa = self.calculate_twa(market.rate_index, swap, current_time);
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

        /// Get current TWA for a swap
        fn get_current_twa(
            self: @ComponentState<TContractState>, swap_id: u256, rate_index: @RateIndex,
        ) -> u256 {
            let swap = self.swaps.read(swap_id);
            self.calculate_twa(rate_index, @swap, get_block_timestamp())
        }

        /// Calculate swap rate with imbalance adjustment
        fn calculate_swap_rate(
            self: @ComponentState<TContractState>,
            pool: @LpPool,
            params: @MarketParams,
            side: SwapSide,
            oracle_rate: u256,
        ) -> (u256, u256, bool) {
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
            } else if oracle_rate > adjustment_bps {
                oracle_rate - adjustment_bps
            } else {
                0
            };

            // Add fee spread
            let final_rate = adjusted_rate + *params.fee_spread_bps;

            (final_rate, adjustment_bps, is_positive)
        }

        /// Calculate cumulative rate at a specific timestamp
        fn calculate_cumulative_at(
            self: @ComponentState<TContractState>, rate_index: @RateIndex, target_time: u64,
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
        fn calculate_twa(
            self: @ComponentState<TContractState>,
            rate_index: @RateIndex,
            swap: @Swap,
            current_time: u64,
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
            let end_cumulative = self.calculate_cumulative_at(rate_index, effective_end_time);

            // TWA = (end_cumulative - start_cumulative) / duration
            if end_cumulative >= start_cumulative {
                div_down(end_cumulative - start_cumulative, duration)
            } else {
                0
            }
        }
    }
}
