use starknet::{ContractAddress, get_contract_address};
use strkfarm_contracts::interfaces::IVesu::{
    IVesu, Amount, ModifyPositionParams, AmountType, AmountDenomination
};
use strkfarm_contracts::interfaces::IVesu::{IStonDispatcher, IStonDispatcherTrait};
use strkfarm_contracts::interfaces::oracle::{IPriceOracleDispatcher, IPriceOracleDispatcherTrait};
use strkfarm_contracts::interfaces::lendcomp::ILendMod;
use strkfarm_contracts::helpers::ERC20Helper;
use core::num::traits::Zero;
use alexandria_math::i257::{I257Trait};
use strkfarm_contracts::helpers::pow;

#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct vesuStruct {
    pub singleton: IStonDispatcher,
    pub pool_id: felt252,
    pub debt: ContractAddress,
    pub col: ContractAddress,
    pub oracle: ContractAddress
}

#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct vesuToken {
    pub underlying_asset: ContractAddress,
}

pub impl vesuHelperImpl of IVesu<vesuStruct> {
    fn getParams(self: vesuStruct) -> ModifyPositionParams {
        let this = get_contract_address();
        let params = ModifyPositionParams {
            pool_id: self.pool_id,
            collateral_asset: self.col,
            debt_asset: self.debt,
            user: this,
            collateral: Amount {
                amount_type: AmountType::Delta,
                denomination: AmountDenomination::Assets,
                value: I257Trait::new(0, is_negative: false)
            },
            debt: Amount {
                amount_type: AmountType::Delta,
                denomination: AmountDenomination::Assets,
                value: I257Trait::new(0, is_negative: false)
            },
            data: array![0].span()
        };
        params
    }
}

pub impl vesuSettingsImpl of ILendMod<vesuStruct, vesuToken> {
    fn deposit(self: vesuStruct, token: ContractAddress, amount: u256) -> u256 {
        let stonDisp = self.singleton;
        let mut deposit_params = self.getParams();
        assert(deposit_params.collateral_asset == token, 'Vesu::deposit::invalid token');
        let collateral = I257Trait::new(amount, is_negative: false);
        deposit_params.collateral.value = collateral;
        ERC20Helper::approve(token, self.singleton.contract_address, amount);
        let _ = stonDisp.modify_position(deposit_params);
        amount
    }

    fn withdraw(self: vesuStruct, token: ContractAddress, amount: u256) -> u256 {
        let stonDisp = self.singleton;
        let mut withdraw_params = self.getParams();
        assert(withdraw_params.collateral_asset == token, 'Vesu::withdraw::invalid token');
        let collateral_amount = I257Trait::new(amount, is_negative: true);
        withdraw_params.collateral.value = collateral_amount;
        let _ = stonDisp.modify_position(withdraw_params);
        amount
    }

    fn borrow(self: vesuStruct, token: ContractAddress, amount: u256) -> u256 {
        let stonDisp = self.singleton;
        let mut borrow_params = self.getParams();
        assert(borrow_params.debt_asset == token, 'Vesu::borrow::invalid token');
        let debt = I257Trait::new(amount, is_negative: false);
        borrow_params.debt.value = debt;
        let _ = stonDisp.modify_position(borrow_params);
        amount
    }

    fn repay(self: vesuStruct, token: ContractAddress, amount: u256) -> u256 {
        let stonDisp = self.singleton;
        let this = get_contract_address();
        let min_borrow = self.min_borrow_required(token);
        let curr_debt = self.borrow_amount(token, this);
        let mut repay_params = self.getParams();
        assert(repay_params.debt_asset == token, 'Vesu::repay::invalid token');
        let mut repay_amount = amount;
        if (curr_debt - amount < min_borrow) {
            repay_amount = curr_debt;
        }
        ERC20Helper::approve(token, self.singleton.contract_address, repay_amount);
        let repay_amount = I257Trait::new(repay_amount, is_negative: true);
        repay_params.debt.value = repay_amount;
        let _ = stonDisp.modify_position(repay_params);
        repay_amount.abs()
    }

    fn health_factor(
        self: @vesuStruct,
        user: ContractAddress,
        deposits: Array<vesuToken>,
        borrows: Array<vesuToken>,
    ) -> u32 {
        let stonDisp = *self.singleton;
        assert(deposits.len() == 1, 'Vesu::hf::invalid dep len');
        assert(borrows.len() == 1, 'Vesu::hf::invalid bor len');
        let col = *deposits.at(0).underlying_asset;
        let debt = *borrows.at(0).underlying_asset;
        let max_ltv = stonDisp.ltv_config(*self.pool_id, col, debt).max_ltv;
        let max_ltv_u256: u256 = max_ltv.into();
        let (_, col_value, debt_value) = stonDisp
            .check_collateralization(*self.pool_id, col, debt, user);
        if (col_value == 0 || debt_value == 0) {
            return 10 * 10000; // for assert healthy when 100% withdraw happens
        }
        let health_factor = ((max_ltv_u256 * pow::ten_pow(4))
            / (debt_value * pow::ten_pow(18) / col_value));
        let health_factor_u32: u32 = health_factor.try_into().unwrap();

        health_factor_u32
    }

    fn assert_valid(self: @vesuStruct) {
        assert(self.singleton.contract_address.is_non_zero(), 'vesu::singleton::zero');
        assert(self.debt.is_non_zero(), 'vesu::debt::zero');
        assert(self.col.is_non_zero(), 'vesu::col::zero');
        assert(self.pool_id.is_non_zero(), 'vesu::pool_id::zero');
    }

    fn max_borrow_amount(
        self: @vesuStruct,
        deposit_token: vesuToken,
        deposit_amount: u256,
        borrow_token: vesuToken,
        min_hf: u32
    ) -> u256 {
        if (true) {
            panic!("Vesu::fn not implemented");
        }
        return 0;
    }

    fn min_borrow_required(self: @vesuStruct, token: ContractAddress,) -> u256 {
        let stonDisp = *self.singleton;
        let (config, _) = stonDisp.asset_config(*self.pool_id, *self.debt);
        let token_price = IPriceOracleDispatcher { contract_address: *self.oracle }
            .get_price(token);
        let token_price_u256: u256 = token_price.into();

        let token_decimals: u256 = ERC20Helper::decimals(token).into();

        let asset_price = (config.floor * pow::ten_pow(8) / token_price_u256)
            / pow::ten_pow(18_u256 - token_decimals);

        asset_price
    }

    fn get_repay_amount(self: @vesuStruct, token: ContractAddress, amount: u256) -> u256 {
        let min_debt = self.min_borrow_required(token);
        let current_debt = self.borrow_amount(token, get_contract_address());
        if (current_debt - amount < min_debt) {
            return current_debt;
        }
        return amount;
    }

    fn deposit_amount(self: @vesuStruct, asset: ContractAddress, user: ContractAddress) -> u256 {
        let stonDisp = *self.singleton;
        let (_, collateral, _) = stonDisp.position(*self.pool_id, *self.col, *self.debt, user);

        collateral
    }

    fn borrow_amount(self: @vesuStruct, asset: ContractAddress, user: ContractAddress) -> u256 {
        let stonDisp = *self.singleton;
        let (_, _, debt) = stonDisp.position(*self.pool_id, *self.col, *self.debt, user);

        debt
    }
}

#[cfg(test)]
mod tests {
    use strkfarm_contracts::interfaces::lendcomp::ILendMod;
    use strkfarm_contracts::helpers::constants;
    use super::{vesuStruct, vesuToken};
    use strkfarm_contracts::interfaces::IVesu::{IStonDispatcher};
    use starknet::{get_contract_address};
    use starknet::contract_address::contract_address_const;
    use snforge_std::{start_cheat_caller_address, stop_cheat_caller_address};
    use strkfarm_contracts::helpers::ERC20Helper;
    use strkfarm_contracts::helpers::pow;

    #[test]
    #[fork("mainnet_971311")]
    fn test_vesu_component() {
        let vesu_settings = vesuStruct {
            singleton: IStonDispatcher { contract_address: constants::VESU_SINGLETON_ADDRESS() },
            pool_id: constants::VESU_POOL_ID(),
            debt: constants::USDT_ADDRESS(),
            col: constants::USDC_ADDRESS(),
            oracle: constants::Oracle()
        };

        let user = constants::TEST_VESU_USER();

        let this = get_contract_address();
        let amount: u256 = 1000 * pow::ten_pow(6);
        let borrow_amt: u256 = 500 * pow::ten_pow(6);

        start_cheat_caller_address(constants::USDC_ADDRESS(), user);
        ERC20Helper::transfer(constants::USDC_ADDRESS(), this, amount);
        stop_cheat_caller_address(constants::USDC_ADDRESS());

        start_cheat_caller_address(constants::USDT_ADDRESS(), user);
        ERC20Helper::transfer(constants::USDT_ADDRESS(), this, amount);
        stop_cheat_caller_address(constants::USDT_ADDRESS());

        //deposit
        let pre_deposit = vesu_settings.deposit_amount(constants::USDC_ADDRESS(), this);
        assert(pre_deposit == 0, 'Vesu::deposit::invalid zero');
        vesu_settings.deposit(constants::USDC_ADDRESS(), amount);
        let post_deposit = vesu_settings.deposit_amount(constants::USDC_ADDRESS(), this);
        assert(post_deposit == 999999999, 'Vesu::deposit::invalid deposit');

        //borrow
        let init_borrow_amt = vesu_settings.borrow_amount(constants::USDT_ADDRESS(), this);
        assert(init_borrow_amt == 0, 'Vesu::borrow::invalid zero');
        vesu_settings.borrow(constants::USDT_ADDRESS(), borrow_amt);
        let bor_amount = vesu_settings.borrow_amount(constants::USDT_ADDRESS(), this);
        assert(bor_amount == 500000001, 'Vesu::borrow::invalid borrow');

        //assert hf
        let mut deposit_array = ArrayTrait::<vesuToken>::new();
        let mut borrow_array = ArrayTrait::<vesuToken>::new();
        let dep = vesuToken { underlying_asset: constants::USDC_ADDRESS(), };
        let bor = vesuToken { underlying_asset: constants::USDT_ADDRESS(), };
        deposit_array.append(dep);
        borrow_array.append(bor);
        let hf = vesu_settings.health_factor(this, deposit_array, borrow_array);
        assert(hf == 18593, 'Vesu::hf::invalid hf');

        //repay
        let repay_amount = 500 * pow::ten_pow(6);
        vesu_settings.repay(constants::USDT_ADDRESS(), repay_amount);
        let bor_amount = vesu_settings.borrow_amount(constants::USDT_ADDRESS(), this);
        assert(bor_amount == 0, 'Vesu::repay::invalid repay');

        //withdraw
        let curr_dep = vesu_settings.deposit_amount(constants::USDC_ADDRESS(), this);
        assert(curr_dep == 999999999, 'Vesu::withdraw::invalid deposit');
        vesu_settings.withdraw(constants::USDC_ADDRESS(), curr_dep);
        let end_dep = vesu_settings.deposit_amount(constants::USDC_ADDRESS(), this);
        assert(end_dep == 0, 'Vesu::withdraw::invalid zero');
    }

    #[test]
    #[fork("mainnet_971311")]
    fn test_hf_user() {
        let vesu_settings = vesuStruct {
            singleton: IStonDispatcher { contract_address: constants::VESU_SINGLETON_ADDRESS() },
            pool_id: constants::VESU_POOL_ID(),
            debt: constants::ETH_ADDRESS(),
            col: constants::USDC_ADDRESS(),
            oracle: constants::Oracle()
        };

        let user_1 = contract_address_const::<
            0x0055741fd3ec832F7b9500E24A885B8729F213357BE4A8E209c4bCa1F3b909Ae
        >();
        //assert hf
        let mut deposit_array = ArrayTrait::<vesuToken>::new();
        let mut borrow_array = ArrayTrait::<vesuToken>::new();
        let dep = vesuToken { underlying_asset: constants::USDC_ADDRESS(), };
        let bor = vesuToken { underlying_asset: constants::ETH_ADDRESS(), };
        deposit_array.append(dep);
        borrow_array.append(bor);
        let hf = vesu_settings.health_factor(user_1, deposit_array, borrow_array);
        assert(hf == 13438, 'Vesu::hf::invalid hf');
    }
}
