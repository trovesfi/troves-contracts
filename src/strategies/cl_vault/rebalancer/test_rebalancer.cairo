#[cfg(test)]
pub mod test_rebalancer {
    use strkfarm_contracts::strategies::cl_vault::rebalancer::rebalancer::{
        IClVaultRebalancerDispatcher, IClVaultRebalancerDispatcherTrait
    };
    use strkfarm_contracts::strategies::cl_vault::interface::{
        IClVaultDispatcher, IClVaultDispatcherTrait
    };
    use snforge_std::{
        declare, ContractClassTrait, start_cheat_caller_address, stop_cheat_caller_address,
        start_cheat_block_number_global, cheat_caller_address, CheatSpan
    };
    use snforge_std::DeclareResultTrait;
    use starknet::{ContractAddress, get_contract_address, contract_address_const};
    use strkfarm_contracts::helpers::constants;
    use strkfarm_contracts::helpers::ERC20Helper;
    use strkfarm_contracts::interfaces::IEkuboCore::{Bounds, PoolKey, PositionKey, IEkuboCoreDispatcher, IEkuboCoreDispatcherTrait};
    use strkfarm_contracts::components::swap::{AvnuMultiRouteSwap, Route, AvnuMultiRouteSwapTrait};
    use strkfarm_contracts::helpers::pow;
    use ekubo::types::i129::i129;
    use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
    use core::num::traits::Zero;
    use openzeppelin::access::accesscontrol::interface::{
        IAccessControlDispatcher, IAccessControlDispatcherTrait
    };
    use strkfarm_contracts::interfaces::oracle::{IPriceOracleDispatcher};
    use strkfarm_contracts::interfaces::IEkuboPosition::{IEkuboDispatcher, IEkuboDispatcherTrait};
    use strkfarm_contracts::interfaces::IEkuboPositionsNFT::{IEkuboNFTDispatcher, IEkuboNFTDispatcherTrait};

    const VAULT_ADDRESS: felt252 = 0x01f083b98674bc21effee29ef443a00c7b9a500fd92cf30341a3da12c73f2324;
    const BLOCK_NUMBER: u64 = 1548957;
    
    fn grant_relayer_role(address: ContractAddress) {
        let access_control = constants::ACCESS_CONTROL();
        let admin = contract_address_const::<0x0613a26e199f9bafa9418567f4ef0d78e9496a8d6aab15fba718a2ec7f2f2f69>(); // AccessControl admin, timelock contract
        start_cheat_caller_address(access_control, admin);
        let access_control_dispatcher = IAccessControlDispatcher { contract_address: access_control };
        let role = strkfarm_contracts::components::accessControl::AccessControl::Roles::RELAYER;
        access_control_dispatcher.grant_role(role, address);
        stop_cheat_caller_address(access_control);
    }

    fn deploy_rebalancer() -> IClVaultRebalancerDispatcher {
        let cls = declare("ClVaultRebalancer").unwrap().contract_class();
        let calldata: Array<felt252> = array![];
        let (address, _) = cls.deploy(@calldata).expect('Rebalancer deploy failed');
        IClVaultRebalancerDispatcher { contract_address: address }
    }

    fn get_vault() -> IClVaultDispatcher {
        IClVaultDispatcher { contract_address: contract_address_const::<VAULT_ADDRESS>() }
    }

    fn get_strk_xstrk_route(amount: u256) -> Route {
        let sqrt_limit: felt252 = 6277100250585753475930931601400621808602321654880405518632; // Price up limit for xSTRK/STRK

        let additional: Array<felt252> = array![
            constants::XSTRK_ADDRESS().into(), // token0
            constants::STRK_ADDRESS().into(), // token1
            34028236692093847977029636859101184, // fee (0.01%)
            200, // tick spacing
            0, // extension
            sqrt_limit, // sqrt limit for price down
        ];
        Route {
            token_from: constants::STRK_ADDRESS(),
            token_to: constants::XSTRK_ADDRESS(),
            exchange_address: constants::EKUBO_CORE(),
            percent: 1000000000000, // 100%
            additional_swap_params: additional
        }
    }

    fn create_swap_params(
        token_from: ContractAddress,
        token_to: ContractAddress,
        amount: u256,
        beneficiary: ContractAddress,
        route: Route
    ) -> AvnuMultiRouteSwap {
        AvnuMultiRouteSwap {
            token_from_address: token_from,
            token_from_amount: amount,
            token_to_address: token_to,
            token_to_amount: 0,
            token_to_min_amount: 1,
            beneficiary,
            integrator_fee_amount_bps: 0,
            integrator_fee_recipient: contract_address_const::<0x00>(),
            routes: array![route]
        }
    }

    fn fund_address_with_strk(address: ContractAddress, amount: u256) {
        let strk_holder = contract_address_const::<0x076601136372fcdbbd914eea797082f7504f828e122288ad45748b0c8b0c9696>(); // byBit
        start_cheat_caller_address(constants::STRK_ADDRESS(), strk_holder);
        ERC20Helper::transfer(constants::STRK_ADDRESS(), address, amount);
        stop_cheat_caller_address(constants::STRK_ADDRESS());
    }

    fn fund_address_with_xstrk(address: ContractAddress, amount: u256) {
        let xstrk_holder = contract_address_const::<0x059a943ca214c10234b9a3b61c558ac20c005127d183b86a99a8f3c60a08b4ff>(); // random holder
        start_cheat_caller_address(constants::XSTRK_ADDRESS(), xstrk_holder);
        ERC20Helper::transfer(constants::XSTRK_ADDRESS(), address, amount);
        stop_cheat_caller_address(constants::XSTRK_ADDRESS());
    }

    /// @notice Continuously swaps until the tick is above the target tick
    /// @param swap_params The swap parameters to use for each swap iteration
    /// @param target_tick The target tick that the current tick must exceed
    /// @param max_iterations Maximum number of swap iterations to prevent infinite loops
    /// @param caller The address that will perform the swaps
    fn swap_until_tick_above(
        swap_params: AvnuMultiRouteSwap,
        target_tick: u128,
        max_iterations: u32,
    ) {
        let vault = get_vault();
        let oracle = IPriceOracleDispatcher { contract_address: constants::ORACLE_OURS() };
        let caller = get_contract_address();

        let mut iteration = 0;
        
        loop {
            // Get current pool price and tick
            let pool_price = IEkuboDispatcher { contract_address: constants::EKUBO_POSITIONS() }
                .get_pool_price(vault.get_settings().pool_key);
            let current_tick = pool_price.tick.mag;
            
            // Check if we've reached the target
            if current_tick > target_tick {
                println!("Target tick reached! Current tick: {:?}, Target: {:?}", current_tick, target_tick);
                break;
            }
            
            // Safety check to prevent infinite loops
            iteration += 1;
            if iteration > max_iterations {
                println!("Max iterations reached without achieving target tick");
                break;
            }
            
            println!("Iteration {:?}: Current tick: {:?}, Target: {:?}", iteration, current_tick, target_tick);
            
            // Ensure caller has sufficient tokens for the swap
            let token_balance = ERC20Helper::balanceOf(swap_params.token_from_address, caller);
            assert(token_balance >= swap_params.token_from_amount, 'Insufficient token balance');
            
            // Execute the swap
            swap_params.clone().swap(oracle);
        };
    }

    #[test]
    #[fork("mainnet_1548957")]
    fn test_rebalancer_deployment() {
        let rebalancer = deploy_rebalancer();
        assert(rebalancer.contract_address.is_non_zero(), 'Deployment failed');
    }

    #[test]
    #[fork("mainnet_latest")]
    fn test_rebalancer_full_flow() {
        let rebalancer = deploy_rebalancer();
        let vault = get_vault();
        let caller = contract_address_const::<0x123>();

        // Get current vault settings
        let vault_settings = vault.get_settings();
        let old_bounds = vault_settings.bounds_settings;

        // Define new bounds (as specified in requirements)
        let new_bounds = Bounds {
            lower: i129 { mag: 64400, sign: false },
            upper: i129 { mag: 64800, sign: false }
        };

        // Fund caller with STRK tokens for swaps
        let price_change_amount = 3653565 * pow::ten_pow(18); // 4673300 STRK
        let rebalance_amount = 62957598 * pow::ten_pow(12); // 500 STRK
        let total_amount = price_change_amount;
        
        fund_address_with_xstrk(caller, 100 * pow::ten_pow(18)); // 100 xSTRK
        fund_address_with_strk(caller, 100 * pow::ten_pow(18)); // 100 STRK
        
        // Create swap routes
        let strk_xstrk_route = get_strk_xstrk_route(price_change_amount);
        let rebalance_route = get_strk_xstrk_route(rebalance_amount);

        // Create swap parameters
        let price_change_swap_params = create_swap_params(
            constants::STRK_ADDRESS(),
            constants::XSTRK_ADDRESS(),
            price_change_amount,
            rebalancer.contract_address,
            strk_xstrk_route.clone()
        );

        let rebalance_swap_params = create_swap_params(
            constants::STRK_ADDRESS(),
            constants::XSTRK_ADDRESS(),
            rebalance_amount,
            vault.contract_address,
            rebalance_route
        );

        // grant relayer role to rebalancer
        grant_relayer_role(rebalancer.contract_address);

        // Get initial balances
        let initial_strk_balance = ERC20Helper::balanceOf(constants::STRK_ADDRESS(), caller);
        let initial_xstrk_balance = ERC20Helper::balanceOf(constants::XSTRK_ADDRESS(), caller);
        println!("Initial STRK balance: {:?}", initial_strk_balance);
        println!("Initial xSTRK balance: {:?}", initial_xstrk_balance);

        // construct sell swap params
        let sell_swap_params = create_swap_params(
            constants::XSTRK_ADDRESS(),
            constants::STRK_ADDRESS(),
            0, // Will be set to xSTRK balance later
            rebalancer.contract_address,
            Route {
                token_from: constants::XSTRK_ADDRESS(),
                token_to: constants::STRK_ADDRESS(),
                exchange_address: constants::EKUBO_CORE(),
                percent: 1000000000000, // 100%
                additional_swap_params: array![
                    constants::XSTRK_ADDRESS().into(), // token0
                    constants::STRK_ADDRESS().into(), // token1
                    34028236692093847977029636859101184, // fee (0.01%)
                    200, // tick spacing
                    0, // extension
                    83351816742282055222672457824989085696 // sqrt limit for price down
                ]
            }
        );

        // Verify rebalancer has no remaining funds
        let rebalancer_strk = ERC20Helper::balanceOf(constants::STRK_ADDRESS(), rebalancer.contract_address);
        let rebalancer_xstrk = ERC20Helper::balanceOf(constants::XSTRK_ADDRESS(), rebalancer.contract_address);
        assert(rebalancer_strk == 0, 'Rebalancer has STRK');
        assert(rebalancer_xstrk == 0, 'Rebalancer has xSTRK');

        // approve 100 STRK and xSTRK to rebalancer
        start_cheat_caller_address(constants::STRK_ADDRESS(), caller);
        let strk_token = ERC20ABIDispatcher { contract_address: constants::STRK_ADDRESS() };
        strk_token.approve(rebalancer.contract_address, 100 * pow::ten_pow(18)); // Approve 100 STRK
        stop_cheat_caller_address(constants::STRK_ADDRESS());

        start_cheat_caller_address(constants::XSTRK_ADDRESS(), caller);
        let xstrk_token = ERC20ABIDispatcher { contract_address: constants::XSTRK_ADDRESS() };
        xstrk_token.approve(rebalancer.contract_address, 100 * pow::ten_pow(18)); // Approve 100 xSTRK
        stop_cheat_caller_address(constants::XSTRK_ADDRESS());

        // Execute rebalance
        cheat_caller_address(rebalancer.contract_address, caller, CheatSpan::TargetCalls(1));
        rebalancer.rebalance(
            vault.contract_address,
            price_change_swap_params,
            new_bounds,
            true,
            rebalance_swap_params,
            new_bounds,
            false,
            sell_swap_params,
            caller
        );

        // Verify bounds were updated
        let updated_settings = vault.get_settings();
        assert(updated_settings.bounds_settings.lower.mag == 59800, 'Lower bound not updated');
        assert(updated_settings.bounds_settings.upper.mag == 60000, 'Upper bound not updated');

        // Verify caller received remaining funds
        let final_strk_balance = ERC20Helper::balanceOf(constants::STRK_ADDRESS(), caller);
        let final_xstrk_balance = ERC20Helper::balanceOf(constants::XSTRK_ADDRESS(), caller);
        println!("Final STRK balance: {:?}", final_strk_balance);
        println!("Final xSTRK balance: {:?}", final_xstrk_balance);

        // Should have less STRK (used for swaps) but some xSTRK from price change swap
        assert(final_strk_balance > initial_strk_balance, 'STRK not used');
        assert(final_xstrk_balance > 0, 'No xSTRK received');

        // Verify rebalancer has no remaining funds
        let rebalancer_strk = ERC20Helper::balanceOf(constants::STRK_ADDRESS(), rebalancer.contract_address);
        let rebalancer_xstrk = ERC20Helper::balanceOf(constants::XSTRK_ADDRESS(), rebalancer.contract_address);
        assert(rebalancer_strk == 0, 'Rebalancer has STRK');
        assert(rebalancer_xstrk == 0, 'Rebalancer has xSTRK');

        // do arbitrage to to bring other markets to same price
        let nostra: ContractAddress = 0x49ff5b3a7d38e2b50198f408fa8281635b5bc81ee49ab87ac36c8324c214427.try_into().unwrap();
        let nostra_pair: ContractAddress = 0x205fd8586f6be6c16f4aa65cc1034ecff96d96481878e55f629cd0cb83e05f.try_into().unwrap();
        let arb_buy_swap_params = create_swap_params(
            constants::STRK_ADDRESS(),
            constants::XSTRK_ADDRESS(),
            100 * pow::ten_pow(18), // 200k STRK
            rebalancer.contract_address,
            Route {
                token_from: constants::STRK_ADDRESS(),
                token_to: constants::XSTRK_ADDRESS(),
                exchange_address: nostra,
                percent: 1000000000000, // 100%
                additional_swap_params: array![
                    nostra_pair.into(), // pair address
                ]
            }
        );

        let sell_swap_params = create_swap_params(
            constants::XSTRK_ADDRESS(),
            constants::STRK_ADDRESS(),
            0, // Will be set to xSTRK balance later
            rebalancer.contract_address,
            Route {
                token_from: constants::XSTRK_ADDRESS(),
                token_to: constants::STRK_ADDRESS(),
                exchange_address: constants::EKUBO_CORE(),
                percent: 1000000000000, // 100%
                additional_swap_params: array![
                    constants::XSTRK_ADDRESS().into(), // token0
                    constants::STRK_ADDRESS().into(), // token1
                    34028236692093847977029636859101184, // fee (0.01%)
                    200, // tick spacing
                    0, // extension
                    83351816742282055222672457824989085696 // sqrt limit for price down
                ]
            }
        );
        rebalancer.arbitrage(
            arb_buy_swap_params,
            sell_swap_params,
            caller,
            10, // 0.1% min gain
        );
    }
}