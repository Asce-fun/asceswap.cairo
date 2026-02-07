pub mod SafeERC20 {
    use core::num::traits::Zero;
    use starknet::ContractAddress;
    use crate::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};

    /// Safe transfer - validates recipient is non-zero and asserts success
    /// Skips transfer if amount is 0 (avoids wasting gas on no-op)
    pub fn safe_transfer(token: ContractAddress, recipient: ContractAddress, amount: u256) {
        assert(!recipient.is_zero(), 'SafeERC20: zero recipient');
        if amount != 0 {
            let dispatcher = IERC20Dispatcher { contract_address: token };
            let success = dispatcher.transfer(recipient, amount);
            assert(success, 'SafeERC20: transfer failed');
        }
    }

    /// Strict transfer - same as safe_transfer but requires amount > 0
    pub fn strict_transfer(token: ContractAddress, recipient: ContractAddress, amount: u256) {
        assert(amount != 0, 'SafeERC20: zero amount');
        safe_transfer(token, recipient, amount);
    }

    /// Safe transfer_from - validates recipient, asserts success
    /// Skips if amount is 0 or sender == recipient
    pub fn safe_transfer_from(
        token: ContractAddress, sender: ContractAddress, recipient: ContractAddress, amount: u256,
    ) {
        assert(!recipient.is_zero(), 'SafeERC20: zero recipient');
        if amount != 0 && sender != recipient {
            let dispatcher = IERC20Dispatcher { contract_address: token };
            let success = dispatcher.transfer_from(sender, recipient, amount);
            assert(success, 'SafeERC20: transferFrom failed');
        }
    }

    /// Strict transfer_from - requires amount > 0
    pub fn strict_transfer_from(
        token: ContractAddress, sender: ContractAddress, recipient: ContractAddress, amount: u256,
    ) {
        assert(amount != 0, 'SafeERC20: zero amount');
        safe_transfer_from(token, sender, recipient, amount);
    }

    /// Safe approve - validates spender is non-zero
    pub fn safe_approve(token: ContractAddress, spender: ContractAddress, amount: u256) {
        assert(!spender.is_zero(), 'SafeERC20: zero spender');
        if amount != 0 {
            let dispatcher = IERC20Dispatcher { contract_address: token };
            let success = dispatcher.approve(spender, amount);
            assert(success, 'SafeERC20: approve failed');
        }
    }

    /// Get balance of an address
    pub fn balance_of(token: ContractAddress, account: ContractAddress) -> u256 {
        let dispatcher = IERC20Dispatcher { contract_address: token };
        dispatcher.balance_of(account)
    }
}
