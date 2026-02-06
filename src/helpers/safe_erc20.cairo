// // Use strict approve, transfers where u want amount to be non zero for sure
// // Use other functions for more flexibility. e.g. during fee transfers where fee can be zero
// sometimes

// pub mod ERC20HelperLib {
//     use starknet::{ContractAddress};
//     use openzeppelin::token::erc20::interface::{
//         IERC20, ERC20ABIDispatcher, ERC20ABIDispatcherTrait
//     };
//     use core::num::traits::Zero;

//     pub fn approve(token: ContractAddress, spender: ContractAddress, amount: u256) {
//         assert(spender.is_non_zero(), 'ERC20::approve::spender 0');
//         if (amount != 0) {
//             //// println!("approving");
//             let approved = ERC20ABIDispatcher { contract_address: token }.approve(spender,
//             amount);
//             assert(approved, 'ERC20: approve failed');

//         }
//     }

//     pub fn strict_approve(token: ContractAddress, spender: ContractAddress, amount: u256) {
//         assert(amount != 0, 'ERC20::strict_approve::amount 0');
//         approve(token, spender, amount);
//     }

//     pub fn transfer(token: ContractAddress, receipient: ContractAddress, amount: u256) {
//         assert(receipient.is_non_zero(), 'ERC20::transfer::receipient 0');
//         if (amount != 0) {
//             //// println!("transfering");
//             let transferred = ERC20ABIDispatcher { contract_address: token }
//                 .transfer(receipient, amount);
//             assert(transferred, 'ERC20: transfer failed');
//         //// println!("transferred");
//         }
//     }

//     pub fn strict_transfer(token: ContractAddress, receipient: ContractAddress, amount: u256) {
//         assert(amount != 0, 'ERC20::transfer: amt 0');
//         transfer(token, receipient, amount);
//     }

//     pub fn transfer_from(
//         token: ContractAddress, sender: ContractAddress, receipient: ContractAddress, amount:
//         u256
//     ) {
//         assert(receipient.is_non_zero(), 'ERC20::transfer_from::rcpt 0');
//         if (amount != 0 && receipient != sender) {
//             //// println!("transfering from: {:?}", amount);
//             let bal = ERC20ABIDispatcher { contract_address: token }.balanceOf(sender);
//             //// println!("balance of sender: {:?}", bal);
//             let transferred = ERC20ABIDispatcher { contract_address: token }
//                 .transferFrom(sender, receipient, amount);
//             assert(transferred, 'ERC20: transfer from failed');
//         //// println!("transferred from");
//         }
//     }

//     pub fn strict_transfer_from(
//         token: ContractAddress, sender: ContractAddress, receipient: ContractAddress, amount:
//         u256
//     ) {
//         assert(amount != 0, 'ERC20::transfer_from::amt 0');
//         transfer_from(token, sender, receipient, amount);
//     }

//     pub fn balanceOf(token: ContractAddress, address: ContractAddress) -> u256 {
//         ERC20ABIDispatcher { contract_address: token }.balanceOf(address)
//     }

//     pub fn totalSupply(token: ContractAddress) -> u256 {
//         ERC20ABIDispatcher { contract_address: token }.totalSupply()
//     }
// }
