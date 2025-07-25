// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// External dependencies (Mangrove protocol)
import {AbstractKandelSeeder} from
  "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/AbstractKandelSeeder.sol";
import {GeometricKandel} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/GeometricKandel.sol";
import {DirectWithBidsAndAsksDistribution} from
  "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/DirectWithBidsAndAsksDistribution.sol";
import {CoreKandel} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/CoreKandel.sol";
import {OfferType} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/TradesBaseQuotePair.sol";
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

  /// @notice Thrown when the management fee exceeds the maximum allowed fee
  error MaxManagementFeeExceeded();

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

  /**
   * @notice Emitted when funds are deposited into the Kandel strategy
   * @dev This indicates that funds are now actively managed by the Kandel market-making strategy
   */
  event FundsEnteredKandel();

  /**
   * @notice Emitted when funds are withdrawn from the Kandel strategy
   * @dev This indicates that funds are no longer actively managed by Kandel and returned to the vault
   */
  event FundsExitedKandel();

  /*//////////////////////////////////////////////////////////////
                           CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Maximum allowed management fee (precision is 100_000)
  uint16 private constant MAX_MANAGEMENT_FEE = 10_000; // 10%

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
   * @dev Emits SetManager and SetFeeRecipient events for initial state indexing
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

    // Validate management fee
    if (_managementFee > MAX_MANAGEMENT_FEE) revert MaxManagementFeeExceeded();

    // Initialize state with default values
    state = State({
      inKandel: false,
      feeRecipient: _owner,
      managementFee: _managementFee,
      lastTimestamp: uint40(block.timestamp)
    });

    // Deploy Kandel instance with reneging disabled (false parameter)
    KANDEL = seeder.sow(OLKey(base, quote, tickSpacing), false);

    // Emit events for initial state for indexing purposes
    emit SetManager(_manager);
    emit SetFeeRecipient(_owner);
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

    // Set inKandel to true when populating (emit event only if state changes)
    if (!state.inKandel) {
      state.inKandel = true;
      emit FundsEnteredKandel();
    }

    // Deposit all available funds to the Kandel strategy
    uint256 baseBalance = BASE.balanceOf(address(this));
    uint256 quoteBalance = QUOTE.balanceOf(address(this));

    // Approve Kandel to spend our tokens for offer funding
    if (baseBalance > 0) {
      BASE.safeApprove(address(KANDEL), baseBalance);
    }

    if (quoteBalance > 0) {
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

  /**
   * @notice Retracts Kandel offers from the market with optional fund and provision withdrawal
   * @param from The starting index of offers to retract
   * @param to The ending index of offers to retract
   * @param baseAmount Amount of base tokens to withdraw (0 = no withdrawal, type(uint256).max = maximum)
   * @param quoteAmount Amount of quote tokens to withdraw (0 = no withdrawal, type(uint256).max = maximum)
   * @param withdrawProvisions Whether to withdraw ETH provisions from Mangrove to manager
   * @param recipient The address to which the withdrawn provisions should be sent to.
   * @dev Retracting offers removes them from the market but keeps funds in Kandel unless withdrawn
   * @dev If both baseAmount and quoteAmount are 0, no funds are withdrawn and inKandel remains true
   * @dev If either amount is non-zero, funds are withdrawn and inKandel is set to false
   * @dev Passing type(uint256).max for amounts will withdraw maximum available tokens
   */
  function retractOffers(
    uint256 from,
    uint256 to,
    uint256 baseAmount,
    uint256 quoteAmount,
    bool withdrawProvisions,
    address payable recipient
  ) external onlyManager {
    KANDEL.retractOffers(from, to);
    if (baseAmount > 0 || quoteAmount > 0) {
      KANDEL.withdrawFunds(baseAmount, quoteAmount, address(this));
      if (state.inKandel) {
        state.inKandel = false;
        emit FundsExitedKandel();
      }
    }
    if (withdrawProvisions) {
      KANDEL.withdrawFromMangrove(type(uint256).max, recipient);
    }
  }

  /**
   * @notice Withdraws token funds from Kandel strategy back to this contract
   * @param baseAmount Amount of base tokens to withdraw (use type(uint256).max for maximum)
   * @param quoteAmount Amount of quote tokens to withdraw (use type(uint256).max for maximum)
   * @dev Passing type(uint256).max will withdraw the maximum available amount for each token
   * @dev Not passing the full amount can be useful if underlying vault strategies don't have all liquidity available yet
   * @dev Always sets inKandel state to false, meaning any new funds will go to the vault and not the Kandel
   */
  function withdrawFunds(uint256 baseAmount, uint256 quoteAmount) external onlyManager {
    KANDEL.withdrawFunds(baseAmount, quoteAmount, address(this));
    if (state.inKandel) {
      state.inKandel = false;
      emit FundsExitedKandel();
    }
  }

  /**
   * @notice Withdraws ETH provisions from Mangrove to the manager
   * @param freeWei Amount of ETH (in wei) to withdraw from Mangrove provisions
   * @param recipient The address to which the withdrawn provisions should be sent to.
   * @dev This withdraws ETH that was deposited for offer gas provisioning
   */
  function withdrawFromMangrove(uint256 freeWei, address payable recipient) external onlyManager {
    KANDEL.withdrawFromMangrove(freeWei, recipient);
  }

  /*//////////////////////////////////////////////////////////////
                       VIEW FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Returns the token balances held in this management contract (vault)
   * @return baseBalance The amount of base tokens in the management contract
   * @return quoteBalance The amount of quote tokens in the management contract
   * @dev These are tokens that are not yet deposited into the Kandel strategy
   */
  function vaultBalances() external view returns (uint256 baseBalance, uint256 quoteBalance) {
    baseBalance = BASE.balanceOf(address(this));
    quoteBalance = QUOTE.balanceOf(address(this));
  }

  /**
   * @notice Returns the token balances held in the Kandel strategy
   * @return baseBalance The amount of base tokens in the Kandel strategy
   * @return quoteBalance The amount of quote tokens in the Kandel strategy
   * @dev These are tokens actively used by the Kandel strategy for market making
   */
  function kandelBalances() external view returns (uint256 baseBalance, uint256 quoteBalance) {
    // Ask offers sell base tokens, so reserveBalance for asks returns base token balance
    baseBalance = KANDEL.reserveBalance(OfferType.Ask);
    // Bid offers sell quote tokens, so reserveBalance for bids returns quote token balance
    quoteBalance = KANDEL.reserveBalance(OfferType.Bid);
  }

  /**
   * @notice Returns the total token balances across both vault and Kandel strategy
   * @return baseBalance The total amount of base tokens (vault + Kandel)
   * @return quoteBalance The total amount of quote tokens (vault + Kandel)
   * @dev This represents the total underlying assets controlled by this management contract
   */
  function totalBalances() public view returns (uint256 baseBalance, uint256 quoteBalance) {
    (uint256 vaultBase, uint256 vaultQuote) = this.vaultBalances();
    (uint256 kandelBase, uint256 kandelQuote) = this.kandelBalances();

    baseBalance = vaultBase + kandelBase;
    quoteBalance = vaultQuote + kandelQuote;
  }

  /**
   * @notice Returns the market configuration for this Kandel management contract
   * @return base The base token address
   * @return quote The quote token address
   * @return tickSpacing The tick spacing for the market
   * @dev This information defines the trading pair and market parameters
   */
  function market() external view returns (address base, address quote, uint256 tickSpacing) {
    base = BASE;
    quote = QUOTE;
    tickSpacing = TICK_SPACING;
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
