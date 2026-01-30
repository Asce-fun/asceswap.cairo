pub mod Helper {
    use asceswap_cairo::types::asce_swap::MarketParams;
    use starknet::{ContractAddress, contract_address_const};


    pub fn admin() -> ContractAddress {
        contract_address_const::<'admin'>()
    }

    pub fn user1() -> ContractAddress {
        contract_address_const::<'user1'>()
    }

    pub fn user2() -> ContractAddress {
        contract_address_const::<'user2'>()
    }

    pub fn lp1() -> ContractAddress {
        contract_address_const::<'lp1'>()
    }

    pub fn treasury() -> ContractAddress {
        contract_address_const::<'treasury'>()
    }

    pub fn curator() -> ContractAddress {
        contract_address_const::<'curator'>()
    }

    pub fn default_market_params() -> MarketParams {
        MarketParams {
            liquidation_threshold_bps: 8000,
            initial_margin_multiplier_bps: 12000,
            min_margin_floor_bps: 2000,
            swap_term_seconds: 2592000,
            min_hold_period_seconds: 3600,
            swap_fee_bps: 50,
            early_exit_fee_bps: 100,
            liquidation_bonus_bps: 500,
            fee_spread_bps: 25,
            max_imbalance_adjustment_bps: 200,
            max_utilization_bps: 8000,
            min_notional: 1000000,
            max_notional_per_swap: 1000000000000,
            max_oracle_staleness_seconds: 3600,
            max_rate_change_per_update_bps: 1000,
            min_rate_bps: 0,
            max_rate_bps: 100000,
            is_lp_permissioned: false,
        }
    }
}
