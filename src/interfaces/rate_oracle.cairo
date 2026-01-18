/// Oracle adapter interface - market creators implement this
#[starknet::interface]
pub trait IOracleAdapter<TContractState> {
    /// Get current price (8 decimals)
    fn get_price(self: @TContractState) -> (u256, u64); // (price, last_update_timestamp)
    
    /// Get current rate (basis points)
    fn get_rate(self: @TContractState) -> (u256, u64); // (rate_bps, last_update_timestamp)
}
