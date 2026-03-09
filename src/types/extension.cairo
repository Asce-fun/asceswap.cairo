use starknet::ContractAddress;
use crate::types::asce_swap::{MarketParams, SwapSide};

#[derive(Copy, Drop, Serde, starknet::Store, Default, PartialEq)]
pub struct CallPoints {
    pub before_market_creation: bool,
    pub after_market_creation: bool,
    pub before_swap_open: bool,
    pub after_swap_open: bool,
    pub before_swap_close: bool,
    pub after_swap_close: bool,
    pub before_add_liquidity: bool,
    pub after_add_liquidity: bool,
    pub before_remove_liquidity: bool,
    pub after_remove_liquidity: bool,
}

#[derive(Copy, Drop, Serde)]
pub struct MarketCreationParams {
    pub rate_oracle: ContractAddress,
    pub collateral_token: ContractAddress,
    pub curator: ContractAddress,
    pub params: MarketParams,
    pub initial_liquidity: u256,
}

#[derive(Copy, Drop, Serde)]
pub struct SwapOpenParams {
    pub side: SwapSide,
    pub notional: u256,
    pub collateral: u256,
    pub max_rate_bps: u256,
    pub swap_term: u64,
    pub receiver: ContractAddress,
}

#[derive(Copy, Drop, Serde)]
pub struct LiquidityParams {
    pub assets: u256,
    pub shares: u256,
    pub receiver: ContractAddress,
}
