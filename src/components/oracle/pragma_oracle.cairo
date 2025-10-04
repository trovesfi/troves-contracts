// From zkLend, but can reaudit
// non-audited (just for to know in future that i intend to reaudit)
// not used in audited contracts

mod errors {
    pub const PRICE_FROM_FUTURE: felt252 = 'PRAGMA_PRICE_FROM_FUTURE';
    pub const STALED_PRICE: felt252 = 'PRAGMA_STALED_PRICE';
    pub const ZERO_PRICE: felt252 = 'PRAGMA_ZERO_PRICE';
  }
  
#[starknet::contract]
pub mod PragmaOracleAdapter {
    use core::num::traits::CheckedSub;
  
    use starknet::{ContractAddress, get_block_timestamp};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
  
    use strkfarm_contracts::interfaces::oracle::{
        IPragmaOracleDispatcher, IPragmaOracleDispatcherTrait, IPriceOracleSource, PragmaDataType,
        PriceWithUpdateTime, AggregationMode
    };
    use strkfarm_contracts::helpers::{pow, safe_math};
  
    use super::errors;
  
    // These two consts MUST be the same.
    const TARGET_DECIMALS: felt252 = 8;
    const TARGET_DECIMALS_U256: u256 = 8;
  
    /// The maximum difference in seconds for a reported timestamp from the future.
    const MAX_FUTURE_SECONDS: u64 = 600;
  
    #[storage]
    struct Storage {
        pub oracle: ContractAddress,
        pub pair: felt252,
        pub timeout: u64,
    }
  
    #[constructor]
    fn constructor(ref self: ContractState, oracle: ContractAddress, pair: felt252, timeout: u64) {
        self.oracle.write(oracle);
        self.pair.write(pair);
        self.timeout.write(timeout);
    }
  
    #[abi(embed_v0)]
    impl IPriceOracleSourceImpl of IPriceOracleSource<ContractState> {
        fn get_price(self: @ContractState) -> felt252 {
            get_data(self).price
        }
  
        fn get_price_with_time(self: @ContractState) -> PriceWithUpdateTime {
            get_data(self)
        }
    }
  
    fn get_data(self: @ContractState) -> PriceWithUpdateTime {
        let oracle_addr = self.oracle.read();
        let pair_key = self.pair.read();
  
        let median = IPragmaOracleDispatcher { contract_address: oracle_addr }
            .get_data(PragmaDataType::SpotEntry(pair_key), AggregationMode::Median);
        assert(median.price != 0, errors::ZERO_PRICE);
  
        // Block times are usually behind real world time by a bit. It's possible that the reported
        // last updated timestamp is in the (very near) future.
        let block_time: u64 = get_block_timestamp();
  
        let time_elasped: u64 = match block_time.checked_sub(median.last_updated_timestamp) {
            Option::Some(value) => value,
            Option::None => {
                assert(
                    median.last_updated_timestamp - block_time <= MAX_FUTURE_SECONDS,
                    errors::PRICE_FROM_FUTURE,
                );
                0
            },
        };
        let timeout = self.timeout.read();
        assert(time_elasped <= timeout, errors::STALED_PRICE);
  
        let scaled_price = scale_price(median.price.into(), median.decimals.into());
        PriceWithUpdateTime {
            price: scaled_price, update_time: median.last_updated_timestamp.into(),
        }
    }
  
    fn scale_price(price: felt252, decimals: felt252) -> felt252 {
        if decimals == TARGET_DECIMALS {
            price
        } else {
            let should_scale_up = Into::<_, u256>::into(decimals) < TARGET_DECIMALS_U256;
            if should_scale_up {
                let multiplier = pow::ten_pow((TARGET_DECIMALS - decimals).into());
                let scaled_price = safe_math::mul(price, multiplier.try_into().unwrap());
                scaled_price
            } else {
                let multiplier = pow::ten_pow((decimals - TARGET_DECIMALS).into());
                let scaled_price = safe_math::div(price, multiplier.try_into().unwrap());
                scaled_price
            }
        }
    }
  }