use starknet::ContractAddress;
use strkfarm_contracts::interfaces::IEkuboCore::Bounds;
use strkfarm_contracts::components::swap::AvnuMultiRouteSwap;

#[starknet::interface]
pub trait IClVaultRebalancer<TContractState> {
    fn rebalance(
        ref self: TContractState,
        vault_address: ContractAddress,
        price_change_swap_params: AvnuMultiRouteSwap,
        required_bounds_after_price_change: Bounds,
        simulate_price_change: bool,
        rebalance_swap_params: AvnuMultiRouteSwap,
        new_bounds: Bounds,
        simulate_rebalance: bool,
        sell_swap_params: AvnuMultiRouteSwap,
        receiver: ContractAddress
    );

    fn arbitrage(
        ref self: TContractState,
        buy_swap_params: AvnuMultiRouteSwap,
        sell_swap_params: AvnuMultiRouteSwap,
        receiver: ContractAddress,
        min_gain_bps: u128
    );
}

#[starknet::contract]
pub mod ClVaultRebalancer {
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use strkfarm_contracts::interfaces::IEkuboCore::{Bounds, PoolKey, PositionKey, IEkuboCoreDispatcher, IEkuboCoreDispatcherTrait};
    use strkfarm_contracts::components::swap::{AvnuMultiRouteSwap, AvnuMultiRouteSwapTrait};
    use strkfarm_contracts::strategies::cl_vault::interface::{IClVaultDispatcher, IClVaultDispatcherTrait};
    use strkfarm_contracts::helpers::ERC20Helper;
    use strkfarm_contracts::interfaces::oracle::{IPriceOracleDispatcher};
    use strkfarm_contracts::helpers::constants;
    use strkfarm_contracts::unaudited::IFlashloan::{IFlash, IVesuDispatcher, IVesuDispatcherTrait, IVesuCallback};
    use strkfarm_contracts::interfaces::IEkuboPosition::{IEkuboDispatcher, IEkuboDispatcherTrait};
    use strkfarm_contracts::interfaces::IEkuboPositionsNFT::{IEkuboNFTDispatcher, IEkuboNFTDispatcherTrait};
    use strkfarm_contracts::helpers::pow;
    use strkfarm_contracts::components::ekuboSwap::{EkuboSwapStruct, ekuboSwapImpl};
    use strkfarm_contracts::components::ekuboSwap::{IRouterDispatcher};
    use strkfarm_contracts::interfaces::IERC4626::{
        IERC4626, IERC4626Dispatcher, IERC4626DispatcherTrait
    };
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait, ILocker};
    use strkfarm_contracts::helpers::constants::{
      EKUBO_CORE
    };
    use ekubo::types::delta::{Delta};

    #[storage]
    pub struct Storage {}

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        Rebalanced: Rebalanced,
    }

    #[derive(Copy, Drop, Serde)]
    struct SwapResult {
        delta: Delta,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Rebalanced {
        #[key]
        pub vault: ContractAddress,
        #[key]
        pub caller: ContractAddress,
        pub old_bounds: Bounds,
        pub new_bounds: Bounds,
    }

    #[derive(Drop, Clone, Serde)]
    pub struct RebalanceParams {
        pub vault_address: ContractAddress,
        pub price_change_swap_params: AvnuMultiRouteSwap,
        pub required_bounds_after_price_change: Bounds,
        pub simulate_price_change: bool,
        pub rebalance_swap_params: AvnuMultiRouteSwap,
        pub new_bounds: Bounds,
        pub simulate_rebalance: bool,
        pub sell_swap_params: AvnuMultiRouteSwap,
        pub nft_id: u64, // Added to track the NFT ID created during liquidity addition
        pub liq: u128, // Added to track the liquidity added
        pub caller: ContractAddress, // Added to track the caller
    }

    #[derive(Drop, Clone, Serde)]
    pub struct ArbitrageParams {
        pub buy_swap_params: AvnuMultiRouteSwap,
        pub sell_swap_params: AvnuMultiRouteSwap,
        pub receiver: ContractAddress,
        pub min_gain_bps: u128,
    }

    pub fn flashloan_callback<TState, impl TIFlash: IFlash<TState>, impl TDrop: Drop<TState>,>(
        ref self: TState,
        core: ICoreDispatcher,
        token: ContractAddress,
        flash_amount: u128,
        calldata: Span<felt252>
    ) -> Span<felt252> {
        // take flash loan
        let this = get_contract_address();
        core.withdraw(token, this, flash_amount);

        // do stuff with the flash loan
        IFlash::use_flash_loan(ref self, token, flash_amount, calldata);

        // repay flash loan
        ERC20Helper::approve(token, core.contract_address, flash_amount.into());
        core.pay(token);

        // return as 0 delta
        let amount: u128 = 0;
        let delta = Delta { amount0: amount.into(), amount1: amount.into() };
        // Serialize our output type into the return data
        let swap_result = SwapResult { delta };
        let mut arr: Array<felt252> = ArrayTrait::new();
        Serde::serialize(@swap_result, ref arr);
        arr.span()
    }

    // Implement ILocker for Ekubo flash loan callbacks
    #[abi(embed_v0)]
    impl LockerImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            /// println!("Received ekubo lock");

            // First element should be the flash loan amount
            let mut data_array = data;
            let flash_amount_felt: felt252 = *data_array.pop_front().unwrap();
            let flash_amount: u128 = flash_amount_felt.try_into().unwrap();
            assert(flash_amount > 0, 'EkFlash: Invalid flash amount');
            
            // Second element should be the token address
            let token_felt: felt252 = *data_array.pop_front().unwrap();
            let token: ContractAddress = token_felt.try_into().unwrap();
            
            // Call the flash loan callback with remaining data
            flashloan_callback(
                ref self,
                ICoreDispatcher { contract_address: EKUBO_CORE() },
                token,
                flash_amount,
                data_array // Remaining calldata
            )
        }
    }

    // handles logic of using flashloan
    impl IFlashImpl of IFlash<ContractState> {
        fn use_flash_loan(
            ref self: ContractState, token: ContractAddress, flash_amount: u128, calldata: Span<felt252>
        ) {
            /// println!("Using flashloan");
            let mut span_array = calldata;
            let action = *span_array.pop_front().unwrap();
            if (action == 1) {
                let deserialized_struct: RebalanceParams = Serde::<RebalanceParams>::deserialize(ref span_array).unwrap();
                let vault_address = deserialized_struct.vault_address;
                let price_change_swap_params = deserialized_struct.price_change_swap_params;
                let old_bounds = deserialized_struct.required_bounds_after_price_change;
                let rebalance_swap_params = deserialized_struct.rebalance_swap_params;
                let new_bounds = deserialized_struct.new_bounds;
                let sell_swap_params = deserialized_struct.sell_swap_params;
                let nft_id = deserialized_struct.nft_id;
                let liq = deserialized_struct.liq;
                let caller = deserialized_struct.caller;
                self._rebalance(
                    vault_address,
                    price_change_swap_params,
                    old_bounds,
                    deserialized_struct.simulate_price_change,
                    rebalance_swap_params,
                    new_bounds,
                    deserialized_struct.simulate_rebalance,
                    sell_swap_params,
                    nft_id,
                    liq,
                    caller
                );
            } else if (action == 2) {
                // handle arbitrage
                let deserialized_struct: ArbitrageParams = Serde::<ArbitrageParams>::deserialize(ref span_array).unwrap();
                let buy_swap_params = deserialized_struct.buy_swap_params;
                let sell_swap_params = deserialized_struct.sell_swap_params;
                let receiver = deserialized_struct.receiver;
                let min_gain_bps = deserialized_struct.min_gain_bps;
                self._arbitrage(
                    buy_swap_params,
                    sell_swap_params,
                    receiver,
                    min_gain_bps
                );
            } else {
                assert(false, 'Invalid action for flash loan');
            }
        }
    }

    #[abi(embed_v0)]
    impl ClVaultRebalancerImpl of super::IClVaultRebalancer<ContractState> {
        fn rebalance(
            ref self: ContractState,
            vault_address: ContractAddress,
            
            // move price params
            price_change_swap_params: AvnuMultiRouteSwap,
            required_bounds_after_price_change: Bounds,
            simulate_price_change: bool,

            // rebalance params
            rebalance_swap_params: AvnuMultiRouteSwap,
            new_bounds: Bounds,
            simulate_rebalance: bool,

            // This is the swap to close books and sell xSTRK
            sell_swap_params: AvnuMultiRouteSwap,
            receiver: ContractAddress
        ) {
            let caller = get_caller_address();
            
            // Get the vault dispatcher
            let vault = IClVaultDispatcher { contract_address: vault_address };
            let old_bounds = vault.get_settings().bounds_settings;

            let from_token = price_change_swap_params.token_from_address;
            let to_token = price_change_swap_params.token_to_address;
            let from_amount = price_change_swap_params.token_from_amount;

            // Step 1: Add small liquidity to Ekubo to ensure the price change can be executed
            let pool_key = vault.get_settings().pool_key;
            /// println!("Adding base liquidity");
            let (nft_id, liq) = self._add_ekubo_liquidity(
                pool_key,
                new_bounds
            );

            // serialise the parameters for flash loan
            let myStruct = RebalanceParams {
                vault_address,
                price_change_swap_params,
                required_bounds_after_price_change,
                simulate_price_change,
                rebalance_swap_params,
                new_bounds,
                simulate_rebalance,
                sell_swap_params,
                nft_id, // This will be set after adding liquidity
                liq, // This will be set after adding liquidity
                caller
            };

            // Call flash loan 
            /// println!("Calling flash loan");
            /// println!("Amount: {:?}", from_amount);
            /// println!("Token: {:?}", from_token);
            let mut calldata: Array<felt252> = array![];
            from_amount.low.serialize(ref calldata);
            from_token.serialize(ref calldata);
            calldata.append(1); // Append action type
            myStruct.serialize(ref calldata);
            ICoreDispatcher {
                contract_address: constants::EKUBO_CORE()
            }.lock(calldata.span());

            // Step 4: Send any remaining funds back to receiver
            /// println!("Returning remaining funds to receiver");
            self._return_remaining_funds(receiver, from_token);
            self._return_remaining_funds(receiver, to_token);

            // Emit rebalanced event
            self.emit(Event::Rebalanced(Rebalanced {
                vault: vault_address,
                caller,
                old_bounds,
                new_bounds,
            }));
        }

        fn arbitrage(
            ref self: ContractState,
            buy_swap_params: AvnuMultiRouteSwap,
            sell_swap_params: AvnuMultiRouteSwap,
            receiver: ContractAddress,
            min_gain_bps: u128
        ) {
            let from_token = buy_swap_params.token_from_address;
            let to_token = buy_swap_params.token_to_address;
            let from_amount = buy_swap_params.token_from_amount;
            assert(from_token != to_token, 'From and to tokens must be diff');
            assert(from_amount > 0, 'Buy swap amt <= 0');

            // Init the flash loan
            let arbParam = ArbitrageParams {
                buy_swap_params,
                sell_swap_params,
                receiver,
                min_gain_bps
            };

            let mut calldata: Array<felt252> = array![];
            from_amount.low.serialize(ref calldata);
            from_token.serialize(ref calldata);
            calldata.serialize(ref calldata);
            calldata.append(2); // Append action type
            arbParam.serialize(ref calldata);
            ICoreDispatcher {
                contract_address: constants::EKUBO_CORE()
            }.lock(calldata.span());

            // Return any remaining funds to the receiver
            self._return_remaining_funds(receiver, from_token);
            self._return_remaining_funds(receiver, to_token);
        }
    }

    #[generate_trait]
    pub impl InternalImpl of InternalTrait {
        fn _return_remaining_funds(ref self: ContractState, recipient: ContractAddress, token: ContractAddress) {
            let this = get_contract_address();
            let balance = ERC20Helper::balanceOf(token, this);
            if balance > 0 {
                ERC20Helper::transfer(token, recipient, balance);
            }
        }

        fn _rebalance(
            ref self: ContractState,
            vault_address: ContractAddress,

            // move price
            price_change_swap_params: AvnuMultiRouteSwap,
            required_bounds_after_price_change: Bounds,
            simulate_price_change: bool,

            // rebalance prams
            rebalance_swap_params: AvnuMultiRouteSwap,
            new_bounds: Bounds,
            simulate_rebalance: bool,

            // close books
            sell_swap_params: AvnuMultiRouteSwap,
            nft_id: u64,
            liq: u128,
            caller: ContractAddress
        ) {
            let vault = IClVaultDispatcher { contract_address: vault_address };
            let this = get_contract_address();
           
            // Step 0: Add small liquidity to Ekubo to ensure the price change can be executed
            let pool_key = vault.get_settings().pool_key;
            /// println!("Calling _rebalance");
            // Step 1: Execute price change swap to move ekubo pool price
            // This ensures the new bounds will be valid for the rebalance
            if price_change_swap_params.token_from_amount > 0 {
                // Execute the price change swap
                // let oracle = IPriceOracleDispatcher { contract_address: constants::ORACLE_OURS() };
                // price_change_swap_params.swap(oracle);
                let ekuboStruct = EkuboSwapStruct {
                    core: ICoreDispatcher { contract_address: constants::EKUBO_CORE(), },
                    router: IRouterDispatcher { contract_address: constants::EKUBO_ROUTER(), }
                };
                ekuboStruct.swap(price_change_swap_params);

                let pool_price = IEkuboDispatcher { contract_address: constants::EKUBO_POSITIONS() }
                .get_pool_price(pool_key);
                assert(pool_price.tick >= required_bounds_after_price_change.lower, 'Price chng did not reach lower');
                assert(pool_price.tick <= required_bounds_after_price_change.upper, 'Price chng did not reach upper');
            }

            assert(!simulate_price_change, 'Price change simulation done');

            // Step 2: Call the vault's rebalance function
            let total_supply = ERC20Helper::total_supply(vault.contract_address);
            let assetInfoBefore = vault.convert_to_assets(total_supply);
            let summary_before = self._summarize_position(
                assetInfoBefore.amount0,
                assetInfoBefore.amount1
            );

            vault.rebalance(new_bounds, rebalance_swap_params);
            assert(!simulate_rebalance, 'Rebalance simulation done');

            // Step 4: Withdraw any positions created during the rebalance
            let (amt0, amt1) = self._withdraw_position(
                nft_id,
                pool_key,
                new_bounds,
                liq
            );

            // Step 5: Swap xSTRK to STRK
            let xSTRKBal = ERC20Helper::balanceOf(constants::XSTRK_ADDRESS(), this);

            // settle funds used for initial LP
            assert(xSTRKBal >= amt0.into(), 'xSTRK balance too low');
            ERC20Helper::transfer(
                constants::XSTRK_ADDRESS(),
                caller,
                amt0.into() // Send xSTRK to caller
            );
            let xSTRKBal = xSTRKBal - amt0.into(); // Update balance after transfer

            if xSTRKBal > 0 {
                let mut _sell_swap_params = sell_swap_params.clone();
                _sell_swap_params.token_from_amount = xSTRKBal; // Sell 100% of xSTRK balance

                // Swap
                _sell_swap_params.swap(IPriceOracleDispatcher { contract_address: constants::ORACLE_OURS() });
            }

            let STRKBal = ERC20Helper::balanceOf(constants::STRK_ADDRESS(), this);
            assert(STRKBal >= amt1.into(), 'STRK bal after reb is too low');
            // Send the LP STRK to the caller
            ERC20Helper::transfer(
                constants::STRK_ADDRESS(),
                caller,
                amt1.into() // Send all STRK except the base amount
            );

            let assetInfo = vault.convert_to_assets(total_supply);
            let summary_after = self._summarize_position(
                assetInfo.amount0,
                assetInfo.amount1
            );
            assert(summary_after >= summary_before, 'Rebalance did not yield profit');
        }

        fn _arbitrage(
            ref self: ContractState,
            buy_swap_params: AvnuMultiRouteSwap,
            sell_swap_params: AvnuMultiRouteSwap,
            receiver: ContractAddress,
            min_gain_bps: u128
        ) {
            // Ensure the buy swap params are valid
            assert(buy_swap_params.token_from_amount > 0, 'Buy swap amt <= 0');
            let to_token = buy_swap_params.token_to_address;
            let from_token = buy_swap_params.token_from_address;
            let from_amount = buy_swap_params.token_from_amount;
            assert(sell_swap_params.token_from_address == to_token, 'Sell swap token mismatch');
            assert(sell_swap_params.token_to_address == from_token, 'Sell swap token mismatch');

            // Execute the buy swap
            buy_swap_params.swap(IPriceOracleDispatcher { contract_address: constants::ORACLE_OURS() });

            // Execute the sell swap
            let balance = ERC20Helper::balanceOf(to_token, get_contract_address());
            let mut _sell_swap_params = sell_swap_params.clone();
            _sell_swap_params.token_from_amount = balance; // Sell all of the bought token
            _sell_swap_params.swap(IPriceOracleDispatcher { contract_address: constants::ORACLE_OURS() });

            let balance_after = ERC20Helper::balanceOf(from_token, get_contract_address());
            assert(balance_after > from_amount, 'Arbitrage did not yield profit');
            let profit = balance_after - from_amount;
            let gain_bps = (profit * 10000) / from_amount; // Calculate gain in basis points
            assert(gain_bps >= min_gain_bps.into(), 'Arbitrage gain below minimum');
        }

        /// @notice Adds liquidity to Ekubo for a given pool key, amounts, and bounds
        /// @param pool_key The pool key to add liquidity to
        /// @param amount0 The amount of token0 to add
        /// @param amount1 The amount of token1 to add
        /// @param bounds The price bounds for the liquidity position
        /// @return The amount of liquidity added
        fn _add_ekubo_liquidity(
            ref self: ContractState,
            pool_key: PoolKey,
            bounds: Bounds
        ) -> (u64, u128) {
            let this = get_contract_address();
            let caller = get_caller_address();
            let ekubo_positions = IEkuboDispatcher { contract_address: constants::EKUBO_POSITIONS() };
            
            // just small amount is enough to to ensure position is created
            // this is required to ensure price change can stop at the price we want
            let amount0 = 100 * pow::ten_pow(ERC20Helper::decimals(pool_key.token0).into());
            let amount1 = 100 * pow::ten_pow(ERC20Helper::decimals(pool_key.token1).into());

            // Get tokens from pool key
            let token0 = pool_key.token0;
            let token1 = pool_key.token1;
            
            // Transfer tokens to Ekubo positions contract
            ERC20Helper::transfer_from(token0, caller, constants::EKUBO_POSITIONS(), amount0);
            ERC20Helper::transfer_from(token1, caller, constants::EKUBO_POSITIONS(), amount1);

            // Get liquidity before deposit to calculate the added amount
            let nft_dispatcher = IEkuboNFTDispatcher { contract_address: constants::EKUBO_POSITIONS_NFT() };
            let nft_id = nft_dispatcher.get_next_token_id();
            
            // Mint and deposit liquidity
            ekubo_positions.mint_and_deposit(pool_key, bounds, 0);
            
            // Clear any unused tokens back to this
            ekubo_positions.clear_minimum_to_recipient(token0, 0, this);
            ekubo_positions.clear_minimum_to_recipient(token1, 0, this);
            
            // Get the position to determine liquidity added
            let position_key = PositionKey {
                salt: nft_id,
                owner: constants::EKUBO_POSITIONS(),
                bounds: bounds
            };
            
            let core_dispatcher = IEkuboCoreDispatcher { contract_address: constants::EKUBO_CORE() };
            let position = core_dispatcher.get_position(pool_key, position_key);
            
            (nft_id, position.liquidity)
        }

        fn _withdraw_position(
            ref self: ContractState,
            nft_id: u64,
            pool_key: PoolKey,
            bounds_settings: Bounds,
            liquidity: u128
        ) -> (u128, u128) {
            let ekubo_positions = IEkuboDispatcher { contract_address: constants::EKUBO_POSITIONS() };
            return ekubo_positions
                .withdraw(
                    nft_id,
                    pool_key,
                    bounds_settings,
                    liquidity,
                    0x00,
                    0x00,
                    true
                );
        }

        // Only works for xSTRK/STRK
        fn _summarize_position(
            self: @ContractState,
            amount0: u256, // xSTRK
            amount1: u256 // STRK
        ) -> u256 {
            let xSTRK = constants::XSTRK_ADDRESS();
            let assets = IERC4626Dispatcher { contract_address: xSTRK }
                .convert_to_assets(amount0);
            return amount1 + assets;
        }
    }
}