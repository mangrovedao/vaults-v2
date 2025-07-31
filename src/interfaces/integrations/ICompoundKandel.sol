// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICompoundKandel {
  /**
   * @notice Allows the admin to withdraw any tokens (and native) that is not the underlying ERC20 or cTokens of the strat.
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
   * @notice Sets the Compound market for a given token.
   * @param cToken The cToken market to set for the underlying token
   * @dev Only callable by admin. Will withdraw all assets from old market if one exists, then deposit into new market
   */
  function setMarket(address cToken) external;

  /**
   * @notice Returns the current Compound market addresses for the base and quote tokens
   * @return baseMarket The address of the Compound market for the base token
   * @return quoteMarket The address of the Compound market for the quote token
   */
  function currentMarkets() external view returns (address baseMarket, address quoteMarket);

  /**
   * @notice Accrues interest for the Compound markets.
   * @dev This function is called by the vault to accrue interest for the Compound markets.
   * @dev it must be always called to get the latest balance update on state changing functions.
   */
  function accrueInterest(address token) external returns (uint256);

  /**
   * @notice Claims rewards from the Compound markets (sepcific to takara integration).
   * @dev This function is called by the vault to claim rewards from the Compound markets.
   * @dev it must be always called to get the latest balance update on state changing functions.
   */
  function claimReward() external;
}
