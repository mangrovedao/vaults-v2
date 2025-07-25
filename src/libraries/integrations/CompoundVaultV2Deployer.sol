// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveVaultV2} from "../../MangroveVaultV2.sol";
import {CompoundMangroveVaultV2} from "../../integrations/compound/CompoundMangroveVaultV2.sol";

library CompoundVaultV2Deployer {
  function deployVault(MangroveVaultV2.VaultInitParams memory params) external returns (address payable vault) {
    vault = payable(address(new CompoundMangroveVaultV2(params)));
  }
}
