#[starknet::component]
pub mod LiquidityManagerComponent {
    use ERC6909Component::InternalTrait as ERC6909InternalTrait;
    use openzeppelin_introspection::src5::SRC5Component;
    use starknet::{ContractAddress, get_contract_address};
    use crate::components::ERC6909::ERC6909Component;
    use crate::components::ERC6909::ERC6909Component::ERC6909Impl;
    use crate::helpers::constants::Constants;
    use crate::helpers::errors::Errors;
    use crate::helpers::fixed_point::{mul_div_down, mul_div_up};
    use crate::helpers::safe_erc20::SafeERC20;
    use crate::helpers::signed_value::{negative, positive};
    use crate::types::asce_swap::{LpPool, PoolAnalytics};

    #[storage]
    pub struct Storage {}

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        Deposit: Deposit,
        Withdraw: Withdraw,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Deposit {
        #[key]
        pub caller: ContractAddress,
        #[key]
        pub receiver: ContractAddress,
        #[key]
        pub pair_id: felt252,
        pub assets: u256,
        pub shares: u256,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Withdraw {
        #[key]
        pub caller: ContractAddress,
        #[key]
        pub receiver: ContractAddress,
        #[key]
        pub pair_id: felt252,
        pub assets: u256,
        pub shares: u256,
        pub timestamp: u64,
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState,
        +HasComponent<TContractState>,
        +Drop<TContractState>,
        impl ERC6909Comp: ERC6909Component::HasComponent<TContractState>,
        +SRC5Component::HasComponent<TContractState>,
        +ERC6909Component::ERC6909HooksTrait<TContractState>,
    > of InternalTrait<TContractState> {
        /// Deposit assets into a market pool, mint shares to receiver
        /// Returns (shares_minted, updated_pool)
        fn _deposit(
            ref self: ComponentState<TContractState>,
            pair_id: felt252,
            assets: u256,
            caller: ContractAddress,
            receiver: ContractAddress,
            mut pool: LpPool,
            collateral_token: ContractAddress,
        ) -> (u256, LpPool) {
            // assert(assets >= Constants::MIN_LP_DEPOSIT, Errors::BELOW_MIN_DEPOSIT);
            let mut erc6909 = get_dep_component_mut!(ref self, ERC6909Comp);
            
            let id: u256 = pair_id.into();

            let shares = self._convert_to_shares(assets, @pool);

            // Update pool state
            pool.total_shares = pool.total_shares + shares;
            pool.total_collateral = pool.total_collateral + assets;

            // Transfer underlying tokens from caller
            SafeERC20::strict_transfer_from(
                collateral_token, caller, get_contract_address(), assets,
            );

            // Mint ERC6909 LP tokens to receiver
            erc6909.mint(receiver, id, shares);

            self
                .emit(
                    Deposit {
                        caller,
                        receiver,
                        pair_id,
                        assets,
                        shares,
                        timestamp: starknet::get_block_timestamp(),
                    },
                );

            (shares, pool)
        }

        /// Mint exact shares to receiver, pull required assets from caller
        /// Returns (assets_deposited, updated_pool)
        fn _mint(
            ref self: ComponentState<TContractState>,
            pair_id: felt252,
            shares: u256,
            caller: ContractAddress,
            receiver: ContractAddress,
            mut pool: LpPool,
            collateral_token: ContractAddress,
        ) -> (u256, LpPool) {
            let mut erc6909 = get_dep_component_mut!(ref self, ERC6909Comp);

            let id: u256 = pair_id.into();

            // ERC4626: assets = previewMint(shares) — rounds UP (caller pays more)
            let assets = self._preview_mint(shares, @pool);

            // Update pool state
            pool.total_shares = pool.total_shares + shares;
            pool.total_collateral = pool.total_collateral + assets;

            // Transfer underlying tokens from caller
            SafeERC20::strict_transfer_from(
                collateral_token, caller, get_contract_address(), assets,
            );

            // Mint ERC6909 LP tokens to receiver
            erc6909.mint(receiver, id, shares);

            self
                .emit(
                    Deposit {
                        caller,
                        receiver,
                        pair_id,
                        assets,
                        shares,
                        timestamp: starknet::get_block_timestamp(),
                    },
                );

            (assets, pool)
        }

        /// Burn caller's shares, send assets to receiver
        /// Returns (assets_out, updated_pool)
        fn _redeem(
            ref self: ComponentState<TContractState>,
            pair_id: felt252,
            shares: u256,
            caller: ContractAddress,
            receiver: ContractAddress,
            mut pool: LpPool,
            collateral_token: ContractAddress,
        ) -> (u256, LpPool) {
            let id: u256 = pair_id.into();

            // Check balance via ERC6909
            let mut erc6909 = get_dep_component_mut!(ref self, ERC6909Comp);
            let caller_balance = erc6909.balance_of(caller, id);
            assert(caller_balance >= shares, Errors::INSUFFICIENT_SHARES);

            // ERC4626: assets = convertToAssets(shares)
            let assets = self._convert_to_assets(shares, @pool);

            // Check available liquidity
            let available = pool.total_collateral
                - pool.locked_for_fixed
                - pool.locked_for_floating;
            assert(assets <= available, Errors::EXCEEDS_AVAILABLE_LIQUIDITY);

            // Update pool
            pool.total_shares = pool.total_shares - shares;
            pool.total_collateral = pool.total_collateral - assets;

            // Burn ERC6909 LP tokens
            erc6909.burn(caller, id, shares);

            // Transfer underlying to receiver
            SafeERC20::strict_transfer(collateral_token, receiver, assets);

            self
                .emit(
                    Withdraw {
                        caller,
                        receiver,
                        pair_id,
                        assets,
                        shares,
                        timestamp: starknet::get_block_timestamp(),
                    },
                );

            (assets, pool)
        }

        /// Withdraw exact assets to receiver, burn required shares from caller
        /// Returns (shares_burned, updated_pool)
        fn _withdraw(
            ref self: ComponentState<TContractState>,
            pair_id: felt252,
            assets: u256,
            caller: ContractAddress,
            receiver: ContractAddress,
            mut pool: LpPool,
            collateral_token: ContractAddress,
        ) -> (u256, LpPool) {
            let id: u256 = pair_id.into();

            // ERC4626: shares = previewWithdraw(assets) — rounds UP (caller burns more)
            let shares = self._preview_withdraw(assets, @pool);

            // Check balance via ERC6909
            let mut erc6909 = get_dep_component_mut!(ref self, ERC6909Comp);
            let caller_balance = erc6909.balance_of(caller, id);
            assert(caller_balance >= shares, Errors::INSUFFICIENT_SHARES);

            // Check available liquidity
            let available = pool.total_collateral
                - pool.locked_for_fixed
                - pool.locked_for_floating;
            assert(assets <= available, Errors::EXCEEDS_AVAILABLE_LIQUIDITY);

            // Update pool
            pool.total_shares = pool.total_shares - shares;
            pool.total_collateral = pool.total_collateral - assets;

            // Burn ERC6909 LP tokens
            erc6909.burn(caller, id, shares);

            // Transfer underlying to receiver
            SafeERC20::strict_transfer(collateral_token, receiver, assets);

            self
                .emit(
                    Withdraw {
                        caller,
                        receiver,
                        pair_id,
                        assets,
                        shares,
                        timestamp: starknet::get_block_timestamp(),
                    },
                );

            (shares, pool)
        }

        /// Get pool analytics
        fn _get_pool_analytics(
            self: @ComponentState<TContractState>, pool: @LpPool,
        ) -> PoolAnalytics {
            let available = *pool.total_collateral
                - *pool.locked_for_fixed
                - *pool.locked_for_floating;

            let util_fixed = if *pool.total_collateral > 0 {
                mul_div_down(*pool.locked_for_fixed, Constants::BPS, *pool.total_collateral)
            } else {
                0
            };

            let util_floating = if *pool.total_collateral > 0 {
                mul_div_down(*pool.locked_for_floating, Constants::BPS, *pool.total_collateral)
            } else {
                0
            };

            // Net exposure: positive = more fixed (LP is net short rate)
            let net_exposure = if *pool.locked_for_fixed >= *pool.locked_for_floating {
                positive(*pool.locked_for_fixed - *pool.locked_for_floating)
            } else {
                negative(*pool.locked_for_floating - *pool.locked_for_fixed)
            };

            PoolAnalytics {
                total_value: *pool.total_collateral,
                available_liquidity: available,
                utilization_fixed_bps: util_fixed,
                utilization_floating_bps: util_floating,
                net_exposure_notional: net_exposure,
            }
        }

        fn _exchange_rate(self: @ComponentState<TContractState>, pool: @LpPool) -> u256 {
            if *pool.total_shares == 0 {
                return Constants::PRECISION; // 1:1 when no shares exist
            }
            // exchange_rate = total_collateral * PRECISION / total_shares
            mul_div_down(*pool.total_collateral, Constants::PRECISION, *pool.total_shares)
        }

        fn _convert_to_shares(
            self: @ComponentState<TContractState>, assets: u256, pool: @LpPool,
        ) -> u256 {
            if *pool.total_shares == 0 || *pool.total_collateral == 0 {
                return assets; // 1:1 for first deposit
            }
            mul_div_down(assets, *pool.total_shares, *pool.total_collateral)
        }

        fn _convert_to_assets(
            self: @ComponentState<TContractState>, shares: u256, pool: @LpPool,
        ) -> u256 {
            if *pool.total_shares == 0 {
                return 0;
            }
            mul_div_down(shares, *pool.total_collateral, *pool.total_shares)
        }

        /// Preview mint: how many assets needed to mint exact shares (rounds UP)
        fn _preview_mint(
            self: @ComponentState<TContractState>, shares: u256, pool: @LpPool,
        ) -> u256 {
            if *pool.total_shares == 0 || *pool.total_collateral == 0 {
                return shares; // 1:1 for first deposit
            }
            mul_div_up(shares, *pool.total_collateral, *pool.total_shares)
        }

        /// Preview withdraw: how many shares needed to withdraw exact assets (rounds UP)
        fn _preview_withdraw(
            self: @ComponentState<TContractState>, assets: u256, pool: @LpPool,
        ) -> u256 {
            if *pool.total_shares == 0 || *pool.total_collateral == 0 {
                return assets; // 1:1
            }
            mul_div_up(assets, *pool.total_shares, *pool.total_collateral)
        }

        /// Get LP's share balance via ERC6909
        fn _balance_of(
            self: @ComponentState<TContractState>, lp: ContractAddress, pair_id: felt252,
        ) -> u256 {
            let id: u256 = pair_id.into();
            let erc6909 = get_dep_component!(self, ERC6909Comp);
            erc6909.balance_of(lp, id)
        }

        fn _total_assets(self: @ComponentState<TContractState>, pool: @LpPool) -> u256 {
            *pool.total_collateral
        }

        fn _max_deposit(self: @ComponentState<TContractState>) -> u256 {
            // No hard cap — limited only by ERC20 balance + approval
            0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff_u256
        }

        fn _max_mint(self: @ComponentState<TContractState>) -> u256 {
            // No hard cap — limited only by ERC20 balance + approval
            0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff_u256
        }

        fn _max_withdraw(
            self: @ComponentState<TContractState>,
            owner: ContractAddress,
            pair_id: felt252,
            pool: @LpPool,
        ) -> u256 {
            let owner_shares = self._balance_of(owner, pair_id);
            if owner_shares == 0 || *pool.total_shares == 0 {
                return 0;
            }
            let share_value = self._convert_to_assets(owner_shares, pool);
            let available = *pool.total_collateral
                - *pool.locked_for_fixed
                - *pool.locked_for_floating;
            if share_value < available {
                share_value
            } else {
                available
            }
        }

        fn _max_redeem(
            self: @ComponentState<TContractState>,
            owner: ContractAddress,
            pair_id: felt252,
            pool: @LpPool,
        ) -> u256 {
            let owner_shares = self._balance_of(owner, pair_id);
            if owner_shares == 0 || *pool.total_shares == 0 {
                return 0;
            }
            let available = *pool.total_collateral
                - *pool.locked_for_fixed
                - *pool.locked_for_floating;
            let max_shares_for_available = self._convert_to_shares(available, pool);
            if owner_shares < max_shares_for_available {
                owner_shares
            } else {
                max_shares_for_available
            }
        }
    }
}
