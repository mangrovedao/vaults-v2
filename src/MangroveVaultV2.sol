// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Internal dependencies
import {KandelManagementRebalancing} from "./base/KandelManagementRebalancing.sol";
import {OracleData} from "./libraries/OracleLib.sol";

// External dependencies (Mangrove strategies)
import {AbstractKandelSeeder} from
  "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/AbstractKandelSeeder.sol";

// External dependencies (Mangrove protocol)
import {IMangrove, Local, OLKey} from "@mgv/src/IMangrove.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {MAX_SAFE_VOLUME, MAX_TICK} from "@mgv/lib/core/Constants.sol";

// External dependencies (solady)
import {FixedPointMathLib as Math} from "@solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "@solady/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "@solady/src/utils/ReentrancyGuard.sol";
import {Ownable} from "@solady/src/auth/Ownable.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {ERC20} from "@solady/src/tokens/ERC20.sol";

/**
 * @notice Rebalance parameters struct
 * @param sell Whether to sell (true) or buy (false)
 * @param amount Amount to swap
 * @param minOut Minimum amount to receive
 * @param target Target contract for swap
 * @param data Calldata for swap
 */
struct RebalanceParams {
  bool sell;
  uint256 amount;
  uint256 minOut;
  address target;
  bytes data;
}

contract MangroveVaultV2 is ERC20, KandelManagementRebalancing, ReentrancyGuard {
  using SafeTransferLib for address;
  using SafeCastLib for uint256;
  using SafeCastLib for int256;
  using Math for int256;
  using Math for uint256;

  /*//////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when a zero address is provided where a non-zero address is required
   * @dev This can occur in various functions in MangroveVault.sol where addresses are expected
   */
  error ZeroAddress();

  /**
   * @notice Thrown when attempting to perform an operation with a zero amount
   * @dev This can occur in mint and burn functions in MangroveVault.sol when the amount is zero
   */
  error ZeroAmount();

  /**
   * @notice Thrown when there's a mismatch between expected and actual initial mint shares
   * @dev This occurs in the mint function in MangroveVault.sol during the initial mint
   * @param expected The expected number of shares
   * @param actual The actual number of shares
   */
  error InitialMintSharesMismatch(uint256 expected, uint256 actual);

  /**
   * @notice Thrown when the oracle returns an invalid (negative) price
   * @dev This occurs in the getPrice function in ChainlinkConsumer.sol
   */
  error OracleInvalidPrice();

  /**
   * @notice Thrown when attempting to withdraw an unauthorized token
   * @dev This can occur in withdrawal functions in MangroveVault.sol
   * @param unauthorizedToken The address of the unauthorized token
   */
  error CannotWithdrawToken(address unauthorizedToken);

  /**
   * @notice Thrown when a fee exceeds the maximum allowed
   * @dev This can occur when setting fees in MangroveVault.sol
   * @param maxAllowed The maximum allowed fee
   * @param attempted The attempted fee
   */
  error MaxFeeExceeded(uint256 maxAllowed, uint256 attempted);

  /**
   * @notice Thrown when a quote amount calculation results in an overflow
   * @dev This can occur in various calculations involving quote amounts in MangroveVault.sol
   */
  error QuoteAmountOverflow();

  /**
   * @notice Thrown when a deposit would exceed the maximum total allowed
   * @dev This occurs in the mint function in MangroveVault.sol
   * @param currentTotal The current total in quote
   * @param nextTotal The next total in quote after the deposit
   * @param maxTotal The maximum allowed total in quote
   */
  error DepositExceedsMaxTotal(uint256 currentTotal, uint256 nextTotal, uint256 maxTotal);

  /**
   * @notice Thrown when an unauthorized contract attempts to perform a swap
   * @dev This occurs in swap-related functions in MangroveVault.sol
   * @param target The address of the unauthorized swap contract
   */
  error UnauthorizedSwapContract(address target);

  /**
   * @notice Thrown when slippage exceeds the allowed amount in a transaction
   * @dev This can occur in mint, burn, and swap functions in MangroveVault.sol
   * @param expected The expected amount
   * @param received The actual received amount
   */
  error SlippageExceeded(uint256 expected, uint256 received);

  /**
   * @notice Thrown when a native transfer fails
   * @dev This can occur in the withdrawNative function in MangroveVault.sol
   */
  error NativeTransferFailed();

  /**
   * @notice Thrown when an unauthorized account attempts to perform an owner/manager-only action
   * @dev This error is used to restrict access to functions that should only be callable by the owner of the manager
   * @param account The address of the unauthorized account that attempted the action
   */
  error ManagerOwnerUnauthorized(address account);

  /**
   * @notice Thrown when the maximum price spread is invalid
   * @dev This can occur when setting the maximum price spread in MangroveVault.sol
   * @param maxPriceSpread The invalid maximum price spread
   */
  error InvalidMaxPriceSpread(uint256 maxPriceSpread);

  /**
   * @notice Thrown when trying to use oracle functionality while the oracle is disabled
   */
  error OracleNotEnabled();

  /**
   * @notice Thrown when trying to disable oracle that is already enabled
   */
  error OracleEnabled();

  /**
   * @notice Thrown when the tick deviation exceeds the maximum allowed deviation
   */
  error TickDeviationExceeded();

  /**
   * @notice Thrown when attempting to execute a position update before the required delay has passed
   */
  error PositionUpdateNotReady();

  /**
   * @notice Thrown when attempting to operate on a non-existent position update
   */
  error NoPositionUpdatePending();

  /**
   * @notice Thrown when attempting to execute a position update that has been disputed
   */
  error PositionUpdateIsDisputed();

  /**
   * @notice Thrown when a function restricted to the guardian is called by another address
   */
  error OnlyGuardian();

  /**
   * @notice Thrown when an invalid maximum tick deviation value is provided
   */
  error InvalidMaxTickDeviation();

  /*//////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a swap operation is performed
   * @param pool Address of the pool where the swap occurred
   * @param baseAmountChange Change in base token amount (positive for increase, negative for decrease; from vault's perspective)
   * @param quoteAmountChange Change in quote token amount (positive for increase, negative for decrease; from vault's perspective)
   * @param sell Boolean indicating whether it's a sell (true) or buy (false) operation
   */
  event Swap(address pool, int256 baseAmountChange, int256 quoteAmountChange, bool sell);

  /**
   * @notice Emitted when shares are minted
   * @param user Address of the user minting shares
   * @param shares Number of shares minted
   * @param baseAmount Amount of base tokens used for minting
   * @param quoteAmount Amount of quote tokens used for minting
   * @param tick Current tick at the time of minting
   */
  event Mint(address indexed user, uint256 shares, uint256 baseAmount, uint256 quoteAmount, int256 tick);

  /**
   * @notice Emitted when shares are burned
   * @param user Address of the user burning shares
   * @param shares Number of shares burned
   * @param baseAmount Amount of base tokens received from burning
   * @param quoteAmount Amount of quote tokens received from burning
   * @param tick Current tick at the time of burning
   */
  event Burn(address indexed user, uint256 shares, uint256 baseAmount, uint256 quoteAmount, int256 tick);

  /**
   * @notice Emitted when the Kandel position is set or updated
   * @param tickIndex0 Tick index of the first offer
   * @param tickOffset Tick offset between offers
   * @param gasprice Gas price for the Kandel strategy
   * @param gasreq Gas requirement for the Kandel strategy
   * @param stepSize Step size for the Kandel strategy
   * @param pricePoints Number of price points for the Kandel strategy
   * @param fundsState Current state of the funds
   */
  event SetKandelPosition(
    int256 tickIndex0,
    uint256 tickOffset,
    uint32 gasprice,
    uint24 gasreq,
    uint32 stepSize,
    uint32 pricePoints,
    State fundsState
  );

  /**
   * @notice Emitted when interest is accrued
   * @param feeShares Number of shares allocated as fees
   * @param newTotalInQuote New total value in quote tokens after accruing interest
   * @param timestamp Timestamp when the interest was accrued
   */
  event AccrueInterest(uint256 feeShares, uint256 newTotalInQuote, uint256 timestamp);

  /**
   * @notice Emitted when the last total value in quote tokens is updated
   * @param lastTotalInQuote Updated last total value in quote tokens
   * @param timestamp Timestamp when the update occurred
   */
  event UpdateLastTotalInQuote(uint256 lastTotalInQuote, uint256 timestamp);

  /**
   * @notice Emitted when the fee data is set
   * @param performanceFee Performance fee
   * @param managementFee Management fee
   * @param feeRecipient Fee recipient
   */
  event SetFeeData(uint256 performanceFee, uint256 managementFee, address feeRecipient);

  /**
   * @notice Emitted when the maximum total value in quote token is set
   * @param maxTotalInQuote Maximum total value in quote token
   */
  event SetMaxTotalInQuote(uint256 maxTotalInQuote);

  /**
   * @notice Emitted when a new oracle is created
   * @param creator Address of the account that created the oracle
   * @param oracle Address of the newly created oracle
   */
  event OracleCreated(address creator, address oracle);

  /**
   * @notice Emitted when the maximum price spread is set
   * @param maxPriceSpread The new maximum price spread
   */
  event SetMaxPriceSpread(uint256 maxPriceSpread);

  /**
   * @notice Emitted when oracle configuration is updated
   * @param oracleEnabled Whether the oracle is enabled
   * @param oracle Address of the oracle contract
   * @param storedTick The stored tick value
   * @param maxTickDeviation Maximum allowed deviation in ticks
   */
  event OracleConfigUpdated(bool oracleEnabled, address oracle, Tick storedTick, uint24 maxTickDeviation);

  /**
   * @notice Emitted when a new guardian is set
   * @param newGuardian Address of the new guardian
   */
  event GuardianSet(address indexed newGuardian);

  /**
   * @notice Emitted when a position update is proposed
   * @param targetTick The target tick for the position update
   * @param executeTime Timestamp when the update can be executed
   */
  event PositionUpdateProposed(Tick targetTick, uint256 executeTime);

  /**
   * @notice Emitted when a proposed position update is disputed
   */
  event PositionUpdateDisputed();

  /**
   * @notice Emitted when a position update is executed
   * @param targetTick The tick that was set during execution
   */
  event PositionUpdateExecuted(Tick targetTick);

  /**
   * @notice Emitted when a position update is canceled
   */
  event PositionUpdateCanceled();

  event EmergencyKill(address indexed guardian, uint256 timestamp);

  event ManagementFeesAccrued(uint256 feeShares, uint256 timeElapsed);

  /*//////////////////////////////////////////////////////////////
                        CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @notice The precision of the performance fee.
  uint256 internal constant PERFORMANCE_FEE_PRECISION = 1e5;
  /// @notice The maximum performance fee.
  uint16 internal constant MAX_PERFORMANCE_FEE = 5e4;

  /// @notice The precision of the management fee.
  uint256 internal constant MANAGEMENT_FEE_PRECISION = 1e5 * 365 days;
  /// @notice The maximum management fee.
  uint16 internal constant MAX_MANAGEMENT_FEE = 5e3;

  /// @notice The minimum amount of liquidity to be able to withdraw (dead share value to mitigate inflation attacks)
  uint256 internal constant MINIMUM_LIQUIDITY = 1e3;

  /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice The Mangrove deployment.
  IMangrove public immutable MGV;

  /// @notice The number of decimals of the LP token.
  uint8 internal immutable DECIMALS;

  /// @notice The name of the LP token.
  string internal NAME;

  /// @notice The symbol of the LP token.
  string internal SYMBOL;

  /// @notice Maximum base token amount allowed in the vault
  uint256 public immutable MAX_BASE;

  /// @notice Maximum quote token amount allowed in the vault
  uint256 public immutable MAX_QUOTE;

  /// @notice The factor to scale the quote token amount by at initial mint.
  uint256 internal immutable QUOTE_SCALE;

  modifier onlyOwnerOrManager() {
    if (msg.sender != owner() && msg.sender != manager) {
      revert ManagerOwnerUnauthorized(msg.sender);
    }
    _;
  }

  /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  constructor(
    AbstractKandelSeeder seeder,
    address base,
    address quote,
    string memory _name,
    string memory _symbol,
    uint8 _decimals,
    uint256 _maxBase,
    uint256 _maxQuote,
    uint256 tickSpacing,
    address _manager,
    uint16 _managementFee,
    OracleData memory _oracle,
    address _owner,
    address _guardian
  ) KandelManagementRebalancing(seeder, base, quote, tickSpacing, _manager, _managementFee, _oracle, _owner, _guardian) {
    NAME = _name;
    SYMBOL = _symbol;
    (bool success, uint8 result) = _tryGetAssetDecimals(quote);
    if (!success) revert();
    uint8 offset = _decimals - result;
    DECIMALS = _decimals;
    QUOTE_SCALE = 10 ** offset;
    MAX_BASE = _maxBase;
    MAX_QUOTE = _maxQuote;
  }

  /**
   * @inheritdoc ERC20
   */
  function decimals() public view override returns (uint8) {
    return DECIMALS;
  }

  /**
   * @inheritdoc ERC20
   */
  function name() public view override returns (string memory) {
    return NAME;
  }

  /**
   * @inheritdoc ERC20
   */
  function symbol() public view override returns (string memory) {
    return SYMBOL;
  }

  /**
   * @notice Calculates the total value of the vault's assets in quote token.
   */
  function totalInQuote() public view returns (uint256 quoteAmount, Tick tick) {
    uint256 baseAmount;
    (baseAmount, quoteAmount) = totalBalances();
    tick = getCurrentTick();
    quoteAmount = quoteAmount + tick.inboundFromOutboundUp(baseAmount);
  }

  /**
   * @notice Calculates the total value of the vault's assets in base token.
   */
  function totalInBase() public view returns (uint256 baseAmount, Tick tick) {
    uint256 quoteAmount;
    (baseAmount, quoteAmount) = totalBalances();
    tick = getCurrentTick();
    baseAmount = baseAmount + getCurrentTick().inboundFromOutboundUp(quoteAmount);
  }

  /**
   * @notice Computes the shares that can be minted and minimum amounts
   */
  function getMintAmounts(uint256 baseMax, uint256 quoteMax)
    external
    view
    returns (uint256 shares, uint256 minBaseOut, uint256 minQuoteOut)
  {
    baseMax = Math.min(baseMax, MAX_SAFE_VOLUME);
    quoteMax = Math.min(quoteMax, MAX_SAFE_VOLUME);

    uint256 _totalSupply = totalSupply();

    if (_totalSupply != 0) {
      (uint256 baseAmount, uint256 quoteAmount) = totalBalances();

      if (baseAmount == 0 && quoteAmount != 0) {
        shares = quoteMax.mulDiv(_totalSupply, quoteAmount);
        minBaseOut = 0;
        minQuoteOut = shares.mulDiv(quoteAmount, _totalSupply);
      } else if (baseAmount != 0 && quoteAmount == 0) {
        shares = baseMax.mulDiv(_totalSupply, baseAmount);
        minBaseOut = shares.mulDiv(baseAmount, _totalSupply);
        minQuoteOut = 0;
      } else if (baseAmount != 0 && quoteAmount != 0) {
        shares = Math.min(baseMax.mulDiv(_totalSupply, baseAmount), quoteMax.mulDiv(_totalSupply, quoteAmount));
        minBaseOut = shares.mulDiv(baseAmount, _totalSupply);
        minQuoteOut = shares.mulDiv(quoteAmount, _totalSupply);
      }
    } else {
      Tick tick = getCurrentTick();

      minBaseOut = tick.outboundFromInbound(quoteMax);
      if (minBaseOut > baseMax) {
        minBaseOut = baseMax;
        minQuoteOut = tick.inboundFromOutboundUp(baseMax);
      } else {
        minQuoteOut = quoteMax;
      }

      (, shares) = ((tick.inboundFromOutboundUp(minBaseOut) + minQuoteOut) * QUOTE_SCALE).zeroFloorSub(MINIMUM_LIQUIDITY);
    }
  }

  /**
   * @notice Calculates the underlying token balances corresponding to a given share amount.
   */
  function totalBalancesByShare(uint256 share) public view returns (uint256 baseAmount, uint256 quoteAmount) {
    (uint256 baseBalance, uint256 quoteBalance) = totalBalances();
    uint256 _totalSupply = totalSupply();

    if (_totalSupply == 0) {
      return (0, 0);
    }

    baseAmount = share.mulDiv(baseBalance, _totalSupply);
    quoteAmount = share.mulDiv(quoteBalance, _totalSupply);
  }

  /**
   * @notice Rebalances the vault by performing a swap
   */
  function rebalance(RebalanceParams memory params)
    external
    payable
    onlyManager
    nonReentrant
    returns (uint256 base, uint256 quote)
  {
    // Accrue fees before rebalancing
    _accrueManagementFees();

    if (!isWhitelisted[params.target]) {
      revert UnauthorizedSwapContract(params.target);
    }

    (uint256 baseBalance, uint256 quoteBalance) = vaultBalances();

    if (params.sell) {
      // Selling base for quote
      (, uint256 missingBase) = params.amount.zeroFloorSub(baseBalance);
      if (missingBase > 0) {
        KANDEL.withdrawFunds(missingBase, 0, address(this));
      }
      BASE.safeApproveWithRetry(params.target, params.amount);
    } else {
      // Buying base with quote
      (, uint256 missingQuote) = params.amount.zeroFloorSub(quoteBalance);
      if (missingQuote > 0) {
        KANDEL.withdrawFunds(0, missingQuote, address(this));
      }
      QUOTE.safeApproveWithRetry(params.target, params.amount);
    }

    // Execute swap
    params.target.functionCall(params.data);

    // Check results
    (uint256 newBaseBalance, uint256 newQuoteBalance) = vaultBalances();

    if (params.sell) {
      uint256 receivedQuote = newQuoteBalance - quoteBalance;
      if (receivedQuote < params.minOut) {
        revert SlippageExceeded(params.minOut, receivedQuote);
      }
      BASE.safeApproveWithRetry(params.target, 0);
    } else {
      uint256 receivedBase = newBaseBalance - baseBalance;
      if (receivedBase < params.minOut) {
        revert SlippageExceeded(params.minOut, receivedBase);
      }
      QUOTE.safeApproveWithRetry(params.target, 0);
    }

    base = newBaseBalance;
    quote = newQuoteBalance;

    emit Swap(
      params.target,
      int256(newBaseBalance) - int256(baseBalance),
      int256(newQuoteBalance) - int256(quoteBalance),
      params.sell
    );

    _checkDistribution();

    return (base, quote);
  }

  /**
   * @notice Emergency kill function that withdraws all funds from Kandel (guardian only)
   * @dev This function is for emergency situations where immediate fund withdrawal is needed
   */
  function kill() external onlyGuardian {
    // Accrue fees before emergency withdrawal
    _accrueManagementFees();

    // Withdraw all offers and funds from Kandel to the vault
    KANDEL.withdrawAllOffersAndFundsTo(payable(address(this)));

    // Update state to reflect funds are no longer in Kandel
    state.inKandel = false;

    emit EmergencyKill(msg.sender, block.timestamp);
  }

  /**
   * @notice Deposits all available funds from the vault to Kandel
   */
  function _depositAllFunds() internal {
    (uint256 baseBalance, uint256 quoteBalance) = vaultBalances();
    if (baseBalance > 0) {
      BASE.safeApproveWithRetry(address(KANDEL), baseBalance);
    }
    if (quoteBalance > 0) {
      QUOTE.safeApproveWithRetry(address(KANDEL), quoteBalance);
    }
    KANDEL.depositFunds(baseBalance, quoteBalance);
  }

  /**
   * @notice Accrues management fees globally based on time elapsed
   * @dev Called before any major operation to ensure fees are up to date
   */
  function _accrueManagementFees() internal {
    uint256 managementFee = state.managementFee;
    if (managementFee == 0) return;

    uint256 lastAccrualTime = state.lastFeeAccrualTime;
    uint256 timeElapsed = block.timestamp - lastAccrualTime;
    if (timeElapsed == 0) return;

    uint256 _totalSupply = totalSupply();
    if (_totalSupply == 0) {
      state.lastFeeAccrualTime = uint64(block.timestamp);
      return;
    }

    // Calculate management fee shares to mint
    // Fee rate is annual, so we calculate the portion for the elapsed time
    uint256 annualFeeRate = managementFee;
    uint256 feeRate = annualFeeRate * timeElapsed / (365 days);

    // Calculate fee shares: feeShares / (totalSupply + feeShares) = feeRate / PRECISION
    // Rearranging: feeShares = (totalSupply * feeRate) / (PRECISION - feeRate)
    uint256 feeShares = _totalSupply.mulDiv(feeRate, MANAGEMENT_FEE_PRECISION - feeRate);

    if (feeShares > 0) {
      _mint(state.feeRecipient, feeShares);
      emit ManagementFeesAccrued(feeShares, timeElapsed);
    }

    state.lastFeeAccrualTime = uint64(block.timestamp);
  }

  /**
   * @dev author Solady (https://github.com/vectorized/solady/blob/main/src/tokens/ERC4626.sol)
   * @dev Helper function to get the decimals of the underlying asset.
   * Useful for setting the return value of `_underlyingDecimals` during initialization.
   * If the retrieval succeeds, `success` will be true, and `result` will hold the result.
   * Otherwise, `success` will be false, and `result` will be zero.
   *
   * Example usage:
   * ```
   * (bool success, uint8 result) = _tryGetAssetDecimals(underlying);
   * _decimals = success ? result : _DEFAULT_UNDERLYING_DECIMALS;
   * ```
   */
  function _tryGetAssetDecimals(address underlying) internal view returns (bool success, uint8 result) {
    /// @solidity memory-safe-assembly
    assembly {
      // Store the function selector of `decimals()`.
      mstore(0x00, 0x313ce567)
      // Arguments are evaluated last to first.
      success :=
        and(
          // Returned value is less than 256, at left-padded to 32 bytes.
          and(lt(mload(0x00), 0x100), gt(returndatasize(), 0x1f)),
          // The staticcall succeeds.
          staticcall(gas(), underlying, 0x1c, 0x04, 0x00, 0x20)
        )
      result := mul(mload(0x00), success)
    }
  }

  // Interaction functions

  function fundMangrove() external payable {
    MGV.fund{value: msg.value}(address(KANDEL));
  }

  /**
   * @notice Manually accrue management fees (public function)
   */
  function accrueManagementFees() external {
    _accrueManagementFees();
  }

  receive() external payable {}

  /**
   * @notice Sets the fee data for the vault (management fee only)
   */
  function setFeeData(uint16 managementFee, address feeRecipient) external onlyOwner {
    if (managementFee > MAX_MANAGEMENT_FEE) {
      revert MaxFeeExceeded(MAX_MANAGEMENT_FEE, managementFee);
    }
    if (feeRecipient == address(0)) revert ZeroAddress();

    // Accrue fees before changing fee parameters
    _accrueManagementFees();

    state.managementFee = managementFee;
    state.feeRecipient = feeRecipient;

    emit SetFeeData(0, managementFee, feeRecipient);
  }

  /**
   * @notice Manually deposits funds to Kandel
   */
  function depositFundsToKandel() external onlyOwnerOrManager {
    // Accrue fees before major operations
    _accrueManagementFees();
    _depositAllFunds();
  }

  /**
   * @notice Withdraws ERC20 tokens from the vault
   */
  function withdrawERC20(address token, uint256 amount) external onlyOwner {
    if (token == BASE || token == QUOTE || token == address(this)) {
      revert CannotWithdrawToken(token);
    }
    token.safeTransfer(msg.sender, amount);
  }

  /**
   * @notice Withdraws native currency from the vault
   */
  function withdrawNative() external onlyOwner {
    (bool success,) = payable(msg.sender).call{value: address(this).balance}("");
    if (!success) {
      revert NativeTransferFailed();
    }
  }

  /**
   * @notice Mints new shares by depositing tokens into the vault
   * @dev For initial minting, oracle must be initialized and use the oracle tick
   */
  function mint(uint256 maxBase, uint256 maxQuote, uint256 minSharesOut) external nonReentrant returns (uint256 shares) {
    if (maxBase == 0 && maxQuote == 0) revert ZeroAmount();

    // Accrue fees before minting
    _accrueManagementFees();

    uint256 _totalSupply = totalSupply();
    Tick tick = getCurrentTick();
    uint256 baseAmount;
    uint256 quoteAmount;

    if (_totalSupply != 0) {
      // Proportional to existing position
      (uint256 baseBalance, uint256 quoteBalance) = totalBalances();

      if (baseBalance == 0 && quoteBalance != 0) {
        shares = maxQuote.mulDiv(_totalSupply, quoteBalance);
        baseAmount = 0;
        quoteAmount = shares.mulDiv(quoteBalance, _totalSupply);
      } else if (baseBalance != 0 && quoteBalance == 0) {
        shares = maxBase.mulDiv(_totalSupply, baseBalance);
        baseAmount = shares.mulDiv(baseBalance, _totalSupply);
        quoteAmount = 0;
      } else if (baseBalance != 0 && quoteBalance != 0) {
        shares = Math.min(maxBase.mulDiv(_totalSupply, baseBalance), maxQuote.mulDiv(_totalSupply, quoteBalance));
        baseAmount = shares.mulDiv(baseBalance, _totalSupply);
        quoteAmount = shares.mulDiv(quoteBalance, _totalSupply);
      }
    } else {
      // Initial minting using oracle tick
      baseAmount = tick.outboundFromInbound(maxQuote);
      if (baseAmount > maxBase) {
        baseAmount = maxBase;
        quoteAmount = tick.inboundFromOutboundUp(maxBase);
      } else {
        quoteAmount = maxQuote;
      }

      (, shares) = ((tick.inboundFromOutboundUp(baseAmount) + quoteAmount) * QUOTE_SCALE).zeroFloorSub(MINIMUM_LIQUIDITY);
      _mint(address(this), MINIMUM_LIQUIDITY);
    }

    if (shares < minSharesOut) {
      revert SlippageExceeded(minSharesOut, shares);
    }

    // Check TVL limits after deposit
    (uint256 currentBaseBalance, uint256 currentQuoteBalance) = totalBalances();

    if (currentBaseBalance + baseAmount > MAX_BASE) {
      revert DepositExceedsMaxTotal(currentBaseBalance, currentBaseBalance + baseAmount, MAX_BASE);
    }

    if (currentQuoteBalance + quoteAmount > MAX_QUOTE) {
      revert DepositExceedsMaxTotal(currentQuoteBalance, currentQuoteBalance + quoteAmount, MAX_QUOTE);
    }

    // Transfer tokens from user to vault
    if (baseAmount > 0) {
      BASE.safeTransferFrom(msg.sender, address(this), baseAmount);
    }
    if (quoteAmount > 0) {
      QUOTE.safeTransferFrom(msg.sender, address(this), quoteAmount);
    }

    _mint(msg.sender, shares);

    emit Mint(msg.sender, shares, baseAmount, quoteAmount, Tick.unwrap(tick));

    return shares;
  }

  /**
   * @notice Burns shares and withdraws underlying assets
   * @dev If TVL - offered volume < amount to withdraw, retract position and burn shares
   */
  function burn(uint256 shares, uint256 minBaseOut, uint256 minQuoteOut)
    external
    nonReentrant
    returns (uint256 base, uint256 quote)
  {
    if (shares == 0) revert ZeroAmount();

    // Accrue fees before burning
    _accrueManagementFees();

    // Get offered volume and TVL
    (uint256 kandelBase, uint256 kandelQuote) = kandelBalances();
    (uint256 totalBase, uint256 totalQuote) = totalBalances();

    uint256 _totalSupply = totalSupply();
    uint256 userShareOfBase = shares.mulDiv(totalBase, _totalSupply);
    uint256 userShareOfQuote = shares.mulDiv(totalQuote, _totalSupply);

    // Check if we need to retract position
    (uint256 vaultBase, uint256 vaultQuote) = vaultBalances();
    if (userShareOfBase > vaultBase || userShareOfQuote > vaultQuote) {
      // Not enough liquidity in vault, need to withdraw from Kandel
      KANDEL.withdrawAllOffersAndFundsTo(payable(address(this)));
    }

    // Burn user shares
    _burn(msg.sender, shares);

    // Calculate output amounts
    base = userShareOfBase;
    quote = userShareOfQuote;

    // Check slippage
    if (base < minBaseOut) {
      revert SlippageExceeded(minBaseOut, base);
    }
    if (quote < minQuoteOut) {
      revert SlippageExceeded(minQuoteOut, quote);
    }

    // Transfer assets to user
    if (base > 0) {
      BASE.safeTransfer(msg.sender, base);
    }
    if (quote > 0) {
      QUOTE.safeTransfer(msg.sender, quote);
    }

    emit Burn(msg.sender, shares, base, quote, Tick.unwrap(getCurrentTick()));

    return (base, quote);
  }
}
