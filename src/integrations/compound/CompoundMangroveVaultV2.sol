// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveVaultV2} from "../../MangroveVaultV2.sol";
import {ICompoundKandel} from "../../interfaces/integrations/ICompoundKandel.sol";

contract CompoundMangroveVaultV2 is MangroveVaultV2 {
  constructor(MangroveVaultV2.VaultInitParams memory _params) MangroveVaultV2(_params) {}

  /**
   * @notice Allows the admin to withdraw tokens from the vault.
   * @dev This function can only be called by the admin.
   * @param token The token to be withdrawn.
   * @param amount The amount of tokens to be withdrawn.
   * @param recipient The address to which the tokens will be sent.
   */
  function adminWithdrawTokens(address token, uint256 amount, address recipient) external onlyOwner {
    ICompoundKandel(address(KANDEL)).adminWithdrawTokens(token, amount, recipient);
  }

  /**
   * @notice Allows the admin to withdraw native tokens from the vault.
   * @dev This function can only be called by the admin.
   * @param amount The amount of native tokens to be withdrawn.
   * @param recipient The address to which the native tokens will be sent.
   */
  function adminWithdrawNative(uint256 amount, address recipient) external onlyOwner {
    ICompoundKandel(address(KANDEL)).adminWithdrawNative(amount, recipient);
  }

  /**
   * @notice Sets the vault for a given token.
   * @dev This function can only be called by the admin.
   * @param cToken The cToken market to set for the underlying token
   */
  function setMarket(address cToken) external onlyOwner {
    ICompoundKandel(address(KANDEL)).setMarket(cToken);
  }

  /**
   * @notice Returns the current Compound market addresses for the base and quote tokens
   * @return baseMarket The address of the Compound market for the base token
   * @return quoteMarket The address of the Compound market for the quote token
   */
  function currentMarkets() external view returns (address baseMarket, address quoteMarket) {
    (baseMarket, quoteMarket) = ICompoundKandel(address(KANDEL)).currentMarkets();
  }
}
