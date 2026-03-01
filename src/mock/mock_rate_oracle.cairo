// Mock rate oracle for testnet — only deployer (owner) can set rate
// Includes circular buffer for rate history (frontend reads directly)

#[starknet::interface]
pub trait IMockRateOracle<TContractState> {
    fn get_rate(self: @TContractState) -> (u256, u64);
    fn get_price(self: @TContractState) -> (u256, u64);
    fn name(self: @TContractState) -> ByteArray;
    fn set_rate(ref self: TContractState, rate_bps: u256, timestamp: u64);
    fn set_stale(ref self: TContractState, is_stale: bool);
    fn owner(self: @TContractState) -> starknet::ContractAddress;
    fn get_rate_history(self: @TContractState, max_count: u32) -> Array<(u256, u64)>;
    fn get_history_count(self: @TContractState) -> u32;
}

#[starknet::contract]
pub mod MockRateOracle {
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};

    const MAX_HISTORY: u32 = 168; // 7 days of hourly updates

    #[storage]
    struct Storage {
        oracle_owner: ContractAddress,
        oracle_name: ByteArray,
        rate_bps: u256,
        timestamp: u64,
        is_stale: bool,
        // Circular buffer for rate history
        history_rate: Map<u32, u256>,
        history_timestamp: Map<u32, u64>,
        history_head: u32,
        history_count: u32,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        name: ByteArray,
        initial_rate: u256,
        initial_timestamp: u64,
    ) {
        self.oracle_owner.write(owner);
        self.oracle_name.write(name);
        self.rate_bps.write(initial_rate);
        self.timestamp.write(initial_timestamp);
        self.is_stale.write(false);
        self.history_head.write(0);
        self.history_count.write(0);
    }

    fn assert_only_owner(self: @ContractState) {
        assert(get_caller_address() == self.oracle_owner.read(), 'Only owner');
    }

    #[abi(embed_v0)]
    impl MockRateOracleImpl of super::IMockRateOracle<ContractState> {
        fn get_rate(self: @ContractState) -> (u256, u64) {
            let timestamp = if self.is_stale.read() {
                0_u64
            } else {
                self.timestamp.read()
            };
            (self.rate_bps.read(), timestamp)
        }

        fn get_price(self: @ContractState) -> (u256, u64) {
            // For rate oracles, price is the rate expressed in 8-decimal format
            // rate_bps / 10000 * 1e8 = rate_bps * 10000
            let rate = self.rate_bps.read();
            let price_8dec = rate * 10000;
            let timestamp = if self.is_stale.read() {
                0_u64
            } else {
                self.timestamp.read()
            };
            (price_8dec, timestamp)
        }

        fn name(self: @ContractState) -> ByteArray {
            self.oracle_name.read()
        }

        fn set_rate(ref self: ContractState, rate_bps: u256, timestamp: u64) {
            assert_only_owner(@self);

            // Save current rate to history buffer before overwriting
            let current_rate = self.rate_bps.read();
            let current_timestamp = self.timestamp.read();
            // Only save if there's an existing rate (timestamp > 0)
            if current_timestamp > 0 {
                let head = self.history_head.read();
                self.history_rate.write(head, current_rate);
                self.history_timestamp.write(head, current_timestamp);

                // Advance head (circular)
                let new_head = (head + 1) % MAX_HISTORY;
                self.history_head.write(new_head);

                // Increment count (cap at MAX_HISTORY)
                let count = self.history_count.read();
                if count < MAX_HISTORY {
                    self.history_count.write(count + 1);
                }
            }

            // Write new current rate
            self.rate_bps.write(rate_bps);
            self.timestamp.write(timestamp);
        }

        fn set_stale(ref self: ContractState, is_stale: bool) {
            assert_only_owner(@self);
            self.is_stale.write(is_stale);
        }

        fn owner(self: @ContractState) -> ContractAddress {
            self.oracle_owner.read()
        }

        fn get_rate_history(self: @ContractState, max_count: u32) -> Array<(u256, u64)> {
            let count = self.history_count.read();
            let head = self.history_head.read();

            // Return min(max_count, count) entries in chronological order
            let return_count = if max_count < count {
                max_count
            } else {
                count
            };

            let mut result: Array<(u256, u64)> = array![];

            if return_count == 0 {
                return result;
            }

            // Oldest entry we want is at: (head - return_count) mod MAX_HISTORY
            // head points to next write slot, so head-1 is most recent, head-count is oldest
            let start = if head >= return_count {
                head - return_count
            } else {
                MAX_HISTORY - (return_count - head)
            };

            let mut i: u32 = 0;
            while i < return_count {
                let idx = (start + i) % MAX_HISTORY;
                let rate = self.history_rate.read(idx);
                let ts = self.history_timestamp.read(idx);
                result.append((rate, ts));
                i += 1;
            }

            result
        }

        fn get_history_count(self: @ContractState) -> u32 {
            self.history_count.read()
        }
    }
}
