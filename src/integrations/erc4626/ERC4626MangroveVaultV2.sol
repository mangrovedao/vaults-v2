// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveVaultV2} from "../../MangroveVaultV2.sol";
import {IERC4626Kandel} from "../../interfaces/integrations/IERC4626Kandel.sol";

contract ERC4626MangroveVaultV2 is MangroveVaultV2 {
  constructor(MangroveVaultV2.VaultInitParams memory _params) MangroveVaultV2(_params) {}

  /**
   * @notice Allows the admin to withdraw tokens from the vault.
   * @dev This function can only be called by the admin.
   * @param token The token to be withdrawn.
   * @param amount The amount of tokens to be withdrawn.
   * @param recipient The address to which the tokens will be sent.
   */
  function adminWithdrawTokens(address token, uint256 amount, address recipient) external onlyOwner {
    IERC4626Kandel(address(KANDEL)).adminWithdrawTokens(token, amount, recipient);
  }

  /**
   * @notice Allows the admin to withdraw native tokens from the vault.
   * @dev This function can only be called by the admin.
   * @param amount The amount of native tokens to be withdrawn.
   * @param recipient The address to which the native tokens will be sent.
   */
  function adminWithdrawNative(uint256 amount, address recipient) external onlyOwner {
    IERC4626Kandel(address(KANDEL)).adminWithdrawNative(amount, recipient);
  }

  /**
   * @notice Sets the vault for a given token.
   * @dev This function can only be called by the admin.
   * @param token The token for which to set the vault.
   * @param vault The vault to be set for the token.
   * @param minAssetsOut The minimum amount of assets that must be withdrawn when moving funds to the new vault
   * @param minSharesOut The minimum amount of shares that must be withdrawn when moving funds to the new vault
   */
  function setVaultForToken(address token, address vault, uint256 minAssetsOut, uint256 minSharesOut)
    external
    onlyOwner
  {
    IERC4626Kandel(address(KANDEL)).setVaultForToken(token, vault, minAssetsOut, minSharesOut);
  }

  /**
   * @notice Returns the current vault addresses for the base and quote tokens
   * @return baseVault The address of the vault for the base token
   * @return quoteVault The address of the vault for the quote token
   */
  function currentVaults() external view returns (address baseVault, address quoteVault) {
    (baseVault, quoteVault) = IERC4626Kandel(address(KANDEL)).currentVaults();
  }
}
