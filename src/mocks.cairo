// Mock contracts for deployment/testing on testnet or mainnet fork
use starknet::ContractAddress;

// ============== MockOracle ==============

#[starknet::interface]
pub trait IMockOracle<TContractState> {
    fn get_rate(self: @TContractState) -> (u256, u64);
    fn set_rate(ref self: TContractState, rate_bps: u256, timestamp: u64);
    fn set_stale(ref self: TContractState, is_stale: bool);
}

#[starknet::contract]
pub mod MockOracle {
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};

    #[storage]
    struct Storage {
        rate_bps: u256,
        timestamp: u64,
        is_stale: bool,
    }

    #[constructor]
    fn constructor(ref self: ContractState, initial_rate: u256, initial_timestamp: u64) {
        self.rate_bps.write(initial_rate);
        self.timestamp.write(initial_timestamp);
        self.is_stale.write(false);
    }

    #[abi(embed_v0)]
    impl MockOracleImpl of super::IMockOracle<ContractState> {
        fn get_rate(self: @ContractState) -> (u256, u64) {
            let timestamp = if self.is_stale.read() {
                0_u64
            } else {
                self.timestamp.read()
            };
            (self.rate_bps.read(), timestamp)
        }

        fn set_rate(ref self: ContractState, rate_bps: u256, timestamp: u64) {
            self.rate_bps.write(rate_bps);
            self.timestamp.write(timestamp);
        }

        fn set_stale(ref self: ContractState, is_stale: bool) {
            self.is_stale.write(is_stale);
        }
    }
}

// ============== MockERC20 ==============

#[starknet::interface]
pub trait IMockERC20<TContractState> {
    fn mint(ref self: TContractState, recipient: ContractAddress, amount: u256);
    fn approve(ref self: TContractState, spender: ContractAddress, amount: u256) -> bool;
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TContractState,
        sender: ContractAddress,
        recipient: ContractAddress,
        amount: u256,
    ) -> bool;
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
    fn allowance(self: @TContractState, owner: ContractAddress, spender: ContractAddress) -> u256;
    fn decimals(self: @TContractState) -> u8;
    fn total_supply(self: @TContractState) -> u256;
}

#[starknet::contract]
pub mod MockERC20 {
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};

    #[storage]
    struct Storage {
        balances: Map<ContractAddress, u256>,
        allowances: Map<(ContractAddress, ContractAddress), u256>,
        token_decimals: u8,
        total_supply: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState, decimals: u8) {
        self.token_decimals.write(decimals);
        self.total_supply.write(0);
    }

    #[abi(embed_v0)]
    impl MockERC20Impl of super::IMockERC20<ContractState> {
        fn mint(ref self: ContractState, recipient: ContractAddress, amount: u256) {
            let current = self.balances.read(recipient);
            self.balances.write(recipient, current + amount);
            self.total_supply.write(self.total_supply.read() + amount);
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            let caller = get_caller_address();
            self.allowances.write((caller, spender), amount);
            true
        }

        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            let caller = get_caller_address();
            let from_balance = self.balances.read(caller);
            assert(from_balance >= amount, 'Insufficient balance');
            self.balances.write(caller, from_balance - amount);
            self.balances.write(recipient, self.balances.read(recipient) + amount);
            true
        }

        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) -> bool {
            let caller = get_caller_address();
            let allowance = self.allowances.read((sender, caller));
            assert(allowance >= amount, 'Insufficient allowance');
            let from_balance = self.balances.read(sender);
            assert(from_balance >= amount, 'Insufficient balance');

            self.allowances.write((sender, caller), allowance - amount);
            self.balances.write(sender, from_balance - amount);
            self.balances.write(recipient, self.balances.read(recipient) + amount);
            true
        }

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.read(account)
        }

        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress,
        ) -> u256 {
            self.allowances.read((owner, spender))
        }

        fn decimals(self: @ContractState) -> u8 {
            self.token_decimals.read()
        }

        fn total_supply(self: @ContractState) -> u256 {
            self.total_supply.read()
        }
    }
}
