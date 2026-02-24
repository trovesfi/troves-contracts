#[cfg(test)]
pub mod test_cl_vault {
    use strkfarm_contracts::strategies::cl_vault::interface::{
        IClVaultDispatcher, IClVaultDispatcherTrait, FeeSettings, 
        InitValues, SqrtValues, ManagedPoolField, ManagedPool
    };
    use snforge_std::{
        declare, ContractClassTrait, start_cheat_caller_address, stop_cheat_caller_address,
        start_cheat_block_number_global
    };
    use snforge_std::{DeclareResultTrait};
    use starknet::{ContractAddress, get_contract_address, class_hash::class_hash_const,};
    use strkfarm_contracts::helpers::constants;
    use strkfarm_contracts::strategies::cl_vault::interface::ClSettings;
    use strkfarm_contracts::components::ekuboSwap::{EkuboSwapStruct, ekuboSwapImpl};
    use strkfarm_contracts::helpers::ERC20Helper;
    use strkfarm_contracts::interfaces::IEkuboCore::{
        IEkuboCoreDispatcher, IEkuboCoreDispatcherTrait, Bounds, PoolKey, PositionKey
    };
    use strkfarm_contracts::interfaces::IEkuboPositionsNFT::{
        IEkuboNFTDispatcher, IEkuboNFTDispatcherTrait
    };
    use strkfarm_contracts::interfaces::IEkuboPosition::{IEkuboDispatcher, IEkuboDispatcherTrait};
    use ekubo::interfaces::core::{ICoreDispatcher};
    use strkfarm_contracts::components::ekuboSwap::{IRouterDispatcher};
    use ekubo::types::i129::{i129};
    use starknet::contract_address::contract_address_const;
    use openzeppelin::utils::serde::SerializedAppend;
    use strkfarm_contracts::helpers::pow;
    use strkfarm_contracts::interfaces::ERC4626Strategy::Settings;
    use strkfarm_contracts::components::swap::{AvnuMultiRouteSwap, Route};
    use strkfarm_contracts::components::swap::{get_swap_params};
    use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
    use strkfarm_contracts::helpers::safe_decimal_math;
    use strkfarm_contracts::tests::utils as test_utils;
    use strkfarm_contracts::components::harvester::reward_shares::{
        IRewardShareDispatcher, IRewardShareDispatcherTrait
    };
    use strkfarm_contracts::interfaces::IEkuboDistributor::{Claim};

    fn get_pool_key() -> PoolKey {
        let poolkey = PoolKey {
            token0: constants::WST_ADDRESS(),
            token1: constants::ETH_ADDRESS(),
            fee: 34028236692093847977029636859101184,
            tick_spacing: 200,
            extension: contract_address_const::<0x00>()
        };

        poolkey
    }

    fn get_pool_key_xstrk() -> PoolKey {
        let poolkey = PoolKey {
            token0: constants::XSTRK_ADDRESS(),
            token1: constants::STRK_ADDRESS(),
            fee: 34028236692093847977029636859101184,
            tick_spacing: 200,
            extension: contract_address_const::<0x00>()
        };

        poolkey
    }

    fn get_bounds() -> Bounds {
        let bounds = Bounds {
            lower: i129 { mag: 160000, sign: false, }, upper: i129 { mag: 180000, sign: false, },
        };

        bounds
    }

    fn get_bounds_xstrk() -> Bounds {
        let bounds = Bounds {
            lower: i129 { mag: 16000, sign: false, }, upper: i129 { mag: 16600, sign: false, },
        };

        bounds
    }

    fn get_pool() -> ManagedPool {
        ManagedPool {
            pool_key: get_pool_key(),
            bounds: get_bounds(),
            nft_id: 0
        }
    }

    fn get_xstrk_pool() -> ManagedPool {
        ManagedPool {
            pool_key: self.get_pool_key_xstrk(),
            bounds: get_bounds_xstrk(),
            nft_id: 0
        }
    }

    fn get_managed_pools() -> Array<ManagedPool> {
        let mut managed_pools = ArrayTrait::<ManagedPool>::new(); 
        let pool1 = get_pool();
        managed_pools.append(pool1);
        let xstrk_pool = get_xstrk_pool();
        managed_pools.append(xstrk_pool);

        managed_pools
    }

    fn ekubo_swap(
        route: Route, from_token: ContractAddress, to_token: ContractAddress, from_amount: u256
    ) {
        let ekubo = get_ekubo_settings();
        let mut route_array = ArrayTrait::<Route>::new();
        route_array.append(route);
        let swap_params = get_swap_params(
            from_token: from_token,
            from_amount: from_amount,
            to_token: to_token,
            to_amount: 0,
            to_min_amount: 0,
            routes: route_array
        );
        ekubo.swap(swap_params);
    }

    fn deploy_cl_vault() -> (IClVaultDispatcher, ERC20ABIDispatcher) {
        let accessControl = test_utils::deploy_access_control();
        let clVault = declare("ConcLiquidityVault").unwrap().contract_class();
        let poolkey1 = get_pool_key();
        let poolkey2 = get_pool_key_xstrk();

        let bounds1 = get_bounds();
        let bounds2 = get_bounds_xstrk();
        
        let init_values = InitValues {
            init0: pow::ten_pow(18),
            init1: 2 * pow::ten_pow(18),
        };

        let managed_pools = get_managed_pools();

        let fee_bps = 1000;
        let name: ByteArray = "uCL_token";
        let symbol: ByteArray = "UCL";
        let mut calldata: Array<felt252> = array![];
        calldata.append_serde(name);
        calldata.append_serde(symbol);
        calldata.append(accessControl.into());
        calldata.append(constants::EKUBO_POSITIONS().into());
        calldata.append(constants::EKUBO_POSITIONS_NFT().into());
        calldata.append(constants::EKUBO_CORE().into());
        calldata.append(constants::ORACLE_OURS().into());
        let fee_settings = FeeSettings {
            fee_bps: fee_bps, fee_collector: constants::EKUBO_FEE_COLLECTOR()
        };
        fee_settings.serialize(ref calldata);
        init_values.serialize(ref calldata);
        managed_pools.serialize(ref calldata);
        let (address, _) = clVault.deploy(@calldata).expect('ClVault deploy failed');

        return (
            IClVaultDispatcher { contract_address: address },
            ERC20ABIDispatcher { contract_address: address },
        );
    }

    fn vault_init(amount: u256) {
        let ekubo_user = constants::EKUBO_USER_ADDRESS();
        let this: ContractAddress = get_contract_address();
        /// println!("vault_init:this: {:?}", this);
        start_cheat_caller_address(constants::ETH_ADDRESS(), ekubo_user);
        ERC20Helper::transfer(constants::ETH_ADDRESS(), this, amount);
        stop_cheat_caller_address(constants::ETH_ADDRESS());
        /// println!("amount {:?}", amount);

        start_cheat_caller_address(constants::WST_ADDRESS(), ekubo_user);
        ERC20Helper::transfer(constants::WST_ADDRESS(), this, amount);
        stop_cheat_caller_address(constants::WST_ADDRESS());
        /// println!("amount {:?}", amount);
    }

    fn vault_init_xstrk_pool(amount: u256) {
        let ekubo_user = constants::VESU_SINGLETON_ADDRESS();
        let this: ContractAddress = get_contract_address();

        start_cheat_caller_address(constants::STRK_ADDRESS(), ekubo_user);
        ERC20Helper::transfer(constants::STRK_ADDRESS(), this, amount);
        stop_cheat_caller_address(constants::STRK_ADDRESS());
        start_cheat_caller_address(constants::XSTRK_ADDRESS(), ekubo_user);
        ERC20Helper::transfer(constants::XSTRK_ADDRESS(), this, amount);
        stop_cheat_caller_address(constants::XSTRK_ADDRESS());
    }

    fn ekubo_deposit() -> (IClVaultDispatcher, u256) {
        let amount = 10 * pow::ten_pow(18);
        let this = get_contract_address();

        let (clVault, _) = deploy_cl_vault();
        // nft id 0 check
        vault_init(amount * 2);

        ERC20Helper::approve(constants::ETH_ADDRESS(), clVault.contract_address, amount_eth_wst * 2);
        ERC20Helper::approve(constants::WST_ADDRESS(), clVault.contract_address, amount_eth_wst * 2);

        let expected_shares = clVault.convert_to_shares(amount, amount);
        let shares = cl_vault.deposit(amount, amount ,this);

        assert(shares1 > 0, 'invalid shares minted');
        assert(shares1 == expected_shares1, 'invalid shares minted');
        return (clVault, shares1);
    }

    fn ekubo_withdraw(clVault: IClVaultDispatcher, withdraw_amount: u256) {
        let this = get_contract_address();
        let vault_shares = ERC20Helper::balanceOf(clVault.contract_address, this);
        let eth_before_withdraw = ERC20Helper::balanceOf(constants::ETH_ADDRESS(), this);
        let wst_before_withdraw = ERC20Helper::balanceOf(constants::WST_ADDRESS(), this);
        clVault.withdraw(withdraw_amount, this);

        let shares_bal = ERC20Helper::balanceOf(clVault.contract_address, this);
        assert(shares_bal == (vault_shares - withdraw_amount), 'invalid shares minted');
        let partial_eth_bal = ERC20Helper::balanceOf(constants::ETH_ADDRESS(), this);
        let partial_wst_bal = ERC20Helper::balanceOf(constants::WST_ADDRESS(), this);
        assert(partial_eth_bal > eth_before_withdraw, 'eth not withdrawn');
        assert(partial_wst_bal > wst_before_withdraw, 'wst not withdrawn');
        assert(
            ERC20Helper::balanceOf(constants::ETH_ADDRESS(), clVault.contract_address) == 0,
            'invalid token bal'
        );
        assert(
            ERC20Helper::balanceOf(constants::WST_ADDRESS(), clVault.contract_address) == 0,
            'invalid token bal'
        );
    }

    fn ekubo_swaps() {
        let pool_price_before = IEkuboDispatcher { contract_address: constants::EKUBO_POSITIONS() }
            .get_pool_price(get_pool_key())
            .tick
            .mag;
        let mut x = 1;
        loop {
            x += 1;
            let eth_route = get_eth_wst_route();
            ekubo_swap(
                eth_route, constants::ETH_ADDRESS(), constants::WST_ADDRESS(), 400000000000000000
            );

            let wst_route = get_wst_eth_route();
            ekubo_swap(
                wst_route, constants::WST_ADDRESS(), constants::ETH_ADDRESS(), 400000000000000000
            );
            if x == 50 {
                break;
            }
        };
        /// println!("fifth swap passed");

        let pool_price_after = IEkuboDispatcher { contract_address: constants::EKUBO_POSITIONS() }
            .get_pool_price(get_pool_key())
            .tick
            .mag;

        /// println!("pool price before: {:?}", pool_price_before);
        /// println!("pool price after: {:?}", pool_price_after);
        assert(pool_price_before != pool_price_after, 'invalid swap pool');
    }

    fn ekubo_swaps_xstrk() {
        let pool_price_before = IEkuboDispatcher { contract_address: constants::EKUBO_POSITIONS() }
            .get_pool_price(get_pool_key_xstrk())
            .tick
            .mag;

        let mut x = 1;
        loop {
            x += 1;
            let eth_route = get_strk_xstrk_route();
            ekubo_swap(
                eth_route,
                constants::STRK_ADDRESS(),
                constants::XSTRK_ADDRESS(),
                5000000000000000000000
            );

            let wst_route = get_xstrk_strk_route();
            ekubo_swap(
                wst_route,
                constants::XSTRK_ADDRESS(),
                constants::STRK_ADDRESS(),
                500000000000000000000
            );
            if x == 50 {
                break;
            }
        };

        let pool_price_after = IEkuboDispatcher { contract_address: constants::EKUBO_POSITIONS() }
            .get_pool_price(get_pool_key_xstrk())
            .tick
            .mag;

        assert(pool_price_before != pool_price_after, 'invalid swap pool');
    }

    #[test]
    #[fork("mainnet_latest")]
    fn test_clVault_constructer() {
        let (clVault, erc20Disp) = deploy_cl_vault();
        let mut i = 0;
        while i != 
        let settings: ClSettings = clVault.get_settings();
        assert(
            settings.ekubo_positions_contract == constants::EKUBO_POSITIONS(),
            'invalid ekubo positions'
        );
        assert(
            settings.ekubo_positions_nft == constants::EKUBO_POSITIONS_NFT(),
            'invalid ekubo positions nft'
        );
        assert(settings.ekubo_core == constants::EKUBO_CORE(), 'invalid ekubo core');
        assert(settings.oracle == constants::ORACLE_OURS(), 'invalid pragma oracle');
        assert(clVault.total_liquidity() == 0, 'invalid total supply');

        assert(erc20Disp.name() == "uCL_token", 'invalid name');
        assert(erc20Disp.symbol() == "UCL", 'invalid symbol');
        assert(erc20Disp.decimals() == 18, 'invalid decimals');
        assert(erc20Disp.total_supply() == 0, 'invalid total supply');
    }

    #[test]
    #[fork("mainnet_1134787")]
    fn test_ekubo_deposit() {
        let (clVault, _) = ekubo_deposit();
        let this = get_contract_address();
        let settings: ClSettings = clVault.get_settings();
        let nft_id: u64 = settings.contract_nft_id;
        let nft_id_u256: u256 = nft_id.into();
        let nft_disp = IEkuboNFTDispatcher { contract_address: settings.ekubo_positions_nft };
        /// println!("nft_id: {:?}", nft_id);

        // assert correct NFT ID, and ensure all balance is used
        assert(nft_disp.ownerOf(nft_id_u256) == clVault.contract_address, 'invalid owner');
        assert(
            ERC20Helper::balanceOf(constants::ETH_ADDRESS(), clVault.contract_address) == 0,
            'invalid ETH amount'
        );
        assert(
            ERC20Helper::balanceOf(constants::WST_ADDRESS(), clVault.contract_address) == 0,
            'invalid WST amount'
        );
        /// println!("checked balances");

        // assert for near equal values
        let cl_shares_bal = ERC20Helper::balanceOf(clVault.contract_address, this);
        let total_liquidity: u256 = clVault.get_position().liquidity.into();
        /// println!("cl_shares_bal: {:?}", cl_shares_bal);
        /// println!("total_liquidity: {:?}", total_liquidity);
        assert((cl_shares_bal) == (total_liquidity), 'invalid shares minted');

        // deposit again
        let amount = 10 * pow::ten_pow(18);
        vault_init(amount);
        let expected_shares2 = clVault.convert_to_shares(amount, amount);
        let shares2 = clVault.deposit(amount, amount, this);
        assert(shares2 > 0, 'invalid shares minted');
        assert(shares2 == expected_shares2, 'invalid shares minted');
        let settings: ClSettings = clVault.get_settings();
        assert(nft_id == settings.contract_nft_id, 'nft id not constant');
        assert(
            ERC20Helper::balanceOf(constants::ETH_ADDRESS(), clVault.contract_address) == 0,
            'invalid ETH amount'
        );
        assert(
            ERC20Helper::balanceOf(constants::WST_ADDRESS(), clVault.contract_address) == 0,
            'invalid WST amount'
        );

        // assert for near equal values
        let cl_shares_bal = ERC20Helper::balanceOf(clVault.contract_address, this);
        let total_liquidity: u256 = clVault.get_position().liquidity.into();
        /// println!("cl_shares_bal: {:?}", cl_shares_bal);
        /// println!("total_liquidity: {:?}", total_liquidity);
        assert(
            (cl_shares_bal / pow::ten_pow(3)) == (total_liquidity / pow::ten_pow(3)),
            'invalid shares minted'
        );
    }
}