// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveVaultV2Factory} from "../../MangroveVaultV2Factory.sol";
import {CompoundMangroveVaultV2} from "./CompoundMangroveVaultV2.sol";
import {MangroveVaultV2} from "../../MangroveVaultV2.sol";
import {CompoundVaultV2Deployer} from "../../libraries/integrations/CompoundVaultV2Deployer.sol";

contract CompoundMangroveVaultV2Factory is MangroveVaultV2Factory {
  function _deployVault(MangroveVaultV2.VaultInitParams memory params)
    internal
    override
    returns (address payable vault)
  {
    vault = CompoundVaultV2Deployer.deployVault(params);
  }
}
