#[starknet::contract]
mod ConcLiquidityVault {
    use starknet::{
        storage::{StoragePointerReadAccess, StoragePointerWriteAccess, Vec, VecTrait, MutableVecTrait},
        ContractAddress, get_contract_address, get_caller_address,
    };
    use openzeppelin::{
        security::{
            pausable::PausableComponent,
            reentrancyguard::ReentrancyGuardComponent
        },
        upgrades::upgradeable::UpgradeableComponent,
        introspection::src5::SRC5Component,
        token::erc20::{
            ERC20Component,
            ERC20HooksEmptyImpl,
            interface::{
                IERC20Mixin,
                ERC20ABIDispatcher,
                ERC20ABIDispatcherTrait
            }
        },
    };
    use ekubo::{
        types::{
            pool_price::PoolPrice,
            position::Position,
            i129::i129
        },
        interfaces::mathlib::{IMathLibDispatcherTrait, dispatcher as ekuboLibDispatcher}
    };
    use strkfarm_contracts::{
        helpers::{
            pow,
            ERC20Helper,
        },
        components::{
            common::CommonComp,
            swap::{AvnuMultiRouteSwap, AvnuMultiRouteSwapImpl}
        },
        interfaces::{
            oracle::IPriceOracleDispatcher,
            IEkuboPosition::{IEkuboDispatcher, IEkuboDispatcherTrait},
            IEkuboPositionsNFT::{IEkuboNFTDispatcher, IEkuboNFTDispatcherTrait},
            IEkuboCore::{
                IEkuboCoreDispatcher,
                IEkuboCoreDispatcherTrait,
                Bounds,
                PositionKey,
                PoolKey
            },
            IEkuboDistributor::{
                IEkuboDistributorDispatcherTrait, Claim, IEkuboDistributorDispatcher,
            }
        },
        strategies::cl_vault::interface::{
            *,
            Events::*
        },
    };

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: ReentrancyGuardComponent, storage: reng, event: ReentrancyGuardEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    // contains standard functions like pause/upgrade/permission assets etc.
    component!(path: CommonComp, storage: common, event: CommonCompEvent);

    #[abi(embed_v0)]
    impl ERC20MixinImpl = ERC20Component::ERC20MixinImpl<ContractState>;

    #[abi(embed_v0)]
    impl CommonCompImpl = CommonComp::CommonImpl<ContractState>;

    // Internal impls
    impl CommonInternalImpl = CommonComp::InternalImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;
    impl ReentrancyGuardInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        reng: ReentrancyGuardComponent::Storage,
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        #[substorage(v0)]
        common: CommonComp::Storage,
        // constants
        ekubo_positions_contract: IEkuboDispatcher,
        ekubo_positions_nft: ContractAddress,
        ekubo_core: ContractAddress,
        oracle: ContractAddress,
        // Changeable settings
        fee_settings: FeeSettings,
        managed_pools: Vec<ManagedPool>,
        // contract managed state
        sqrt_values: Vec<SqrtValues>, // sqrt values for each pool (same order as managed_pools)
        init_values: InitValues, // initial ratios for token distribution, responsible for setting the mathematical order of shares for new vaults
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        #[flat]
        ERC20Event: ERC20Component::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        #[flat]
        PausableEvent: PausableComponent::Event,
        #[flat]
        CommonCompEvent: CommonComp::Event,
        Deposit: Deposit,
        Withdraw: Withdraw,
        Rebalance: Rebalance,
        HandleFees: HandleFees,
        FeeSettings: FeeSettings,
        Harvest: HarvestEvent,
        PoolUpdated: PoolUpdated,
        EkuboPositionUpdated: EkuboPositionUpdated,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: ByteArray,
        symbol: ByteArray,
        access_control: ContractAddress,
        ekubo_positions_contract: ContractAddress,
        ekubo_positions_nft: ContractAddress,
        ekubo_core: ContractAddress,
        oracle: ContractAddress,
        fee_settings: FeeSettings,
        init_values: InitValues,
        managed_pools: Array<ManagedPool>,
    ) {
        self.erc20.initializer(name, symbol);
        self.common.initializer(access_control);
        self
            .ekubo_positions_contract
            .write(IEkuboDispatcher { contract_address: ekubo_positions_contract });

        // add all pools
        assert(managed_pools.len() != 0, 'empty pool list');
        let mut i = 0;
        while i != managed_pools.len() {
            let pool_ref = managed_pools.at(i);
            self._modify_pool(*pool_ref, true);
            i += 1;
        }

        self.ekubo_positions_nft.write(ekubo_positions_nft);
        self.ekubo_core.write(ekubo_core);
        self.oracle.write(oracle);
        assert(fee_settings.fee_bps <= 10000, 'invalid fee bps');
        self.fee_settings.write(fee_settings);
        assert(init_values.init0 != 0, 'invalid init0');
        assert(init_values.init1 != 0, 'invalid init1');
        self.init_values.write(init_values);
    }

    #[abi(embed_v0)]
    impl ExternalImpl of IClVault<ContractState> {
        /// @notice Deposits assets into the contract and mints corresponding shares.
        fn deposit(
            ref self: ContractState, amount0: u256, amount1: u256, receiver: ContractAddress
        ) -> u256 {
            // 
            self.common.assert_not_paused();
            let caller: ContractAddress = get_caller_address();
            assert(amount0 > 0 || amount1 > 0, 'amounts cannot be zero');
            let shares = self._process_deposit(amount0, amount1);
            // mint shares
            self.erc20.mint(receiver, shares);

            self
                .emit(
                    Deposit { 
                        sender: caller, 
                        owner: receiver, 
                        shares: shares,
                        amount0: amount0, 
                        amount1: amount1 
                    }
                );
            return shares;
        }

        /// @notice Withdraws assets by redeeming shares from the contract.
        fn withdraw(
            ref self: ContractState, shares: u256, receiver: ContractAddress
        ) -> MyPositions {
            self.common.assert_not_paused();
            let caller = get_caller_address();

            let max_shares = self.balance_of(caller);
            assert(shares <= max_shares, 'insufficient shares');

            // read positions before burning shares for correct calc
            let my_positions = self.convert_to_assets(shares);

            // burn shares
            self.erc20.burn(caller, shares);

            let mut i = 0;
            while i != self.managed_pools.len() {
                let pool = self.managed_pools[i].read();
                self.handle_fees(i);

                // withdraw from ekubo
                let position = *my_positions.positions.at(i.try_into().unwrap());
                let (amt0, amt1) = self._withdraw_position(position.liquidity, i);
                assert(amt0.into() == position.amount0, 'invalid amount0');
                assert(amt1.into() == position.amount1, 'invalid amount1');
                i += 1;
            }

            // transfer proceeds to receiver
            let pool_key = self.managed_pools[0].read().pool_key;
            ERC20Helper::transfer(pool_key.token0, receiver, my_positions.total_amount0);
            ERC20Helper::transfer(pool_key.token1, receiver, my_positions.total_amount1);

            self
                .emit(
                    Withdraw {
                        sender: caller,
                        receiver,
                        owner: receiver,
                        shares: shares,
                        amount0: my_positions.total_amount0,
                        amount1: my_positions.total_amount1
                    }
                );
            return my_positions;
        }

        /// @notice Converts given asset amounts into the corresponding number of shares.
        /// @dev no compulsion to use entire amount0 and amount1, can use partial amounts
        fn convert_to_shares(self: @ContractState, amount0: u256, amount1: u256) -> SharesInfo {
            self._convert_to_shares(amount0, amount1)
        }

        /// @notice Converts shares into the corresponding asset amounts.
        /// @dev Proportionally convert shares to assets across all pools
        fn convert_to_assets(self: @ContractState, shares: u256) -> MyPositions {
            let mut i = 0;
            let mut total_amount0 = 0;
            let mut total_amount1 = 0;
            let mut positions = ArrayTrait::<MyPosition>::new();
            let supply = self.total_supply();
            while i != self.managed_pools.len() {
                let liquidity = self._convert_to_liquidity(shares, i, supply);
                let (delta_amt0, delta_amt1) = self._calculate_liquidity_delta(i, liquidity);
                
                positions.append(MyPosition {
                    liquidity: liquidity,
                    amount0: delta_amt0.mag.into(),
                    amount1: delta_amt1.mag.into(),
                });
                total_amount0 += delta_amt0.mag.into();
                total_amount1 += delta_amt1.mag.into();
                i += 1;
            }
            return MyPositions {
                positions: positions,
                total_amount0: total_amount0,
                total_amount1: total_amount1
            };
        }

        /// @notice Returns the total ekubo liquidity of the pool.
        fn total_liquidity_per_pool(self: @ContractState, pool_index: u64) -> u256 {
            let pool = self.managed_pools[pool_index].read();
            let position_key = PositionKey {
                salt: pool.nft_id,
                owner: self.ekubo_positions_contract.read().contract_address,
                bounds: pool.bounds
            };
            let curr_position: Position = IEkuboCoreDispatcher {
                contract_address: self.ekubo_core.read()
            }
                .get_position(pool.pool_key, position_key);

            curr_position.liquidity.into()
        }

                /// @notice Retrieves the current position details from the Ekubo core contract.
        /// @dev This function fetches the position data using the contract's position key
        /// and pool key from the Ekubo core contract.
        /// @return curr_position The current position details.
        fn get_position(self: @ContractState, pool_index: u64) -> MyPosition {
            let pool = self.managed_pools[pool_index].read();
            let (range_amount0, range_amount1, range_liq) = self._get_range_amounts(pool);
            MyPosition {
                liquidity: range_liq.into(),
                amount0: range_amount0.into(),
                amount1: range_amount1.into(),
            }
        }

        fn get_positions(self: @ContractState) -> MyPositions {
            let mut positions = ArrayTrait::<MyPosition>::new();
            let mut i = 0;
            let mut total_amount0 = 0;
            let mut total_amount1 = 0;
            while i != self.managed_pools.len() {
                let position = self.get_position(i);
                positions.append(position);
                total_amount0 += position.amount0;
                total_amount1 += position.amount1;
                i += 1;
            }
            MyPositions { 
                positions: positions,
                total_amount0: total_amount0,
                total_amount1: total_amount1
            }
        }

        /// @notice Collects and handles fees generated by the contract.
        /// @dev This function retrieves token balances, collects strategy fees, deposits
        /// collected fees back into the liquidity pool, and emits a fee-handling event.
        fn handle_fees(ref self: ContractState, pool_index: u64) {
            self.common.assert_not_paused();
            let pool = self.managed_pools[pool_index].read();
            let this: ContractAddress = get_contract_address();
            let token0: ContractAddress = pool.pool_key.token0;
            let token1: ContractAddress = pool.pool_key.token1;

            let nft_id = pool.nft_id;
            let bounds = pool.bounds;
            let positions_disp = self.ekubo_positions_contract.read();
            
            let token_info = positions_disp.get_token_info(nft_id, pool.pool_key, bounds);
          
            let (fee0, fee1) = self._collect_strat_fee(pool);
            
            if (fee0 == 0 && fee1 == 0) {
                return;
            }

            // deposit fees
            // @dev This action may leave some unused balances in the contract
            // Adjusting these amounts to exact required amounts unnecessarily
            // overcomplicates the logic and not of significant benefit
            // - This is taken care during rebalance calls
            // which we plan to run at regular intervals
            // (every fews days once or dependening on the amount of fee)
            self._ekubo_deposit(this, fee0, fee1, this, pool_index);

            self
                .emit(
                    HandleFees {
                        token0_addr: token0,
                        token0_origin_bal: token_info.amount0.into(),
                        token0_deposited: token_info.fees0.into(),
                        token1_addr: token1,
                        token1_origin_bal: token_info.amount1.into(),
                        token1_deposited: token_info.fees1.into(),
                        pool_info: pool
                    }
                );
        }

        /// @notice Harvests rewards from the specified rewards contract.
        /// reward token (e.g. STRK) -> token0 and token1 
        fn harvest(
            ref self: ContractState,
            rewardsContract: ContractAddress,
            claim: Claim,
            proof: Span<felt252>,
            swapInfo1: AvnuMultiRouteSwap,
            swapInfo2: AvnuMultiRouteSwap
        ) {
            self.common.assert_not_paused();
            self.common.assert_relayer_role();

            // claim rewards
            let (rewardToken, mut reward_amt) = self._ekubo_harvest(rewardsContract, claim, proof);

            // collect fees
            let fee_settings = self.fee_settings.read();
            let fee_amount = reward_amt * fee_settings.fee_bps / 10000;
            if (fee_amount > 0) {
                ERC20Helper::transfer(rewardToken, fee_settings.fee_collector, fee_amount);
                reward_amt -= fee_amount;
            }

            // validate swap info
            // aim to swap 100% of STRK into token0 and token1
            let pool = self.managed_pools[0].read();
            let token0 = pool.pool_key.token0;
            let token1 = pool.pool_key.token1;
            assert(
                swapInfo1.token_from_address == rewardToken,
                'invalid token from address [1]'
            );
            assert(swapInfo1.token_to_address == token0, 'invalid token to address [1]');
            assert(
                swapInfo2.token_from_address == rewardToken,
                'invalid token from address [2]'
            );
            assert(swapInfo2.token_to_address == token1, 'invalid token to address [2]');
            assert(reward_amt > 0, 'No harvest amt');
            assert(
                swapInfo1.token_from_amount + swapInfo2.token_from_amount == reward_amt,
                'invalid reward token balance'
            );

            let mut token0_amt: u256 = swapInfo1.token_from_amount;
            let oracle = self._get_oracle_dispatcher();
            if (swapInfo1.token_from_amount > 0
                && swapInfo1.token_from_address != swapInfo1.token_to_address) {
                token0_amt = swapInfo1.swap(oracle);
            }
            let mut token1_amt: u256 = swapInfo2.token_from_amount;
            if (swapInfo2.token_from_amount > 0
                && swapInfo2.token_from_address != swapInfo2.token_to_address) {
                    token1_amt = swapInfo2.swap(oracle);
            }

            self
                .emit(
                    HarvestEvent {
                        rewardToken: rewardToken,
                        rewardAmount: reward_amt,
                        token0: token0,
                        token0Amount: token0_amt,
                        token1: token1,
                        token1Amount: token1_amt
                    }
                );
        }

        /// @notice Retrieves the current settings of the contract + pool info
        fn get_pool_settings(self: @ContractState, pool_index: u64) -> ClSettings {
            let pool = self.managed_pools[pool_index].read();
            ClSettings {
                ekubo_positions_contract: self.ekubo_positions_contract.read().contract_address,
                bounds_settings: pool.bounds,
                pool_key: pool.pool_key,
                ekubo_positions_nft: self.ekubo_positions_nft.read(),
                contract_nft_id: pool.nft_id,
                ekubo_core: self.ekubo_core.read(),
                oracle: self.oracle.read(),
                fee_settings: self.fee_settings.read()
            }
        }

        fn get_managed_pools(self: @ContractState) -> Array<ManagedPool> {
            let mut pools = ArrayTrait::<ManagedPool>::new();
            let mut i = 0;
            while i != self.managed_pools.len() {
                pools.append(self.managed_pools[i].read());
                i += 1;
            }

            pools
        }

        /// @notice Updates the fee settings of the contract.
        fn set_settings(ref self: ContractState, fee_settings: FeeSettings) {
            self.common.assert_governor_role();
            self.fee_settings.write(fee_settings);
            self.emit(fee_settings);
        }

        /// @notice Rebalances the liquidity position based on new bounds.
        /// @dev This function withdraws existing liquidity, adjusts token balances via swaps,
        ///      updates the position bounds, and redeposits liquidity.
        /// @param new_bounds The new lower and upper tick bounds for the position.
        /// @param swap_params Parameters for swapping tokens to balance liquidity before redeposit.
        fn rebalance_pool(ref self: ContractState, rebalance_params: RebalanceParams) {
            self.common.assert_relayer_role();
            assert(rebalance_params.rebal.len().into() == self.managed_pools.len(), 'invalid rebal len');
            // assert pool key checks
            let mut i = 0;

            // assert same pool keys (intend to only rebalance between same pool keys)
            while i != self.managed_pools.len() {
                let stored_pool = self.managed_pools[i].read();
                let input_pool_key = *rebalance_params.rebal.at(i.try_into().unwrap()).pool_key;
        
                assert(
                    stored_pool.pool_key == input_pool_key,
                    'pool_key mismatch'
                );
                i += 1;
            }

            i = 0;
            while i != self.managed_pools.len() {
                let pool = self.managed_pools[i].read();
                let rebal_params = *rebalance_params.rebal.at(i.try_into().unwrap());

                if (rebal_params.liquidity_burn == 0) {
                    // no intent to withdraw liquidity
                    i += 1;
                    continue;
                }

                // assert liquidity to withdraw is valid
                let pool_liq = self.total_liquidity_per_pool(pool_index: i);
                if rebal_params.liquidity_burn > pool_liq.try_into().unwrap() {
                    panic!("invalid liq remove at index {:?}", i);
                }

                let liq_to_withdraw = rebal_params.liquidity_burn.into();
                self._withdraw_position(liq_to_withdraw, i);
                i += 1;
            }
            
            // swap
            if rebalance_params.swap_params.token_from_amount > 0 {
                rebalance_params.swap_params.swap(self._get_oracle_dispatcher());
            }

            // mint liquidity
            i = 0;
            let this = get_contract_address();
            let caller = get_caller_address();
            while i != self.managed_pools.len() {
                let pool = self.managed_pools[i].read();
                let rebal_params = *rebalance_params.rebal.at(i.try_into().unwrap());

                if rebal_params.liquidity_mint == 0 {
                    // no intent to mint liquidity
                    i += 1;
                    continue;
                }

                // update pool bounds (further computations depend on the new bounds)
                let new_bounds = rebal_params.new_bounds;
                self._set_pool_data(ManagedPoolField::Bounds(new_bounds), i);
                self.sqrt_values[i].write(self._create_sqrt_values(new_bounds));

                // assert sufficient token balances
                let token0_bal = ERC20Helper::balanceOf(pool.pool_key.token0, this);
                let token1_bal = ERC20Helper::balanceOf(pool.pool_key.token1, this);
                let liquidity = rebal_params.liquidity_mint;
                let (delta_amt0, delta_amt1) = self._calculate_liquidity_delta(i, (liquidity).into());
                
                if (token0_bal.try_into().unwrap() < delta_amt0.mag) {
                    panic!("insufficient amt0 at index {:?}, required {:?}, available {:?}", i, delta_amt0.mag, token0_bal);
                }
                if (token1_bal.try_into().unwrap() < delta_amt1.mag) {
                    panic!("insufficient amt1 at index {:?}, required {:?}, available {:?}", i, delta_amt1.mag, token1_bal);
                }

                self._ekubo_deposit(
                    this, 
                    delta_amt0.mag.into(), 
                    delta_amt1.mag.into(),  
                    this, 
                    i
                );

                i += 1;
            }

            self
                .emit(
                    Rebalance {
                        actions: rebalance_params.rebal
                    }
                );
        }

        fn add_pool(ref self: ContractState, pool: ManagedPool) {
            self.common.assert_governor_role();
            self._modify_pool(pool, true);
        }

        fn remove_pool(ref self: ContractState, pool_index: u64) {
            self.common.assert_governor_role();
            let pool = self.managed_pools[pool_index].read();
            self._modify_pool(pool, false);
        }

        fn get_amount_delta(self: @ContractState, pool_index: u64, liquidity: u256) -> (u256, u256) {
            let (delta_amt0, delta_amt1) = self._calculate_liquidity_delta(pool_index, liquidity);
            (delta_amt0.mag.into(), delta_amt1.mag.into())
        }

        fn get_fee_settings(self: @ContractState) -> FeeSettings {
            self.fee_settings.read()
        }

        fn get_managed_pools_len(self: @ContractState) -> u64 {
            self.managed_pools.len()
        }

        fn get_managed_pool(self: @ContractState, index: u64) -> ManagedPool {
            self.managed_pools[index].read()
        }
    }

    #[generate_trait]
    pub impl InternalImpl of InternalTrait {
        fn get_sqrt_lower_upper(ref self: ContractState, bounds: Bounds) -> (u256, u256) {
            let sqrt_lower = ekuboLibDispatcher().tick_to_sqrt_ratio(bounds.lower);
            let sqrt_upper = ekuboLibDispatcher().tick_to_sqrt_ratio(bounds.upper);
            (sqrt_lower, sqrt_upper)
        }

        fn _create_sqrt_values(ref self: ContractState, bounds: Bounds) -> SqrtValues {
            let (sqrt_lower, sqrt_upper) = self.get_sqrt_lower_upper(bounds);
            SqrtValues { sqrt_lower: sqrt_lower, sqrt_upper: sqrt_upper }
        }

        fn _is_valid_token_pair(self: @ContractState, pool_key1: PoolKey, pool_key2: PoolKey) -> bool {
            let is_token0_equal = pool_key1.token0 == pool_key2.token0;
            let is_token1_equal = pool_key1.token1 == pool_key2.token1;
            return is_token0_equal && is_token1_equal;
        }

        fn _ekubo_harvest(ref self: ContractState, rewardsContract: ContractAddress, claim: Claim, proof: Span<felt252>) -> (ContractAddress, u256) {
            let distributor: IEkuboDistributorDispatcher = IEkuboDistributorDispatcher {
                contract_address: rewardsContract
            };
            let rewardToken: ContractAddress = distributor.get_token().contract_address;
            let rewardTokenDisp = ERC20ABIDispatcher { contract_address: rewardToken };
    
            if (proof.len() == 0) {
                return (rewardToken, 0);
            }
    
            let this = get_contract_address();
            let pre_bal = rewardTokenDisp.balanceOf(this);
            distributor.claim(claim, proof);
            let post_bal = rewardTokenDisp.balanceOf(this);
    
            // claim may not be exactly as requested, so we do bal diff check
            let amount = (post_bal - pre_bal);
            assert(amount > 0, 'No harvest');

            (rewardToken, amount)
        }

        fn _find_pool_index(
            self: @ContractState,
            pool_key: PoolKey,
            bounds: Bounds
        ) -> Option<u64> {
            let mut i = 0;
            while i != self.managed_pools.len() {
                let pool = self.managed_pools[i].read();
                if pool.pool_key == pool_key
                    && pool.bounds == bounds
                {
                    return Option::Some(i);
                }
                i += 1;
            }
            Option::None
        }

        fn _modify_pool(ref self: ContractState, pool: ManagedPool, is_add: bool) {
            if is_add {
                // Add pool logic
                // Check pool doesn't already exist
                let existing_index = self._find_pool_index(pool.pool_key, pool.bounds);
                assert(existing_index.is_none(), 'pool already exists');

                // Validate tokens match first pool
                if self.managed_pools.len() > 0 {
                    let pool1 = self.managed_pools[0].read();
                    assert(self._is_valid_token_pair(pool1.pool_key, pool.pool_key), 'invalid token pair');
                }

                // Add pool and calculate sqrt values
                self.managed_pools.push(pool);
                self.sqrt_values.push(self._create_sqrt_values(pool.bounds));

                // Emit event
                self.emit(
                    PoolUpdated {
                        pool_key: pool.pool_key,
                        bounds: pool.bounds,
                        pool_index: self.managed_pools.len() - 1,
                        is_add: true
                    }
                );
            } else {
                // Remove pool logic
                // Find pool index
                let pool_index_opt = self._find_pool_index(pool.pool_key, pool.bounds);
                assert(pool_index_opt.is_some(), 'pool does not exist');
                let pool_index = pool_index_opt.unwrap();

                // Check liquidity is zero
                let position_liquidity = self.total_liquidity_per_pool(pool_index);
                assert(position_liquidity == 0, 'liquidity must be zero');

                // Swap with last element
                let last_index = self.managed_pools.len() - 1;
                let last_pool = self.managed_pools[last_index].read();
                let last_sqrt = self.sqrt_values[last_index].read();
                if pool_index != last_index {
                    self.managed_pools[pool_index].write(last_pool);
                    self.sqrt_values[pool_index].write(last_sqrt);

                    self.emit(
                        PoolUpdated {
                            pool_key: pool.pool_key,
                            bounds: pool.bounds,
                            pool_index: pool_index,
                            is_add: false
                        }
                    );

                    // since its a swap, we need to emit the addition of the last pool
                    // and removal event below
                    self.emit(
                        PoolUpdated {
                            pool_key: last_pool.pool_key,
                            bounds: last_pool.bounds,
                            pool_index: pool_index,
                            is_add: true
                        }
                    );
                }

                // Remove last element
                self.managed_pools.pop();
                self.sqrt_values.pop();

                // emit removal of last pool
                self.emit(
                    PoolUpdated {
                        pool_key: last_pool.pool_key,
                        bounds: last_pool.bounds,
                        pool_index: last_index,
                        is_add: false
                    }
                );
            }
        }

        fn _set_pool_data(ref self: ContractState, field: ManagedPoolField, pool_index: u64) {
            let curr_pool = self.managed_pools[pool_index].read();
            let mut updated = curr_pool;
            match field {
                ManagedPoolField::Bounds(bounds) => {
                    updated.bounds = bounds;
                },
                ManagedPoolField::NftId(nft_id) => {
                    updated.nft_id = nft_id;
                },
            };
            self.managed_pools[pool_index].write(updated);
        }

        fn _get_range_amounts(self: @ContractState, pool: ManagedPool) -> (u128, u128, u128) {
            let positions_disp = self.ekubo_positions_contract.read();
            if pool.nft_id == 0 {
                return (0, 0, 0);
            }
            let pool_info = positions_disp.get_token_info(pool.nft_id, pool.pool_key, pool.bounds);
            let range_amount0 = pool_info.amount0;
            let range_amount1 = pool_info.amount1;
            let range_liq = pool_info.liquidity;

            (range_amount0, range_amount1, range_liq)
        }

        fn _pay_ekubo(
            ref self: ContractState, sender: ContractAddress, token: ContractAddress, amount: u256
        ) {
            let this = get_contract_address();
            let positions_disp = self.ekubo_positions_contract.read();
            if (this == sender) {
                ERC20Helper::transfer(token, positions_disp.contract_address, amount);
            } else {
                ERC20Helper::transfer_from(token, sender, positions_disp.contract_address, amount);
            }
        }

        fn _get_pool_price(self: @ContractState, pool_index: u64) -> PoolPrice {
            let disp = self.ekubo_positions_contract.read();
            let pool = self.managed_pools[pool_index].read();
            return disp.get_pool_price(pool.pool_key);
        }

        fn _get_oracle_dispatcher(self: @ContractState) -> IPriceOracleDispatcher {
            IPriceOracleDispatcher { contract_address: self.oracle.read() }
        }

        fn _calculate_liquidity_delta(
            self: @ContractState,
            pool_index: u64,
            liquidity: u256
        ) -> (i129, i129) {
            let current_sqrt_price = self._get_pool_price(pool_index).sqrt_ratio;
            let delta = ekuboLibDispatcher()
                .liquidity_delta_to_amount_delta(
                    current_sqrt_price,
                    i129 { mag: liquidity.try_into().unwrap(), sign: false },
                    self.sqrt_values[pool_index].read().sqrt_lower,
                    self.sqrt_values[pool_index].read().sqrt_upper
                );
            (delta.amount0, delta.amount1)
        }

        fn _calculate_shares_from_amounts(
            self: @ContractState,
            amount0: u256,
            amount1: u256,
            total_supply: u256,
            total_under0: u256,
            total_under1: u256
        ) -> u256 {
            let pool = self.managed_pools[0].read();
            let dec0 = ERC20Helper::decimals(pool.pool_key.token0);
            let dec1 = ERC20Helper::decimals(pool.pool_key.token1);
            let scale0: u256 = pow::ten_pow(18 - dec0.into());
            let scale1: u256 = pow::ten_pow(18 - dec1.into());

            // normalize incoming amounts
            let amount0_n = amount0 * scale0;
            let amount1_n = amount1 * scale1;

            if total_supply > 0 {
                let shares0 = (amount0_n * total_supply) / total_under0;
                let shares1 = (amount1_n * total_supply) / total_under1;
                if shares0 < shares1 { shares0 } else { shares1 }
            } else {
                // todo to review
                let init = self.init_values.read();
                let shares0 = if init.init0 > 0 {
                    amount0_n * 1_000_000_000_000_000_000_u256 / init.init0
                } else { 0 };
                let shares1 = if init.init1 > 0 {
                    amount1_n * 1_000_000_000_000_000_000_u256 / init.init1
                } else { 0 };
                if shares0 > 0 && shares1 > 0 {
                    if shares0 < shares1 { shares0 } else { shares1 }
                } else {
                    shares0 + shares1
                }
            }
        }

        fn _withdraw_position(ref self: ContractState, liquidity: u256, pool_index: u64) -> (u128, u128) {
            let disp = self.ekubo_positions_contract.read();
            let pool = self.managed_pools[pool_index].read();
            let old_liq = self.total_liquidity_per_pool(pool_index);
            let (amount0, amount1) = disp
                .withdraw(
                    pool.nft_id,
                    pool.pool_key,
                    pool.bounds,
                    liquidity.try_into().unwrap(),
                    0x00,
                    0x00,
                    false
                );

            let current_liq = self.total_liquidity_per_pool(pool_index);
            
            if current_liq == 0 {
                self.managed_pools[pool_index].write(
                    ManagedPool {
                        pool_key: pool.pool_key,
                        bounds: pool.bounds,
                        nft_id: 0
                    }
                );
            }

            if (old_liq - current_liq).into() != liquidity {
                let diff: felt252 = old_liq.try_into().unwrap() - current_liq.try_into().unwrap();
                panic!("invalid liquidity removed for index {:?} and diff {:?}", pool_index, diff);
            }

            self.emit(
                EkuboPositionUpdated {
                    nft_id: pool.nft_id,
                    pool_key: pool.pool_key,
                    bounds: pool.bounds,
                    amount0_delta: i129{ mag: amount0.try_into().unwrap(), sign: true },
                    amount1_delta: i129{ mag: amount1.try_into().unwrap(), sign: true },
                    liquidity_delta: i129{ mag: liquidity.try_into().unwrap(), sign: true }
                }
            );

            (amount0, amount1)
        }

        // @returns liquidity
        fn _ekubo_deposit(
            ref self: ContractState,
            sender: ContractAddress,
            amount0: u256,
            amount1: u256,
            receiver: ContractAddress,
            pool_index: u64 
        ) {
            let pool = self.managed_pools[pool_index].read();
            let pool_key = pool.pool_key;
            let token0 = pool_key.token0;
            let token1 = pool_key.token1;
            let positions_disp = self.ekubo_positions_contract.read();

            // send funds to ekubo
            self._pay_ekubo(sender, token0, amount0);
            self._pay_ekubo(sender, token1, amount1);

            let mut initial_position = MyPosition {
                liquidity: 0,
                amount0: 0,
                amount1: 0
            };
  
            let nft_id = pool.nft_id;
            if nft_id == 0 {
                let nft_id: u64 = IEkuboNFTDispatcher {
                    contract_address: self.ekubo_positions_nft.read()
                }
                    .get_next_token_id();
                self._set_pool_data(ManagedPoolField::NftId(nft_id), pool_index);
                positions_disp
                    .mint_and_deposit(pool.pool_key, pool.bounds, 0);
            } else {
                initial_position = self.get_position(pool_index);
                positions_disp
                    .deposit(nft_id, pool.pool_key, pool.bounds, 0);
            }
            
            // clear any unused tokens and send to receiver
            positions_disp.clear_minimum_to_recipient(token0, 0, receiver);
            positions_disp.clear_minimum_to_recipient(token1, 0, receiver);

            let final_position = self.get_position(pool_index);
            self.emit(
                EkuboPositionUpdated {
                    nft_id: nft_id,
                    pool_key: pool.pool_key,
                    bounds: pool.bounds,
                    amount0_delta: i129{ mag: (final_position.amount0 - initial_position.amount0).try_into().unwrap(), sign: false },
                    amount1_delta: i129{ mag: (final_position.amount1 - initial_position.amount1).try_into().unwrap(), sign: false },
                    liquidity_delta: i129{ mag: (final_position.liquidity - initial_position.liquidity).try_into().unwrap(), sign: false }
                }
            );
        }

        fn _collect_strat_fee(ref self: ContractState, pool: ManagedPool) -> (u256, u256) {
            // collect fees from ekubo positions
            let nft_id = pool.nft_id;
            if (nft_id == 0) {
                return (0, 0);
            }

            let pool_key = pool.pool_key;
            let bounds = pool.bounds;
            let token0 = pool_key.token0;
            let token1 = pool_key.token1;
            let (fee0, fee1) = self
                .ekubo_positions_contract
                .read()
                .collect_fees(nft_id, pool_key, bounds);

            let fee_settings = self.fee_settings.read();
            
            let bps =
            fee_settings.fee_bps;
            let collector = fee_settings.fee_collector;
            let fee_eth = (fee0.into() * bps) / 10000;
            let fee_wst_eth = (fee1.into() * bps) / 10000;

            // transfer to fee collector
            ERC20Helper::transfer(token0, collector, fee_eth);
            ERC20Helper::transfer(token1, collector, fee_wst_eth);

            // return remaining amounts
            (fee0.into() - fee_eth, fee1.into() - fee_wst_eth)
        }   

        fn _process_deposit(
            ref self: ContractState,
            amount0: u256,
            amount1: u256,
        ) -> u256 {
            let caller = get_caller_address();
            assert(amount0 > 0 || amount1 > 0, 'zero deposit');

            let SharesInfo { shares, user_level_positions, vault_level_positions } = self._convert_to_shares(amount0, amount1);
            assert(shares > 0, 'zero shares');

            let total_supply = self.total_supply();
            if total_supply > 0 {
                assert(vault_level_positions.total_amount0 > 0 || vault_level_positions.total_amount1 > 0, 'empty vault');
            }

            // allow first deposit without ekubo deposit to allow vault curator to 
            // call rebalance to add initial liquidity as they want. 
            // - subsequent deposits will follow the current liquidity to deposit proportionally
            if total_supply > 0 {
                let mut i = 0;
                while i != self.managed_pools.len() {
                    self.handle_fees(i); // optional
                    
                    let position = *vault_level_positions.positions.at(i.try_into().unwrap());
                    self._ekubo_deposit(
                        caller,
                        position.amount0,
                        position.amount1,
                        caller,
                        i
                    );
                    i += 1;
                } 
            }

            return shares;
        }

        /// @notice Converts given liquidity into shares.
        /// returns shares, user_level_positions, vault_level_positions
        fn _convert_to_shares(self: @ContractState, amount0: u256, amount1: u256) -> SharesInfo {
            let mut i = 0;
            let mut vault_total_amount0: u256 = 0;
            let mut vault_total_amount1: u256 = 0;
            let mut ranges = ArrayTrait::<MyPosition>::new();

            let total_supply = self.total_supply();

            // compute total amounts spread across all pools
            // - We shall divide user amounts proportionally to the range amounts
            while i != self.managed_pools.len() {
                let pool = self.managed_pools[i].read();
                let (range_amt0, range_amt1, range_liq) = self._get_range_amounts(pool);
                vault_total_amount0 += range_amt0.into();
                vault_total_amount1 += range_amt1.into();
                ranges.append(MyPosition {
                    liquidity: range_liq.into(),
                    amount0: range_amt0.into(),
                    amount1: range_amt1.into(),
                });

                // use pool 0 as ref liquidity to calculate shares
                if (i == 0 && range_liq == 0 && total_supply > 0) {
                    panic!("pool 0 has no liquidity");
                }

                i += 1;
            }

            let mut user_total_amount0 = 0_u256;
            let mut user_total_amount1 = 0_u256;
            let mut user_positions = ArrayTrait::<MyPosition>::new();

            if (total_supply == 0) {
                let shares = self._calculate_shares_from_amounts(
                    amount0,
                    amount1,
                    total_supply,
                    vault_total_amount0,
                    vault_total_amount1,
                );
                return SharesInfo {
                    shares: shares,
                    user_level_positions: MyPositions {
                        positions: user_positions,
                        total_amount0: user_total_amount0,
                        total_amount1: user_total_amount1,
                    },
                    vault_level_positions: MyPositions {
                        positions: ranges,
                        total_amount0: vault_total_amount0,
                        total_amount1: vault_total_amount1,
                    },
                };
            }

            let mut i = 0;
            let mut shares = 0_u256;
            while i != self.managed_pools.len() {
                let pool = self.managed_pools[i].read();
                let range_position = ranges.at(i.try_into().unwrap());
                let range_amt0 = range_position.amount0;
                let range_amt1 = range_position.amount1;
                let range_liq = range_position.liquidity;

                // divide user amount proportionally to the range amounts
                let deposit_amt0 = if vault_total_amount0 > 0 {
                    (amount0 * (*range_amt0).into()) / vault_total_amount0
                } else { 0 };
                let deposit_amt1 = if vault_total_amount1 > 0 {
                    (amount1 * (*range_amt1).into()) / vault_total_amount1
                } else { 0 };

                let user_new_liq0 = if *range_amt0 > 0 {
                    (*range_liq * deposit_amt0.try_into().unwrap()) / *range_amt0
                } else { 0 };
                let user_new_liq1 = if *range_amt1 > 0 {
                    (*range_liq * deposit_amt1.try_into().unwrap()) / *range_amt1
                } else { 0 };
                // use min of the two to avoid overflow
                let user_new_liq = if user_new_liq0 > 0 && user_new_liq1 > 0 {
                    if user_new_liq0 < user_new_liq1 { user_new_liq0 } else { user_new_liq1 }
                } else {
                    user_new_liq0 + user_new_liq1
                };

                // actual deposit amounts
                let user_actual_deposit0 = if *range_liq > 0 {
                    user_new_liq * *range_amt0 / *range_liq
                } else { 0 };
                let user_actual_deposit1 = if *range_liq > 0 {
                    user_new_liq * *range_amt1 / *range_liq
                } else { 0 };
                user_total_amount0 += user_actual_deposit0;
                user_total_amount1 += user_actual_deposit1;
                user_positions.append(MyPosition {
                    liquidity: user_new_liq,
                    amount0: user_actual_deposit0,
                    amount1: user_actual_deposit1,
                });

                // use pool 0 as ref liquidity to calculate shares
                if (i == 0) {
                    shares = self._calculate_shares_from_amounts(
                        deposit_amt0,
                        deposit_amt1,
                        total_supply,
                        vault_total_amount0,
                        vault_total_amount1,
                    );
                }

                i += 1;
            }

            SharesInfo {
                shares: shares,
                user_level_positions: MyPositions {
                    positions: user_positions,
                    total_amount0: user_total_amount0,
                    total_amount1: user_total_amount1,
                },
                vault_level_positions: MyPositions {
                    positions: ranges,
                    total_amount0: vault_total_amount0,
                    total_amount1: vault_total_amount1,
                },
            }
        }

        fn _convert_to_liquidity(self: @ContractState, shares: u256, pool_index: u64, supply: u256) -> u256 {
            if (supply == 0) {
                return supply;
            }

            let total_liquidity = self.total_liquidity_per_pool(pool_index);
            return (shares * total_liquidity.into()) / supply;
        }
    }
}
