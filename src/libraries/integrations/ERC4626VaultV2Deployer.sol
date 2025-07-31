// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveVaultV2} from "../../MangroveVaultV2.sol";
import {ERC4626MangroveVaultV2} from "../../integrations/erc4626/ERC4626MangroveVaultV2.sol";

/**
 * @title ERC4626VaultV2Deployer
 * @notice Library for deploying ERC4626MangroveVaultV2 instances
 * @dev This library provides a factory function to deploy ERC4626-compatible
 *      MangroveVaultV2 contracts with the specified initialization parameters.
 * @author Mangrove
 */
library ERC4626VaultV2Deployer {
  /**
   * @notice Deploys a new ERC4626MangroveVaultV2 instance
   * @param params The initialization parameters for the vault
   * @return vault The address of the newly deployed ERC4626MangroveVaultV2 contract
   * @dev Creates a new ERC4626-compatible vault that extends MangroveVaultV2 with
   *      standard ERC4626 tokenized vault functionality.
   */
  function deployVault(MangroveVaultV2.VaultInitParams memory params) external returns (address payable vault) {
    vault = payable(address(new ERC4626MangroveVaultV2(params)));
  }
}
