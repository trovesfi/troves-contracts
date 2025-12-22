use starknet::ContractAddress;

// Define the contract interface
#[starknet::interface]
pub trait IAumOracle<TContractState> {
    /// Reports current assets and estimated delta, updating internal estimates.
    /// Only callable by accounts with the RELAYER_ROLE.
    fn report(ref self: TContractState, current_assets: u256, new_estimated_assets_delta: u256);

    /// Resets the internally stored estimated assets to zero.
    /// Only callable by accounts with the RELAYER_ROLE.
    fn reset_estimated_assets(ref self: TContractState);

    /// Retrieves the current internally stored estimated assets.
    fn get_estimated_assets(self: @TContractState) -> u256;

    /// Retrieves the address of the vault contract.
    fn get_vault_address(self: @TContractState) -> starknet::ContractAddress;

    fn assert_vesu_health_factor(ref self: TContractState, vesu_singleton: ContractAddress, pool_id: felt252, collateral: ContractAddress, debt: ContractAddress, user: ContractAddress, min_hf: u32, max_hf: u32);
}

#[starknet::interface]
pub trait IVault<TContractState> {
    fn report(ref self: TContractState, new_aum: u256);
}

// Define the role identifier for RELAYER
const RELAYER_ROLE: felt252 = selector!("RELAYER_ROLE");

// Define the contract module
#[starknet::contract]
pub mod AumOracle {
    // Core library imports
    use super::{RELAYER_ROLE, IVaultDispatcherTrait};
    use starknet::{ContractAddress, ClassHash};
    use starknet::storage::*;

    use strkfarm_contracts::components::vesu::{vesuStruct, vesuSettingsImpl, vesuToken};
    use strkfarm_contracts::interfaces::IVesu::{IStonDispatcher};
    use strkfarm_contracts::helpers::constants;

    // OpenZeppelin Access Control Component imports <a href="https://docs.openzeppelin.com/../contracts-cairo/2.0.0/access#access" target="_blank" rel="noopener noreferrer" className="bg-light-secondary dark:bg-dark-secondary px-1 rounded ml-1 no-underline text-xs text-black/70 dark:text-white/70 relative hover:underline">1</a>
    use openzeppelin::access::accesscontrol::AccessControlComponent;
    use openzeppelin::access::accesscontrol::DEFAULT_ADMIN_ROLE;
    use openzeppelin::upgrades::upgradeable::UpgradeableComponent;
    use openzeppelin::upgrades::interface::IUpgradeable;
    use openzeppelin::introspection::src5::SRC5Component;

    // Component declaration for AccessControl <a href="https://docs.openzeppelin.com/../contracts-cairo/2.0.0/access#access" target="_blank" rel="noopener noreferrer" className="bg-light-secondary dark:bg-dark-secondary px-1 rounded ml-1 no-underline text-xs text-black/70 dark:text-white/70 relative hover:underline">1</a>
    component!(path: AccessControlComponent, storage: accesscontrol, event: AccessControlEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    // Embed AccessControl's external ABI and internal implementations <a href="https://docs.openzeppelin.com/../contracts-cairo/2.0.0/access#access" target="_blank" rel="noopener noreferrer" className="bg-light-secondary dark:bg-dark-secondary px-1 rounded ml-1 no-underline text-xs text-black/70 dark:text-white/70 relative hover:underline">1</a>
    #[abi(embed_v0)]
    impl AccessControlImpl = AccessControlComponent::AccessControlImpl<ContractState>;
    impl AccessControlInternalImpl = AccessControlComponent::InternalImpl<ContractState>;
 
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    // Define storage variables
    #[storage]
    pub struct Storage {
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage, 
        #[substorage(v0)]
        accesscontrol: AccessControlComponent::Storage, // Substorage for AccessControl component <a href="https://docs.openzeppelin.com/../contracts-cairo/2.0.0/access#access" target="_blank" rel="noopener noreferrer" className="bg-light-secondary dark:bg-dark-secondary px-1 rounded ml-1 no-underline text-xs text-black/70 dark:text-white/70 relative hover:underline">1</a>
        vault_address: ContractAddress, // Address of the vault contract
        estimated_assets: u256, // Stored estimated assets
    }

    // Events for AccessControlComponent <a href="https://docs.openzeppelin.com/../contracts-cairo/2.0.0/access#access" target="_blank" rel="noopener noreferrer" className="bg-light-secondary dark:bg-dark-secondary px-1 rounded ml-1 no-underline text-xs text-black/70 dark:text-white/70 relative hover:underline">1</a>
    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
    }

    /// Constructor for the AssetReporter contract.
    /// Initializes the Access Control component, grants roles, and sets the vault address.
    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin_address: ContractAddress,
        default_relayer_address: ContractAddress,
        vault_contract_address: ContractAddress
    ) {
        // Initialize the AccessControl component <a href="https://docs.openzeppelin.com/../contracts-cairo/2.0.0/access#access" target="_blank" rel="noopener noreferrer" className="bg-light-secondary dark:bg-dark-secondary px-1 rounded ml-1 no-underline text-xs text-black/70 dark:text-white/70 relative hover:underline">1</a>
        self.accesscontrol.initializer();
        // Grant DEFAULT_ADMIN_ROLE to the specified admin address.
        // This admin will be able to manage other roles, including RELAYER_ROLE <a href="https://docs.openzeppelin.com/../contracts-cairo/2.0.0/access#access" target="_blank" rel="noopener noreferrer" className="bg-light-secondary dark:bg-dark-secondary px-1 rounded ml-1 no-underline text-xs text-black/70 dark:text-white/70 relative hover:underline">1</a>.
        self.accesscontrol.set_role_admin(DEFAULT_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        self.accesscontrol.set_role_admin(RELAYER_ROLE, DEFAULT_ADMIN_ROLE);
        self.accesscontrol._grant_role(DEFAULT_ADMIN_ROLE, admin_address);
        self.accesscontrol._grant_role(RELAYER_ROLE, default_relayer_address);

        // Store the vault contract address, which cannot be edited after deployment.
        self.vault_address.write(vault_contract_address);
    }

    // Implement the contract interface <a href="https://docs.starknet.io/guides/quickstart/hellostarknet" target="_blank" rel="noopener noreferrer" className="bg-light-secondary dark:bg-dark-secondary px-1 rounded ml-1 no-underline text-xs text-black/70 dark:text-white/70 relative hover:underline">6</a><a href="https://book.cairo-lang.org/ch100-00-introduction-to-smart-contracts.html" target="_blank" rel="noopener noreferrer" className="bg-light-secondary dark:bg-dark-secondary px-1 rounded ml-1 no-underline text-xs text-black/70 dark:text-white/70 relative hover:underline">7</a>
    #[abi(embed_v0)]
    pub impl AssetReporterImpl of super::IAumOracle<ContractState> {
        /// Reports current assets and estimated delta.
        ///
        /// This function updates the contract's internal estimated assets and
        /// conceptually calls a vault contract's `report` function.
        /// Access is restricted to accounts with the `RELAYER_ROLE` <a href="https://docs.openzeppelin.com/../contracts-cairo/2.0.0/access#access" target="_blank" rel="noopener noreferrer" className="bg-light-secondary dark:bg-dark-secondary px-1 rounded ml-1 no-underline text-xs text-black/70 dark:text-white/70 relative hover:underline">1</a>.
        ///
        /// Arguments:
        /// * `current_assets`: The current total assets.
        /// * `new_estimated_assets_delta`: The change in estimated assets.
        fn report(ref self: ContractState, current_assets: u256, new_estimated_assets_delta: u256) {
            // Assert that only an account with the RELAYER_ROLE can call this function <a href="https://docs.openzeppelin.com/../contracts-cairo/2.0.0/access#access" target="_blank" rel="noopener noreferrer" className="bg-light-secondary dark:bg-dark-secondary px-1 rounded ml-1 no-underline text-xs text-black/70 dark:text-white/70 relative hover:underline">1</a>
            self.accesscontrol.assert_only_role(RELAYER_ROLE);

            let old_stored_estimated_assets = self.estimated_assets.read();

            // Store the new estimated value by adding `new_estimated_assets_delta` to the current estimation.
            let new_stored_estimated_assets = old_stored_estimated_assets + new_estimated_assets_delta;
            self.estimated_assets.write(new_stored_estimated_assets);

            // Calculate the `new_aum` to be passed to the vault's report function:
            // `current_assets + old_stored_estimated_assets + new_estimated_assets_delta`
            // This simplifies to `current_assets + new_stored_estimated_assets`.
            let new_aum_for_vault_report = current_assets + new_stored_estimated_assets;

            super::IVaultDispatcher {
                contract_address: self.vault_address.read()
            }.report(new_aum_for_vault_report);
        }

        /// Resets the internally stored estimated assets to zero.
        /// Only callable by accounts with the `RELAYER_ROLE` <a href="https://docs.openzeppelin.com/../contracts-cairo/2.0.0/access#access" target="_blank" rel="noopener noreferrer" className="bg-light-secondary dark:bg-dark-secondary px-1 rounded ml-1 no-underline text-xs text-black/70 dark:text-white/70 relative hover:underline">1</a>.
        fn reset_estimated_assets(ref self: ContractState) {
            // Assert that only an account with the RELAYER_ROLE can call this function <a href="https://docs.openzeppelin.com/../contracts-cairo/2.0.0/access#access" target="_blank" rel="noopener noreferrer" className="bg-light-secondary dark:bg-dark-secondary px-1 rounded ml-1 no-underline text-xs text-black/70 dark:text-white/70 relative hover:underline">1</a>
            self.accesscontrol.assert_only_role(RELAYER_ROLE);
            self.estimated_assets.write(0);
        }

        /// Retrieves the current internally stored estimated assets.
        ///
        /// Returns:
        /// * `u256`: The current estimated assets.
        fn get_estimated_assets(self: @ContractState) -> u256 {
            self.estimated_assets.read()
        }

        /// Retrieves the address of the vault contract.
        ///
        /// Returns:
        /// * `ContractAddress`: The address of the vault contract.
        fn get_vault_address(self: @ContractState) -> ContractAddress {
            self.vault_address.read()
        }

        fn assert_vesu_health_factor(ref self: ContractState, vesu_singleton: ContractAddress, pool_id: felt252, collateral: ContractAddress, debt: ContractAddress, user: ContractAddress, min_hf: u32, max_hf: u32) {
            let _struct = vesuStruct {
                singleton: IStonDispatcher { contract_address: vesu_singleton },
                pool_id,
                debt: debt,
                col: collateral,
                oracle: constants::ORACLE_OURS()
            };
            let deposits: Array<vesuToken> = array![vesuToken {
                underlying_asset: collateral,
            }];
            let borrows: Array<vesuToken> = array![vesuToken {
                underlying_asset: debt,
            }];
            let hf = _struct.health_factor(user, deposits, borrows);
            assert(hf >= min_hf, 'vesu hf too low');
            assert(hf <= max_hf, 'vesu hf too high');
        }
    }

    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);

            self.upgradeable.upgrade(new_class_hash);
        }
    }
}