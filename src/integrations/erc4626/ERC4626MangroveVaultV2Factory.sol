// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveVaultV2Factory} from "../../MangroveVaultV2Factory.sol";
import {ERC4626MangroveVaultV2} from "./ERC4626MangroveVaultV2.sol";
import {MangroveVaultV2} from "../../MangroveVaultV2.sol";
import {ERC4626VaultV2Deployer} from "../../libraries/integrations/ERC4626VaultV2Deployer.sol";

contract ERC4626MangroveVaultV2Factory is MangroveVaultV2Factory {
  function _deployVault(MangroveVaultV2.VaultInitParams memory params)
    internal
    override
    returns (address payable vault)
  {
    vault = ERC4626VaultV2Deployer.deployVault(params);
  }
}
