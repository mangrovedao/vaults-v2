// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveVaultV2} from "../../MangroveVaultV2.sol";
import {CompoundMangroveVaultV2} from "../../integrations/compound/CompoundMangroveVaultV2.sol";

/**
 * @title CompoundVaultV2Deployer
 * @notice Library for deploying CompoundMangroveVaultV2 instances
 * @dev This library provides a factory function to deploy Compound-integrated
 *      MangroveVaultV2 contracts with the specified initialization parameters.
 * @author Mangrove
 */
library CompoundVaultV2Deployer {
  /**
   * @notice Deploys a new CompoundMangroveVaultV2 instance
   * @param params The initialization parameters for the vault
   * @return vault The address of the newly deployed CompoundMangroveVaultV2 contract
   * @dev Creates a new vault that extends MangroveVaultV2 with Compound V2 integration
   *      capabilities, including reward claiming and admin token withdrawal functions.
   */
  function deployVault(MangroveVaultV2.VaultInitParams memory params) external returns (address payable vault) {
    vault = payable(address(new CompoundMangroveVaultV2(params)));
  }
}
