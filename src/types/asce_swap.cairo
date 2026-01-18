use starknet::{ContractAddress, contract_address_const};
#[derive(Drop, Copy, Serde, starknet::Store, PartialEq, Debug)]
pub enum RateType {
    #[default]
    Fixed,
    Variable,
}

#[derive(Drop, Copy, Serde, starknet::Store, PartialEq, Debug)]
pub enum LiquidationSide {
    #[default]
    Buyer,
    LP,
}

#[derive(Drop, Copy, Serde, starknet::Store, PartialEq, Debug)]
pub enum MarketStatus {
    Active,
    Paused,
    #[default]
    Closed,
}

///Signed Value Representation for PnL calculations
#[derive(Drop, Copy, Serde, starknet::Store, PartialEq, Debug)]
pub struct SignedValue {
    pub value: u256,
    pub is_negative: bool,
}


/// Market parameters set at creation time
#[derive(Drop, Copy, Serde, Debug, starknet::Store)]
pub struct MarketParams {
    pub collateral_price_oracle: ContractAddress,
    pub reference_rate_oracle: ContractAddress,
    pub swap_token: ContractAddress,
    pub liquidation_threshold: u16, // bps (e.g., 8500 = 85%)
    pub swap_terms: u64, // in seconds
    pub fee_spread: u16, // bps 
    pub min_util_fee: u16, // bps
    pub max_util_fee: u16, // bps
    pub max_rate_adjustment: u16, // bps
    pub early_exit_fee: u16, // bps
    pub liquidation_incentive: u16, // bps
    pub max_oracle_staleness: u64, // in seconds
    pub min_notional: u256 //// minimum notional in token units
}


///Market State and Accounting Info
#[derive(Drop, Copy, Serde, Debug, starknet::Store)]
pub struct Market {
    pub status: MarketStatus,
    pub paused: bool,
    pub rate_type: RateType,
    pub paired_market_id: u256, // the market id of the paired market (fixed/float)
    pub params: MarketParams,
    pub total_lp_collateral: u256, // total collateral supplied by LPs
    pub total_lp_shares: u256, // total shares issued to LPs
    pub locked_lp_collateral: u256 // collateral locked in open swaps
}

//Individual Swap Info
#[derive(Drop, Copy, Serde, Debug, starknet::Store)]
pub struct Swap {
    pub market_id: u256,
    pub notional_amount: u256,
    pub fixed_rate: u256,
    pub buyer_collateral: u256, // token amount
    pub lp_collateral: u256, // token amount
    pub required_collateral_usd: u256, // USD value at creation (18 decimals)
    pub start_time: u64,
    pub expiration_time: u64,
    pub start_cumulative_rate_time: u256,
    pub is_settled: bool,
    pub is_liquidated: bool,
}


/// Rate index for TWA calculation
#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct RateIndex {
    pub last_update_time: u64,
    pub last_rate: u256, // bps
    pub cumulative_rate_time: u256 // Σ(rate × Δtime)
}

/// LP position in a market
#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct LpPosition {
    pub shares: u256,
}


/// Protocol fee configuration
#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct ProtocolFees {
    pub market_creation_fee: u256, // flat amount in native token
    pub swap_fee_bps: u16, // % of collateral
    pub early_exit_fee_bps: u16, // % of collateral
    pub liquidation_reward_bps: u16, // % of seized collateral
    pub protocol_share_bps: u16 // % of fees to treasury
}


/// Market liquidity info
#[derive(Drop, Copy, Serde)]
pub struct MarketLiquidity {
    pub total_collateral: u256,
    pub available_collateral: u256,
    pub utilization_bps: u256,
}

/// Default implementations
pub impl DefaultMarket of Default<Market> {
    fn default() -> Market {
        Market {
            status: MarketStatus::Closed,
            paused: false,
            rate_type: RateType::Fixed,
            paired_market_id: 0,
            params: Default::default(),
            total_lp_collateral: 0,
            locked_lp_collateral: 0,
            total_lp_shares: 0,
        }
    }
}


pub impl DefaultMarketParams of Default<MarketParams> {
    fn default() -> MarketParams {
        MarketParams {
            collateral_price_oracle: contract_address_const::<0>(),
            reference_rate_oracle: contract_address_const::<0>(),
            swap_token: contract_address_const::<0>(),
            liquidation_threshold: 0,
            swap_terms: 0,
            fee_spread: 0,
            min_util_fee: 0,
            max_util_fee: 0,
            max_rate_adjustment: 0,
            early_exit_fee: 0,
            liquidation_incentive: 0,
            max_oracle_staleness: 0,
            min_notional: 0,
        }
    }
}

pub impl DefaultSwap of Default<Swap> {
    fn default() -> Swap {
        Swap {
            market_id: 0,
            notional_amount: 0,
            fixed_rate: 0,
            buyer_collateral: 0,
            lp_collateral: 0,
            required_collateral_usd: 0,
            start_time: 0,
            expiration_time: 0,
            start_cumulative_rate_time: 0,
            is_settled: false,
            is_liquidated: false,
        }
    }
}

pub impl DefaultRateIndex of Default<RateIndex> {
    fn default() -> RateIndex {
        RateIndex { last_update_time: 0, last_rate: 0, cumulative_rate_time: 0 }
    }
}

pub impl DefaultLpPosition of Default<LpPosition> {
    fn default() -> LpPosition {
        LpPosition { shares: 0 }
    }
}

pub impl DefaultProtocolFees of Default<ProtocolFees> {
    fn default() -> ProtocolFees {
        ProtocolFees {
            market_creation_fee: 0,
            swap_fee_bps: 0,
            early_exit_fee_bps: 0,
            liquidation_reward_bps: 0,
            protocol_share_bps: 0,
        }
    }
}

pub impl DefaultSignedValue of Default<SignedValue> {
    fn default() -> SignedValue {
        SignedValue { value: 0, is_negative: false }
    }
}

