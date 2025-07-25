// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC4626Kandel {
  /**
   * @notice Allows the admin to withdraw any tokens (and native) that is not the underlying ERC20 or ERC4626 of the strat.
   * @param token The token to withdraw.
   * @param amount The amount of tokens to withdraw.
   * @param recipient The recipient of the tokens.
   */
  function adminWithdrawTokens(address token, uint256 amount, address recipient) external;

  /**
   * @notice Allows the admin to withdraw native tokens.
   * @param amount The amount of native tokens to withdraw.
   * @param recipient The recipient of the native tokens.
   */
  function adminWithdrawNative(uint256 amount, address recipient) external;

  /**
   * @notice Sets the vault for a given token.
   * @param token The token for which to set the vault.
   * @param vault The address of the vault to set.
   * @param minAssetsOut The minimum amount of assets that must be withdrawn when moving funds to the new vault
   * @param minSharesOut The minimum amount of shares that must be withdrawn when moving funds to the new vault
   */
  function setVaultForToken(address token, address vault, uint256 minAssetsOut, uint256 minSharesOut) external;

  /**
   * @notice Returns the current vault addresses for the base and quote tokens
   * @return baseVault The address of the vault for the base token
   * @return quoteVault The address of the vault for the quote token
   */
  function currentVaults() external view returns (address baseVault, address quoteVault);
}
