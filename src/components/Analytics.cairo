#[starknet::component]
pub mod AnalyticsComponent {
    use openzeppelin_introspection::src5::SRC5Component;
    use starknet::{ContractAddress, get_block_timestamp};
    use crate::components::ERC6909::ERC6909Component;
    use crate::components::LiquidityManager::LiquidityManagerComponent;
    use crate::components::LiquidityManager::LiquidityManagerComponent::InternalTrait as LiquidityInternalTrait;
    use crate::components::MarketManager::MarketManagerComponent;
    use crate::components::MarketManager::MarketManagerComponent::InternalTrait as MarketInternalTrait;
    use crate::components::SwapManager::SwapManagerComponent;
    use crate::components::SwapManager::SwapManagerComponent::InternalTrait as SwapInternalTrait;
    use crate::helpers::constants::Constants;
    use crate::helpers::signed_value::{add_signed, apply_pnl, negative, positive, zero};
    use crate::types::asce_swap::{
        LpAnalytics, ScenarioResult, SignedValue, Swap, SwapAnalytics, SwapSide, SwapStatus,
        UserDashboard, UserLpSummary, UserSwapSummary,
    };

    #[storage]
    pub struct Storage {}

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        AnalyticsQueried: AnalyticsQueried,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AnalyticsQueried {}

    #[generate_trait]
    pub impl InternalImpl<
        TContractState,
        +HasComponent<TContractState>,
        +Drop<TContractState>,
        impl MarketMgr: MarketManagerComponent::HasComponent<TContractState>,
        impl SwapMgr: SwapManagerComponent::HasComponent<TContractState>,
        impl LiquidityMgr: LiquidityManagerComponent::HasComponent<TContractState>,
        +ERC6909Component::HasComponent<TContractState>,
        +SRC5Component::HasComponent<TContractState>,
        +ERC6909Component::ERC6909HooksTrait<TContractState>,
    > of InternalTrait<TContractState> {
        fn _get_swap_analytics(
            self: @ComponentState<TContractState>, swap_id: u256,
        ) -> SwapAnalytics {
            let contract = self.get_contract();
            let swap_mgr = SwapMgr::get_component(contract);
            let market_mgr = MarketMgr::get_component(contract);

            let swap = swap_mgr.get_swap(swap_id);
            let market = market_mgr._get_market(swap.pair_id);
            let health = swap_mgr.get_health_status(swap_id, @market);
            let current_time = get_block_timestamp();

            let (current_floating_rate_bps, _) = market_mgr._get_oracle_rate(market.rate_oracle);

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
            let term_days = term_seconds / 86400;
            let yield_term_bps = if term_days > 0 && swap.buyer_collateral > 0 {
                let spread_value = current_spread_bps.value;
                let annualization_factor = 365_u256 / term_days.into();
                let yield_value = (spread_value * leverage_x100 * annualization_factor) / 100;

                match swap.side {
                    SwapSide::Fixed => {
                        if current_spread_bps.is_negative {
                            negative(yield_value)
                        } else {
                            positive(yield_value)
                        }
                    },
                    SwapSide::Floating => {
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
            let projected_pnl_at_expiry = _calculate_projected_pnl(
                @swap, current_floating_rate_bps, swap.expiration_time,
            );

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
                elapsed_seconds,
                remaining_seconds,
                progress_bps,
                projected_pnl_at_expiry,
            }
        }

        fn _get_lp_analytics(
            self: @ComponentState<TContractState>, lp: ContractAddress, pair_id: felt252,
        ) -> LpAnalytics {
            let contract = self.get_contract();
            let market_mgr = MarketMgr::get_component(contract);
            let liquidity_mgr = LiquidityMgr::get_component(contract);

            let market = market_mgr._get_market(pair_id);
            let shares = liquidity_mgr._balance_of(lp, pair_id);
            let pool_analytics = liquidity_mgr._get_pool_analytics(@market.pool);

            let share_value = liquidity_mgr._convert_to_assets(shares, @market.pool);

            let share_percentage_bps = if market.pool.total_shares > 0 {
                (shares * Constants::BPS) / market.pool.total_shares
            } else {
                0
            };

            let total_locked = market.pool.locked_for_fixed + market.pool.locked_for_floating;
            let utilization_bps = if market.pool.total_collateral > 0 {
                (total_locked * Constants::BPS) / market.pool.total_collateral
            } else {
                0
            };

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

            let max_withdrawable = if share_value < pool_analytics.available_liquidity {
                share_value
            } else {
                pool_analytics.available_liquidity
            };

            LpAnalytics {
                shares,
                share_value,
                share_percentage_bps,
                pool_tvl: pool_analytics.total_value,
                available_liquidity: pool_analytics.available_liquidity,
                utilization_bps,
                net_exposure: pool_analytics.net_exposure_notional,
                your_exposure,
                max_withdrawable,
            }
        }

        fn _preview_swap_scenarios(
            self: @ComponentState<TContractState>, swap_id: u256, rate_scenarios_bps: Span<u256>,
        ) -> Span<ScenarioResult> {
            let contract = self.get_contract();
            let swap_mgr = SwapMgr::get_component(contract);

            let swap = swap_mgr.get_swap(swap_id);
            let mut results: Array<ScenarioResult> = array![];

            for rate_bps in rate_scenarios_bps {
                let pnl = _calculate_projected_pnl(@swap, *rate_bps, swap.expiration_time);
                let is_profitable = !pnl.is_negative && pnl.value > 0;
                results.append(ScenarioResult { rate_bps: *rate_bps, pnl, is_profitable });
            }

            results.span()
        }

        fn _get_breakeven_rate(self: @ComponentState<TContractState>, swap_id: u256) -> u256 {
            let contract = self.get_contract();
            let swap_mgr = SwapMgr::get_component(contract);
            let swap = swap_mgr.get_swap(swap_id);
            swap.fixed_rate_bps
        }

        fn _get_user_swaps_summary(
            self: @ComponentState<TContractState>, swap_ids: Span<u256>,
        ) -> Span<UserSwapSummary> {
            let contract = self.get_contract();
            let swap_mgr = SwapMgr::get_component(contract);
            let market_mgr = MarketMgr::get_component(contract);

            let mut summaries: Array<UserSwapSummary> = array![];
            let current_time = get_block_timestamp();

            for swap_id in swap_ids {
                let swap = swap_mgr.get_swap(*swap_id);
                let market = market_mgr._get_market(swap.pair_id);
                let health = swap_mgr.get_health_status(*swap_id, @market);

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

        fn _get_user_dashboard(
            self: @ComponentState<TContractState>,
            user: ContractAddress,
            swap_ids: Span<u256>,
            lp_pair_ids: Span<felt252>,
        ) -> UserDashboard {
            let contract = self.get_contract();
            let swap_mgr = SwapMgr::get_component(contract);
            let market_mgr = MarketMgr::get_component(contract);
            let liquidity_mgr = LiquidityMgr::get_component(contract);

            let mut total_swaps: u32 = 0;
            let mut active_swaps: u32 = 0;
            let mut total_notional: u256 = 0;
            let mut total_collateral_locked: u256 = 0;
            let mut total_pnl: SignedValue = zero();

            for swap_id in swap_ids {
                let swap = swap_mgr.get_swap(*swap_id);
                let market = market_mgr._get_market(swap.pair_id);
                let health = swap_mgr.get_health_status(*swap_id, @market);

                total_swaps += 1;

                if swap.status == SwapStatus::Active {
                    active_swaps += 1;
                    total_notional += swap.notional;
                    total_collateral_locked += swap.buyer_collateral;
                    total_pnl = add_signed(total_pnl, health.current_pnl);
                }
            }

            let mut total_lp_value: u256 = 0;
            let mut total_lp_positions: u32 = 0;

            for pair_id in lp_pair_ids {
                let shares = liquidity_mgr._balance_of(user, *pair_id);
                if shares > 0 {
                    let market = market_mgr._get_market(*pair_id);
                    let share_value = liquidity_mgr._convert_to_assets(shares, @market.pool);
                    total_lp_value += share_value;
                    total_lp_positions += 1;
                }
            }

            let total_portfolio_value = apply_pnl(total_collateral_locked, total_pnl)
                + total_lp_value;

            UserDashboard {
                total_swaps,
                active_swaps,
                total_notional,
                total_collateral_locked,
                total_unrealized_pnl: total_pnl,
                total_lp_value,
                total_lp_positions,
                total_portfolio_value,
            }
        }

        fn _get_user_lp_summary(
            self: @ComponentState<TContractState>, user: ContractAddress, pair_ids: Span<felt252>,
        ) -> Span<UserLpSummary> {
            let contract = self.get_contract();
            let market_mgr = MarketMgr::get_component(contract);
            let liquidity_mgr = LiquidityMgr::get_component(contract);

            let mut summaries: Array<UserLpSummary> = array![];

            for pair_id in pair_ids {
                let shares = liquidity_mgr._balance_of(user, *pair_id);

                if shares > 0 {
                    let market = market_mgr._get_market(*pair_id);
                    let share_value = liquidity_mgr._convert_to_assets(shares, @market.pool);

                    let share_percentage_bps = if market.pool.total_shares > 0 {
                        (shares * Constants::BPS) / market.pool.total_shares
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

                    summaries
                        .append(
                            UserLpSummary {
                                pair_id: *pair_id,
                                shares,
                                share_value,
                                share_percentage_bps,
                                utilization_bps,
                            },
                        );
                }
            }

            summaries.span()
        }
    }

    /// Calculate projected PnL for a swap at a given rate and time
    fn _calculate_projected_pnl(
        swap: @Swap, projected_rate_bps: u256, at_time: u64,
    ) -> SignedValue {
        let notional = *swap.notional;
        let fixed_rate = *swap.fixed_rate_bps;
        let term_seconds = at_time - *swap.start_time;

        let seconds_per_year: u256 = 31536000; // 365 days

        let fixed_payment = (notional * fixed_rate * term_seconds.into())
            / (Constants::BPS * seconds_per_year);
        let floating_payment = (notional * projected_rate_bps * term_seconds.into())
            / (Constants::BPS * seconds_per_year);

        match *swap.side {
            SwapSide::Fixed => {
                if floating_payment >= fixed_payment {
                    positive(floating_payment - fixed_payment)
                } else {
                    negative(fixed_payment - floating_payment)
                }
            },
            SwapSide::Floating => {
                if fixed_payment >= floating_payment {
                    positive(fixed_payment - floating_payment)
                } else {
                    negative(floating_payment - fixed_payment)
                }
            },
        }
    }
}
