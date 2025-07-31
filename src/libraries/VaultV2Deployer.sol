// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Internal dependencies
import {MangroveVaultV2} from "../MangroveVaultV2.sol";

/**
 * @title VaultV2Deployer
 * @notice Library for deploying MangroveVaultV2 instances
 * @author Mangrove
 */
library VaultV2Deployer {
  /**
   * @notice Deploys a new MangroveVaultV2 instance
   * @param params The initialization parameters for the vault
   * @return vault The address of the newly deployed MangroveVaultV2 contract
   * @dev Creates a new base MangroveVaultV2 contract with the specified parameters.
   *      This is the standard vault implementation without additional integrations.
   */
  function deployVault(MangroveVaultV2.VaultInitParams memory params) external returns (address payable vault) {
    vault = payable(address(new MangroveVaultV2(params)));
  }
}
