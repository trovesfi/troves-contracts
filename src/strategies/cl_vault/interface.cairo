use starknet::{ContractAddress};
use strkfarm_contracts::interfaces::IEkuboCore::{Bounds, PoolKey, PositionKey};
use ekubo::types::position::Position;
use strkfarm_contracts::components::swap::{AvnuMultiRouteSwap};
use strkfarm_contracts::interfaces::IEkuboDistributor::Claim;
use ekubo::types::i129::{i129};

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

#[derive(Drop, Serde, Copy)]
pub struct MyPosition {
    pub liquidity: u256,
    pub amount0: u256,
    pub amount1: u256,
}

#[derive(Drop, Serde)]
pub struct MyPositions {
    pub positions: Array<MyPosition>,
    pub total_amount0: u256,
    pub total_amount1: u256,
}

#[derive(Drop, Serde)]
pub struct SharesInfo {
    pub shares: u256,
    pub user_level_positions: MyPositions,
    pub vault_level_positions: MyPositions,
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

#[derive(Drop, Copy, Serde, starknet::Store, starknet::Event)]
pub struct RangeInstruction {
    pub liquidity_mint: u128,
    pub liquidity_burn: u128,
    pub pool_key: PoolKey,
    pub new_bounds: Bounds,
}

#[derive(Drop, Serde)]
pub struct RebalanceParams {
    pub rebal: Array<RangeInstruction>,
    pub swap_params: AvnuMultiRouteSwap,
}

pub mod Events {
    use starknet::{ContractAddress};
    use strkfarm_contracts::interfaces::IEkuboCore::{Bounds, PoolKey, PositionKey};
    use ekubo::types::position::Position;
    use strkfarm_contracts::components::swap::{AvnuMultiRouteSwap};
    use strkfarm_contracts::interfaces::IEkuboDistributor::Claim;
    use super::*;

    #[derive(Drop, starknet::Event)]
    pub struct Deposit {
        #[key]
        pub sender: ContractAddress,
        #[key]
        pub owner: ContractAddress,
        pub shares: u256,
        pub amount0: u256,
        pub amount1: u256
    }

    #[derive(Drop, starknet::Event)]
    pub struct Withdraw {
        #[key]
        pub sender: ContractAddress,
        #[key]
        pub receiver: ContractAddress,
        #[key]
        pub owner: ContractAddress,
        pub shares: u256,
        pub amount0: u256,
        pub amount1: u256
    }

    #[derive(Drop, starknet::Event)]
    pub struct EkuboPositionUpdated {
        pub nft_id: u64,
        pub pool_key: PoolKey,
        pub bounds: Bounds,
        pub amount0_delta: i129,
        pub amount1_delta: i129,
        pub liquidity_delta: i129
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

    #[derive(Drop, starknet::Event)]
    pub struct HandleFees {
        pub token0_addr: ContractAddress,
        pub token0_origin_bal: u256,
        pub token0_deposited: u256,
        pub token1_addr: ContractAddress,
        pub token1_origin_bal: u256,
        pub token1_deposited: u256,
        pub pool_info: ManagedPool
    }

    #[derive(Drop, starknet::Event)]
    pub struct PoolUpdated {
        pub pool_key: PoolKey,
        pub bounds: Bounds,
        pub pool_index: u64,
        pub is_add: bool
    }

    #[derive(Drop, starknet::Event)]
    pub struct Rebalance {
        pub actions: Array<RangeInstruction>,
    }
}



#[starknet::interface]
pub trait IClVault<TContractState> {
    // returns shares
    fn deposit(
        ref self: TContractState, amount0: u256, amount1: u256, receiver: ContractAddress
    ) -> u256;
    fn withdraw(ref self: TContractState, shares: u256, receiver: ContractAddress) -> MyPositions;
    fn convert_to_shares(self: @TContractState, amount0: u256, amount1: u256) -> SharesInfo;
    fn convert_to_assets(self: @TContractState, shares: u256) -> MyPositions;
    fn total_liquidity_per_pool(self: @TContractState, pool_index: u64) -> u256;
    fn get_position(self: @TContractState, pool_index: u64) -> MyPosition;
    fn get_positions(self: @TContractState) -> MyPositions;
    fn handle_fees(ref self: TContractState, pool_index: u64);
    fn harvest(
        ref self: TContractState,
        rewardsContract: ContractAddress,
        claim: Claim,
        proof: Span<felt252>,
        swapInfo1: AvnuMultiRouteSwap,
        swapInfo2: AvnuMultiRouteSwap
    );
    fn get_pool_settings(self: @TContractState, pool_index: u64) -> ClSettings;
    fn get_managed_pools(self: @TContractState) -> Array<ManagedPool>;
    fn get_managed_pools_len(self: @TContractState) -> u64;
    fn rebalance_pool(ref self: TContractState, rebalance_params: RebalanceParams);
    fn set_settings(ref self: TContractState, fee_settings: FeeSettings);
    fn add_pool(ref self: TContractState, pool: ManagedPool);
    fn remove_pool(ref self: TContractState, pool_index: u64);
    fn get_amount_delta(self: @TContractState, pool_index: u64, liquidity: u256) -> (u256, u256);
    fn get_fee_settings(self: @TContractState) -> FeeSettings;
    fn get_managed_pool(self: @TContractState, index: u64) -> ManagedPool;
}
