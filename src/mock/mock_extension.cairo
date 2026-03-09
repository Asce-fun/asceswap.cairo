#[starknet::interface]
pub trait IMockExtension<TContractState> {
    fn get_before_market_creation_count(self: @TContractState) -> u32;
    fn get_after_market_creation_count(self: @TContractState) -> u32;
    fn get_before_swap_open_count(self: @TContractState) -> u32;
    fn get_after_swap_open_count(self: @TContractState) -> u32;
    fn get_before_swap_close_count(self: @TContractState) -> u32;
    fn get_after_swap_close_count(self: @TContractState) -> u32;
    fn get_before_add_liquidity_count(self: @TContractState) -> u32;
    fn get_after_add_liquidity_count(self: @TContractState) -> u32;
    fn get_before_remove_liquidity_count(self: @TContractState) -> u32;
    fn get_after_remove_liquidity_count(self: @TContractState) -> u32;
    fn get_last_pair_id(self: @TContractState) -> felt252;
    fn get_last_swap_id(self: @TContractState) -> u256;
    fn set_should_revert(ref self: TContractState, hook_name: felt252, should_revert: bool);
}

#[starknet::contract]
pub mod MockExtension {
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::ContractAddress;
    use crate::interfaces::extension::IExtension;
    use crate::interfaces::asce_swap::{IAsceSwapDispatcher, IAsceSwapDispatcherTrait};
    use crate::types::extension::{
        CallPoints, MarketCreationParams, SwapOpenParams, LiquidityParams,
    };
    use crate::types::asce_swap::{SettlementType, SettlementResult};

    #[storage]
    struct Storage {
        core: ContractAddress,
        before_market_creation_count: u32,
        after_market_creation_count: u32,
        before_swap_open_count: u32,
        after_swap_open_count: u32,
        before_swap_close_count: u32,
        after_swap_close_count: u32,
        before_add_liquidity_count: u32,
        after_add_liquidity_count: u32,
        before_remove_liquidity_count: u32,
        after_remove_liquidity_count: u32,
        last_pair_id: felt252,
        last_swap_id: u256,
        should_revert: Map<felt252, bool>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, core: ContractAddress, call_points: CallPoints) {
        self.core.write(core);
        IAsceSwapDispatcher { contract_address: core }.set_call_points(call_points);
    }

    #[abi(embed_v0)]
    impl MockExtensionImpl of super::IMockExtension<ContractState> {
        fn get_before_market_creation_count(self: @ContractState) -> u32 {
            self.before_market_creation_count.read()
        }
        fn get_after_market_creation_count(self: @ContractState) -> u32 {
            self.after_market_creation_count.read()
        }
        fn get_before_swap_open_count(self: @ContractState) -> u32 {
            self.before_swap_open_count.read()
        }
        fn get_after_swap_open_count(self: @ContractState) -> u32 {
            self.after_swap_open_count.read()
        }
        fn get_before_swap_close_count(self: @ContractState) -> u32 {
            self.before_swap_close_count.read()
        }
        fn get_after_swap_close_count(self: @ContractState) -> u32 {
            self.after_swap_close_count.read()
        }
        fn get_before_add_liquidity_count(self: @ContractState) -> u32 {
            self.before_add_liquidity_count.read()
        }
        fn get_after_add_liquidity_count(self: @ContractState) -> u32 {
            self.after_add_liquidity_count.read()
        }
        fn get_before_remove_liquidity_count(self: @ContractState) -> u32 {
            self.before_remove_liquidity_count.read()
        }
        fn get_after_remove_liquidity_count(self: @ContractState) -> u32 {
            self.after_remove_liquidity_count.read()
        }
        fn get_last_pair_id(self: @ContractState) -> felt252 {
            self.last_pair_id.read()
        }
        fn get_last_swap_id(self: @ContractState) -> u256 {
            self.last_swap_id.read()
        }
        fn set_should_revert(ref self: ContractState, hook_name: felt252, should_revert: bool) {
            self.should_revert.write(hook_name, should_revert);
        }
    }

    #[abi(embed_v0)]
    impl ExtensionImpl of IExtension<ContractState> {
        fn before_market_creation(
            ref self: ContractState,
            caller: ContractAddress,
            creation_params: MarketCreationParams,
        ) {
            assert(!self.should_revert.read('before_market_creation'), 'MOCK_REVERT');
            self
                .before_market_creation_count
                .write(self.before_market_creation_count.read() + 1);
        }

        fn after_market_creation(
            ref self: ContractState,
            caller: ContractAddress,
            pair_id: felt252,
            creation_params: MarketCreationParams,
            shares_minted: u256,
        ) {
            assert(!self.should_revert.read('after_market_creation'), 'MOCK_REVERT');
            self
                .after_market_creation_count
                .write(self.after_market_creation_count.read() + 1);
            self.last_pair_id.write(pair_id);
        }

        fn before_swap_open(
            ref self: ContractState,
            caller: ContractAddress,
            pair_id: felt252,
            params: SwapOpenParams,
        ) {
            assert(!self.should_revert.read('before_swap_open'), 'MOCK_REVERT');
            self.before_swap_open_count.write(self.before_swap_open_count.read() + 1);
        }

        fn after_swap_open(
            ref self: ContractState,
            caller: ContractAddress,
            pair_id: felt252,
            params: SwapOpenParams,
            swap_id: u256,
        ) {
            assert(!self.should_revert.read('after_swap_open'), 'MOCK_REVERT');
            self.after_swap_open_count.write(self.after_swap_open_count.read() + 1);
            self.last_swap_id.write(swap_id);
        }

        fn before_swap_close(
            ref self: ContractState,
            caller: ContractAddress,
            pair_id: felt252,
            swap_id: u256,
            settlement_type: SettlementType,
        ) {
            assert(!self.should_revert.read('before_swap_close'), 'MOCK_REVERT');
            self.before_swap_close_count.write(self.before_swap_close_count.read() + 1);
        }

        fn after_swap_close(
            ref self: ContractState,
            caller: ContractAddress,
            pair_id: felt252,
            swap_id: u256,
            settlement_type: SettlementType,
            settlement_result: SettlementResult,
        ) {
            assert(!self.should_revert.read('after_swap_close'), 'MOCK_REVERT');
            self.after_swap_close_count.write(self.after_swap_close_count.read() + 1);
        }

        fn before_add_liquidity(
            ref self: ContractState,
            caller: ContractAddress,
            pair_id: felt252,
            params: LiquidityParams,
        ) {
            assert(!self.should_revert.read('before_add_liquidity'), 'MOCK_REVERT');
            self.before_add_liquidity_count.write(self.before_add_liquidity_count.read() + 1);
        }

        fn after_add_liquidity(
            ref self: ContractState,
            caller: ContractAddress,
            pair_id: felt252,
            params: LiquidityParams,
        ) {
            assert(!self.should_revert.read('after_add_liquidity'), 'MOCK_REVERT');
            self.after_add_liquidity_count.write(self.after_add_liquidity_count.read() + 1);
        }

        fn before_remove_liquidity(
            ref self: ContractState,
            caller: ContractAddress,
            pair_id: felt252,
            params: LiquidityParams,
        ) {
            assert(!self.should_revert.read('before_remove_liquidity'), 'MOCK_REVERT');
            self
                .before_remove_liquidity_count
                .write(self.before_remove_liquidity_count.read() + 1);
        }

        fn after_remove_liquidity(
            ref self: ContractState,
            caller: ContractAddress,
            pair_id: felt252,
            params: LiquidityParams,
        ) {
            assert(!self.should_revert.read('after_remove_liquidity'), 'MOCK_REVERT');
            self
                .after_remove_liquidity_count
                .write(self.after_remove_liquidity_count.read() + 1);
        }
    }
}
