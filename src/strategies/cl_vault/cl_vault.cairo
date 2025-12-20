#[starknet::contract]
mod ConcLiquidityVault {
    use core::{
        option::OptionTrait,
    };
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
            interface::IERC20Mixin,
            ERC20HooksEmptyImpl
        }
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
            safe_decimal_math,
            constants
        },
        components::{
            harvester::{
                harvester_lib::{
                    HarvestConfig,
                    HarvestConfigImpl,
                    HarvestHooksTrait,
                    HarvestBeforeHookResult
                },
                defi_spring_default_style::{
                    SNFStyleClaimSettings,
                    ClaimImpl as DefaultClaimImpl
                },
                defi_spring_ekubo_style::{
                    EkuboStyleClaimSettings,
                    ClaimImpl
                }
            },
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
            IEkuboDistributor::Claim
        },
        strategies::cl_vault::interface::{
            IClVault,
            FeeSettings,
            MyPosition,
            ClSettings,
            ManagedPool,
            SqrtValues,
            InitValues,
            ManagedPoolField,
            RebalanceParams
        }
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

    #[derive(Drop, starknet::Event)]
    struct Deposit {
        #[key]
        sender: ContractAddress,
        #[key]
        owner: ContractAddress,
        shares: u256,
        amount0: u256,
        amount1: u256
    }

    #[derive(Drop, starknet::Event)]
    struct Withdraw {
        #[key]
        sender: ContractAddress,
        #[key]
        receiver: ContractAddress,
        #[key]
        owner: ContractAddress,
        shares: u256,
        amount0: u256,
        amount1: u256
    }

    #[derive(Drop, Copy, starknet::Event)]
    pub struct HarvestEvent {
        #[key]
        pub rewardToken: ContractAddress,
        pub rewardAmount: u256,
        #[key]
        pub token0: ContractAddress,
        pub token0Amount: u256,
        #[key]
        pub token1: ContractAddress,
        pub token1Amount: u256
    }

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
        sqrt_values: Vec<SqrtValues>,  
        init_values: InitValues, // initial ratios for token distribution
        is_incentives_on: bool
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
        PoolAdded: PoolAdded
    }

    #[derive(Drop, starknet::Event)]
    pub struct Rebalance {
        old_bounds: Bounds,
        old_liquidity: u256,
        new_bounds: Bounds,
        new_liquidity: u256
    }

    #[derive(Drop, starknet::Event)]
    pub struct HandleFees {
        token0_addr: ContractAddress,
        token0_origin_bal: u256,
        token0_deposited: u256,
        token1_addr: ContractAddress,
        token1_origin_bal: u256,
        token1_deposited: u256,
        pool_info: ManagedPool
    }

    #[derive(Drop, starknet::Event)]
    pub struct PoolAdded {
        pool_key: PoolKey,
        bounds: Bounds
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
        assert(managed_pools.len() != 0, 'empty pool list');
        let pool0 = *managed_pools.at(0);
        let mut i = 0;
        while i != managed_pools.len() {
            let pool = *managed_pools.at(i);
            assert(pool.pool_key.token0 == pool0.pool_key.token0, 'invalid token0');
            assert(pool.pool_key.token1 == pool0.pool_key.token1, 'invalid token1');
            i += 1;
        }
        self.set_managed_pools(managed_pools);
        self.ekubo_positions_nft.write(ekubo_positions_nft);
        self.ekubo_core.write(ekubo_core);
        self.oracle.write(oracle);
        assert(fee_settings.fee_bps <= 10000, 'invalid fee bps');
        self.fee_settings.write(fee_settings);
        self.is_incentives_on.write(true);
        assert(init_values.init0 != 0, 'invalid init0');
        assert(init_values.init1 != 0, 'invalid init1');
        self.init_values.write(init_values);
    }

    #[abi(embed_v0)]
    impl ExternalImpl of IClVault<ContractState> {
        /// @notice Deposits assets into the contract and mints corresponding shares.
        /// @dev This function handles fees, calculates liquidity, mints shares,
        /// and deposits assets into Ekubo. It ensures that the deposited liquidity
        /// matches the expected amount.
        /// @param amount0 The amount of the first asset to deposit.
        /// @param amount1 The amount of the second asset to deposit.
        /// @param receiver The address that will receive the minted shares.
        /// @return shares The number of shares minted for the deposited liquidity.
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
        /// @dev This function ensures the caller has enough shares, calculates the assets to
        /// withdraw, handles fees, removes liquidity from the pool, transfers the withdrawn assets
        /// to the receiver, burns the shares, and updates the contract state accordingly.
        /// @param shares The number of shares to redeem.
        /// @param receiver The address that will receive the withdrawn assets.
        /// @return position A struct containing the withdrawn liquidity, amount0, and amount1.
        fn withdraw(
            ref self: ContractState, shares: u256, receiver: ContractAddress
        ) -> MyPosition {
            self.common.assert_not_paused();
            let caller = get_caller_address();

            let max_shares = self.balance_of(caller);
            assert(shares <= max_shares, 'insufficient shares');

            // burn shares
            // total supply 
            let supply = self.total_supply();
            self.erc20.burn(caller, shares);

            let mut i = 0;
            let mut total_amt0 = 0;
            let mut total_amt1 = 0;
            let mut liquidities = ArrayTrait::<u256>::new();
            while i != self.managed_pools.len() {
                let pool = self.managed_pools[i].read();
                self.handle_fees(i);
                let liquidity_to_withdraw = self._convert_to_liquidity(shares, i, supply);
                println!("liq to withdraw {:?}", liquidity_to_withdraw);

                let old_liq = self.get_position(i).liquidity;

                let (amt0, amt1) = self._withdraw_position(liquidity_to_withdraw, pool);

                println!("withdraw done");
                total_amt0 += amt0.into();
                total_amt1 += amt1.into();
                liquidities.append(liquidity_to_withdraw);

                let current_liq = self.get_position(i).liquidity;

                if current_liq == 0 {
                    self.managed_pools[i].write(
                        ManagedPool {
                            pool_key: pool.pool_key,
                            bounds: pool.bounds,
                            nft_id: 0
                        }
                    );
                }

                if (old_liq - current_liq).into() != liquidity_to_withdraw {
                    let mut diff = 0;
                    if old_liq > current_liq {
                        diff = old_liq - current_liq;
                    } else {
                        diff = current_liq - old_liq;
                    }
                    panic!("invalid liquidity removed for index {:?} and diff {:?}", 
                        i, diff
                    );
                }
                i += 1;
            }

            // transfer proceeds to receiver
            let pool_key = self.managed_pools[0].read().pool_key;
            ERC20Helper::transfer(pool_key.token0, receiver, total_amt0.into());
            ERC20Helper::transfer(pool_key.token1, receiver, total_amt1.into());

            self
                .emit(
                    Withdraw {
                        sender: caller,
                        receiver,
                        owner: receiver,
                        shares: shares,
                        amount0: total_amt0,
                        amount1: total_amt1
                    }
                );
            return MyPosition {
                liquidity: liquidities, amount0: total_amt0.into(), amount1: total_amt1.into()
            };
        }

        /// @notice Converts given asset amounts into the corresponding number of shares.
        /// @dev This function calculates the maximum liquidity based on the provided asset amounts
        ///      and then converts that liquidity into shares.
        /// @param amount0 The amount of the first asset.
        /// @param amount1 The amount of the second asset.
        /// @return shares The number of shares corresponding to the provided asset amounts.
        fn convert_to_shares(self: @ContractState, amount0: u256, amount1: u256) -> u256 {
            let mut i = 0;
            let mut total_amount0: u256 = 0;
            let mut total_amount1: u256 = 0;
            let mut ranges = ArrayTrait::<(u128, u128, u128)>::new();

            while i != self.managed_pools.len() {
                let pool = self.managed_pools[i].read();
                let (range_amt0, range_amt1, range_liq) = self.get_range_amounts(pool);
                total_amount0 += range_amt0.into();
                total_amount1 += range_amt1.into();
                ranges.append((range_amt0, range_amt1, range_liq));
                i += 1;
            }

            let mut shares: u256 = 0;
            while i != self.managed_pools.len() {
                let pool = self.managed_pools[i].read();
                let (range_amt0, range_amt1, range_liq) = ranges.at(i.try_into().unwrap());

                let deposit_amt0 = (amount0 * (*range_amt0).into()) / total_amount0;
                let deposit_amt1 = (amount1 * (*range_amt1).into()) / total_amount1;

                let user_new_liq = (*range_liq * deposit_amt0.try_into().unwrap()) / *range_amt0;

                let mut range_shares: u256 = 0;
                if self.total_supply() != 0 {
                    range_shares =
                        (user_new_liq.into() * self.total_supply()) / (*range_liq).into();
                } else {
                    let init_values = self.init_values.read();
                    let shares_from_token0 = if init_values.init0 != 0 {
                        deposit_amt0 * 1000000000000000000_u256 / init_values.init0
                    } else { 0 };
                    let shares_from_token1 = if init_values.init1 != 0 {
                        deposit_amt1 * 1000000000000000000_u256 / init_values.init1
                    } else { 0 };
                    range_shares = if shares_from_token0 != 0 && shares_from_token1 != 0 {
                        (shares_from_token0 + shares_from_token1) / 2
                    } else {
                        shares_from_token0 + shares_from_token1
                    };
                }

                shares += range_shares;
                i += 1;
            }

            shares
        }

        /// @notice Converts shares into the corresponding asset amounts.
        /// @dev This function calculates the equivalent liquidity for the given shares,
        ///      converts it to asset amounts using the current pool price, and ensures
        ///      the calculated amounts are valid.
        /// @param shares The number of shares to convert.
        /// @return position A struct containing the corresponding liquidity, amount0, and amount1.
        fn convert_to_assets(self: @ContractState, shares: u256) -> MyPosition {
            let mut i = 0;
            let mut amount0 = 0;
            let mut amount1 = 0;
            let mut liquidities = ArrayTrait::<u256>::new();
            // total suply and send to _convert_to_liquidity
            let supply = self.total_supply();
            while i != self.managed_pools.len() {
                let current_sqrt_price = self.get_pool_price(i).sqrt_ratio;
                let liquidity = self._convert_to_liquidity(shares, i, supply);
                let delta = ekuboLibDispatcher()
                    .liquidity_delta_to_amount_delta(
                        current_sqrt_price,
                        i129 { mag: liquidity.try_into().unwrap(), sign: false },
                        self.sqrt_values[i].read().sqrt_lower,
                        self.sqrt_values[i].read().sqrt_upper
                    );
                assert(!delta.amount0.sign, 'invalid amount0');
                assert(!delta.amount1.sign, 'invalid amount1');
                liquidities.append(liquidity);
                amount0 += delta.amount0.mag.into();
                amount1 += delta.amount1.mag.into();
            }
            return MyPosition {
                liquidity: liquidities, amount0: amount0, amount1: amount1
            };
        }

        /// @notice Returns the total liquidity of the contract.
        /// @dev This function retrieves the current position and returns its liquidity value.
        /// @return liquidity The total liquidity in the contract.
        fn total_liquidity_per_pool(self: @ContractState, pool_index: u64) -> u256 {
            let position = self.get_position(pool_index);
            position.liquidity.into()
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
            
            let (fee0, fee1) = self._collect_strat_fee(pool);
            
            if (fee0 == 0 && fee1 == 0) {
                return;
            }

            let token_info = positions_disp.get_token_info(nft_id, pool.pool_key, bounds);
            
            // deposit fees
            // @dev This action may leave some unused balances in the contract
            // Adjusting these amounts to exact required amounts unnecessarily
            // overcomplicates the logic and not of significant benefit
            // - This is taken care during rebalance/handle_unused calls
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
        /// @dev This function claims rewards using the provided claim data and proof,
        /// then swaps them based on the given swap information.
        /// @param rewardsContract The contract address from which rewards are claimed.
        /// @param claim The claim data for the rewards.
        /// @param proof The Merkle proof verifying the claim.
        /// @param swapInfo The swap information for converting harvested rewards.
        /// 
        /// harvest -> strk from strknet
        /// strk -> token0 and token1 
        /// liq -> deposit 
        fn harvest(
            ref self: ContractState,
            rewardsContract: ContractAddress,
            claim: Claim,
            proof: Span<felt252>,
            swapInfo1: AvnuMultiRouteSwap,
            swapInfo2: AvnuMultiRouteSwap
        ) {
            self.common.assert_not_paused();
            assert(self.is_incentives_on.read(), 'incentives are off');
            self.common.assert_relayer_role();

            let ekuboSettings = EkuboStyleClaimSettings { rewardsContract: rewardsContract, };
            let config = HarvestConfig {};
            // just dummy config, not used
            let snfSettings = SNFStyleClaimSettings {
                rewardsContract: 0.try_into().unwrap()
            };

            let rewardToken = constants::STRK_ADDRESS();
            let pre_bal = ERC20Helper::balanceOf(rewardToken, get_contract_address());
            config
                .simple_harvest(
                    ref self,
                    ekuboSettings,
                    claim,
                    proof,
                    snfSettings,
                    swapInfo1.clone(), // doesnt do anything anyways
                    IPriceOracleDispatcher { contract_address: self.oracle.read() }
                );
            let post_bal = ERC20Helper::balanceOf(rewardToken, get_contract_address());

            // validate swap info
            // aim to swap 100% of STRK into token0 and token1
            let pool = self.managed_pools[0].read();
            let token0 = pool.pool_key.token0;
            let token1 = pool.pool_key.token1;
            assert(
                swapInfo1.token_from_address == constants::STRK_ADDRESS(),
                'invalid token from address [1]'
            );
            assert(swapInfo1.token_to_address == token0, 'invalid token to address [1]');
            assert(
                swapInfo2.token_from_address == constants::STRK_ADDRESS(),
                'invalid token from address [2]'
            );
            assert(swapInfo2.token_to_address == token1, 'invalid token to address [2]');
            let strk_amt = post_bal - pre_bal;
            assert(strk_amt > 0, 'No harvest amt');
            assert(
                swapInfo1.token_from_amount + swapInfo2.token_from_amount == strk_amt,
                'invalid STRK balance'
            );

            let mut token0_amt: u256 = swapInfo1.token_from_amount;
            if (swapInfo1.token_from_amount > 0
                && swapInfo1.token_from_address != swapInfo1.token_to_address) {
                token0_amt = swapInfo1
                    .swap(IPriceOracleDispatcher { contract_address: self.oracle.read() });
            }
            println!("swap 1");
            let mut token1_amt: u256 = swapInfo2.token_from_amount;
            if (swapInfo2.token_from_amount > 0
                && swapInfo2.token_from_address != swapInfo2.token_to_address) {
                    token1_amt = swapInfo2
                    .swap(IPriceOracleDispatcher { contract_address: self.oracle.read() });
            }
            println!("swap 2");

            self
                .emit(
                    HarvestEvent {
                        rewardToken: constants::STRK_ADDRESS(),
                        rewardAmount: strk_amt,
                        token0: token0,
                        token0Amount: token0_amt,
                        token1: token1,
                        token1Amount: token1_amt
                    }
                );
        }

        /// @notice Retrieves the current position details from the Ekubo core contract.
        /// @dev This function fetches the position data using the contract's position key
        /// and pool key from the Ekubo core contract.
        /// @return curr_position The current position details.
        fn get_position(self: @ContractState, pool_index: u64) -> Position {
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

            curr_position
        }

        /// @notice Retrieves the current settings of the contract.
        /// @dev This function reads various contract settings including fee settings, bounds, pool
        /// key, and oracle.
        /// @return ClSettings Struct containing the contract's current settings.
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
        /// @dev Only the contract owner can call this function to modify fee settings.
        /// @param fee_settings The new fee settings to be applied.
        fn set_settings(ref self: ContractState, fee_settings: FeeSettings) {
            self.common.assert_governor_role();
            self.fee_settings.write(fee_settings);
            self.emit(fee_settings);
        }

        fn set_incentives_off(ref self: ContractState) {
            self.common.assert_governor_role();
            self.is_incentives_on.write(false);
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

            while i != self.managed_pools.len() {
                let stored_pool = self.managed_pools[i].read();
                let input_pool_key = *rebalance_params.rebal.at(i.try_into().unwrap()).pool_key; // Add pool_key to RangeInstruction
        
                assert(stored_pool.pool_key.token0 == input_pool_key.token0, 'pool_key mismatch token0');
                assert(stored_pool.pool_key.token1 == input_pool_key.token1, 'pool_key mismatch token1');
                assert(stored_pool.pool_key.fee == input_pool_key.fee, 'pool_key mismatch fee');
                assert(stored_pool.pool_key.tick_spacing == input_pool_key.tick_spacing, 'pool_key mismatch tick_spacing');
                assert(stored_pool.pool_key.extension == input_pool_key.extension, 'pool_key mismatch extension');
        
                i += 1;
            }

            i = 0;
            while i != self.managed_pools.len() {
                let pool = self.managed_pools[i].read();
                let pool_liq = self.get_position(i).liquidity;
                if pool_liq == 0 {
                    // do some stuff
                    println!("zero liq");
                    i += 1;
                    continue;
                }
                let params = *rebalance_params.rebal.at(i.try_into().unwrap());
                if params.liquidity_burn == 0 {
                    i += 1;
                    continue;
                }
                let mut liq_to_withdraw = 0;
                if params.liquidity_burn > pool_liq {
                    println!("liq req {:?}", params.liquidity_burn)
                    panic!("invalid liq requested at index {:?}", 
                        i
                    );
                }
                if params.liquidity_burn <= pool_liq {
                    liq_to_withdraw = pool_liq;
                } else {
                    liq_to_withdraw = *rebalance_params.rebal.at(i.try_into().unwrap()).liquidity_burn;
                }
                // if po0. liq > rebalance_params.burns.at(i).liquidit ... panic-> index 
 
                self._withdraw_position(liq_to_withdraw.into(), pool);
                i += 1;
            }
            println!("withdraw done");
            
            // swap
            if rebalance_params.is_swap {
                rebalance_params.swap_params.swap(IPriceOracleDispatcher { contract_address: self.oracle.read() });
            }
            println!("swap done");

            i = 0;
            let this = get_contract_address();
            let caller = get_caller_address();
            while i != self.managed_pools.len() {
                let pool = self.managed_pools[i].read();
                if *rebalance_params.rebal.at(i.try_into().unwrap()).liquidity_mint == 0 {
                    i += 1;
                    continue;
                }
                let token0_bal = ERC20Helper::balanceOf(pool.pool_key.token0, this);
                println!("token0 bal {:?}", token0_bal);
                let token1_bal = ERC20Helper::balanceOf(pool.pool_key.token1, this);
                println!("token1 bal {:?}", token1_bal);

                let curr_sqrt_price = self.get_pool_price(i).sqrt_ratio;
                let liquidity = rebalance_params.rebal.at(i.try_into().unwrap()).liquidity_mint;
                let delta = ekuboLibDispatcher()
                    .liquidity_delta_to_amount_delta(
                        curr_sqrt_price,
                        i129 { mag: *liquidity.try_into().unwrap(), sign: false },
                        self.sqrt_values[i].read().sqrt_lower,
                        self.sqrt_values[i].read().sqrt_upper
                    );
                assert(!delta.amount0.sign, 'invalid amount0');
                assert(!delta.amount1.sign, 'invalid amount1');
                println!("invalid 1");
                println!("rebal amount 0 {:?}", delta.amount0.mag);
                println!("rebal amount 1 {:?}", delta.amount1.mag);
                
                if rebalance_params.is_swap {
                    assert(token0_bal.try_into().unwrap() > delta.amount0.mag, 'invalid amount0');
                    assert(token1_bal.try_into().unwrap() > delta.amount1.mag, 'invalid amount1');
                    println!("invalid 2");
                }

                let new_bounds = rebalance_params.rebal.at(i.try_into().unwrap()).new_bounds;
                self.set_pool_data(ManagedPoolField::Bounds(*new_bounds), i);

                let (sqrt_lower, sqrt_upper) = self.get_sqrt_lower_upper(*new_bounds);
                let sqrt_struct = SqrtValues { sqrt_lower: sqrt_lower, sqrt_upper: sqrt_upper };
                self.sqrt_values[i].write(sqrt_struct);

                let mut user = this;
                if rebalance_params.is_swap {
                    user = this;
                } else {
                    user = caller;
                }
                self._ekubo_deposit(
                    user, 
                    delta.amount0.mag.into(), 
                    delta.amount1.mag.into(),  
                    user, 
                    i
                );

                i += 1;
            }

            println!("deposit done");

            // self
            //     .emit(
            //         Rebalance {
            //             old_bounds,
            //             old_liquidity: old_position.liquidity.into(),
            //             new_bounds,
            //             new_liquidity: new_position.liquidity.into()
            //         }
            //     );
        }

        /// @notice Handles any unused token balances by swapping them before redepositing
        /// liquidity.
        /// @dev This function ensures that the majority of token balances are used efficiently
        /// before deposit.
        /// @param swap_params Parameters for swapping tokens to balance liquidity before redeposit.
        fn handle_unused(ref self: ContractState, swap_params: AvnuMultiRouteSwap, pool_index: u64) {
            self.common.assert_relayer_role();
            let this = get_contract_address();
            let pool = self.managed_pools[pool_index].read();
            let pool_key = pool.pool_key;
            assert(
                swap_params.token_from_address == pool_key.token0
                    || swap_params.token_from_address == pool_key.token1,
                'invalid swap params [1]'
            );
            assert(
                swap_params.token_to_address == pool_key.token0
                    || swap_params.token_to_address == pool_key.token1,
                'invalid swap params [2]'
            );

            // Perform swap before deposit to adjust balances
            swap_params.swap(IPriceOracleDispatcher { contract_address: self.oracle.read() });

            // Deposit remaining balances
            let token0_bal = ERC20Helper::balanceOf(pool_key.token0, this);
            let token1_bal = ERC20Helper::balanceOf(pool_key.token1, this);
            self._ekubo_deposit(this, token0_bal, token1_bal, this, pool_index);

            // Assert that most of the balance is used
            let token0_bal_new = ERC20Helper::balanceOf(pool_key.token0, this);
            let token1_bal_new = ERC20Helper::balanceOf(pool_key.token1, this);
            assert(
                safe_decimal_math::is_under_by_percent_bps(token0_bal_new, token0_bal, 1),
                'invalid token0 balance'
            );
            assert(
                safe_decimal_math::is_under_by_percent_bps(token1_bal_new, token1_bal, 1),
                'invalid token1 balance'
            );
        }

        fn add_pool(ref self: ContractState, pool: ManagedPool) {
            self.common.assert_governor_role();
            let pool1 = self.managed_pools[0].read();
            assert(pool1.pool_key.token0 == pool.pool_key.token0, 'invalid token0');
            assert(pool1.pool_key.token1 == pool.pool_key.token1, 'invalid token1');
            self.managed_pools.push(pool);
        }

        fn remove_pool(ref self: ContractState, pool_index: u64) {
            self.common.assert_governor_role();
            let mut i = 0;
            while i != self.managed_pools.len() {
                if i == (self.managed_pools.len() - 1) {
                    self.managed_pools.pop();
                } 
                if i == pool_index {
                    let pool = self.managed_pools[i + 1].read();
                    self.managed_pools[i].write(pool);
                }
                i += 1;
            }
        }

        fn get_amount_delta(self: @ContractState, pool_index: u64, liquidity: u256) -> (u256, u256) {
            let pool = self.managed_pools[pool_index].read();
            let current_sqrt_price = self.get_pool_price(pool_index).sqrt_ratio;
            let delta = ekuboLibDispatcher()
                .liquidity_delta_to_amount_delta(
                    current_sqrt_price,
                    i129 { mag: liquidity.try_into().unwrap(), sign: false },
                    self.sqrt_values[pool_index].read().sqrt_lower,
                    self.sqrt_values[pool_index].read().sqrt_upper
                );
                
            (delta.amount0.mag.into(), delta.amount1.mag.into())
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

        fn set_managed_pools(ref self: ContractState, managed_pools: Array<ManagedPool>) {
            let mut i = 0;
            while i != managed_pools.len() {
                let pool_ref = managed_pools.at(i);
                self.managed_pools.push(*pool_ref);
                let (sqrt_lower, sqrt_upper) = self.get_sqrt_lower_upper(*pool_ref.bounds);
                let sqrt_value = SqrtValues {
                    sqrt_lower: sqrt_lower,
                    sqrt_upper: sqrt_upper
                };
                self.sqrt_values.push(sqrt_value);
                i += 1;

                self.emit(
                    PoolAdded {
                        pool_key: *pool_ref.pool_key,
                        bounds: *pool_ref.bounds
                    }
                );
            }
        }

        fn set_pool_data(ref self: ContractState, field: ManagedPoolField, pool_index: u64) {
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

        fn get_range_amounts(self: @ContractState, pool: ManagedPool) -> (u128, u128, u128) {
            let mut range_amount0 = 0;
            let mut range_amount1 = 0;
            let mut range_liq = 0;
            let positions_disp = self.ekubo_positions_contract.read();
            println!("check");
            if pool.nft_id == 0 {
                return (0, 0, 0);
            }
            let pool_info = positions_disp.get_token_info(pool.nft_id, pool.pool_key, pool.bounds);
            println!("check");
            range_amount0 = pool_info.amount0;
            range_amount1 = pool_info.amount1;
            range_liq = pool_info.liquidity;

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

        fn get_pool_price(self: @ContractState, pool_index: u64) -> PoolPrice {
            let disp = self.ekubo_positions_contract.read();
            let pool = self.managed_pools[pool_index].read();
            return disp.get_pool_price(pool.pool_key);
        }

        fn _withdraw_position(ref self: ContractState, liquidity: u256, pool: ManagedPool) -> (u128, u128) {
            let disp = self.ekubo_positions_contract.read();
            println!("withdrawn position");
            return disp
                .withdraw(
                    pool.nft_id,
                    pool.pool_key,
                    pool.bounds,
                    liquidity.try_into().unwrap(),
                    0x00,
                    0x00,
                    false
                );
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
            println!("ekubo payed");
  
            let nft_id = pool.nft_id;
            if nft_id == 0 {
                println!("nft id 0");
                let nft_id: u64 = IEkuboNFTDispatcher {
                    contract_address: self.ekubo_positions_nft.read()
                }
                    .get_next_token_id();
                println!("nft id {:?}", nft_id);
                self.set_pool_data(ManagedPoolField::NftId(nft_id), pool_index);
                positions_disp
                    .mint_and_deposit(pool.pool_key, pool.bounds, 0);
            } else {
                println!("nft id not zero");
                positions_disp
                    .deposit(nft_id, pool.pool_key, pool.bounds, 0);
            }
            // clear any unused tokens and send to receiver
            positions_disp.clear_minimum_to_recipient(token0, 0, receiver);
            positions_disp.clear_minimum_to_recipient(token1, 0, receiver);
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

            let pool = self.managed_pools[0].read();
            let dec0 = ERC20Helper::decimals(pool.pool_key.token0);
            let dec1 = ERC20Helper::decimals(pool.pool_key.token1);
            println!("dec0 {:?}", dec0);
            println!("dec1 {:?}", dec1);

            let scale0: u256 = pow::ten_pow(18 - dec0.into());
            let scale1: u256 = pow::ten_pow(18 - dec1.into());

            // normalize incoming amounts
            let amount0_n = amount0 * scale0;
            let amount1_n = amount1 * scale1;

            let mut total_under0: u256 = 0;
            let mut total_under1: u256 = 0;

            let mut ranges = ArrayTrait::<(u128, u128, u128)>::new();

            let mut i = 0;
            while i != self.managed_pools.len() {
                let pool = self.managed_pools[i].read();
                let (amt0, amt1, liq) = self.get_range_amounts(pool);
                println!("amount0 {:?}", amt0);
                println!("amount1 {:?}", amt1);

                total_under0 += amt0.into() * scale0;
                total_under1 += amt1.into() * scale1;

                ranges.append((amt0, amt1, liq));
                i += 1;
            }
            println!("get ranges");

            let ts = self.total_supply();
            let mut shares: u256 = 0;

            if ts > 0 {
                println!("enter supply not 0");
                assert(total_under0 > 0 || total_under1 > 0, 'empty vault');

                let mut shares0: u256 = 0;
                let mut shares1: u256 = 0;

                shares0 = (amount0_n * ts) / total_under0;
                shares1 = (amount1_n * ts) / total_under1;

                // if only one token deposited, use that shares
                if shares0 > 0 && shares1 > 0 {
                    shares = if shares0 < shares1 { shares0 } else { shares1 };
                } else {
                    shares = shares0 + shares1;
                }
            } else {
                // FIRST MINT
                println!("enter total supply 0");
                let init = self.init_values.read();

                let mut shares0: u256 = 0;
                let mut shares1: u256 = 0;

                if init.init0 > 0 {
                    shares0 = (amount0_n * 1_000_000_000_000_000_000_u256) / init.init0;
                }
                if init.init1 > 0 {
                    shares1 = (amount1_n * 1_000_000_000_000_000_000_u256) / init.init1;
                }

                if shares0 > 0 && shares1 > 0 {
                    shares = if shares0 < shares1 { shares0 } else { shares1 };
                } else {
                    shares = shares0 + shares1;
                }
                println!("shares to mint {:?}", shares);
            }

            assert(shares > 0, 'zero shares');

            let total_shares_before = ts;
            i = 0;

            let condition1 = ts > 0;
            let (amt0, amt1, liq) = ranges[0];
            let condition2 = ts > 0 && *liq == 0;

            if condition1 || condition2 {
                println!("1st 2nd deposit cond pass");
                while i != self.managed_pools.len() {
                    self.handle_fees(i); // optional
                    
                    let (amt0, amt1, liq) = ranges.at(i.try_into().unwrap());
                    
                    // proportion of this range
                    let total_under0_scale = total_under0 / scale0;
                    let total_under1_scale = total_under1 / scale1;
                    let dep0 = if total_under0 > 0 {
                        (amount0 * (*amt0).into()) / total_under0_scale
                    } else { 0 };
                    
                    let dep1 = if total_under1 > 0 {
                        (amount1 * (*amt1).into()) / total_under1_scale
                    } else { 0 };
                    
                    println!("deposit0 {:?}", dep0);
                    println!("deposit1 {:?}", dep1);
                    
                    self._ekubo_deposit(
                        caller,
                        dep0,
                        dep1,
                        caller,
                        i
                    );
                    println!("deposit done ");
                    i += 1;
                } 
            }

            return shares;
        }

        fn _convert_to_shares(self: @ContractState, liquidity: u256, pool_index: u64) -> u256 {
            let supply = self.total_supply();
            if (supply == 0) {
                return liquidity;
            }
            let position = self.get_position(pool_index);
            let total_liquidity = position.liquidity;
            return (liquidity * supply) / total_liquidity.into();
        }

        fn _convert_to_liquidity(self: @ContractState, shares: u256, pool_index: u64, supply: u256) -> u256 {
            if (supply == 0) {
                return supply;
            }

            println!("shares {:?}", shares);
            
            let position = self.get_position(pool_index);
            let total_liquidity = position.liquidity;
            println!("liquidity {:?}", total_liquidity);
            println!("supply {:?}", supply);

            return (shares * total_liquidity.into()) / supply;
        }
    }

    /// hooks defining before and after actions for the harvest function
    impl HarvestHooksImpl of HarvestHooksTrait<ContractState> {
        fn before_update(ref self: ContractState) -> HarvestBeforeHookResult {
            // dont do any swap here
            // returning STRK address will do nothing, just claim STRK and leaves it
            // The handling is anyways done in the harvest function after simple_harvest call
            HarvestBeforeHookResult { baseToken: constants::STRK_ADDRESS() }
        }

        fn after_update(ref self: ContractState, token: ContractAddress, amount: u256) {
            let fee_amount = amount * self.fee_settings.read().fee_bps / 10000;
            if (fee_amount > 0) {
                ERC20Helper::transfer(token, self.fee_settings.read().fee_collector, fee_amount);
            }
            // leave the rest in the contract, will be handled by the harvest function
        }
    }
}
