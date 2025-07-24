// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@solady/src/auth/Ownable.sol";
import {OracleData, OracleLib} from "../libraries/OracleLib.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";

/**
 * @title OracleRange
 * @notice A contract that manages oracle updates with a timelock mechanism and guardian oversight
 * @dev This contract implements a two-step oracle update process:
 *      1. Owner proposes a new oracle configuration
 *      2. After timelock period expires, owner can accept the proposal
 *      3. Guardian can reject proposals at any time during the timelock
 * @author Mangrove
 */
contract OracleRange is Ownable {
  using OracleLib for OracleData;

  /*//////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when caller is not the guardian
  error NotGuardian();

  /// @notice Thrown when trying to accept an oracle that is still timelocked
  error OracleTimelocked();

  /// @notice Thrown when trying to propose an invalid oracle configuration
  error InvalidOracle();

  /*//////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a new oracle is proposed
   * @param key The hash of the proposed oracle data
   * @param oracle The proposed oracle data
   */
  event ProposedOracle(bytes32 indexed key, OracleData oracle);

  /**
   * @notice Emitted when a proposed oracle is accepted and becomes active
   * @param key The hash of the accepted oracle data
   */
  event AcceptedOracle(bytes32 indexed key);

  /**
   * @notice Emitted when a proposed oracle is rejected by the guardian
   * @param key The hash of the rejected oracle data
   */
  event RejectedOracle(bytes32 indexed key);

  /**
   * @notice Emitted when a new guardian is designated
   * @param oldGuardian The address of the previous guardian
   * @param newGuardian The address of the new guardian
   */
  event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);

  /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice The currently active oracle configuration
  OracleData public oracle;

  /// @notice The proposed oracle configuration awaiting timelock completion
  OracleData public proposedOracle;

  /// @notice Address that can reject proposed oracle updates
  /// @dev Guardian provides an additional security layer against malicious oracle proposals
  address public guardian;

  /*//////////////////////////////////////////////////////////////
                           MODIFIERS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Restricts function access to the guardian only
   * @dev Reverts with NotGuardian if caller is not the guardian
   */
  modifier onlyGuardian() {
    if (msg.sender != guardian) revert NotGuardian();
    _;
  }

  /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Initializes the OracleRange contract
   * @param _oracle Initial oracle configuration to set as active
   * @param _owner Address that will own the contract (can propose/accept oracle updates)
   * @param _guardian Address that can reject oracle proposals
   * @dev Sets the initial oracle's proposedAt timestamp to current block timestamp
   * @dev Emits events for initial guardian and oracle state for proper indexing
   */
  constructor(OracleData memory _oracle, address _owner, address _guardian) {
    // Set proposal timestamp for initial oracle to current time
    _oracle.proposedAt = uint40(block.timestamp);
    oracle = _oracle;
    _initializeOwner(_owner);
    guardian = _guardian;

    // Emit events for initial state for indexing purposes
    bytes32 oracleKey = keccak256(abi.encode(_oracle));
    emit GuardianChanged(address(0), _guardian);
    emit ProposedOracle(oracleKey, _oracle);
    emit AcceptedOracle(oracleKey);
  }

  /*//////////////////////////////////////////////////////////////
                       INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Internal function to guard owner initialization
   * @return bool Always returns true to allow owner initialization only once
   * @dev Required override from Ownable to enable owner initialization in constructor
   */
  function _guardInitializeOwner() internal pure override returns (bool) {
    return true;
  }

  /*//////////////////////////////////////////////////////////////
                       PUBLIC FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Gets the current tick based on oracle configuration
   */
  function getCurrentTick() public view returns (Tick) {
    return oracle.tick();
  }

  /*//////////////////////////////////////////////////////////////
                       EXTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Proposes a new oracle configuration
   * @param _oracle The new oracle configuration to propose
   * @dev Only owner can propose. Validates oracle before acceptance and sets proposedAt timestamp
   * @dev The proposed oracle will be subject to timelock defined in _oracle.timelockMinutes
   * @dev Reverts with InvalidOracle if the oracle configuration cannot provide valid tick values
   */
  function proposeOracle(OracleData memory _oracle) external onlyOwner {
    // Validate that the oracle can provide valid tick values
    if (!_oracle.isValid()) revert InvalidOracle();

    // Set proposal timestamp to current block time
    _oracle.proposedAt = uint40(block.timestamp);
    proposedOracle = _oracle;
    emit ProposedOracle(keccak256(abi.encode(_oracle)), _oracle);
  }

  /**
   * @notice Accepts the currently proposed oracle and makes it active
   * @dev Only owner can accept. Reverts if oracle is still timelocked
   * @dev Once accepted, the proposed oracle becomes the active oracle
   */
  function acceptOracle() external onlyOwner {
    OracleData memory _oracle = proposedOracle;
    // Check if timelock period has elapsed
    if (oracle.timelocked(_oracle.proposedAt)) revert OracleTimelocked();
    oracle = _oracle;
    emit AcceptedOracle(keccak256(abi.encode(_oracle)));
  }

  /**
   * @notice Rejects the currently proposed oracle
   * @dev Only guardian can reject. Clears the proposed oracle and emits RejectedOracle event
   * @dev Guardian can reject at any time during the timelock period
   */
  function rejectOracle() external onlyGuardian {
    OracleData memory _oracle = proposedOracle;
    delete proposedOracle; // Clear the proposed oracle
    emit RejectedOracle(keccak256(abi.encode(_oracle)));
  }

  /**
   * @notice Sets a new guardian address
   * @param newGuardian The address of the new guardian
   * @dev Only the current guardian can designate a new guardian
   * @dev The new guardian will have the ability to reject oracle proposals
   */
  function setGuardian(address newGuardian) external onlyGuardian {
    address oldGuardian = guardian;
    guardian = newGuardian;
    emit GuardianChanged(oldGuardian, newGuardian);
  }
}
