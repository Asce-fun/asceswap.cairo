#[derive(Drop, Copy, Serde, starknet::Store, PartialEq)]
pub enum RateType{
    #[default]
    pub Fixed,
    pub Variable,
}

#[derive(Drop,Copy,Serde,starknet::Store)]
pub struct MarketParams{
    pub reference_rate_oracle:ContractAddress,
    pub swap_token:ContractAddress,
    pub liquidation_threshold:u16,
    pub swap_term:u64,
    pub fee_spread:u16,
    pub min_util_fee:u16,
    pub max_util_fee:u16,
    pub max_rate_adjustment:u16,
    pub early_exit_fee:u16,
    pub liquidation_incentive:u16,
}

#[derive(Drop,Copy,Serde,starknet::Store)]
pub struct Market{
    pub is_active:bool,
    pub paused:bool,
    pub rate_type:RateType,
    pub paired_market_id:u256,
    pub params:MarketParams,
    pub total_lp_collateral:u256,
    pub locked_lp_collateral:u256,
    pub total_lp_shares:u256,

}

#[derive(Drop,Copy,Serde,starknet::Store)]
pub struct Swap{
    pub market_id:u256,
    pub notional_amount:u256,
    pub fixer_rate:u256,
    pub buyer_collateral:u256,
    pub lp_collateral:u256,
    pub start_time:u64,
    pub expiration_time:u64,
    pub start_cumulative_rate_time:u256,
    pub is_settled:bool,
    pub is_liquidated:bool,
}


#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct RateIndex{
    pub last_updated_time:u64,
    pub last_rate:u256,
    pub cumulative_rate_time:u256,
}


#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct LpPosition {
    pub shares: u256,
}

#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct ActiveSwapsCounter {
    pub count: u256,
}