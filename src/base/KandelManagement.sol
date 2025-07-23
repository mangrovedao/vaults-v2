// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// External dependencies (Mangrove protocol)
import {AbstractKandelSeeder} from
  "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/AbstractKandelSeeder.sol";
import {GeometricKandel} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/GeometricKandel.sol";
import {DirectWithBidsAndAsksDistribution} from
  "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/DirectWithBidsAndAsksDistribution.sol";
import {CoreKandel} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/CoreKandel.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {MAX_TICK} from "@mgv/lib/core/Constants.sol";

// External dependencies (solady)
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

// Internal dependencies
import {OracleRange} from "./OracleRange.sol";
import {OracleData, OracleLib} from "../libraries/OracleLib.sol";

/**
 * @title KandelManagement
 * @notice Manages a Kandel market-making strategy with oracle-based position validation
 * @dev This contract extends OracleRange to provide oracle-validated Kandel strategy management.
 *      It ensures that all Kandel positions respect oracle-defined price ranges by validating
 *      bid and ask distributions before deployment.
 * @author Mangrove
 */
contract KandelManagement is OracleRange {
  using OracleLib for OracleData;
  using SafeTransferLib for address;

  /*//////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when caller is not the manager
  error NotManager();
  
  /// @notice Thrown when the proposed distribution doesn't respect oracle constraints
  error InvalidDistribution();

  /*//////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a new manager is set
   * @param manager The address of the new manager
   */
  event SetManager(address indexed manager);

  /**
   * @notice Emitted when the fee recipient is updated
   * @param feeRecipient The address of the new fee recipient
   */
  event SetFeeRecipient(address indexed feeRecipient);

  /*//////////////////////////////////////////////////////////////
                       IMMUTABLE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice The Kandel strategy instance managed by this contract
  GeometricKandel public immutable KANDEL;

  /// @notice The base token address for the trading pair
  address internal immutable BASE;
  
  /// @notice The quote token address for the trading pair
  address internal immutable QUOTE;
  
  /// @notice The tick spacing for the trading pair
  uint256 internal immutable TICK_SPACING;

  /*//////////////////////////////////////////////////////////////
                           STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Packed state variables for gas optimization
   * @param inKandel Whether the contract is currently managing Kandel positions
   * @param feeRecipient Address that receives management fees
   * @param managementFee Management fee in basis points (10000 = 100%)
   * @param lastTimestamp Last timestamp when state was updated
   */
  struct State {
    bool inKandel; // 8 bits
    address feeRecipient; // 160 bits -> 168 bits
    uint16 managementFee; // 16 bits -> 184 bits
    uint40 lastTimestamp; // 40 bits -> 224 bits
  }

  /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice Address that can execute Kandel management operations
  /// @dev Manager has operational control while owner has governance control
  address public manager;

  /// @notice Packed state variables for the contract
  State public state;

  /*//////////////////////////////////////////////////////////////
                           MODIFIERS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Restricts function access to the manager only
   * @dev Reverts with NotManager if caller is not the manager
   */
  modifier onlyManager() {
    if (msg.sender != manager) revert NotManager();
    _;
  }

  /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Initializes the KandelManagement contract
   * @param seeder The Kandel seeder contract used to deploy the Kandel instance
   * @param base The base token address for the trading pair
   * @param quote The quote token address for the trading pair
   * @param tickSpacing The tick spacing for the trading pair
   * @param _manager The initial manager address
   * @param _managementFee The management fee in basis points (10000 = 100%)
   * @param _oracle The initial oracle configuration
   * @param _owner The owner address (inherited from OracleRange)
   * @param _guardian The guardian address (inherited from OracleRange)
   * @dev Deploys a new GeometricKandel instance through the seeder
   */
  constructor(
    AbstractKandelSeeder seeder,
    address base,
    address quote,
    uint256 tickSpacing,
    address _manager,
    uint16 _managementFee,
    OracleData memory _oracle,
    address _owner,
    address _guardian
  ) OracleRange(_oracle, _owner, _guardian) {
    BASE = base;
    QUOTE = quote;
    TICK_SPACING = tickSpacing;
    manager = _manager;
    
    // Initialize state with default values
    state = State({
      inKandel: false,
      feeRecipient: _owner,
      managementFee: _managementFee,
      lastTimestamp: uint40(block.timestamp)
    });
    
    // Deploy Kandel instance with reneging disabled (false parameter)
    KANDEL = seeder.sow(OLKey(base, quote, tickSpacing), false);
  }

  /*//////////////////////////////////////////////////////////////
                       EXTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Sets a new manager for the contract
   * @param _manager The address of the new manager
   * @dev Only owner can set the manager. Manager has operational control over Kandel functions
   */
  function setManager(address _manager) external onlyOwner {
    manager = _manager;
    emit SetManager(_manager);
  }

  /**
   * @notice Sets a new fee recipient for the contract
   * @param _feeRecipient The address of the new fee recipient
   * @dev Only owner can set the fee recipient. Fee recipient receives management fees
   */
  function setFeeRecipient(address _feeRecipient) external onlyOwner {
    state.feeRecipient = _feeRecipient;
    emit SetFeeRecipient(_feeRecipient);
  }

  /**
   * @notice Populates Kandel offers from scratch with oracle validation
   * @param from The starting index for offer placement
   * @param to The ending index for offer placement
   * @param baseQuoteTickIndex0 The base quote tick index at position 0
   * @param _baseQuoteTickOffset The tick offset between price points
   * @param firstAskIndex The index where asks start (bids are below this)
   * @param bidGives The amount of quote token each bid offer gives
   * @param askGives The amount of base token each ask offer gives
   * @param parameters The Kandel parameters (gas price, gas req, step size, price points)
   * @dev Validates the distribution against oracle constraints before populating
   * @dev Requires ETH payment for offer provisioning (passed via msg.value)
   */
  function populateFromOffset(
    uint256 from,
    uint256 to,
    Tick baseQuoteTickIndex0,
    uint256 _baseQuoteTickOffset,
    uint256 firstAskIndex,
    uint256 bidGives,
    uint256 askGives,
    CoreKandel.Params calldata parameters
  ) external payable onlyManager {
    // Create distribution based on provided parameters
    DirectWithBidsAndAsksDistribution.Distribution memory distribution = KANDEL.createDistribution(
      from,
      to,
      baseQuoteTickIndex0,
      _baseQuoteTickOffset,
      firstAskIndex,
      bidGives,
      askGives,
      parameters.pricePoints,
      parameters.stepSize
    );
    // Validate distribution against oracle constraints
    if (!_checkDistribution(distribution)) revert InvalidDistribution();
    
    // Set inKandel to true when populating
    state.inKandel = true;

    // Deposit all available funds to the Kandel strategy
    uint baseBalance = BASE.balanceOf(address(this));
    uint quoteBalance = QUOTE.balanceOf(address(this));

    // Approve Kandel to spend our tokens for offer funding
    if (baseBalance > 0){
      BASE.safeApprove(address(KANDEL), baseBalance);
    }

    if (quoteBalance > 0){
      QUOTE.safeApprove(address(KANDEL), quoteBalance);
    }
    
    // Populate Kandel with validated distribution, depositing all available funds
    KANDEL.populate{value: msg.value}(distribution, parameters, baseBalance, quoteBalance);
  }

  /**
   * @notice Populates a chunk of existing Kandel offers with oracle validation
   * @param from The starting index for offer placement
   * @param to The ending index for offer placement
   * @param baseQuoteTickIndex0 The base quote tick index at position 0
   * @param firstAskIndex The index where asks start (bids are below this)
   * @param bidGives The amount of quote token each bid offer gives
   * @param askGives The amount of base token each ask offer gives
   * @dev Uses existing Kandel parameters and validates against oracle constraints
   * @dev No ETH payment required as this updates existing offers
   */
  function populateChunkFromOffset(
    uint256 from,
    uint256 to,
    Tick baseQuoteTickIndex0,
    uint256 firstAskIndex,
    uint256 bidGives,
    uint256 askGives
  ) external onlyManager {
    // Get current Kandel parameters
    CoreKandel.Params memory parameters = _params();
    uint256 baseQuoteTickOffset = KANDEL.baseQuoteTickOffset();
    
    // Create distribution with current parameters
    DirectWithBidsAndAsksDistribution.Distribution memory distribution = KANDEL.createDistribution(
      from,
      to,
      baseQuoteTickIndex0,
      baseQuoteTickOffset,
      firstAskIndex,
      bidGives,
      askGives,
      parameters.pricePoints,
      parameters.stepSize
    );
    // Validate distribution against oracle constraints
    if (!_checkDistribution(distribution)) revert InvalidDistribution();
    // Update Kandel chunk with validated distribution
    KANDEL.populateChunk(distribution);
  }

  /*//////////////////////////////////////////////////////////////
                       INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Finds the minimum tick from an array of distribution offers
   * @param offers Array of distribution offers to search
   * @return Tick The minimum tick value found, or MAX_TICK if no valid offers
   * @dev Skips offers with zero gives amount as they are inactive
   */
  function _minTick(DirectWithBidsAndAsksDistribution.DistributionOffer[] memory offers) private pure returns (Tick) {
    int256 minTick = MAX_TICK;
    for (uint256 i = 0; i < offers.length; i++) {
      // Skip inactive offers (zero gives)
      if (offers[i].gives == 0) continue;
      if (Tick.unwrap(offers[i].tick) < minTick) {
        minTick = Tick.unwrap(offers[i].tick);
      }
    }
    return Tick.wrap(minTick);
  }

  /**
   * @notice Validates a distribution against oracle price constraints
   * @param distribution The distribution to validate
   * @return bool True if distribution respects oracle constraints, false otherwise
   * @dev Checks that the minimum ask tick and minimum bid tick are within oracle deviation
   * @dev Uses the current active oracle configuration for validation
   */
  function _checkDistribution(DirectWithBidsAndAsksDistribution.Distribution memory distribution)
    private
    view
    returns (bool)
  {
    // Get the current oracle configuration
    OracleData memory _oracle = oracle;
    // Validate that min ask and min bid ticks are within oracle range
    return _oracle.accepts(_minTick(distribution.asks), _minTick(distribution.bids));
  }

  /**
   * @notice Retrieves current Kandel parameters
   * @return params The current Kandel parameters struct
   * @dev Fetches gas price, gas requirement, step size, and price points from Kandel
   */
  function _params() private view returns (CoreKandel.Params memory params) {
    (uint32 gasprice, uint24 gasreq, uint32 stepSize, uint32 pricePoints) = KANDEL.params();
    params.gasprice = gasprice;
    params.gasreq = gasreq;
    params.stepSize = stepSize;
    params.pricePoints = pricePoints;
  }
}
