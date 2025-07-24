// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// External dependencies (Mangrove strategies)
import {KandelManagementRebalancing} from "./base/KandelManagementRebalancing.sol";
import {AbstractKandelSeeder} from
  "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/AbstractKandelSeeder.sol";

// External dependencies (solady)
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

// External dependencies (Mangrove core)
import {TickLib, Tick} from "@mgv/lib/core/TickLib.sol";

// Internal dependencies
import {OracleData, OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title MangroveVaultV2
 * @notice A vault that provides liquidity to Mangrove through a Kandel market-making strategy
 * @dev This contract combines ERC20 vault functionality with Kandel market-making strategy management.
 *      Users can deposit base and quote tokens to mint vault shares, which represent their proportional
 *      ownership of the vault's assets. The vault actively manages liquidity using a Kandel strategy
 *      with oracle-validated price ranges and includes management fee accrual capabilities.
 * @author Mangrove
 */
contract MangroveVaultV2 is KandelManagementRebalancing, ERC20 {
  using FixedPointMathLib for uint256;
  using OracleLib for OracleData;
  using SafeTransferLib for address;

  /*//////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when initial mint amounts don't result in a valid tick within oracle constraints
  error InvalidInitialMintAmounts();

  /// @notice Thrown when the mint operation would result in fewer shares than the minimum required
  error InsufficientSharesOut();

  /// @notice Thrown when the burn operation would result in less tokens than the minimum required
  error BurnSlippageExceeded();

  /*//////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when management fees are accrued and minted to the fee recipient
   * @param feeShares The number of vault shares minted as management fees
   */
  event AccruedFees(uint256 feeShares);

  /*//////////////////////////////////////////////////////////////
                           CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Minimum liquidity that remains locked in the contract to prevent inflation attacks
  uint256 private constant MINIMUM_LIQUIDITY = 1e3;

  /// @notice Precision factor for management fee calculations (accounts for 1e5 precision and seconds per year)
  uint256 internal constant MANAGEMENT_FEE_PRECISION = 1e5 * 365 days;

  /*//////////////////////////////////////////////////////////////
                       IMMUTABLE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice The name of the ERC20 token
  string internal name_;

  /// @notice The symbol of the ERC20 token
  string internal symbol_;

  /// @notice The number of decimals for the ERC20 token
  uint8 internal immutable DECIMALS;

  /// @notice Offset multiplier used in initial share calculations to ensure reasonable share amounts
  uint256 internal immutable QUOTE_OFFSET;

  /*//////////////////////////////////////////////////////////////
                           STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Parameters required to initialize the MangroveVaultV2 contract
   * @param seeder The Kandel seeder contract used to deploy the Kandel instance
   * @param base The base token address for the trading pair
   * @param quote The quote token address for the trading pair
   * @param tickSpacing The tick spacing for the trading pair
   * @param manager The initial manager address
   * @param managementFee The management fee in basis points (10000 = 100%)
   * @param oracle The initial oracle configuration
   * @param owner The owner address (inherited from OracleRange)
   * @param guardian The guardian address (inherited from OracleRange)
   * @param name The name for the ERC20 vault token
   * @param symbol The symbol for the ERC20 vault token
   * @param decimals The number of decimals for the ERC20 vault token
   * @param quoteOffsetDecimals The number of decimals used to calculate the quote offset multiplier
   */
  struct VaultInitParams {
    AbstractKandelSeeder seeder;
    address base;
    address quote;
    uint256 tickSpacing;
    address manager;
    uint16 managementFee;
    OracleData oracle;
    address owner;
    address guardian;
    string name;
    string symbol;
    uint8 decimals;
    uint8 quoteOffsetDecimals;
  }

  /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Initializes the MangroveVaultV2 contract with the provided parameters
   * @param _params The initialization parameters containing all required configuration
   * @dev Sets up the vault as an ERC20 token and initializes the underlying Kandel management system.
   *      The quote offset is calculated as 2 * 10^quoteOffsetDecimals to ensure reasonable share amounts
   *      during initial minting operations.
   */
  constructor(VaultInitParams memory _params)
    KandelManagementRebalancing(
      _params.seeder,
      _params.base,
      _params.quote,
      _params.tickSpacing,
      _params.manager,
      _params.managementFee,
      _params.oracle,
      _params.owner,
      _params.guardian
    )
  {
    name_ = _params.name;
    symbol_ = _params.symbol;
    DECIMALS = _params.decimals;
    QUOTE_OFFSET = 2 * 10 ** _params.quoteOffsetDecimals;
  }

  /*//////////////////////////////////////////////////////////////
                      ERC20 METADATA FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Returns the name of the vault token
   * @return The name string of the ERC20 token
   */
  function name() public view override returns (string memory) {
    return name_;
  }

  /**
   * @notice Returns the symbol of the vault token
   * @return The symbol string of the ERC20 token
   */
  function symbol() public view override returns (string memory) {
    return symbol_;
  }

  /**
   * @notice Returns the number of decimals used for the vault token
   * @return The number of decimals as a uint8
   */
  function decimals() public view override returns (uint8) {
    return DECIMALS;
  }

  /*//////////////////////////////////////////////////////////////
                     VAULT CALCULATION FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Calculates the amount of shares and tokens required for a mint operation
   * @param baseAmountMax The maximum amount of base tokens the user is willing to deposit
   * @param quoteAmountMax The maximum amount of quote tokens the user is willing to deposit
   * @return sharesOut The number of vault shares that will be minted
   * @return baseIn The amount of base tokens that will be deposited
   * @return quoteIn The amount of quote tokens that will be deposited
   * @dev For the first mint (when total supply is 0), both max amounts are used and shares are calculated
   *      based on the total value with quote offset. For subsequent mints, the deposit amounts are
   *      proportional to existing balances, and the limiting factor determines the actual amounts used.
   */
  function getMintAmounts(uint256 baseAmountMax, uint256 quoteAmountMax)
    public
    view
    returns (uint256 sharesOut, uint256 baseIn, uint256 quoteIn)
  {
    (uint256 baseBalance, uint256 quoteBalance) = totalBalances();
    uint256 supply = totalSupply();
    supply += _accruedFeeShares(state);

    if (supply == 0) {
      baseIn = baseAmountMax;
      quoteIn = quoteAmountMax;
      Tick tick = TickLib.tickFromVolumes(quoteIn + quoteBalance, baseIn + baseBalance);
      if (!oracle.withinDeviation(tick)) revert InvalidInitialMintAmounts();
      sharesOut = (quoteIn + quoteBalance) * QUOTE_OFFSET;
    } else {
      uint256 sharesFromBase = baseAmountMax.fullMulDiv(supply, baseBalance);
      uint256 sharesFromQuote = quoteAmountMax.fullMulDiv(supply, quoteBalance);
      sharesOut = FixedPointMathLib.min(sharesFromBase, sharesFromQuote);
      baseIn = sharesOut.fullMulDiv(baseBalance, supply);
      quoteIn = sharesOut.fullMulDiv(quoteBalance, supply);
    }
  }

  /**
   * @notice Returns current fee configuration and pending fee shares
   * @return managementFee The current management fee in basis points
   * @return feeRecipient The address that receives management fees
   * @return pendingFeeShares The number of fee shares that can be claimed
   * @dev This is a view function that provides transparency into fee accrual without triggering fee collection
   */
  function feeData() external view returns (uint256 managementFee, address feeRecipient, uint256 pendingFeeShares) {
    State memory s = state;
    return (s.managementFee, s.feeRecipient, _accruedFeeShares(s));
  }

  /*//////////////////////////////////////////////////////////////
                        VAULT OPERATIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Mints vault shares by depositing base and quote tokens
   * @param to The address that will receive the minted shares
   * @param baseAmountMax The maximum amount of base tokens to deposit
   * @param quoteAmountMax The maximum amount of quote tokens to deposit
   * @param minSharesOut The minimum number of shares that must be received
   * @return sharesOut The actual number of shares minted
   * @return baseIn The actual amount of base tokens deposited
   * @return quoteIn The actual amount of quote tokens deposited
   * @dev This function transfers tokens from the caller, accrues any pending fees, and mints shares.
   *      For the first mint, minimum liquidity is permanently locked in the contract.
   *      Reverts if the calculated shares are below the minimum requirement.
   */
  function mint(address to, uint256 baseAmountMax, uint256 quoteAmountMax, uint256 minSharesOut)
    external
    nonReentrant
    returns (uint256 sharesOut, uint256 baseIn, uint256 quoteIn)
  {
    (sharesOut, baseIn, quoteIn) = getMintAmounts(baseAmountMax, quoteAmountMax);
    if (sharesOut < minSharesOut) revert InsufficientSharesOut();
    _accrueFees();

    BASE.safeTransferFrom(msg.sender, address(this), baseIn);
    QUOTE.safeTransferFrom(msg.sender, address(this), quoteIn);

    if (totalSupply() == 0) {
      _mint(address(this), MINIMUM_LIQUIDITY);
    }

    _mint(to, sharesOut);
    return (sharesOut, baseIn, quoteIn);
  }

  /**
   * @notice Burns vault shares to withdraw base and quote tokens
   * @param from The address from which shares will be burned
   * @param receiver The address that will receive the withdrawn tokens
   * @param shares The number of vault shares to burn
   * @param minBaseOut The minimum amount of base tokens that must be received
   * @param minQuoteOut The minimum amount of quote tokens that must be received
   * @return baseOut The actual amount of base tokens withdrawn
   * @return quoteOut The actual amount of quote tokens withdrawn
   * @dev This function burns shares from the specified address (requires allowance if not self),
   *      calculates proportional token amounts, and transfers tokens to the receiver.
   *      May withdraw funds from the Kandel strategy if local balance is insufficient.
   *      Reverts if the calculated token amounts are below the minimum requirements.
   */
  function burn(address from, address receiver, uint256 shares, uint256 minBaseOut, uint256 minQuoteOut)
    external
    nonReentrant
    returns (uint256 baseOut, uint256 quoteOut)
  {
    _accrueFees();
    if (from != msg.sender) {
      _spendAllowance(from, msg.sender, shares);
    }

    uint256 supply = totalSupply();
    (uint256 baseBalance, uint256 quoteBalance) = totalBalances();

    baseOut = shares.fullMulDiv(baseBalance, supply);
    quoteOut = shares.fullMulDiv(quoteBalance, supply);
    if (baseOut < minBaseOut) revert BurnSlippageExceeded();
    if (quoteOut < minQuoteOut) revert BurnSlippageExceeded();
    _burn(from, shares);
    baseOut = _sendTokensTo(BASE, receiver, baseOut);
    quoteOut = _sendTokensTo(QUOTE, receiver, quoteOut);
  }

  /*//////////////////////////////////////////////////////////////
                       INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Internal function to send tokens to a recipient, withdrawing from Kandel if necessary
   * @param token The address of the token to send
   * @param to The recipient address
   * @param amount The amount of tokens to send
   * @return sent The actual amount of tokens sent (may be less than requested if insufficient balance)
   * @dev If the local balance is insufficient, this function will attempt to withdraw funds from
   *      the Kandel strategy before sending. The actual sent amount may be less than requested
   *      if there are insufficient total funds available.
   */
  function _sendTokensTo(address token, address to, uint256 amount) internal returns (uint256 sent) {
    uint256 localBalance = token.balanceOf(address(this));
    if (localBalance < amount) {
      if (token == BASE) {
        KANDEL.withdrawFunds(amount - localBalance, 0, address(this));
      } else {
        KANDEL.withdrawFunds(0, amount - localBalance, address(this));
      }
      localBalance = token.balanceOf(address(this));
    }
    sent = FixedPointMathLib.min(amount, localBalance);
    token.safeTransfer(to, sent);
  }

  /**
   * @notice Internal function to accrue and mint management fees
   * @dev Calculates accrued fees based on time elapsed and management fee rate, mints shares
   *      to the fee recipient, and updates the last timestamp. Only accrues fees if there are
   *      any to be collected and updates timestamp to prevent future over-accrual.
   */
  function _accrueFees() internal {
    State memory s = state;
    uint256 feeShares = _accruedFeeShares(s);
    if (feeShares > 0) {
      _mint(s.feeRecipient, feeShares);
      emit AccruedFees(feeShares);
    }
    if (s.lastTimestamp < block.timestamp) {
      state.lastTimestamp = uint40(block.timestamp);
    }
  }

  /**
   * @notice Internal view function to calculate accrued management fee shares
   * @param s The current state struct containing fee configuration and last update timestamp
   * @return feeShares The number of fee shares that have accrued since the last update
   * @dev Calculates fees using the formula: (supply * managementFee * timeElapsed) / MANAGEMENT_FEE_PRECISION
   *      Returns 0 if no management fee is set or no time has elapsed since last update.
   */
  function _accruedFeeShares(State memory s) internal view returns (uint256 feeShares) {
    if (s.managementFee > 0) {
      uint256 currentTime = block.timestamp;
      if (currentTime > s.lastTimestamp) {
        uint256 supply = totalSupply();
        uint256 spanned = currentTime - s.lastTimestamp;
        // TODO: check if fullMulDiv is necessary
        feeShares = supply.fullMulDiv(s.managementFee * spanned, MANAGEMENT_FEE_PRECISION);
      }
    }
  }
}
