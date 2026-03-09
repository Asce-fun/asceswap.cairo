#[starknet::component]
pub mod ExtensionManagerComponent {
    use core::num::traits::Zero;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};
    use starknet::{ContractAddress, get_caller_address};
    use crate::helpers::errors::Errors;
    use crate::interfaces::extension::{IExtensionDispatcher, IExtensionDispatcherTrait};
    use crate::types::asce_swap::{SettlementResult, SettlementType};
    use crate::types::extension::{
        CallPoints, LiquidityParams, MarketCreationParams, SwapOpenParams,
    };

    #[storage]
    pub struct Storage {
        extension_call_points: Map<ContractAddress, CallPoints>,
        extension_registered: Map<ContractAddress, bool>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        ExtensionRegistered: ExtensionRegistered,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ExtensionRegistered {
        #[key]
        pub extension: ContractAddress,
        pub call_points: CallPoints,
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>, +Drop<TContractState>,
    > of InternalTrait<TContractState> {
        /// Register caller's call points (one-time only)
        fn set_call_points(ref self: ComponentState<TContractState>, call_points: CallPoints) {
            let caller = get_caller_address();
            assert(!self.extension_registered.read(caller), Errors::EXTENSION_NOT_REGISTERED);

            // Assert not all-false
            let has_any = call_points.before_market_creation
                || call_points.after_market_creation
                || call_points.before_swap_open
                || call_points.after_swap_open
                || call_points.before_swap_close
                || call_points.after_swap_close
                || call_points.before_add_liquidity
                || call_points.after_add_liquidity
                || call_points.before_remove_liquidity
                || call_points.after_remove_liquidity;
            assert(has_any, Errors::INVALID_PARAMS);

            self.extension_registered.write(caller, true);
            self.extension_call_points.write(caller, call_points);

            self.emit(ExtensionRegistered { extension: caller, call_points });
        }

        /// Check if an extension is registered
        fn is_extension_registered(
            self: @ComponentState<TContractState>, extension: ContractAddress,
        ) -> bool {
            self.extension_registered.read(extension)
        }

        /// Get call points for an extension, returning Default if extension is zero
        /// or if extension == caller (re-entry skip)
        fn _get_call_points(
            self: @ComponentState<TContractState>,
            extension: ContractAddress,
            caller: ContractAddress,
        ) -> CallPoints {
            if extension.is_zero() || extension == caller {
                return Default::default();
            }
            self.extension_call_points.read(extension)
        }


        fn _dispatch_before_market_creation(
            self: @ComponentState<TContractState>,
            extension: ContractAddress,
            caller: ContractAddress,
            creation_params: MarketCreationParams,
        ) {
            let cp = self._get_call_points(extension, caller);
            if cp.before_market_creation {
                IExtensionDispatcher { contract_address: extension }
                    .before_market_creation(caller, creation_params);
            }
        }

        fn _dispatch_after_market_creation(
            self: @ComponentState<TContractState>,
            extension: ContractAddress,
            caller: ContractAddress,
            pair_id: felt252,
            creation_params: MarketCreationParams,
            shares_minted: u256,
        ) {
            let cp = self._get_call_points(extension, caller);
            if cp.after_market_creation {
                IExtensionDispatcher { contract_address: extension }
                    .after_market_creation(caller, pair_id, creation_params, shares_minted);
            }
        }

        fn _dispatch_before_swap_open(
            self: @ComponentState<TContractState>,
            extension: ContractAddress,
            caller: ContractAddress,
            pair_id: felt252,
            params: SwapOpenParams,
        ) {
            let cp = self._get_call_points(extension, caller);
            if cp.before_swap_open {
                IExtensionDispatcher { contract_address: extension }
                    .before_swap_open(caller, pair_id, params);
            }
        }

        fn _dispatch_after_swap_open(
            self: @ComponentState<TContractState>,
            extension: ContractAddress,
            caller: ContractAddress,
            pair_id: felt252,
            params: SwapOpenParams,
            swap_id: u256,
        ) {
            let cp = self._get_call_points(extension, caller);
            if cp.after_swap_open {
                IExtensionDispatcher { contract_address: extension }
                    .after_swap_open(caller, pair_id, params, swap_id);
            }
        }

        fn _dispatch_before_swap_close(
            self: @ComponentState<TContractState>,
            extension: ContractAddress,
            caller: ContractAddress,
            pair_id: felt252,
            swap_id: u256,
            settlement_type: SettlementType,
        ) {
            let cp = self._get_call_points(extension, caller);
            if cp.before_swap_close {
                IExtensionDispatcher { contract_address: extension }
                    .before_swap_close(caller, pair_id, swap_id, settlement_type);
            }
        }

        fn _dispatch_after_swap_close(
            self: @ComponentState<TContractState>,
            extension: ContractAddress,
            caller: ContractAddress,
            pair_id: felt252,
            swap_id: u256,
            settlement_type: SettlementType,
            settlement_result: SettlementResult,
        ) {
            let cp = self._get_call_points(extension, caller);
            if cp.after_swap_close {
                IExtensionDispatcher { contract_address: extension }
                    .after_swap_close(caller, pair_id, swap_id, settlement_type, settlement_result);
            }
        }

        fn _dispatch_before_add_liquidity(
            self: @ComponentState<TContractState>,
            extension: ContractAddress,
            caller: ContractAddress,
            pair_id: felt252,
            params: LiquidityParams,
        ) {
            let cp = self._get_call_points(extension, caller);
            if cp.before_add_liquidity {
                IExtensionDispatcher { contract_address: extension }
                    .before_add_liquidity(caller, pair_id, params);
            }
        }

        fn _dispatch_after_add_liquidity(
            self: @ComponentState<TContractState>,
            extension: ContractAddress,
            caller: ContractAddress,
            pair_id: felt252,
            params: LiquidityParams,
        ) {
            let cp = self._get_call_points(extension, caller);
            if cp.after_add_liquidity {
                IExtensionDispatcher { contract_address: extension }
                    .after_add_liquidity(caller, pair_id, params);
            }
        }

        fn _dispatch_before_remove_liquidity(
            self: @ComponentState<TContractState>,
            extension: ContractAddress,
            caller: ContractAddress,
            pair_id: felt252,
            params: LiquidityParams,
        ) {
            let cp = self._get_call_points(extension, caller);
            if cp.before_remove_liquidity {
                IExtensionDispatcher { contract_address: extension }
                    .before_remove_liquidity(caller, pair_id, params);
            }
        }

        fn _dispatch_after_remove_liquidity(
            self: @ComponentState<TContractState>,
            extension: ContractAddress,
            caller: ContractAddress,
            pair_id: felt252,
            params: LiquidityParams,
        ) {
            let cp = self._get_call_points(extension, caller);
            if cp.after_remove_liquidity {
                IExtensionDispatcher { contract_address: extension }
                    .after_remove_liquidity(caller, pair_id, params);
            }
        }
    }
}
