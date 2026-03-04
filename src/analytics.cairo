/// Analytics Contract
///
/// Aggregates data from the main AsceSwap contract into page-level responses.
/// Each function provides all data needed for a single frontend page in one call.
///
/// This reduces RPC calls and improves frontend UX.

#[starknet::contract]
pub mod Analytics {
    use core::num::traits::Zero;
    use starknet::ContractAddress;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::get_block_timestamp;
    use crate::interfaces::analytics::IAnalytics;
    use crate::interfaces::asce_swap::{IAsceSwapDispatcher, IAsceSwapDispatcherTrait};
    use crate::interfaces::erc6909::{IERC6909Dispatcher, IERC6909DispatcherTrait};
    use crate::libraries::settlement_engine::SettlementEngine;
    use crate::types::analytics::{
        DashboardPageData, DetailedScenario, LpPageData, MarketForLp, MarketForTrading,
        MarketsPageData, SwapDetailData, SwapScenarioAnalysis,
    };
    use crate::types::asce_swap::{MarketStatus, SignedValue, SwapSide, SwapStatus};

    // 24 hours in seconds
    const EXPIRING_SOON_THRESHOLD: u64 = 86400;
    // Health factor threshold for "at risk" (150%)
    const AT_RISK_THRESHOLD_BPS: u256 = 15000;

    #[storage]
    pub struct Storage {
        asce_swap_contract: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, asce_swap: ContractAddress) {
        assert(!asce_swap.is_zero(), 'Invalid AsceSwap address');
        self.asce_swap_contract.write(asce_swap);
    }

    #[abi(embed_v0)]
    impl AnalyticsImpl of IAnalytics<ContractState> {
        /// Get all data needed for user dashboard page (with explicit IDs)
        /// Use this if you already have the IDs from an indexer
        fn get_dashboard_page(
            self: @ContractState,
            user: ContractAddress,
            swap_ids: Span<u256>,
            lp_pair_ids: Span<felt252>,
        ) -> DashboardPageData {
            let asce_swap = self._get_dispatcher();

            // Get aggregated dashboard from main contract
            let dashboard = asce_swap.get_user_dashboard(user, swap_ids, lp_pair_ids);

            // Get detailed swap summaries
            let swap_summaries = asce_swap.get_user_swaps_summary(swap_ids);

            // Get detailed LP summaries
            let lp_summaries = asce_swap.get_user_lp_summary(user, lp_pair_ids);

            // Analyze swap positions
            let mut fixed_positions: u32 = 0;
            let mut floating_positions: u32 = 0;
            let mut positions_at_risk: u32 = 0;
            let mut expiring_soon_count: u32 = 0;
            let mut total_health: u256 = 0;
            let mut active_count: u32 = 0;

            let mut i: u32 = 0;
            let len = swap_summaries.len();
            while i < len {
                let swap = *swap_summaries.at(i);

                if swap.status == SwapStatus::Active {
                    active_count += 1;
                    total_health += swap.health_factor_bps;

                    // Count by side
                    if swap.side == SwapSide::Fixed {
                        fixed_positions += 1;
                    } else {
                        floating_positions += 1;
                    }

                    // Check health
                    if swap.health_factor_bps < AT_RISK_THRESHOLD_BPS {
                        positions_at_risk += 1;
                    }

                    // Check expiring soon
                    if swap.remaining_seconds < EXPIRING_SOON_THRESHOLD {
                        expiring_soon_count += 1;
                    }
                }

                i += 1;
            }

            // Calculate average health factor
            let avg_health_factor_bps = if active_count > 0 {
                total_health / active_count.into()
            } else {
                0
            };

            // Calculate total LP share percentage (weighted average)
            let mut total_lp_share_percentage_bps: u256 = 0;
            let mut j: u32 = 0;
            let lp_len = lp_summaries.len();
            while j < lp_len {
                let lp = *lp_summaries.at(j);
                total_lp_share_percentage_bps += lp.share_percentage_bps;
                j += 1;
            }

            DashboardPageData {
                user,
                total_portfolio_value: dashboard.total_portfolio_value,
                total_collateral_at_risk: dashboard.total_collateral_locked,
                total_unrealized_pnl: dashboard.total_unrealized_pnl,
                total_swaps: dashboard.total_swaps,
                active_swaps: dashboard.active_swaps,
                fixed_positions,
                floating_positions,
                total_notional_exposure: dashboard.total_notional,
                avg_health_factor_bps,
                positions_at_risk,
                total_lp_value: dashboard.total_lp_value,
                total_lp_positions: dashboard.total_lp_positions,
                total_lp_share_percentage_bps,
                swap_positions: swap_summaries,
                lp_positions: lp_summaries,
                has_expiring_soon: expiring_soon_count > 0,
                expiring_soon_count,
            }
        }

        /// Get all data needed for LP page
        fn get_lp_page(
            self: @ContractState, user: ContractAddress, market_pair_ids: Span<felt252>,
        ) -> LpPageData {
            let asce_swap = self._get_dispatcher();
            let erc6909 = self._get_erc6909_dispatcher();

            let mut markets: Array<MarketForLp> = array![];
            let mut total_protocol_tvl: u256 = 0;
            let mut total_active_markets: u32 = 0;
            let mut total_user_lp_value: u256 = 0;
            let mut total_user_positions: u32 = 0;
            let mut weighted_util_sum: u256 = 0;
            let mut weight_sum: u256 = 0;

            let mut i: u32 = 0;
            let len = market_pair_ids.len();
            while i < len {
                let pair_id = *market_pair_ids.at(i);
                let market = asce_swap.get_market(pair_id);
                let pool_analytics = asce_swap.get_pool_analytics(pair_id);

                // Get user's position in this market via ERC6909 balance
                let user_shares = erc6909.balance_of(user, pair_id.into());
                let user_share_value = asce_swap.convert_to_assets(pair_id, user_shares);

                // Calculate utilization
                let utilization_bps = if pool_analytics.total_value > 0 {
                    ((pool_analytics.total_value - pool_analytics.available_liquidity) * 10000)
                        / pool_analytics.total_value
                } else {
                    0
                };

                let market_for_lp = MarketForLp {
                    pair_id,
                    status: market.status,
                    collateral_token: market.collateral_token,
                    decimals: market.decimals,
                    total_tvl: pool_analytics.total_value,
                    available_liquidity: pool_analytics.available_liquidity,
                    utilization_bps,
                    current_rate_bps: market.rate_index.last_rate_bps,
                    base_fee_spread_bps: market.params.base_fee_spread_bps,
                    net_exposure: pool_analytics.net_exposure_notional,
                    active_swaps: market.active_swap_count,
                    user_shares,
                    user_share_value,
                    user_can_withdraw: true,
                };

                markets.append(market_for_lp);

                // Aggregate stats
                total_protocol_tvl += pool_analytics.total_value;

                if market.status == MarketStatus::Active {
                    total_active_markets += 1;
                }

                if user_shares > 0 {
                    total_user_lp_value += user_share_value;
                    total_user_positions += 1;

                    // Weighted utilization
                    weighted_util_sum += utilization_bps * user_share_value;
                    weight_sum += user_share_value;
                }

                i += 1;
            }

            let weighted_avg_utilization_bps = if weight_sum > 0 {
                weighted_util_sum / weight_sum
            } else {
                0
            };

            LpPageData {
                user,
                total_lp_value: total_user_lp_value,
                total_positions: total_user_positions,
                weighted_avg_utilization_bps,
                markets: markets.span(),
                total_protocol_tvl,
                total_active_markets,
            }
        }

        /// Get all data needed for markets/trading page
        fn get_markets_page(
            self: @ContractState, market_pair_ids: Span<felt252>,
        ) -> MarketsPageData {
            let asce_swap = self._get_dispatcher();

            let mut markets: Array<MarketForTrading> = array![];
            let mut total_markets: u32 = 0;
            let mut active_markets: u32 = 0;
            let mut total_protocol_tvl: u256 = 0;
            let mut total_active_swaps: u256 = 0;

            let mut i: u32 = 0;
            let len = market_pair_ids.len();
            while i < len {
                let pair_id = *market_pair_ids.at(i);
                let market = asce_swap.get_market(pair_id);
                let pool_analytics = asce_swap.get_pool_analytics(pair_id);

                total_markets += 1;
                total_protocol_tvl += pool_analytics.total_value;
                total_active_swaps += market.active_swap_count;

                if market.status == MarketStatus::Active {
                    active_markets += 1;
                }

                // Get quotes for both sides to show rates
                // Use min_notional_per_swap and max_swap_term as reference
                let fixed_quote = asce_swap
                    .get_swap_quote(
                        pair_id,
                        SwapSide::Fixed,
                        market.params.min_notional_per_swap,
                        market.params.max_swap_term_seconds,
                    );
                let floating_quote = asce_swap
                    .get_swap_quote(
                        pair_id,
                        SwapSide::Floating,
                        market.params.min_notional_per_swap,
                        market.params.max_swap_term_seconds,
                    );

                let market_for_trading = MarketForTrading {
                    pair_id,
                    status: market.status,
                    collateral_token: market.collateral_token,
                    decimals: market.decimals,
                    current_oracle_rate_bps: market.rate_index.last_rate_bps,
                    fixed_side_rate_bps: fixed_quote.final_rate_bps,
                    floating_side_rate_bps: floating_quote.final_rate_bps,
                    available_for_fixed: pool_analytics.available_liquidity, // Simplified
                    available_for_floating: pool_analytics.available_liquidity,
                    total_liquidity: pool_analytics.total_value,
                    total_swaps_created: market.total_swaps_created,
                    active_swap_count: market.active_swap_count,
                    min_swap_term_seconds: market.params.min_swap_term_seconds,
                    max_swap_term_seconds: market.params.max_swap_term_seconds,
                    min_notional_per_swap: market.params.min_notional_per_swap,
                    swap_fee_bps: market.params.swap_fee_bps,
                    max_early_exit_fee_bps: market.params.max_early_exit_fee_bps,
                    min_early_exit_fee_bps: market.params.min_early_exit_fee_bps,
                };

                markets.append(market_for_trading);

                i += 1;
            }

            MarketsPageData {
                markets: markets.span(),
                total_markets,
                active_markets,
                total_protocol_tvl,
                total_active_swaps,
            }
        }

        /// Get complete data for a single swap position detail page
        fn get_swap_detail(self: @ContractState, swap_id: u256) -> SwapDetailData {
            let asce_swap = self._get_dispatcher();

            let swap = asce_swap.get_swap(swap_id);
            let swap_analytics = asce_swap.get_swap_analytics(swap_id);
            let health_status = asce_swap.get_health_status(swap_id);
            let breakeven_rate = asce_swap.get_breakeven_rate(swap_id);
            let market = asce_swap.get_market(swap.pair_id);
            let pool_analytics = asce_swap.get_pool_analytics(swap.pair_id);

            // Get owner from ERC721
            // Note: We need to call the main contract differently for this
            // For now, we'll use a zero address placeholder - the main contract should expose this
            let owner: ContractAddress = Zero::zero();

            // Calculate early exit info with time-decaying fee
            let current_time = get_block_timestamp();
            let fee_bps = SettlementEngine::calculate_early_exit_fee_bps(
                swap.start_time, swap.expiration_time, current_time,
                market.params.max_early_exit_fee_bps, market.params.min_early_exit_fee_bps,
            );
            let early_exit_fee = (swap.buyer_collateral * fee_bps) / 10000;
            let early_exit_payout = if swap_analytics.current_pnl.is_negative {
                let loss = if swap_analytics.current_pnl.value > swap.buyer_collateral {
                    swap.buyer_collateral
                } else {
                    swap_analytics.current_pnl.value
                };
                if swap.buyer_collateral > loss + early_exit_fee {
                    swap.buyer_collateral - loss - early_exit_fee
                } else {
                    0
                }
            } else {
                swap.buyer_collateral + swap_analytics.current_pnl.value - early_exit_fee
            };

            // Calculate market utilization
            let market_utilization_bps = if pool_analytics.total_value > 0 {
                ((pool_analytics.total_value - pool_analytics.available_liquidity) * 10000)
                    / pool_analytics.total_value
            } else {
                0
            };

            SwapDetailData {
                swap_id,
                pair_id: swap.pair_id,
                owner,
                side: swap.side,
                status: swap.status,
                notional: swap.notional,
                collateral: swap.buyer_collateral,
                leverage_x100: swap_analytics.leverage_x100,
                fixed_rate_bps: swap.fixed_rate_bps,
                current_floating_rate_bps: swap_analytics.current_floating_rate_bps,
                spread_bps: swap_analytics.current_spread_bps,
                current_pnl: swap_analytics.current_pnl,
                projected_pnl_at_expiry: swap_analytics.projected_pnl_at_expiry,
                breakeven_rate_bps: breakeven_rate,
                health_factor_bps: health_status.health_factor_bps,
                required_margin: health_status.required_margin,
                start_time: swap.start_time,
                expiration_time: swap.expiration_time,
                elapsed_seconds: swap_analytics.elapsed_seconds,
                remaining_seconds: swap_analytics.remaining_seconds,
                progress_bps: swap_analytics.progress_bps,
                early_exit_fee,
                early_exit_payout,
                market_utilization_bps,
                market_tvl: pool_analytics.total_value,
            }
        }

        /// Get scenario analysis for a swap with custom rate points
        fn get_swap_scenarios(
            self: @ContractState, swap_id: u256, rate_scenarios_bps: Span<u256>,
        ) -> SwapScenarioAnalysis {
            let asce_swap = self._get_dispatcher();

            let swap = asce_swap.get_swap(swap_id);
            let swap_analytics = asce_swap.get_swap_analytics(swap_id);
            let breakeven_rate = asce_swap.get_breakeven_rate(swap_id);

            // Get scenarios from main contract
            let scenarios = asce_swap.preview_swap_scenarios(swap_id, rate_scenarios_bps);

            // Enhance with additional calculations
            let mut detailed_scenarios: Array<DetailedScenario> = array![];

            let mut i: u32 = 0;
            let len = scenarios.len();
            while i < len {
                let scenario = *scenarios.at(i);

                // Calculate payout
                let payout = if scenario.pnl.is_negative {
                    if scenario.pnl.value >= swap.buyer_collateral {
                        0
                    } else {
                        swap.buyer_collateral - scenario.pnl.value
                    }
                } else {
                    swap.buyer_collateral + scenario.pnl.value
                };

                // Calculate return percentage (ROI)
                let return_percentage_bps = if swap.buyer_collateral > 0 {
                    if scenario.pnl.is_negative {
                        SignedValue {
                            value: (scenario.pnl.value * 10000) / swap.buyer_collateral,
                            is_negative: true,
                        }
                    } else {
                        SignedValue {
                            value: (scenario.pnl.value * 10000) / swap.buyer_collateral,
                            is_negative: false,
                        }
                    }
                } else {
                    SignedValue { value: 0, is_negative: false }
                };

                detailed_scenarios
                    .append(
                        DetailedScenario {
                            rate_bps: scenario.rate_bps,
                            pnl: scenario.pnl,
                            payout,
                            return_percentage_bps,
                        },
                    );

                i += 1;
            }

            SwapScenarioAnalysis {
                swap_id,
                current_rate_bps: swap_analytics.current_floating_rate_bps,
                fixed_rate_bps: swap.fixed_rate_bps,
                breakeven_rate_bps: breakeven_rate,
                scenarios: detailed_scenarios.span(),
            }
        }

        /// Get protocol-wide statistics
        fn get_protocol_stats(
            self: @ContractState, market_pair_ids: Span<felt252>,
        ) -> (u256, u256, u32, u32) {
            let asce_swap = self._get_dispatcher();

            let mut total_tvl: u256 = 0;
            let mut total_volume: u256 = 0; // Approximated by total swaps created * avg notional
            let mut active_markets: u32 = 0;
            let mut active_swaps: u32 = 0;

            let mut i: u32 = 0;
            let len = market_pair_ids.len();
            while i < len {
                let pair_id = *market_pair_ids.at(i);
                let market = asce_swap.get_market(pair_id);
                let pool_analytics = asce_swap.get_pool_analytics(pair_id);

                total_tvl += pool_analytics.total_value;

                if market.status == MarketStatus::Active {
                    active_markets += 1;
                }

                // Convert u256 to u32 safely for active swaps count
                if market.active_swap_count < 0xFFFFFFFF_u256 {
                    let count: u32 = market.active_swap_count.try_into().unwrap();
                    active_swaps += count;
                }

                i += 1;
            }

            (total_tvl, total_volume, active_markets, active_swaps)
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _get_dispatcher(self: @ContractState) -> IAsceSwapDispatcher {
            IAsceSwapDispatcher { contract_address: self.asce_swap_contract.read() }
        }

        fn _get_erc6909_dispatcher(self: @ContractState) -> IERC6909Dispatcher {
            IERC6909Dispatcher { contract_address: self.asce_swap_contract.read() }
        }
    }
}
