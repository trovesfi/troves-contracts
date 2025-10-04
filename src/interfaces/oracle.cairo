use starknet::{ContractAddress};

//
// Re-uses zkLend's oracle middleware contract to interact with
// Pragma.
// https://github.com/zkLend/zklend-v1-core/blob/master/src/default_price_oracle.cairo
//
// We deploy the came classhash of contract
// https://starkscan.co/contract/0x023fb3afbff2c0e3399f896dcf7400acf1a161941cfb386e34a123f228c62832#read-write-contract-sub-write
//

#[derive(Drop, Serde)]
pub struct PriceWithUpdateTime {
    pub price: felt252,
    pub update_time: felt252
}

#[starknet::interface]
pub trait IPriceOracle<TContractState> {
    /// Get the price of the token in USD with 8 decimals.
    fn get_price(self: @TContractState, token: ContractAddress) -> felt252;

    /// Get the price of the token in USD with 8 decimals and update timestamp.
    fn get_price_with_time(self: @TContractState, token: ContractAddress) -> PriceWithUpdateTime;
}

#[derive(Drop, Serde)]
pub enum PragmaDataType {
    SpotEntry: felt252,
    FutureEntry: (felt252, u64),
    GenericEntry: felt252,
}

#[derive(Drop, Serde)]
pub struct PragmaPricesResponse {
    pub price: u128,
    pub decimals: u32,
    pub last_updated_timestamp: u64,
    pub num_sources_aggregated: u32,
    expiration_timestamp: Option<u64>,
}

#[derive(Drop, Serde)]
pub enum SimpleDataType {
    SpotEntry: (),
    FutureEntry: (),
}

#[derive(Drop, Serde)]
pub enum AggregationMode {
    Median: (),
    Mean: (),
    ConversionRate: (),
    Error: (),
}

#[starknet::interface]
pub trait IPragmaOracle<TContractState> {
    fn get_data_median(self: @TContractState, data_type: PragmaDataType) -> PragmaPricesResponse;
    fn get_data(self: @TContractState, data_type: PragmaDataType, aggregation_mode: AggregationMode) -> PragmaPricesResponse;
    fn get_data_with_USD_hop(
        self: @TContractState,
        base_currency_id: felt252,
        quote_currency_id: felt252,
        aggregation_mode: AggregationMode,
        typeof: SimpleDataType,
        expiration_timestamp: Option::<u64>
    ) -> PragmaPricesResponse;
    // fn set_mock_price()
}

#[starknet::interface]
pub trait IPragmaNostraMock<TContractState> {
    fn get_spot_median(
        self: @TContractState, pair_id: felt252
    ) -> (felt252, felt252, felt252, felt252);
    fn get_spot_with_USD_hop(
        self: @TContractState,
        base_currency_id: felt252,
        quote_currency_id: felt252,
        aggregation_mode: felt252,
    ) -> (felt252, felt252, felt252, felt252);
}

#[starknet::interface]
pub trait IPriceOracleSource<TContractState> {
    //
    // Getters
    //

    /// Get the price of the token in USD with 8 decimals.
    fn get_price(self: @TContractState) -> felt252;

    /// Get the price of the token in USD with 8 decimals and update timestamp.
    fn get_price_with_time(self: @TContractState) -> PriceWithUpdateTime;
}