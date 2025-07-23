// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {KandelManagement} from "./KandelManagement.sol";
import {OracleData, OracleLib} from "../libraries/OracleLib.sol";
import {AbstractKandelSeeder} from
  "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/AbstractKandelSeeder.sol";

/**
 * @title KandelManagementRebalancing
 * @notice Extends KandelManagement with whitelist functionality for authorized rebalancing operations
 * @dev This contract adds a timelock-based whitelist system to KandelManagement, allowing the owner
 *      to propose addresses for whitelisting with guardian oversight. Whitelisted addresses can
 *      be targets for rebalancing operations for the vault.
 * @author Mangrove
 */
contract KandelManagementRebalancing is KandelManagement {
  using OracleLib for OracleData;

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
   * @notice Emitted when a proposed address is rejected by the guardian
   * @param _address The address that was rejected
   */
  event WhitelistRejected(address indexed _address);

  /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice Mapping to track which addresses are whitelisted for rebalancing operations
  mapping(address => bool) public isWhitelisted;

  /// @notice Private mapping to track whitelist propositions with their timestamps
  /// @dev Maps address to the timestamp when it was proposed (0 = not proposed)
  mapping(address => uint40) private _whitelistPropositions;

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
                       WHITELIST FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Proposes an address for whitelisting with timelock protection
   * @param _address The address to propose for whitelisting
   * @dev Only owner can propose addresses. The proposal must go through a timelock period
   *      before it can be accepted. Guardian can reject during the timelock period.
   * @dev Reverts with AlreadyProposed if the address is already proposed
   */
  function proposeWhitelist(address _address) external onlyOwner {
    if (!_canWhitelist(_address)) revert InvalidWhitelistAddress();
    uint40 existing = _whitelistPropositions[_address];
    if (existing > 0) revert AlreadyProposed();
    _whitelistPropositions[_address] = uint40(block.timestamp);
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
    uint40 existing = _whitelistPropositions[_address];
    if (existing == 0) revert NotProposed();

    if (oracle.timelocked(existing)) {
      revert TimelockNotExpired();
    }

    isWhitelisted[_address] = true;
    delete _whitelistPropositions[_address];
    emit WhitelistAccepted(_address);
  }

  /**
   * @notice Rejects a proposed address and removes it from consideration
   * @param _address The address to reject
   * @dev Only guardian can reject proposals. This clears the proposal without
   *      adding the address to the whitelist. Guardian can reject at any time
   *      during the timelock period.
   * @dev Reverts with NotProposed if the address was not proposed
   */
  function rejectWhitelist(address _address) external onlyGuardian {
    uint40 existing = _whitelistPropositions[_address];
    if (existing == 0) revert NotProposed();
    delete _whitelistPropositions[_address];
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
    // Cannot whitelist the Kandel contract itself
    if (_address == address(KANDEL)) return false;

    // Cannot whitelist the base token
    if (_address == BASE) return false;

    // Cannot whitelist the quote token
    if (_address == QUOTE) return false;

    return true;
  }

  /*//////////////////////////////////////////////////////////////
                       VIEW FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Returns the timestamp when an address was proposed for whitelisting
   * @param _address The address to check
   * @return timestamp The timestamp when the address was proposed (0 if not proposed)
   * @dev This function allows external callers to check the status of whitelist proposals
   */
  function whitelistProposedAt(address _address) external view returns (uint40 timestamp) {
    return _whitelistPropositions[_address];
  }

  /**
   * @notice Checks if a whitelist proposal can be accepted (timelock has expired)
   * @param _address The address to check
   * @return canAccept True if the proposal exists and timelock has expired
   * @dev Returns false if the address was not proposed or if timelock hasn't expired
   */
  function canAcceptWhitelist(address _address) external view returns (bool canAccept) {
    uint40 proposedAt = _whitelistPropositions[_address];
    if (proposedAt == 0) return false;

    return !oracle.timelocked(proposedAt);
  }
}
