use starknet::ContractAddress;


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


#[starknet::interface]
pub trait IMockOracleManipulable<TContractState> {
    fn get_rate(self: @TContractState) -> (u256, u64);
    fn set_rate(ref self: TContractState, rate_bps: u256, timestamp: u64);
    fn set_rate_sequence(ref self: TContractState, rates: Span<u256>, interval: u64);
    fn advance_sequence(ref self: TContractState);
}

#[starknet::contract]
pub mod MockOracleManipulable {
    use starknet::storage::{
        MutableVecTrait, StoragePointerReadAccess, StoragePointerWriteAccess, Vec, VecTrait,
    };

    #[storage]
    struct Storage {
        current_rate_bps: u256,
        current_timestamp: u64,
        rate_sequence: Vec<u256>,
        sequence_index: u64,
        interval: u64,
    }

    #[constructor]
    fn constructor(ref self: ContractState, initial_rate: u256, initial_timestamp: u64) {
        self.current_rate_bps.write(initial_rate);
        self.current_timestamp.write(initial_timestamp);
        self.sequence_index.write(0);
        self.interval.write(3600);
    }

    #[abi(embed_v0)]
    impl MockOracleManipulableImpl of super::IMockOracleManipulable<ContractState> {
        fn get_rate(self: @ContractState) -> (u256, u64) {
            (self.current_rate_bps.read(), self.current_timestamp.read())
        }

        fn set_rate(ref self: ContractState, rate_bps: u256, timestamp: u64) {
            self.current_rate_bps.write(rate_bps);
            self.current_timestamp.write(timestamp);
        }

        fn set_rate_sequence(ref self: ContractState, rates: Span<u256>, interval: u64) {
            self.sequence_index.write(0);
            self.interval.write(interval);

            let mut i: u32 = 0;
            let len: u32 = rates.len();
            while i < len {
                self.rate_sequence.append().write(*rates.at(i));
                i += 1;
            }
        }

        fn advance_sequence(ref self: ContractState) {
            let index = self.sequence_index.read();
            let len = self.rate_sequence.len();

            if index < len {
                let rate = self.rate_sequence.at(index).read();
                self.current_rate_bps.write(rate);
                self.current_timestamp.write(self.current_timestamp.read() + self.interval.read());
                self.sequence_index.write(index + 1);
            }
        }
    }
}
