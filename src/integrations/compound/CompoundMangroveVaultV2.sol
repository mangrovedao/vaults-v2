// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveVaultV2} from "../../MangroveVaultV2.sol";
import {ICompoundKandel} from "../../interfaces/integrations/ICompoundKandel.sol";

contract CompoundMangroveVaultV2 is MangroveVaultV2 {
  constructor(MangroveVaultV2.VaultInitParams memory _params) MangroveVaultV2(_params) {}

  /**
   * @notice Allows the admin to withdraw tokens from the vault.
   * @dev This function can only be called by the admin.
   * @param token The token to be withdrawn. Use address(0) to withdraw the native token.
   * @param amount The amount of tokens to be withdrawn.
   * @param recipient The address to which the tokens will be sent.
   */
  function adminWithdrawTokens(address token, uint256 amount, address recipient) external onlyOwner {
    if (token == address(0)) ICompoundKandel(address(KANDEL)).adminWithdrawNative(amount, recipient);
    else ICompoundKandel(address(KANDEL)).adminWithdrawTokens(token, amount, recipient);
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

  /**
   * @notice Claims rewards from the Takara fork of Compound V2
   * @dev This function is specific to the Takara fork of Compound V2 and claims
   *      any accumulated rewards for the underlying Kandel strategy. The rewards
   *      are claimed directly by the Kandel contract.
   */
  function claimReward() external {
    ICompoundKandel(address(KANDEL)).claimReward();
  }

  /*//////////////////////////////////////////////////////////////
                       INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  function _accrueCompoundInterestForToken(address token) internal {
    ICompoundKandel(address(KANDEL)).accrueInterest(token);
  }

  function _accrueCompoundInterest() internal {
    _accrueCompoundInterestForToken(address(BASE));
    _accrueCompoundInterestForToken(address(QUOTE));
  }

  function _onBeforeMint() internal override {
    _accrueCompoundInterest();
  }

  function _onBeforeBurn() internal override {
    _accrueCompoundInterest();
  }
}
