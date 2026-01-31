#[starknet::component]
pub mod LiquidityManagerComponent {
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};
    use starknet::{ContractAddress, get_block_timestamp, get_contract_address};
    use crate::helpers::constants::Constants;
    use crate::helpers::errors::Errors;
    use crate::helpers::fixed_point::mul_div_down;
    use crate::helpers::signed_value::{negative, positive};
    use crate::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use crate::types::asce_swap::{LpPool, LpPosition, PoolAnalytics, ProtocolConfig};

    #[storage]
    pub struct Storage {
        lp_positions: Map<(ContractAddress, felt252), LpPosition>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        LpDeposited: LpDeposited,
        LpWithdrawn: LpWithdrawn,
    }

    #[derive(Drop, starknet::Event)]
    pub struct LpDeposited {
        #[key]
        pub lp: ContractAddress,
        #[key]
        pub pair_id: felt252,
        pub amount: u256,
        pub shares_minted: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct LpWithdrawn {
        #[key]
        pub lp: ContractAddress,
        #[key]
        pub pair_id: felt252,
        pub shares_burned: u256,
        pub amount_received: u256,
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>, +Drop<TContractState>,
    > of InternalTrait<TContractState> {
        /// Supply LP collateral to a market
        /// Returns (shares_minted, updated_pool)
        fn supply_lp_collateral(
            ref self: ComponentState<TContractState>,
            pair_id: felt252,
            amount: u256,
            caller: ContractAddress,
            mut pool: LpPool,
            config: @ProtocolConfig,
            collateral_token: ContractAddress,
        ) -> (u256, LpPool) {
            assert(amount >= Constants::MIN_LP_DEPOSIT, Errors::BELOW_MIN_DEPOSIT);

            let shares_to_mint = if pool.total_shares == 0 {
                // First deposit - apply inflation protection
                assert(amount >= *config.min_first_lp_deposit, Errors::FIRST_DEPOSIT_TOO_SMALL);

                // Shares = amount - burned
                let shares = amount - *config.burned_shares_amount;

                // Total shares includes burned (owned by no one)
                pool.total_shares = amount;
                pool.total_collateral = amount;

                shares
            } else {
                // Normal proportional calculation using internal method
                let shares = Self::_calculate_shares_to_mint(
                    amount, pool.total_shares, pool.total_collateral,
                );

                pool.total_shares = pool.total_shares + shares;
                pool.total_collateral = pool.total_collateral + amount;

                shares
            };

            // Update LP position
            let mut position = self.lp_positions.read((caller, pair_id));
            position.shares = position.shares + shares_to_mint;
            position.last_deposit_time = get_block_timestamp();
            self.lp_positions.write((caller, pair_id), position);

            // Transfer tokens
            let token = IERC20Dispatcher { contract_address: collateral_token };
            let success = token.transfer_from(caller, get_contract_address(), amount);
            assert(success, Errors::TRANSFER_FROM_FAILED);

            self.emit(LpDeposited { lp: caller, pair_id, amount, shares_minted: shares_to_mint });

            (shares_to_mint, pool)
        }

        /// Withdraw LP collateral from a market
        /// Returns (withdrawal_amount, updated_pool)
        fn withdraw_lp_collateral(
            ref self: ComponentState<TContractState>,
            pair_id: felt252,
            shares: u256,
            caller: ContractAddress,
            mut pool: LpPool,
            collateral_token: ContractAddress,
        ) -> (u256, LpPool) {
            let mut position = self.lp_positions.read((caller, pair_id));
            assert(position.shares >= shares, Errors::INSUFFICIENT_SHARES);

            let current_time = get_block_timestamp();
            assert(
                current_time >= position.last_deposit_time + Constants::MIN_LP_COOLDOWN_SECONDS,
                Errors::LP_COOLDOWN_NOT_MET,
            );

            // Calculate withdrawal amount using internal method
            let withdrawal_amount = Self::_calculate_withdrawal_amount(
                shares, pool.total_shares, pool.total_collateral,
            );

            // Check available liquidity (not locked)
            let available = pool.total_collateral
                - pool.locked_for_fixed
                - pool.locked_for_floating;
            assert(withdrawal_amount <= available, Errors::EXCEEDS_AVAILABLE_LIQUIDITY);

            // Update LP position
            position.shares = position.shares - shares;
            self.lp_positions.write((caller, pair_id), position);

            // Update pool
            pool.total_shares = pool.total_shares - shares;
            pool.total_collateral = pool.total_collateral - withdrawal_amount;

            // Transfer tokens
            let token = IERC20Dispatcher { contract_address: collateral_token };
            let success = token.transfer(caller, withdrawal_amount);
            assert(success, Errors::TRANSFER_FAILED);

            self
                .emit(
                    LpWithdrawn {
                        lp: caller,
                        pair_id,
                        shares_burned: shares,
                        amount_received: withdrawal_amount,
                    },
                );

            (withdrawal_amount, pool)
        }

        /// Get LP position
        fn get_lp_position(
            self: @ComponentState<TContractState>, lp: ContractAddress, pair_id: felt252,
        ) -> LpPosition {
            self.lp_positions.read((lp, pair_id))
        }

        /// Get pool analytics
        fn get_pool_analytics(
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

        // ============================================================
        // ERC4626-LIKE VAULT READ FUNCTIONS
        // ============================================================

        /// Get the exchange rate: assets per share (scaled by 1e18 for precision)
        /// Returns how many assets (collateral) one share is worth
        fn exchange_rate(self: @ComponentState<TContractState>, pool: @LpPool) -> u256 {
            if *pool.total_shares == 0 {
                return Constants::PRECISION; // 1:1 when no shares exist
            }
            // exchange_rate = total_collateral * PRECISION / total_shares
            mul_div_down(*pool.total_collateral, Constants::PRECISION, *pool.total_shares)
        }

        /// Get total assets in the pool
        fn total_assets(self: @ComponentState<TContractState>, pool: @LpPool) -> u256 {
            *pool.total_collateral
        }

        /// Get available liquidity (not locked in swaps)
        fn available_liquidity(self: @ComponentState<TContractState>, pool: @LpPool) -> u256 {
            *pool.total_collateral - *pool.locked_for_fixed - *pool.locked_for_floating
        }

        /// Get total shares outstanding
        fn total_supply(self: @ComponentState<TContractState>, pool: @LpPool) -> u256 {
            *pool.total_shares
        }

        /// Convert assets to shares (how many shares for a given asset amount)
        /// Used for: "If I deposit X assets, how many shares do I get?"
        fn convert_to_shares(
            self: @ComponentState<TContractState>, assets: u256, pool: @LpPool,
        ) -> u256 {
            if *pool.total_shares == 0 || *pool.total_collateral == 0 {
                return assets; // 1:1 for first deposit
            }
            Self::_calculate_shares_to_mint(assets, *pool.total_shares, *pool.total_collateral)
        }

        /// Convert shares to assets (how many assets for a given share amount)
        /// Used for: "If I have X shares, how many assets are they worth?"
        fn convert_to_assets(
            self: @ComponentState<TContractState>, shares: u256, pool: @LpPool,
        ) -> u256 {
            if *pool.total_shares == 0 {
                return shares; // 1:1 when no shares
            }
            Self::_calculate_withdrawal_amount(shares, *pool.total_shares, *pool.total_collateral)
        }

        /// Preview deposit: how many shares would be minted for a deposit amount
        /// Includes protocol considerations (inflation protection for first deposit)
        fn preview_deposit(
            self: @ComponentState<TContractState>,
            assets: u256,
            pool: @LpPool,
            config: @ProtocolConfig,
        ) -> u256 {
            if *pool.total_shares == 0 {
                // First deposit: shares = assets - burned_shares_amount
                if assets < *config.min_first_lp_deposit {
                    return 0; // Would fail min requirement
                }
                assets - *config.burned_shares_amount
            } else {
                Self::_calculate_shares_to_mint(assets, *pool.total_shares, *pool.total_collateral)
            }
        }

        /// Preview withdraw: how many assets would be received for burning shares
        fn preview_withdraw(
            self: @ComponentState<TContractState>, shares: u256, pool: @LpPool,
        ) -> u256 {
            Self::_calculate_withdrawal_amount(shares, *pool.total_shares, *pool.total_collateral)
        }

        /// Preview redeem: alias for preview_withdraw (ERC4626 terminology)
        fn preview_redeem(
            self: @ComponentState<TContractState>, shares: u256, pool: @LpPool,
        ) -> u256 {
            self.preview_withdraw(shares, pool)
        }

        /// Maximum deposit amount allowed
        /// Returns u256 max since there's no explicit cap (utilization limits apply elsewhere)
        fn max_deposit(self: @ComponentState<TContractState>) -> u256 {
            // No explicit deposit cap - utilization limits are checked at swap time
            0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff_u256
        }

        /// Maximum withdrawal for an LP (based on their position and available liquidity)
        fn max_withdraw(
            self: @ComponentState<TContractState>,
            lp: ContractAddress,
            pair_id: felt252,
            pool: @LpPool,
        ) -> u256 {
            let position = self.lp_positions.read((lp, pair_id));
            if position.shares == 0 {
                return 0;
            }

            // Calculate what their shares are worth
            let position_value = Self::_calculate_withdrawal_amount(
                position.shares, *pool.total_shares, *pool.total_collateral,
            );

            // Available liquidity constraint
            let available = *pool.total_collateral
                - *pool.locked_for_fixed
                - *pool.locked_for_floating;

            // Return the lesser of position value and available liquidity
            if position_value < available {
                position_value
            } else {
                available
            }
        }

        /// Maximum shares that can be redeemed by an LP
        fn max_redeem(
            self: @ComponentState<TContractState>,
            lp: ContractAddress,
            pair_id: felt252,
            pool: @LpPool,
        ) -> u256 {
            let position = self.lp_positions.read((lp, pair_id));
            if position.shares == 0 {
                return 0;
            }

            // Calculate max withdrawal in assets
            let max_assets = self.max_withdraw(lp, pair_id, pool);

            // Convert back to shares (how many shares to burn for max_assets)
            if *pool.total_collateral == 0 || max_assets == 0 {
                return 0;
            }

            // shares = max_assets * total_shares / total_collateral (round down)
            let shares_for_max = mul_div_down(
                max_assets, *pool.total_shares, *pool.total_collateral,
            );

            // Cap at user's actual shares
            if shares_for_max < position.shares {
                shares_for_max
            } else {
                position.shares
            }
        }

        /// Check if cooldown period has passed for an LP
        fn is_cooldown_met(
            self: @ComponentState<TContractState>, lp: ContractAddress, pair_id: felt252,
        ) -> bool {
            let position = self.lp_positions.read((lp, pair_id));
            let current_time = get_block_timestamp();
            current_time >= position.last_deposit_time + Constants::MIN_LP_COOLDOWN_SECONDS
        }

        /// Get LP's share balance
        fn balance_of(
            self: @ComponentState<TContractState>, lp: ContractAddress, pair_id: felt252,
        ) -> u256 {
            self.lp_positions.read((lp, pair_id)).shares
        }

        // ============================================================
        // INTERNAL CALCULATION FUNCTIONS
        // ============================================================

        /// Calculate LP shares to mint (round DOWN - user gets less)
        fn _calculate_shares_to_mint(
            deposit: u256, total_shares: u256, total_collateral: u256,
        ) -> u256 {
            if total_shares == 0 || total_collateral == 0 {
                return deposit;
            }
            mul_div_down(deposit, total_shares, total_collateral)
        }

        /// Calculate collateral for LP withdrawal (round DOWN - user gets less)
        fn _calculate_withdrawal_amount(
            shares: u256, total_shares: u256, total_collateral: u256,
        ) -> u256 {
            if total_shares == 0 {
                return 0;
            }
            mul_div_down(shares, total_collateral, total_shares)
        }
    }
}
