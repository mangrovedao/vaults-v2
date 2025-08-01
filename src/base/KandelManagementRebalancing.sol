// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {KandelManagement} from "./KandelManagement.sol";
import {OracleData, OracleLib} from "../libraries/OracleLib.sol";
import {TickLib, Tick} from "@mgv/lib/core/TickLib.sol";
import {AbstractKandelSeeder} from
  "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/AbstractKandelSeeder.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {LibCall} from "lib/solady/src/utils/LibCall.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";

/**
 * @title KandelManagementRebalancing
 * @notice Extends KandelManagement with whitelist functionality for authorized rebalancing operations
 * @dev This contract adds a timelock-based whitelist system to KandelManagement, allowing the owner
 *      to propose addresses for whitelisting with guardian oversight. Whitelisted addresses can
 *      be targets for rebalancing operations for the vault.
 * @author Mangrove
 */
contract KandelManagementRebalancing is KandelManagement, ReentrancyGuardTransient {
  using OracleLib for OracleData;
  using SafeTransferLib for address;
  using LibCall for address;

  /*//////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when trying to propose an address that is already proposed
  error AlreadyProposed();

  /// @notice Thrown when trying to accept/reject an address that was not proposed
  error NotProposed();

  /// @notice Thrown when trying to accept a whitelist proposal before the timelock has expired
  error TimelockNotExpired();

  /// @notice Thrown when trying to whitelist an invalid address (Kandel contract, base token, or quote token)
  error InvalidWhitelistAddress();

  /// @notice Thrown when trying to rebalance with a non-whitelisted target address
  error InvalidRebalanceAddress();

  /// @notice Thrown when there is insufficient token balance for the requested operation
  error InsufficientBalanceForRebalance();

  /// @notice Thrown when the trade tick is outside the oracle's acceptable range
  error InvalidTradeTick();

  /*//////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when an address is proposed for whitelisting
   * @param _address The address proposed for whitelisting
   */
  event WhitelistProposed(address indexed _address);

  /**
   * @notice Emitted when a proposed address is accepted and added to the whitelist
   * @param _address The address that was accepted and whitelisted
   */
  event WhitelistAccepted(address indexed _address);

  /**
   * @notice Emitted when a proposed address is rejected by the guardian or owner
   * @dev Can also be emitted when an address is removed from the whitelist by the guardian or owner
   * @param _address The address that was rejected
   */
  event WhitelistRejected(address indexed _address);

  /**
   * @notice Emitted when a rebalancing operation is performed
   * @param target The target contract for rebalancing
   * @param isSell True if selling base token for quote token, false if buying base token with quote token
   * @param amountIn The amount of tokens sent in the swap
   * @param amountOut The amount of tokens received from the swap
   * @param baseBalanceAfter The balance of the base token after the rebalancing operation
   * @param quoteBalanceAfter The balance of the quote token after the rebalancing operation
   */
  event Rebalanced(
    address indexed target,
    bool isSell,
    uint256 amountIn,
    uint256 amountOut,
    uint256 baseBalanceAfter,
    uint256 quoteBalanceAfter
  );

  /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice Mapping to track which addresses are whitelisted for rebalancing operations
  mapping(address => bool) public isWhitelisted;

  /// @notice Mapping to track whitelist propositions with their timestamps
  /// @dev Maps address to the timestamp when it was proposed for whitelisting (0 = not proposed)
  /// @dev This mapping is used to implement timelock functionality for whitelist proposals
  mapping(address => uint40) public whitelistProposedAt;

  /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Initializes the KandelManagementRebalancing contract
   * @param _seeder The Kandel seeder contract used to deploy the Kandel instance
   * @param _base The base token address for the trading pair
   * @param _quote The quote token address for the trading pair
   * @param _tickSpacing The tick spacing for the trading pair
   * @param _manager The initial manager address
   * @param _managementFee The management fee in basis points (10000 = 100%)
   * @param _oracle The initial oracle configuration
   * @param _owner The owner address (inherited from OracleRange)
   * @param _guardian The guardian address (inherited from OracleRange)
   * @dev Inherits all functionality from KandelManagement and adds whitelist capabilities
   */
  constructor(
    AbstractKandelSeeder _seeder,
    address _base,
    address _quote,
    uint256 _tickSpacing,
    address _manager,
    uint16 _managementFee,
    OracleData memory _oracle,
    address _owner,
    address _guardian
  ) KandelManagement(_seeder, _base, _quote, _tickSpacing, _manager, _managementFee, _oracle, _owner, _guardian) {}

  /*//////////////////////////////////////////////////////////////
                       REBALANCING FUNCTION
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Parameters for rebalancing operations
   * @param isSell True if selling base token for quote token, false if buying base token with quote token
   * @param amountIn The amount of tokens to send for the swap
   * @param amountInKandel The amount of tokens to withdraw from the Kandel balance
   * @param amountOut The amount of tokens expected to receive from the swap
   * @param minAmountOut The minimum amount of tokens expected to receive (slippage protection)
   * @param target The whitelisted contract address to perform the swap
   * @param data The call data to send to the target contract for the swap
   */
  struct RebalanceParams {
    bool isSell;
    uint256 amountIn;
    uint256 amountInKandel;
    uint256 minAmountOut;
    address target;
    bytes data;
  }

  /**
   * @notice Deposits any remaining tokens in the vault back to the Kandel strategy
   * @dev Checks balances of both base and quote tokens in the vault
   * @dev Only calls depositFunds if there are tokens to deposit
   * @dev Approves Kandel to spend tokens before depositing
   */
  function _sendTokenToKandel() internal {
    uint256 baseBalance = BASE.balanceOf(address(this));
    uint256 quoteBalance = QUOTE.balanceOf(address(this));
    bool deposit;
    if (baseBalance > 0) {
      BASE.safeApprove(address(KANDEL), baseBalance);
      deposit = true;
    }
    if (quoteBalance > 0) {
      QUOTE.safeApprove(address(KANDEL), quoteBalance);
      deposit = true;
    }
    if (deposit) {
      KANDEL.depositFunds(baseBalance, quoteBalance);
    }
  }

  /**
   * @notice Performs a rebalancing operation by swapping tokens through a whitelisted target
   * @param _params The rebalancing parameters including swap direction, amounts, and target
   * @return sent The actual amount of tokens sent in the swap
   * @return received The actual amount of tokens received from the swap
   * @return callResult The return data from the target contract call
   * @dev Only callable by the manager
   * @dev Only whitelisted addresses can be used as swap targets
   * @dev Validates the trade price against oracle constraints
   * @dev Automatically deposits remaining tokens back to Kandel after the swap
   * @dev Reverts with InvalidRebalanceAddress if target is not whitelisted
   * @dev Reverts with InvalidTradeTick if the trade price is outside oracle range
   * @dev Reverts with InsufficientBalanceForRebalance if there are not enough tokens available
   */
  function rebalance(RebalanceParams memory _params)
    external
    payable
    onlyManager
    nonReentrant
    returns (uint256 sent, uint256 received, bytes memory callResult)
  {
    if (!isWhitelisted[_params.target]) revert InvalidRebalanceAddress();
    // take the tokens from the kandel
    KANDEL.withdrawFunds(
      _params.isSell ? _params.amountInKandel : 0, _params.isSell ? 0 : _params.amountInKandel, address(this)
    );

    address sellToken = _params.isSell ? BASE : QUOTE;
    address buyToken = _params.isSell ? QUOTE : BASE;

    // take a snapshot of the balances
    uint256 sellBalance = sellToken.balanceOf(address(this));
    received = buyToken.balanceOf(address(this));

    // check if we have enough balance for the swap
    if (sellBalance < _params.amountIn) revert InsufficientBalanceForRebalance();

    // give allowance of the funds to the target
    sellToken.safeApprove(_params.target, _params.amountIn);

    // call the target contract
    callResult = _params.target.callContract(msg.value, _params.data);

    // get the amount of token we sent (if underflow, it means we received which is not expected)
    uint256 finalSentBalance = sellToken.balanceOf(address(this));
    received = buyToken.balanceOf(address(this)) - received;

    if (finalSentBalance < sellBalance) {
      sent = sellBalance - finalSentBalance;
      if (!oracle.acceptsTrade(_params.isSell, received, sent)) revert InvalidTradeTick();
    }

    // remove allowance
    sellToken.safeApprove(_params.target, 0);

    // send the tokens to the kandel if needed
    if (state.inKandel) _sendTokenToKandel();

    // get the total balance after the rebalancing operation
    (uint256 baseBalanceAfter, uint256 quoteBalanceAfter) = totalBalances();

    // emit the event
    emit Rebalanced(_params.target, _params.isSell, received, sent, baseBalanceAfter, quoteBalanceAfter);
  }

  /*//////////////////////////////////////////////////////////////
                       WHITELIST FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Proposes an address for whitelisting with timelock protection
   * @param _address The address to propose for whitelisting
   * @dev Only owner can propose addresses. The proposal must go through a timelock period
   *      before it can be accepted. Guardian can reject during the timelock period.
   * @dev Reverts with AlreadyProposed if the address is already proposed or whitelisted
   */
  function proposeWhitelist(address _address) external onlyOwner {
    if (!_canWhitelist(_address)) revert InvalidWhitelistAddress();
    uint40 existing = whitelistProposedAt[_address];
    bool isWhitelisted_ = isWhitelisted[_address];
    if (existing > 0 || isWhitelisted_) revert AlreadyProposed();
    whitelistProposedAt[_address] = uint40(block.timestamp);
    emit WhitelistProposed(_address);
  }

  /**
   * @notice Accepts a proposed address and adds it to the whitelist
   * @param _address The address to accept and whitelist
   * @dev Only owner can accept proposals. The proposal must have existed for at least
   *      the timelock duration (oracle.timelockMinutes). Once accepted, the proposal
   *      is cleared and the address is added to the whitelist.
   * @dev Reverts with NotProposed if the address was not proposed
   * @dev Reverts with TimelockNotExpired if the timelock period hasn't passed
   */
  function acceptWhitelist(address _address) external onlyOwner {
    uint40 existing = whitelistProposedAt[_address];
    if (existing == 0) revert NotProposed();

    if (oracle.timelocked(existing)) {
      revert TimelockNotExpired();
    }

    isWhitelisted[_address] = true;
    delete whitelistProposedAt[_address];
    emit WhitelistAccepted(_address);
  }

  /**
   * @notice Rejects a proposed address and removes it from consideration or from the whitelist
   * @param _address The address to reject
   * @dev Only guardian can reject proposals. This clears the proposal without
   *      adding the address to the whitelist. Guardian can reject at any time
   *      during the timelock period.
   * @dev Reverts with NotProposed if the address was not proposed
   */
  function rejectWhitelist(address _address) external {
    if (msg.sender != guardian) _checkOwner();
    uint40 existing = whitelistProposedAt[_address];
    bool isWhitelisted_ = isWhitelisted[_address];
    if (existing == 0 && !isWhitelisted_) revert NotProposed();
    if (existing > 0) delete whitelistProposedAt[_address];
    if (isWhitelisted_) delete isWhitelisted[_address];
    emit WhitelistRejected(_address);
  }

  /*//////////////////////////////////////////////////////////////
                      INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Validates whether an address can be whitelisted
   * @param _address The address to validate
   * @return canWhitelist True if the address can be whitelisted, false otherwise
   * @dev Virtual function that can be overridden in derived contracts for custom validation
   * @dev Current implementation prevents whitelisting the Kandel contract, base token, and quote token
   */
  function _canWhitelist(address _address) internal view virtual returns (bool canWhitelist) {
    // Cannot whitelist the Kandel contract, base token, or quote token
    return !(_address == address(KANDEL) || _address == BASE || _address == QUOTE);
  }
}
