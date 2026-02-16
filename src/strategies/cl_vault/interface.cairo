use starknet::{ContractAddress};
use strkfarm_contracts::interfaces::IEkuboCore::{Bounds, PoolKey, PositionKey};
use ekubo::types::position::Position;
use strkfarm_contracts::components::swap::{AvnuMultiRouteSwap};
use strkfarm_contracts::interfaces::IEkuboDistributor::Claim;

#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct ClSettings {
    pub ekubo_positions_contract: ContractAddress,
    pub bounds_settings: Bounds,
    pub pool_key: PoolKey,
    pub ekubo_positions_nft: ContractAddress,
    pub contract_nft_id: u64, // NFT position id of Ekubo position
    pub ekubo_core: ContractAddress,
    pub oracle: ContractAddress,
    pub fee_settings: FeeSettings,
}

#[derive(Drop, Serde)]
pub struct MyPosition {
    pub liquidity: Array<u256>,
    pub amount0: u256,
    pub amount1: u256,
}

#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct ManagedPool {
    pub pool_key: PoolKey,
    pub bounds: Bounds,
    pub nft_id: u64
}
// todo : add sqrt values if possible 

#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct SqrtValues {
    pub sqrt_lower: u256,
    pub sqrt_upper: u256
}

#[derive(Drop)]
pub enum ManagedPoolField {
    Bounds: Bounds,
    NftId: u64,
}

#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct InitValues {
    pub init0: u256,
    pub init1: u256
}

#[derive(Drop, Copy, Serde, starknet::Store, starknet::Event)]
pub struct FeeSettings {
    pub fee_bps: u256,
    pub fee_collector: ContractAddress
}

#[starknet::interface]
pub trait IClVault<TContractState> {
    // returns shares
    fn deposit(
        ref self: TContractState, amount0: u256, amount1: u256, receiver: ContractAddress
    ) -> u256;
    fn withdraw(ref self: TContractState, shares: u256, receiver: ContractAddress) -> MyPosition;
    fn convert_to_shares(ref self: TContractState, amount0: u256, amount1: u256) -> u256;
    fn convert_to_assets(self: @TContractState, shares: u256) -> MyPosition;
    fn liquidity_per_pool(self: @TContractState, pool: ManagedPool) -> u256;
    fn get_position_key(self: @TContractState, pool: ManagedPool) -> PositionKey;
    fn get_position(self: @TContractState, pool: ManagedPool) -> Position;
    fn handle_fees(ref self: TContractState, pool: ManagedPool);
    fn harvest(
        ref self: TContractState,
        rewardsContract: ContractAddress,
        claim: Claim,
        proof: Span<felt252>,
        swapInfo1: AvnuMultiRouteSwap,
        swapInfo2: AvnuMultiRouteSwap
    );
    fn get_pool_settings(self: @TContractState, pool: ManagedPool) -> ClSettings;
    fn handle_unused(ref self: TContractState, swap_params: AvnuMultiRouteSwap, pool: ManagedPool);
    fn rebalance_pool(ref self: TContractState, new_bounds: Bounds, swap_params: AvnuMultiRouteSwap, pool: ManagedPool);
    fn rebalance_all_pools(ref self: TContractState, new_bounds: Array<Bounds>, swap_params: Array<AvnuMultiRouteSwap>);
    fn set_settings(ref self: TContractState, fee_settings: FeeSettings);
    fn set_incentives_off(ref self: TContractState);
}
