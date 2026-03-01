// Enhanced MockERC20 for testnet — owner can mint any amount, public faucet has cooldown
use starknet::ContractAddress;

#[starknet::interface]
pub trait IMockToken<TContractState> {
    // ERC20 standard
    fn name(self: @TContractState) -> ByteArray;
    fn symbol(self: @TContractState) -> ByteArray;
    fn decimals(self: @TContractState) -> u8;
    fn total_supply(self: @TContractState) -> u256;
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
    fn allowance(self: @TContractState, owner: ContractAddress, spender: ContractAddress) -> u256;
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256,
    ) -> bool;
    fn approve(ref self: TContractState, spender: ContractAddress, amount: u256) -> bool;

    // Owner mint — arbitrary amount to any address (for bootstrapping liquidity)
    fn owner_mint(ref self: TContractState, recipient: ContractAddress, amount: u256);

    // Public faucet — fixed amount to caller with cooldown
    fn mint(ref self: TContractState);
    fn mint_amount(self: @TContractState) -> u256;
    fn mint_cooldown_seconds(self: @TContractState) -> u64;
    fn last_mint_time(self: @TContractState, account: ContractAddress) -> u64;
    fn owner(self: @TContractState) -> ContractAddress;
}

#[starknet::contract]
pub mod MockToken {
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address};

    #[storage]
    struct Storage {
        token_owner: ContractAddress,
        token_name: ByteArray,
        token_symbol: ByteArray,
        token_decimals: u8,
        token_mint_amount: u256,
        token_mint_cooldown: u64,
        total_supply: u256,
        balances: Map<ContractAddress, u256>,
        allowances: Map<(ContractAddress, ContractAddress), u256>,
        last_mint_time: Map<ContractAddress, u64>,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        name: ByteArray,
        symbol: ByteArray,
        decimals: u8,
        mint_amount: u256,
        mint_cooldown_seconds: u64,
    ) {
        self.token_owner.write(owner);
        self.token_name.write(name);
        self.token_symbol.write(symbol);
        self.token_decimals.write(decimals);
        self.token_mint_amount.write(mint_amount);
        self.token_mint_cooldown.write(mint_cooldown_seconds);
        self.total_supply.write(0);
    }

    fn assert_only_owner(self: @ContractState) {
        assert(get_caller_address() == self.token_owner.read(), 'Only owner');
    }

    #[abi(embed_v0)]
    impl MockTokenImpl of super::IMockToken<ContractState> {
        fn name(self: @ContractState) -> ByteArray {
            self.token_name.read()
        }

        fn symbol(self: @ContractState) -> ByteArray {
            self.token_symbol.read()
        }

        fn decimals(self: @ContractState) -> u8 {
            self.token_decimals.read()
        }

        fn total_supply(self: @ContractState) -> u256 {
            self.total_supply.read()
        }

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.read(account)
        }

        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress,
        ) -> u256 {
            self.allowances.read((owner, spender))
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
            let current_allowance = self.allowances.read((sender, caller));
            assert(current_allowance >= amount, 'Insufficient allowance');
            let from_balance = self.balances.read(sender);
            assert(from_balance >= amount, 'Insufficient balance');

            self.allowances.write((sender, caller), current_allowance - amount);
            self.balances.write(sender, from_balance - amount);
            self.balances.write(recipient, self.balances.read(recipient) + amount);
            true
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            let caller = get_caller_address();
            self.allowances.write((caller, spender), amount);
            true
        }

        fn owner_mint(ref self: ContractState, recipient: ContractAddress, amount: u256) {
            assert_only_owner(@self);
            self.balances.write(recipient, self.balances.read(recipient) + amount);
            self.total_supply.write(self.total_supply.read() + amount);
        }

        fn mint(ref self: ContractState) {
            let caller = get_caller_address();
            let now = get_block_timestamp();
            let last = self.last_mint_time.read(caller);
            let cooldown = self.token_mint_cooldown.read();

            assert(now - last >= cooldown, 'Mint cooldown active');

            let amount = self.token_mint_amount.read();
            self.balances.write(caller, self.balances.read(caller) + amount);
            self.total_supply.write(self.total_supply.read() + amount);
            self.last_mint_time.write(caller, now);
        }

        fn mint_amount(self: @ContractState) -> u256 {
            self.token_mint_amount.read()
        }

        fn mint_cooldown_seconds(self: @ContractState) -> u64 {
            self.token_mint_cooldown.read()
        }

        fn last_mint_time(self: @ContractState, account: ContractAddress) -> u64 {
            self.last_mint_time.read(account)
        }

        fn owner(self: @ContractState) -> ContractAddress {
            self.token_owner.read()
        }
    }
}
