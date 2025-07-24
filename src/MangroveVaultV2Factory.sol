// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Internal dependencies
import {MangroveVaultV2} from "./MangroveVaultV2.sol";

// External dependencies (Solady)
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";

// Libraries
import {VaultV2Deployer} from "./libraries/VaultV2Deployer.sol";

/**
 * @title MangroveVaultV2Factory
 * @notice Factory contract for deploying MangroveVaultV2 instances
 * @dev This factory provides a standardized way to deploy MangroveVaultV2 contracts
 *      with proper event logging for indexing and tracking deployed vaults.
 *      Each deployment emits an event containing the vault address and initialization parameters.
 * @author Mangrove
 */
contract MangroveVaultV2Factory {
  using EnumerableSetLib for EnumerableSetLib.AddressSet;

  /*//////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a new MangroveVaultV2 is deployed
   * @param vault The address of the deployed vault contract
   * @param params The initialization parameters used to create the vault
   */
  event VaultDeployed(address vault, MangroveVaultV2.VaultInitParams params);

  /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice Enumerable set of all deployed vault addresses
  EnumerableSetLib.AddressSet private _deployedVaults;

  /*//////////////////////////////////////////////////////////////
                      EXTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Deploys a new MangroveVaultV2 instance
   * @param params The initialization parameters for the vault
   * @return vault The address of the newly deployed vault
   * @dev Creates a new MangroveVaultV2 contract with the provided parameters,
   *      registers it in the factory's tracking system, and emits a VaultDeployed event
   *      containing the vault address and the complete initialization parameters struct.
   */
  function deployVault(MangroveVaultV2.VaultInitParams memory params) external returns (address vault) {
    // Deploy the new vault
    vault = VaultV2Deployer.deployVault(params);

    // Register the vault in our tracking system
    _deployedVaults.add(vault);

    // Emit deployment event with parameters
    emit VaultDeployed(vault, params);

    return vault;
  }

  /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Returns the number of vaults deployed by this factory
   * @return count The total number of deployed vaults
   */
  function getDeployedVaultCount() external view returns (uint256 count) {
    return _deployedVaults.length();
  }

  /**
   * @notice Returns the vault address at a specific index
   * @param index The index in the deployed vaults enumerable set
   * @return vault The vault address at the given index
   * @dev Reverts if index is out of bounds
   */
  function getDeployedVault(uint256 index) external view returns (address vault) {
    return _deployedVaults.at(index);
  }

  /**
   * @notice Returns all deployed vault addresses
   * @return vaults Array of all deployed vault addresses
   * @dev Use with caution for large numbers of deployed vaults due to gas costs
   */
  function getAllDeployedVaults() external view returns (address[] memory vaults) {
    return _deployedVaults.values();
  }

  /**
   * @notice Checks if an address is a vault deployed by this factory
   * @param vault The address to check
   * @return isDeployed True if the address is a deployed vault, false otherwise
   */
  function isDeployedVault(address vault) external view returns (bool isDeployed) {
    return _deployedVaults.contains(vault);
  }
}
