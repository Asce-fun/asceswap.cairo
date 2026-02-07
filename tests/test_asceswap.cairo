use asceswap_cairo::helpers::constants::Constants;
use asceswap_cairo::interfaces::asce_swap::{IAsceSwapDispatcher, IAsceSwapDispatcherTrait};
use asceswap_cairo::types::asce_swap::{MarketStatus, SwapSide, SwapStatus};
use core::num::traits::Zero;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
    start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use super::helpers::erc20::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};
use super::helpers::helper::Helper;
use super::helpers::oracle::{IMockOracleDispatcher, IMockOracleDispatcherTrait};

#[test]
fn test_deploy_access_registry() {
    let address = _deploy_access_registry();
    assert(address.is_non_zero(), 'deployed');
}

#[test]
fn test_deploy_asceswap() {
    // Deploy access registry first
    let access_address = _deploy_access_registry();

    // Deploy main contract
    let asceswap_address = _deploy_asceswap(access_address);

    let asceswap = IAsceSwapDispatcher { contract_address: asceswap_address };

    // Verify initial state
    let config = asceswap.get_protocol_config();
    assert(config.treasury == Helper::treasury(), 'treasury set');
    assert(config.protocol_fee_share_bps == 2000, 'fee share 20%');
    assert(asceswap.get_next_swap_id() == 1, 'swap id 1');
}

#[test]
fn test_create_market() {
    let (asceswap, erc20, oracle) = setup_contracts();
    let initial_liquidity: u256 = 100000000; // 100 USDC

    // Admin approves collateral for initial liquidity
    start_cheat_caller_address(erc20.contract_address, Helper::admin());
    erc20.approve(asceswap.contract_address, initial_liquidity);
    stop_cheat_caller_address(erc20.contract_address);

    start_cheat_caller_address(asceswap.contract_address, Helper::admin());
    let (pair_id, shares) = asceswap
        .create_market_pair(
            oracle.contract_address,
            erc20.contract_address,
            Helper::curator(),
            Helper::default_market_params(),
            initial_liquidity,
        );
    stop_cheat_caller_address(asceswap.contract_address);

    assert(pair_id == 1, 'first market');
    let config = asceswap.get_protocol_config();
    let expected_shares = initial_liquidity - config.burned_shares_amount;
    assert(shares == expected_shares, 'shares minted');

    let market = asceswap.get_market(pair_id);
    assert(market.status == MarketStatus::Active, 'active');
    assert(market.rate_oracle == oracle.contract_address, 'oracle set');
    assert(market.pool.total_collateral == initial_liquidity, 'pool has liquidity');
}

#[test]
fn test_pause_unpause_market() {
    let (asceswap, erc20, oracle) = setup_contracts();
    let initial_liquidity: u256 = 100000000;

    // Admin approves collateral for initial liquidity
    start_cheat_caller_address(erc20.contract_address, Helper::admin());
    erc20.approve(asceswap.contract_address, initial_liquidity);
    stop_cheat_caller_address(erc20.contract_address);

    // Create market
    start_cheat_caller_address(asceswap.contract_address, Helper::admin());
    let (pair_id, _) = asceswap
        .create_market_pair(
            oracle.contract_address,
            erc20.contract_address,
            Helper::curator(),
            Helper::default_market_params(),
            initial_liquidity,
        );

    // Pause
    asceswap.pause_market(pair_id);
    let market = asceswap.get_market(pair_id);
    assert(market.status == MarketStatus::Paused, 'paused');

    // Unpause
    asceswap.unpause_market(pair_id);
    let market = asceswap.get_market(pair_id);
    assert(market.status == MarketStatus::Active, 'active');

    stop_cheat_caller_address(asceswap.contract_address);
}


#[test]
fn test_lp_deposit() {
    let (asceswap, erc20, oracle) = setup_contracts();
    let initial_liquidity: u256 = 100000000; // 100 USDC

    // Admin approves collateral for initial liquidity
    start_cheat_caller_address(erc20.contract_address, Helper::admin());
    erc20.approve(asceswap.contract_address, initial_liquidity);
    stop_cheat_caller_address(erc20.contract_address);

    // Create market with initial liquidity
    start_cheat_caller_address(asceswap.contract_address, Helper::admin());
    let (pair_id, _) = asceswap
        .create_market_pair(
            oracle.contract_address,
            erc20.contract_address,
            Helper::curator(),
            Helper::default_market_params(),
            initial_liquidity,
        );
    stop_cheat_caller_address(asceswap.contract_address);

    // LP approves and deposits (second deposit — proportional shares)
    let deposit: u256 = 100000000; // 100 USDC

    start_cheat_caller_address(erc20.contract_address, Helper::lp1());
    erc20.approve(asceswap.contract_address, deposit);
    stop_cheat_caller_address(erc20.contract_address);

    start_cheat_caller_address(asceswap.contract_address, Helper::lp1());
    let shares = asceswap.supply_lp_collateral(pair_id, deposit);
    stop_cheat_caller_address(asceswap.contract_address);

    // Second deposit: proportional shares (pool already has liquidity from creation)
    assert(shares > 0, 'shares minted');

    // Check position
    let position = asceswap.get_lp_position(Helper::lp1(), pair_id);
    assert(position.shares == shares, 'position updated');
}

#[test]
fn test_lp_withdraw_after_cooldown() {
    let (asceswap, erc20, oracle) = setup_contracts();
    let initial_liquidity: u256 = 100000000;

    // Admin approves collateral for initial liquidity
    start_cheat_caller_address(erc20.contract_address, Helper::admin());
    erc20.approve(asceswap.contract_address, initial_liquidity);
    stop_cheat_caller_address(erc20.contract_address);

    // Create market with initial liquidity
    start_cheat_caller_address(asceswap.contract_address, Helper::admin());
    let (pair_id, _) = asceswap
        .create_market_pair(
            oracle.contract_address,
            erc20.contract_address,
            Helper::curator(),
            Helper::default_market_params(),
            initial_liquidity,
        );
    stop_cheat_caller_address(asceswap.contract_address);

    // LP deposits
    let deposit: u256 = 100000000;

    start_cheat_caller_address(erc20.contract_address, Helper::lp1());
    erc20.approve(asceswap.contract_address, deposit);
    stop_cheat_caller_address(erc20.contract_address);

    start_cheat_caller_address(asceswap.contract_address, Helper::lp1());
    let shares = asceswap.supply_lp_collateral(pair_id, deposit);
    stop_cheat_caller_address(asceswap.contract_address);

    // Advance time past cooldown
    let initial_time: u64 = 1000000;
    let cooldown = Constants::MIN_LP_COOLDOWN_SECONDS;
    start_cheat_block_timestamp(asceswap.contract_address, initial_time + cooldown + 1);

    // Withdraw half
    let withdraw_shares = shares / 2;
    start_cheat_caller_address(asceswap.contract_address, Helper::lp1());
    let withdrawn = asceswap.withdraw_lp_collateral(pair_id, withdraw_shares);
    stop_cheat_caller_address(asceswap.contract_address);

    assert(withdrawn > 0, 'withdrawn amount');

    let position = asceswap.get_lp_position(Helper::lp1(), pair_id);
    assert(position.shares == shares - withdraw_shares, 'remaining');
}

fn setup_market_with_liquidity() -> (
    IAsceSwapDispatcher, IMockERC20Dispatcher, IMockOracleDispatcher, felt252,
) {
    let (asceswap, erc20, oracle) = setup_contracts();
    let initial_liquidity: u256 = 1000000000; // 1000 USDC

    // Admin approves collateral for initial liquidity
    start_cheat_caller_address(erc20.contract_address, Helper::admin());
    erc20.approve(asceswap.contract_address, initial_liquidity);
    stop_cheat_caller_address(erc20.contract_address);

    // Create market with initial liquidity in a single call
    start_cheat_caller_address(asceswap.contract_address, Helper::admin());
    let (pair_id, _) = asceswap
        .create_market_pair(
            oracle.contract_address,
            erc20.contract_address,
            Helper::curator(),
            Helper::default_market_params(),
            initial_liquidity,
        );
    stop_cheat_caller_address(asceswap.contract_address);

    (asceswap, erc20, oracle, pair_id)
}

#[test]
fn test_get_swap_quote() {
    let (asceswap, _, _, pair_id) = setup_market_with_liquidity();

    let quote = asceswap.get_swap_quote(pair_id, SwapSide::Fixed, 10000000);
    assert(quote.base_rate_bps > 0, 'has rate');
    assert(quote.required_collateral > 0, 'has collateral');
}

#[test]
fn test_buy_swap_fixed() {
    let (asceswap, erc20, _, pair_id) = setup_market_with_liquidity();

    let notional: u256 = 10000000;
    let collateral: u256 = 5000000;

    // User approves
    start_cheat_caller_address(erc20.contract_address, Helper::user1());
    erc20.approve(asceswap.contract_address, collateral);
    stop_cheat_caller_address(erc20.contract_address);

    // Buy swap
    start_cheat_caller_address(asceswap.contract_address, Helper::user1());
    let swap_id = asceswap.buy_swap(pair_id, SwapSide::Fixed, notional, collateral, 10000);
    stop_cheat_caller_address(asceswap.contract_address);

    assert(swap_id == 1, 'first swap');

    let swap = asceswap.get_swap(swap_id);
    assert(swap.status == SwapStatus::Active, 'active');
    assert(swap.side == SwapSide::Fixed, 'fixed side');
}

#[test]
fn test_settle_swap() {
    let (asceswap, erc20, oracle, pair_id) = setup_market_with_liquidity();

    let collateral: u256 = 5000000;

    start_cheat_caller_address(erc20.contract_address, Helper::user1());
    erc20.approve(asceswap.contract_address, collateral);
    stop_cheat_caller_address(erc20.contract_address);

    start_cheat_caller_address(asceswap.contract_address, Helper::user1());
    let swap_id = asceswap.buy_swap(pair_id, SwapSide::Fixed, 10000000, collateral, 10000);
    stop_cheat_caller_address(asceswap.contract_address);

    // Advance past expiry
    let swap = asceswap.get_swap(swap_id);
    let new_time = swap.expiration_time + 1;
    start_cheat_block_timestamp(asceswap.contract_address, new_time);

    // Update oracle timestamp to match (rate stays the same)
    oracle.set_rate(500, new_time);

    // Settle (must be called by swap owner)
    start_cheat_caller_address(asceswap.contract_address, Helper::user1());
    asceswap.settle_swap(swap_id);
    stop_cheat_caller_address(asceswap.contract_address);

    let settled = asceswap.get_swap(swap_id);
    assert(settled.status == SwapStatus::Settled, 'settled');
}

#[test]
fn test_get_health_status() {
    let (asceswap, erc20, _, pair_id) = setup_market_with_liquidity();

    let collateral: u256 = 5000000;

    start_cheat_caller_address(erc20.contract_address, Helper::user1());
    erc20.approve(asceswap.contract_address, collateral);
    stop_cheat_caller_address(erc20.contract_address);

    start_cheat_caller_address(asceswap.contract_address, Helper::user1());
    let swap_id = asceswap.buy_swap(pair_id, SwapSide::Fixed, 10000000, collateral, 10000);
    stop_cheat_caller_address(asceswap.contract_address);

    let health = asceswap.get_health_status(swap_id);
    assert(health.health_factor_bps > 0, 'has health');
    assert(health.is_liquidatable == false, 'not liquidatable');
}

#[test]
fn test_pool_analytics() {
    let (asceswap, _, _, pair_id) = setup_market_with_liquidity();

    let analytics = asceswap.get_pool_analytics(pair_id);
    assert(analytics.total_value > 0, 'has value');
    assert(analytics.available_liquidity > 0, 'has liquidity');
}

fn _deploy_access_registry() -> ContractAddress {
    let class = declare("AccessRegistry").unwrap().contract_class();
    let (address, _) = class.deploy(@array![Helper::admin().into()]).unwrap();
    address
}

fn _deploy_asceswap(access_registry: ContractAddress) -> ContractAddress {
    let asceswap_class = declare("Asceswap").unwrap().contract_class();
    let (asceswap_address, _) = asceswap_class
        .deploy(@array![access_registry.into(), Helper::treasury().into()])
        .unwrap();
    asceswap_address
}


fn setup_contracts() -> (IAsceSwapDispatcher, IMockERC20Dispatcher, IMockOracleDispatcher) {
    // Deploy access registry

    let access_address = _deploy_access_registry();

    // Deploy mock ERC20
    let erc20_class = declare("MockERC20").unwrap().contract_class();
    let (erc20_address, _) = erc20_class.deploy(@array![6]).unwrap();
    let erc20 = IMockERC20Dispatcher { contract_address: erc20_address };

    // Deploy mock oracle (5% rate = 500 bps)
    // u256 is serialized as (low, high) - two felt252 values
    let oracle_class = declare("MockOracle").unwrap().contract_class();
    let initial_time: u64 = 1000000;
    let rate_low: felt252 = 500;
    let rate_high: felt252 = 0;
    let (oracle_address, _) = oracle_class
        .deploy(@array![rate_low, rate_high, initial_time.into()])
        .unwrap();
    let oracle = IMockOracleDispatcher { contract_address: oracle_address };

    // Deploy main contract
    let asceswap_address = _deploy_asceswap(access_address);
    let asceswap = IAsceSwapDispatcher { contract_address: asceswap_address };

    // Set block timestamp
    start_cheat_block_timestamp(asceswap_address, initial_time);

    // Mint tokens to test users
    erc20
        .mint(
            Helper::admin(), 100000000000,
        ); // 100,000 USDC (for initial liquidity on market creation)
    erc20.mint(Helper::user1(), 10000000000); // 10,000 USDC
    erc20.mint(Helper::lp1(), 100000000000); // 100,000 USDC

    (asceswap, erc20, oracle)
}
