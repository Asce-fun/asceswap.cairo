#[starknet::component]
pub mod MarketManagerComponent {
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp};
    use crate::helpers::constants::Constants;
    use crate::helpers::errors::Errors;
    use crate::helpers::fixed_point::mul_div_up;
    use crate::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use crate::interfaces::rate_oracle::{IOracleAdapterDispatcher, IOracleAdapterDispatcherTrait};
    use crate::types::asce_swap::{LpPool, MarketPair, MarketParams, MarketStatus, RateIndex};

    #[storage]
    pub struct Storage {
        markets: Map<felt252, MarketPair>,
        next_pair_id: felt252,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        MarketPairCreated: MarketPairCreated,
        MarketPaused: MarketPaused,
        MarketUnpaused: MarketUnpaused,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MarketPairCreated {
        #[key]
        pub pair_id: felt252,
        pub rate_oracle: ContractAddress,
        pub collateral_token: ContractAddress,
        pub curator: ContractAddress,
        pub min_swap_term_seconds: u64,
        pub max_swap_term_seconds: u64,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MarketPaused {
        #[key]
        pub pair_id: felt252,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MarketUnpaused {
        #[key]
        pub pair_id: felt252,
        pub timestamp: u64,
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>, +Drop<TContractState>,
    > of InternalTrait<TContractState> {
        /// Initialize the market manager
        fn initializer(ref self: ComponentState<TContractState>) {
            self.next_pair_id.write(1);
        }

        /// Create a new market pair
        fn _create_market_pair(
            ref self: ComponentState<TContractState>,
            rate_oracle: ContractAddress,
            collateral_token: ContractAddress,
            curator: ContractAddress,
            params: MarketParams,
        ) -> felt252 {
            self._validate_market_params(@params);

            // Get oracle rate
            let (initial_rate, rate_timestamp) = self._get_oracle_rate(rate_oracle);
            let current_time = get_block_timestamp();
            assert(current_time >= rate_timestamp, Errors::ORACLE_INVALID_RATE);

            assert(
                current_time - rate_timestamp <= params.max_oracle_staleness_seconds,
                Errors::ORACLE_STALE,
            );
            assert(initial_rate > 0, Errors::ORACLE_INVALID_RATE);

            /// Get token decimals
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

            self.markets.write(pair_id, market);
            self
                .emit(
                    MarketPairCreated {
                        pair_id,
                        rate_oracle,
                        collateral_token,
                        curator,
                        min_swap_term_seconds: params.min_swap_term_seconds,
                        max_swap_term_seconds: params.max_swap_term_seconds,
                        timestamp: current_time,
                    },
                );

            pair_id
        }

        /// Pause a market
        fn _pause_market(ref self: ComponentState<TContractState>, pair_id: felt252) {
            let mut market = self.markets.read(pair_id);
            assert(market.status == MarketStatus::Active, Errors::MARKET_NOT_ACTIVE);
            market.status = MarketStatus::Paused;
            self.markets.write(pair_id, market);
            self.emit(MarketPaused { pair_id, timestamp: get_block_timestamp() });
        }

        /// Unpause a market
        fn _unpause_market(ref self: ComponentState<TContractState>, pair_id: felt252) {
            let mut market = self.markets.read(pair_id);
            assert(market.status == MarketStatus::Paused, Errors::MARKET_NOT_PAUSED);
            market.status = MarketStatus::Active;
            self.markets.write(pair_id, market);
            self.emit(MarketUnpaused { pair_id, timestamp: get_block_timestamp() });
        }

        /// Get a market by pair_id
        fn _get_market(self: @ComponentState<TContractState>, pair_id: felt252) -> MarketPair {
            self.markets.read(pair_id)
        }

        /// Update market state (called by other components)
        fn _write_market(
            ref self: ComponentState<TContractState>, pair_id: felt252, market: MarketPair,
        ) {
            self.markets.write(pair_id, market);
        }


        /// Validate market parameters
        fn _validate_market_params(self: @ComponentState<TContractState>, params: @MarketParams) {
            // liquidation_threshold_bps
            assert(
                *params.liquidation_threshold_bps >= Constants::MIN_LIQUIDATION_THRESHOLD_BPS
                    && *params
                        .liquidation_threshold_bps <= Constants::MAX_LIQUIDATION_THRESHOLD_BPS,
                Errors::INVALID_PARAMS,
            );

            //initial_margin_multiplier_bps
            assert(
                *params.initial_margin_multiplier_bps >= Constants::MIN_MARGIN_MULTIPLIER_BPS
                    && *params
                        .initial_margin_multiplier_bps <= Constants::MAX_MARGIN_MULTIPLIER_BPS,
                Errors::INVALID_PARAMS,
            );

            // min_margin_floor_bps — lower + upper bound
            assert(
                *params.min_margin_floor_bps >= Constants::MIN_MARGIN_FLOOR_BPS
                    && *params.min_margin_floor_bps <= Constants::BPS,
                Errors::INVALID_PARAMS,
            );

            // min_swap_term_seconds — floor prevents flash swap attacks
            assert(
                *params.min_swap_term_seconds >= Constants::MIN_SWAP_TERM_SECONDS,
                Errors::INVALID_PARAMS,
            );

            // min <= max swap term (cross-field)
            assert(
                *params.min_swap_term_seconds <= *params.max_swap_term_seconds,
                Errors::INVALID_PARAMS,
            );

            // 7. min_hold_period_seconds — must be > 0 and <= min_swap_term
            assert(
                *params.min_hold_period_seconds > 0
                    && *params.min_hold_period_seconds <= *params.min_swap_term_seconds,
                Errors::INVALID_PARAMS,
            );

            //swap_fee_bps
            assert(*params.swap_fee_bps <= Constants::MAX_FEE_BPS, Errors::INVALID_PARAMS);

            //early_exit_fee_bps
            assert(*params.early_exit_fee_bps <= Constants::MAX_FEE_BPS, Errors::INVALID_PARAMS);

            //liquidation_bonus_bps
            assert(*params.liquidation_bonus_bps <= Constants::MAX_FEE_BPS, Errors::INVALID_PARAMS);

            // base_fee_spread_bps — reasonable base spread
            assert(*params.base_fee_spread_bps <= Constants::MAX_FEE_BPS, Errors::INVALID_PARAMS);

            //demand_spread_factor — within protocol bounds
            assert(
                *params.demand_spread_factor >= Constants::MIN_DEMAND_SPREAD_FACTOR
                    && *params.demand_spread_factor <= Constants::MAX_DEMAND_SPREAD_FACTOR,
                Errors::INVALID_PARAMS,
            );

            // max_total_utilization_bps — hard ceiling
            assert(
                *params.max_total_utilization_bps > 0
                    && *params
                        .max_total_utilization_bps <= Constants::MAX_TOTAL_UTILIZATION_CAP_BPS,
                Errors::INVALID_PARAMS,
            );

            // min_notional_per_swap
            assert(*params.min_notional_per_swap > 0, Errors::INVALID_PARAMS);

            //max_oracle_staleness_seconds
            assert(
                *params.max_oracle_staleness_seconds >= Constants::MIN_ORACLE_STALENESS_SECONDS,
                Errors::INVALID_PARAMS,
            );

            //max_rate_change_per_update_bps — must be > 0 and <= 100%
            assert(
                *params.max_rate_change_per_update_bps > 0
                    && *params.max_rate_change_per_update_bps <= Constants::BPS,
                Errors::INVALID_PARAMS,
            );
        }

        /// Get oracle rate
        fn _get_oracle_rate(
            self: @ComponentState<TContractState>, oracle: ContractAddress,
        ) -> (u256, u64) {
            let oracle_adapter = IOracleAdapterDispatcher { contract_address: oracle };
            oracle_adapter.get_rate()
        }

        /// Update rate index with latest oracle value
        fn _update_rate_index(
            ref self: ComponentState<TContractState>, ref market: MarketPair, current_time: u64,
        ) -> u256 {
            let (raw_rate, rate_timestamp) = self._get_oracle_rate(market.rate_oracle);
            assert(current_time >= rate_timestamp, Errors::ORACLE_INVALID_RATE);
            // Check staleness
            assert(
                current_time - rate_timestamp <= market.params.max_oracle_staleness_seconds,
                Errors::ORACLE_STALE,
            );

            let mut rate_index = market.rate_index;

            // If first update, just initialize(although this condition should never trigger , since
            // we are already intializing at market creation)
            // if rate_index.last_update_time == 0 {
            //     rate_index.last_update_time = current_time;
            //     rate_index.last_rate_bps = raw_rate;
            //     rate_index.cumulative_rate_time = 0;
            //     rate_index.last_valid_rate_bps = raw_rate;
            //     market.rate_index = rate_index;
            //     return raw_rate;
            // }

            let time_delta: u256 = (current_time - rate_index.last_update_time).into();

            // No time passed, return current rate
            if time_delta == 0 {
                return rate_index.last_rate_bps;
            }

            // Accumulate: previous_rate * time_elapsed
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

            clamped_rate
        }
    }
}
