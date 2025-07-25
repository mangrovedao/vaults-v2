// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveVaultV2} from "../../MangroveVaultV2.sol";
import {ERC4626MangroveVaultV2} from "../../integrations/erc4626/ERC4626MangroveVaultV2.sol";

library ERC4626VaultV2Deployer {
  function deployVault(MangroveVaultV2.VaultInitParams memory params) external returns (address payable vault) {
    vault = payable(address(new ERC4626MangroveVaultV2(params)));
  }
}
