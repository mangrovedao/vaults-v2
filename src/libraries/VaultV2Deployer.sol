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
  function deployVault(MangroveVaultV2.VaultInitParams memory params) external returns (address vault) {
    vault = address(new MangroveVaultV2(params));
  }
}
