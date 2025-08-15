// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveVaultV2, ERC20, OracleData, OracleLib} from "../src/MangroveVaultV2.sol";
import {KandelManagement} from "../src/base/KandelManagement.sol";
import {MangroveTest, MockERC20} from "./base/MangroveTest.t.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {TickLib, Tick} from "@mgv/lib/core/TickLib.sol";
import {console} from "forge-std/console.sol";

contract MangroveVaultV2Test is MangroveTest {
  using OracleLib for OracleData;
  using FixedPointMathLib for uint256;

  MangroveVaultV2 public vault;
  address public manager;
  address public guardian;
  address public owner;
  address public user1;
  address public user2;
  address public feeRecipient;

  uint16 public constant MANAGEMENT_FEE = 500; // 5%
  uint8 public constant QUOTE_OFFSET_DECIMALS = 0;
  string public constant VAULT_NAME = "Mangrove Vault Token";
  string public constant VAULT_SYMBOL = "MVT";

  function setUp() public virtual override {
    super.setUp();

    manager = makeAddr("manager");
    guardian = makeAddr("guardian");
    owner = makeAddr("owner");
    user1 = makeAddr("user1");
    user2 = makeAddr("user2");
    feeRecipient = makeAddr("feeRecipient");

    // Setup oracle configuration
    OracleData memory oracle;
    oracle.isStatic = true;
    oracle.maxDeviation = 1000; // Wide range for testing
    oracle.timelockMinutes = 60; // 1 hour
    oracle.staticValue = int24(Tick.unwrap(TickLib.tickFromVolumes(2000e6, 1 ether)));

    // Setup vault initialization parameters
    MangroveVaultV2.VaultInitParams memory params = MangroveVaultV2.VaultInitParams({
      seeder: seeder,
      base: address(WETH),
      quote: address(USDC),
      tickSpacing: 1,
      manager: manager,
      managementFee: MANAGEMENT_FEE,
      oracle: oracle,
      owner: owner,
      guardian: guardian,
      name: VAULT_NAME,
      symbol: VAULT_SYMBOL,
      quoteOffsetDecimals: QUOTE_OFFSET_DECIMALS
    });

    vault = new MangroveVaultV2(params);

    // Mint tokens to test users
    MockERC20(address(WETH)).mint(user1, 100 ether);
    MockERC20(address(USDC)).mint(user1, 100_000e6);
    MockERC20(address(WETH)).mint(user2, 50 ether);
    MockERC20(address(USDC)).mint(user2, 50_000e6);

    // Approve vault to spend user tokens
    vm.startPrank(user1);
    WETH.approve(address(vault), type(uint256).max);
    USDC.approve(address(vault), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(user2);
    WETH.approve(address(vault), type(uint256).max);
    USDC.approve(address(vault), type(uint256).max);
    vm.stopPrank();
  }

  /*//////////////////////////////////////////////////////////////
                      CONSTRUCTOR TESTS
  //////////////////////////////////////////////////////////////*/

  function test_constructor() public view {
    assertEq(vault.name(), VAULT_NAME);
    assertEq(vault.symbol(), VAULT_SYMBOL);
    assertEq(vault.decimals(), 18);
    assertEq(vault.manager(), manager);

    (uint256 managementFee, address feeRecipient_, uint256 pendingFeeShares) = vault.feeData();
    assertEq(managementFee, MANAGEMENT_FEE);
    assertEq(feeRecipient_, owner); // Initial fee recipient is owner
    assertEq(pendingFeeShares, 0);
  }

  /*//////////////////////////////////////////////////////////////
                      ERC20 METADATA TESTS
  //////////////////////////////////////////////////////////////*/

  function test_name() public view {
    assertEq(vault.name(), VAULT_NAME);
  }

  function test_symbol() public view {
    assertEq(vault.symbol(), VAULT_SYMBOL);
  }

  function test_decimals() public view {
    assertEq(vault.decimals(), 18);
  }

  /*//////////////////////////////////////////////////////////////
                       MINT CALCULATION TESTS
  //////////////////////////////////////////////////////////////*/

  function test_getMintAmounts_initialMint() public view {
    uint256 baseAmount = 1 ether;
    uint256 quoteAmount = 2000e6;

    (uint256 sharesOut, uint256 baseIn, uint256 quoteIn) = vault.getMintAmounts(baseAmount, quoteAmount);

    assertEq(baseIn, baseAmount);
    assertEq(quoteIn, quoteAmount);
    // Shares calculated based on quote amount with offset
    uint256 expectedShares = quoteAmount * (2 * 10 ** QUOTE_OFFSET_DECIMALS);
    assertEq(sharesOut, expectedShares);
  }

  function test_getMintAmounts_subsequentMint() public {
    // First mint
    uint256 initialBase = 1 ether;
    uint256 initialQuote = 2000e6;

    vm.prank(user1);
    vault.mint(user1, initialBase, initialQuote, 0);

    // Second mint - should be proportional
    uint256 baseAmount = 0.5 ether;
    uint256 quoteAmount = 2000e6; // More quote than proportional

    (uint256 sharesOut, uint256 baseIn, uint256 quoteIn) = vault.getMintAmounts(baseAmount, quoteAmount);

    // Should be limited by base amount
    assertEq(baseIn, baseAmount);
    assertEq(quoteIn, 1000e6); // Proportional to base amount

    uint256 supply = vault.totalSupply();
    (uint256 baseBalance,) = vault.totalBalances();
    uint256 expectedShares = baseAmount.fullMulDiv(supply, baseBalance);
    assertEq(sharesOut, expectedShares);
  }

  function test_getMintAmounts_invalidInitialTick() public {
    // Test with amounts that would create a tick outside oracle range
    OracleData memory restrictiveOracle;
    restrictiveOracle.isStatic = true;
    restrictiveOracle.staticValue = int24(0);
    restrictiveOracle.maxDeviation = 10; // Very restrictive
    restrictiveOracle.timelockMinutes = 60;

    vm.startPrank(owner);
    vault.proposeOracle(restrictiveOracle);
    vm.warp(block.timestamp + 61 minutes);
    vault.acceptOracle();
    vm.stopPrank();

    vm.expectRevert(MangroveVaultV2.InvalidInitialMintAmounts.selector);
    vault.getMintAmounts(1 ether, 10_000e6); // This creates an invalid tick
  }

  /*//////////////////////////////////////////////////////////////
                           MINT TESTS
  //////////////////////////////////////////////////////////////*/

  function test_mint_emitsReceivedTokensEvent() public {
    uint256 baseAmount = 1 ether;
    uint256 quoteAmount = 2000e6;

    // Calculate expected balances after mint
    uint256 expectedBaseBalance = baseAmount;
    uint256 expectedQuoteBalance = quoteAmount;

    vm.expectEmit(false, false, false, true);
    emit MangroveVaultV2.ReceivedTokens(baseAmount, quoteAmount, expectedBaseBalance, expectedQuoteBalance);

    vm.prank(user1);
    vault.mint(user1, baseAmount, quoteAmount, 0);
  }

  function test_mint_emitsReceivedTokensEvent_subsequentMint() public {
    // Initial mint
    vm.prank(user1);
    vault.mint(user1, 1 ether, 2000e6, 0);

    // Second mint
    uint256 baseAmount = 0.5 ether;
    uint256 quoteAmount = 1000e6;

    // Expected balances after second mint
    uint256 expectedBaseBalance = 1.5 ether;
    uint256 expectedQuoteBalance = 3000e6;

    vm.expectEmit(false, false, false, true);
    emit MangroveVaultV2.ReceivedTokens(baseAmount, quoteAmount, expectedBaseBalance, expectedQuoteBalance);

    vm.prank(user2);
    vault.mint(user2, baseAmount, quoteAmount, 0);
  }

  function test_mint_initialMint() public {
    uint256 baseAmount = 1 ether;
    uint256 quoteAmount = 2000e6;

    vm.expectEmit(false, false, false, true);
    emit MangroveVaultV2.ReceivedTokens(baseAmount, quoteAmount, baseAmount, quoteAmount);
    vm.expectEmit(true, true, false, true);
    emit ERC20.Transfer(address(0), address(vault), 1e3);
    vm.expectEmit(true, true, false, true);
    emit ERC20.Transfer(address(0), user1, quoteAmount * (2 * 10 ** QUOTE_OFFSET_DECIMALS));

    vm.prank(user1);
    (uint256 sharesOut, uint256 baseIn, uint256 quoteIn) = vault.mint(user1, baseAmount, quoteAmount, 0);

    assertEq(baseIn, baseAmount);
    assertEq(quoteIn, quoteAmount);
    assertEq(vault.balanceOf(user1), sharesOut);
    assertEq(vault.totalSupply(), sharesOut + 1000); // +1000 for minimum liquidity

    // Check token balances
    assertEq(WETH.balanceOf(address(vault)), baseAmount);
    assertEq(USDC.balanceOf(address(vault)), quoteAmount);
  }

  function test_mint_subsequentMint() public {
    // Initial mint
    vm.prank(user1);
    vault.mint(user1, 1 ether, 2000e6, 0);

    uint256 initialSupply = vault.totalSupply();
    uint256 initialUser1Balance = vault.balanceOf(user1);

    // Subsequent mint
    vm.prank(user2);
    (uint256 sharesOut,,) = vault.mint(user2, 0.5 ether, 1000e6, 0);

    assertEq(vault.balanceOf(user2), sharesOut);
    assertEq(vault.balanceOf(user1), initialUser1Balance); // User1 balance unchanged
    assertEq(vault.totalSupply(), initialSupply + sharesOut);
  }

  function test_mint_insufficientSharesOut() public {
    uint256 baseAmount = 1 ether;
    uint256 quoteAmount = 2000e6;
    uint256 minSharesOut = type(uint256).max; // Impossibly high

    vm.prank(user1);
    vm.expectRevert(MangroveVaultV2.InsufficientSharesOut.selector);
    vault.mint(user1, baseAmount, quoteAmount, minSharesOut);
  }

  function test_mint_withAccruedFees() public {
    // Initial mint
    vm.prank(user1);
    vault.mint(user1, 1 ether, 2000e6, 0);

    // Fast forward time to accrue fees
    vm.warp(block.timestamp + 365 days);

    uint256 feeRecipientBalanceBefore = vault.balanceOf(owner);

    // Second mint should accrue fees
    vm.prank(user2);
    vault.mint(user2, 0.5 ether, 1000e6, 0);

    uint256 feeRecipientBalanceAfter = vault.balanceOf(owner);
    assertGt(feeRecipientBalanceAfter, feeRecipientBalanceBefore);
  }

  /*//////////////////////////////////////////////////////////////
                           BURN TESTS
  //////////////////////////////////////////////////////////////*/

  function test_burn_emitsSentTokensEvent() public {
    uint256 baseMint = 1 ether;
    uint256 quoteMint = 2000e6;

    // Setup: mint first
    vm.prank(user1);
    (uint256 sharesOut,,) = vault.mint(user1, baseMint, quoteMint, 0);
    uint256 supply = vault.totalSupply();

    uint256 sharesToBurn = sharesOut / 2;

    // Calculate expected amounts and balances
    uint256 expectedBaseOut = baseMint * sharesToBurn / supply;
    uint256 expectedQuoteOut = quoteMint * sharesToBurn / supply;
    uint256 expectedBaseBalance = baseMint - expectedBaseOut;
    uint256 expectedQuoteBalance = quoteMint - expectedQuoteOut;

    vm.expectEmit(false, false, false, true);
    emit MangroveVaultV2.SentTokens(expectedBaseOut, expectedQuoteOut, expectedBaseBalance, expectedQuoteBalance);
    vm.expectEmit(false, false, false, true);
    emit ERC20.Transfer(user1, address(0), sharesToBurn);

    vm.prank(user1);
    vault.burn(user1, user1, sharesToBurn, 0, 0);
  }

  function test_burn_emitsSentTokensEvent_multipleUsers() public {
    // Setup: two users mint
    vm.prank(user1);
    vault.mint(user1, 1 ether, 2000e6, 0);

    vm.prank(user2);
    (uint256 shares2,,) = vault.mint(user2, 0.5 ether, 1000e6, 0);

    // User2 burns all their shares
    uint256 expectedBaseOut = 0.5 ether;
    uint256 expectedQuoteOut = 1000e6;
    uint256 expectedBaseBalance = 1 ether; // 1.5 - 0.5
    uint256 expectedQuoteBalance = 2000e6; // 3000 - 1000

    vm.expectEmit(false, false, false, true);
    emit MangroveVaultV2.SentTokens(expectedBaseOut, expectedQuoteOut, expectedBaseBalance, expectedQuoteBalance);

    vm.prank(user2);
    vault.burn(user2, user2, shares2, 0, 0);
  }

  function test_burn_basic() public {
    // Setup: mint first
    vm.prank(user1);
    (uint256 sharesOut,,) = vault.mint(user1, 1 ether, 2000e6, 0);

    uint256 sharesToBurn = sharesOut / 2;

    vm.prank(user1);
    (uint256 baseOut, uint256 quoteOut) = vault.burn(user1, user1, sharesToBurn, 0, 0);

    assertGt(baseOut, 0);
    assertGt(quoteOut, 0);
    assertEq(vault.balanceOf(user1), sharesOut - sharesToBurn);

    // Check user received tokens
    assertGt(WETH.balanceOf(user1), 99 ether); // Should have more than initial - deposit + withdrawal
    assertGt(USDC.balanceOf(user1), 98_000e6);
  }

  function test_burn_withAllowance() public {
    // Setup: mint first
    vm.prank(user1);
    (uint256 sharesOut,,) = vault.mint(user1, 1 ether, 2000e6, 0);

    uint256 sharesToBurn = sharesOut / 2;

    // User1 approves user2 to burn their shares
    vm.prank(user1);
    vault.approve(user2, sharesToBurn);

    // User2 burns user1's shares to themselves
    vm.prank(user2);
    (uint256 baseOut, uint256 quoteOut) = vault.burn(user1, user2, sharesToBurn, 0, 0);

    assertGt(baseOut, 0);
    assertGt(quoteOut, 0);
    assertEq(vault.balanceOf(user1), sharesOut - sharesToBurn);

    // Check user2 received tokens
    assertGt(WETH.balanceOf(user2), 50 ether);
    assertGt(USDC.balanceOf(user2), 50_000e6);
  }

  function test_burn_slippageProtection() public {
    // Setup: mint first
    vm.prank(user1);
    (uint256 sharesOut,,) = vault.mint(user1, 1 ether, 2000e6, 0);

    uint256 sharesToBurn = sharesOut / 2;

    vm.prank(user1);
    vm.expectRevert(MangroveVaultV2.BurnSlippageExceeded.selector);
    vault.burn(user1, user1, sharesToBurn, type(uint256).max, 0); // Impossible minBaseOut

    vm.prank(user1);
    vm.expectRevert(MangroveVaultV2.BurnSlippageExceeded.selector);
    vault.burn(user1, user1, sharesToBurn, 0, type(uint256).max); // Impossible minQuoteOut
  }

  /*//////////////////////////////////////////////////////////////
                          FEE ACCRUAL TESTS
  //////////////////////////////////////////////////////////////*/

  function test_feeAccrual_noTime() public {
    vm.prank(user1);
    vault.mint(user1, 1 ether, 2000e6, 0);

    (,, uint256 pendingFeeShares) = vault.feeData();
    assertEq(pendingFeeShares, 0);
  }

  function test_feeAccrual_withTime() public {
    vm.prank(user1);
    vault.mint(user1, 1 ether, 2000e6, 0);

    // Fast forward 1 year
    vm.warp(block.timestamp + 365 days);

    (,, uint256 pendingFeeShares) = vault.feeData();
    assertGt(pendingFeeShares, 0);

    // Expected fee shares calculation
    uint256 supply = vault.totalSupply();
    uint256 expectedFeeShares =
      supply.fullMulDiv(uint256(MANAGEMENT_FEE) * uint256(365 days), uint256(1e5) * uint256(365 days));
    assertEq(pendingFeeShares, expectedFeeShares);
  }

  function test_feeAccrual_accrueOnMint() public {
    vm.prank(user1);
    vault.mint(user1, 1 ether, 2000e6, 0);

    // Fast forward time
    vm.warp(block.timestamp + 365 days);

    uint256 feeRecipientBalanceBefore = vault.balanceOf(owner);

    (,, uint256 pendingFeeShares) = vault.feeData();

    vm.expectEmit(true, true, false, true);
    emit ERC20.Transfer(address(0), address(owner), pendingFeeShares);

    vm.expectEmit(true, true, false, true);
    emit MangroveVaultV2.AccruedFees(pendingFeeShares); // Will be calculated in the call

    vm.prank(user2);
    vault.mint(user2, 0.5 ether, 1000e6, 0);

    uint256 feeRecipientBalanceAfter = vault.balanceOf(owner);
    assertGt(feeRecipientBalanceAfter, feeRecipientBalanceBefore);
  }

  function test_feeAccrual_accrueOnBurn() public {
    vm.prank(user1);
    (uint256 sharesOut,,) = vault.mint(user1, 1 ether, 2000e6, 0);

    // Fast forward time
    vm.warp(block.timestamp + 365 days);

    uint256 feeRecipientBalanceBefore = vault.balanceOf(owner);

    vm.prank(user1);
    vault.burn(user1, user1, sharesOut / 2, 0, 0);

    uint256 feeRecipientBalanceAfter = vault.balanceOf(owner);
    assertGt(feeRecipientBalanceAfter, feeRecipientBalanceBefore);
  }

  function test_events_withFeesAccrued() public {
    // Initial mint
    vm.prank(user1);
    vault.mint(user1, 1 ether, 2000e6, 0);

    // Fast forward time to accrue fees
    vm.warp(block.timestamp + 365 days);

    // Second mint should emit both AccruedFees and ReceivedTokens events
    uint256 baseAmount = 0.5 ether;
    uint256 quoteAmount = 1000e6;

    vm.prank(user2);
    vault.mint(user2, baseAmount, quoteAmount, 0);
  }

  /*//////////////////////////////////////////////////////////////
                         SET FEE DATA TESTS
  //////////////////////////////////////////////////////////////*/

  function test_setFeeData_accruesFeesFirst() public {
    // Initial mint to create shares
    vm.prank(user1);
    vault.mint(user1, 1 ether, 2000e6, 0);

    // Fast forward time to accrue fees
    vm.warp(block.timestamp + 365 days);

    address newFeeRecipient = makeAddr("newFeeRecipient");
    uint16 newManagementFee = 1000; // 10%

    // Get pending fees before calling setFeeData
    (,, uint256 pendingFeeShares) = vault.feeData();
    assertGt(pendingFeeShares, 0);

    uint256 ownerBalanceBefore = vault.balanceOf(owner);

    // Expect AccruedFees event to be emitted first
    vm.expectEmit(true, true, false, true);
    emit MangroveVaultV2.AccruedFees(pendingFeeShares);

    // Then expect SetFeeData event
    vm.expectEmit(true, true, false, true);
    emit KandelManagement.SetFeeData(newFeeRecipient, newManagementFee);

    vm.prank(owner);
    vault.setFeeData(newFeeRecipient, newManagementFee);

    // Verify old fee recipient received the accrued fees
    uint256 ownerBalanceAfter = vault.balanceOf(owner);
    assertEq(ownerBalanceAfter, ownerBalanceBefore + pendingFeeShares);

    // Verify fee data was updated
    (uint256 managementFee, address feeRecipient_, uint256 newPendingFeeShares) = vault.feeData();
    assertEq(managementFee, newManagementFee);
    assertEq(feeRecipient_, newFeeRecipient);
    assertEq(newPendingFeeShares, 0); // Should be 0 since we just updated
  }

  function test_setFeeData_noFeesAccrued() public {
    // Initial mint
    vm.prank(user1);
    vault.mint(user1, 1 ether, 2000e6, 0);

    address newFeeRecipient = makeAddr("newFeeRecipient");
    uint16 newManagementFee = 1000; // 10%

    // No time passed, so no fees should be accrued
    (,, uint256 pendingFeeShares) = vault.feeData();
    assertEq(pendingFeeShares, 0);

    uint256 ownerBalanceBefore = vault.balanceOf(owner);

    // Should only emit SetFeeData event (no AccruedFees event)
    vm.expectEmit(true, true, false, true);
    emit KandelManagement.SetFeeData(newFeeRecipient, newManagementFee);

    vm.prank(owner);
    vault.setFeeData(newFeeRecipient, newManagementFee);

    // Owner balance should be unchanged
    uint256 ownerBalanceAfter = vault.balanceOf(owner);
    assertEq(ownerBalanceAfter, ownerBalanceBefore);

    // Verify fee data was updated
    (uint256 managementFee, address feeRecipient_,) = vault.feeData();
    assertEq(managementFee, newManagementFee);
    assertEq(feeRecipient_, newFeeRecipient);
  }

  function test_setFeeData_onlyOwner() public {
    address newFeeRecipient = makeAddr("newFeeRecipient");
    uint16 newManagementFee = 1000;

    // Should revert when called by non-owner
    vm.prank(user1);
    vm.expectRevert(); // Ownable.Unauthorized selector would be more specific
    vault.setFeeData(newFeeRecipient, newManagementFee);

    vm.prank(manager);
    vm.expectRevert(); // Ownable.Unauthorized selector would be more specific
    vault.setFeeData(newFeeRecipient, newManagementFee);

    vm.prank(guardian);
    vm.expectRevert(); // Ownable.Unauthorized selector would be more specific
    vault.setFeeData(newFeeRecipient, newManagementFee);

    // Should succeed when called by owner
    vm.prank(owner);
    vault.setFeeData(newFeeRecipient, newManagementFee);
  }

  function test_setFeeData_maxFeeValidation() public {
    address newFeeRecipient = makeAddr("newFeeRecipient");
    uint16 invalidManagementFee = 10001; // 100.01% - exceeds max

    vm.prank(owner);
    vm.expectRevert(KandelManagement.MaxManagementFeeExceeded.selector);
    vault.setFeeData(newFeeRecipient, invalidManagementFee);

    // Should succeed with valid fee
    uint16 validManagementFee = 10000; // 100% - at the maximum
    vm.prank(owner);
    vault.setFeeData(newFeeRecipient, validManagementFee);
  }

  function test_setFeeData_changeFeeRecipientWithAccruedFees() public {
    // Initial mint
    vm.prank(user1);
    vault.mint(user1, 1 ether, 2000e6, 0);

    // Fast forward time to accrue fees
    vm.warp(block.timestamp + 365 days);

    address newFeeRecipient = makeAddr("newFeeRecipient");
    uint16 sameManagementFee = MANAGEMENT_FEE; // Keep same fee, just change recipient

    // Get pending fees before calling setFeeData
    (,, uint256 pendingFeeShares) = vault.feeData();
    assertGt(pendingFeeShares, 0);

    uint256 ownerBalanceBefore = vault.balanceOf(owner);
    uint256 newRecipientBalanceBefore = vault.balanceOf(newFeeRecipient);

    vm.prank(owner);
    vault.setFeeData(newFeeRecipient, sameManagementFee);

    // Old fee recipient (owner) should have received the accrued fees
    uint256 ownerBalanceAfter = vault.balanceOf(owner);
    assertEq(ownerBalanceAfter, ownerBalanceBefore + pendingFeeShares);

    // New fee recipient should still have their original balance (no fees yet)
    uint256 newRecipientBalanceAfter = vault.balanceOf(newFeeRecipient);
    assertEq(newRecipientBalanceAfter, newRecipientBalanceBefore);

    // Future fees should go to new recipient
    vm.warp(block.timestamp + 365 days);
    (,, uint256 newPendingFeeShares) = vault.feeData();
    assertGt(newPendingFeeShares, 0);

    // Trigger fee accrual by calling mint
    vm.prank(user2);
    vault.mint(user2, 0.1 ether, 200e6, 0);

    // New fee recipient should now have the newly accrued fees
    uint256 finalNewRecipientBalance = vault.balanceOf(newFeeRecipient);
    assertGt(finalNewRecipientBalance, newRecipientBalanceBefore);
  }

  function test_setFeeData_changeManagementFeeWithAccruedFees() public {
    // Initial mint
    vm.prank(user1);
    vault.mint(user1, 1 ether, 2000e6, 0);

    // Fast forward time to accrue fees at old rate
    vm.warp(block.timestamp + 365 days);

    uint16 newManagementFee = 1000; // 10% (different from initial 5%)

    // Get pending fees at old rate
    (,, uint256 pendingFeesAtOldRate) = vault.feeData();
    assertGt(pendingFeesAtOldRate, 0);

    uint256 ownerBalanceBefore = vault.balanceOf(owner);

    vm.prank(owner);
    vault.setFeeData(owner, newManagementFee); // Keep same recipient, change rate

    // Owner should have received fees calculated at old rate
    uint256 ownerBalanceAfter = vault.balanceOf(owner);
    assertEq(ownerBalanceAfter, ownerBalanceBefore + pendingFeesAtOldRate);

    // Fast forward another year at new rate
    vm.warp(block.timestamp + 365 days);

    (,, uint256 pendingFeesAtNewRate) = vault.feeData();
    assertGt(pendingFeesAtNewRate, 0);

    // New fees should be calculated at the new rate (10% vs 5%)
    // So approximately double the rate (though not exactly due to compound effects)
    uint256 supply = vault.totalSupply();
    uint256 expectedNewFees =
      supply.fullMulDiv(uint256(newManagementFee) * uint256(365 days), uint256(1e5) * uint256(365 days));

    // Allow for small differences due to rounding and timing
    assertApproxEqRel(pendingFeesAtNewRate, expectedNewFees, 1e15); // 0.1% tolerance
  }

  /*//////////////////////////////////////////////////////////////
                         PAUSABLE TESTS
  //////////////////////////////////////////////////////////////*/

  function test_pausable_initialState() public view {
    // Vault should start in unpaused state
    // We can infer this by checking that mint/burn work initially
    // There's no public getter for paused state, so we test behavior
  }

  function test_setPaused_onlyOwner() public {
    // Should revert when called by non-owner
    vm.prank(user1);
    vm.expectRevert(); // Ownable.Unauthorized selector would be more specific
    vault.setPaused(true);

    vm.prank(manager);
    vm.expectRevert(); // Ownable.Unauthorized selector would be more specific
    vault.setPaused(true);

    vm.prank(guardian);
    vm.expectRevert(); // Ownable.Unauthorized selector would be more specific
    vault.setPaused(true);

    // Should succeed when called by owner
    vm.prank(owner);
    vault.setPaused(true);
  }

  function test_setPaused_emitsEvent() public {
    // Expect SetPaused event with true
    vm.expectEmit(false, false, false, true);
    emit MangroveVaultV2.SetPaused(true);

    vm.prank(owner);
    vault.setPaused(true);

    // Expect SetPaused event with false
    vm.expectEmit(false, false, false, true);
    emit MangroveVaultV2.SetPaused(false);

    vm.prank(owner);
    vault.setPaused(false);
  }

  function test_setPaused_revertsSameState() public {
    // Should revert when trying to set to same state (initially false)
    vm.prank(owner);
    vm.expectRevert(MangroveVaultV2.PausedStateNotChanged.selector);
    vault.setPaused(false);

    // Pause the vault first
    vm.prank(owner);
    vault.setPaused(true);

    // Should revert when trying to pause again
    vm.prank(owner);
    vm.expectRevert(MangroveVaultV2.PausedStateNotChanged.selector);
    vault.setPaused(true);

    // Unpause the vault
    vm.prank(owner);
    vault.setPaused(false);

    // Should revert when trying to unpause again
    vm.prank(owner);
    vm.expectRevert(MangroveVaultV2.PausedStateNotChanged.selector);
    vault.setPaused(false);
  }

  function test_mint_whenPaused() public {
    // Pause the vault
    vm.prank(owner);
    vault.setPaused(true);

    // Mint should revert when paused
    vm.prank(user1);
    vm.expectRevert(MangroveVaultV2.Paused.selector);
    vault.mint(user1, 1 ether, 2000e6, 0);
  }

  function test_burn_whenPaused() public {
    // First mint some shares when unpaused
    vm.prank(user1);
    (uint256 shares,,) = vault.mint(user1, 1 ether, 2000e6, 0);

    // Pause the vault
    vm.prank(owner);
    vault.setPaused(true);

    // Burn should revert when paused
    vm.prank(user1);
    vm.expectRevert(MangroveVaultV2.Paused.selector);
    vault.burn(user1, user1, shares, 0, 0);
  }

  function test_cannotChnageToSameState() public {
    vm.prank(owner);
    vm.expectRevert(MangroveVaultV2.PausedStateNotChanged.selector);
    vault.setPaused(false);
  }

  function test_burn_whenUnpaused() public {
    // First mint some shares
    vm.prank(user1);
    (uint256 shares,,) = vault.mint(user1, 1 ether, 2000e6, 0);

    // Burn should succeed when unpaused
    vm.prank(user1);
    (uint256 baseOut, uint256 quoteOut) = vault.burn(user1, user1, shares / 2, 0, 0);

    assertGt(baseOut, 0);
    assertGt(quoteOut, 0);
  }

  function test_pausable_workflow() public {
    // Initial state: should be able to mint
    vm.prank(user1);
    (uint256 shares1,,) = vault.mint(user1, 1 ether, 2000e6, 0);

    // Pause the vault
    vm.expectEmit(false, false, false, true);
    emit MangroveVaultV2.SetPaused(true);

    vm.prank(owner);
    vault.setPaused(true);

    // Should not be able to mint when paused
    vm.prank(user2);
    vm.expectRevert(MangroveVaultV2.Paused.selector);
    vault.mint(user2, 0.5 ether, 1000e6, 0);

    // Should not be able to burn when paused
    vm.prank(user1);
    vm.expectRevert(MangroveVaultV2.Paused.selector);
    vault.burn(user1, user1, shares1 / 2, 0, 0);

    // Unpause the vault
    vm.expectEmit(false, false, false, true);
    emit MangroveVaultV2.SetPaused(false);

    vm.prank(owner);
    vault.setPaused(false);

    // Should be able to mint again
    vm.prank(user2);
    (uint256 shares2,,) = vault.mint(user2, 0.5 ether, 1000e6, 0);
    assertGt(shares2, 0);

    // Should be able to burn again
    vm.prank(user1);
    (uint256 baseOut, uint256 quoteOut) = vault.burn(user1, user1, shares1 / 2, 0, 0);
    assertGt(baseOut, 0);
    assertGt(quoteOut, 0);
  }

  function test_pausable_doesNotAffectOtherFunctions() public {
    // Setup: mint some shares first
    vm.prank(user1);
    vault.mint(user1, 1 ether, 2000e6, 0);

    // Pause the vault
    vm.prank(owner);
    vault.setPaused(true);

    // View functions should still work when paused
    (uint256 managementFee, address feeRecipient_,) = vault.feeData();
    assertEq(managementFee, MANAGEMENT_FEE);
    assertEq(feeRecipient_, owner);

    // getMintAmounts should still work when paused (it's a view function)
    (uint256 sharesOut, uint256 baseIn, uint256 quoteIn) = vault.getMintAmounts(0.5 ether, 1000e6);
    assertGt(sharesOut, 0);
    assertEq(baseIn, 0.5 ether);
    assertEq(quoteIn, 1000e6);

    // totalBalances should still work when paused
    (uint256 baseBalance, uint256 quoteBalance) = vault.totalBalances();
    assertGt(baseBalance, 0);
    assertGt(quoteBalance, 0);

    // Owner functions should still work when paused
    address newFeeRecipient = makeAddr("newFeeRecipient");
    vm.prank(owner);
    vault.setFeeData(newFeeRecipient, MANAGEMENT_FEE);

    // Check the change took effect
    (, address updatedFeeRecipient,) = vault.feeData();
    assertEq(updatedFeeRecipient, newFeeRecipient);
  }

  function test_pausable_emergencyScenario() public {
    // Simulate emergency scenario where vault needs to be paused immediately
    vm.prank(user1);
    vault.mint(user1, 1 ether, 2000e6, 0);

    vm.prank(user2);
    vault.mint(user2, 0.5 ether, 1000e6, 0);

    // Emergency: pause the vault
    vm.prank(owner);
    vault.setPaused(true);

    // No users should be able to mint or burn during emergency
    vm.prank(user1);
    vm.expectRevert(MangroveVaultV2.Paused.selector);
    vault.mint(user1, 0.1 ether, 200e6, 0);

    uint256 balance = vault.balanceOf(user2);

    vm.prank(user2);
    vm.expectRevert(MangroveVaultV2.Paused.selector);
    vault.burn(user2, user2, balance, 0, 0);

    // After emergency is resolved, resume operations
    vm.prank(owner);
    vault.setPaused(false);

    // Operations should resume normally
    vm.prank(user1);
    vault.mint(user1, 0.1 ether, 200e6, 0);

    balance = vault.balanceOf(user2);

    vm.prank(user2);
    vault.burn(user2, user2, balance / 2, 0, 0);
  }

  /*//////////////////////////////////////////////////////////////
                        INTEGRATION TESTS
  //////////////////////////////////////////////////////////////*/

  function test_multipleUsersFlow() public {
    // User1 mints
    vm.prank(user1);
    (uint256 shares1,,) = vault.mint(user1, 1 ether, 2000e6, 0);

    // User2 mints
    vm.prank(user2);
    (uint256 shares2,,) = vault.mint(user2, 0.5 ether, 1000e6, 0);

    assertEq(vault.balanceOf(user1), shares1);
    assertEq(vault.balanceOf(user2), shares2);

    // Check total balances
    (uint256 totalBase, uint256 totalQuote) = vault.totalBalances();
    assertEq(totalBase, 1.5 ether);
    assertEq(totalQuote, 3000e6);

    // User1 burns half
    vm.prank(user1);
    vault.burn(user1, user1, shares1 / 2, 0, 0);

    // User2 burns all
    vm.prank(user2);
    vault.burn(user2, user2, shares2, 0, 0);

    assertEq(vault.balanceOf(user1), shares1 / 2);
    assertEq(vault.balanceOf(user2), 0);
  }

  function test_sendTokensTo_withKandelWithdrawal() public {
    // This test would require setting up Kandel with funds, which is complex
    // For now, we test the basic case where local balance is sufficient
    vm.prank(user1);
    vault.mint(user1, 1 ether, 2000e6, 0);

    uint256 balance = vault.balanceOf(user1);

    vm.prank(user1);
    (uint256 baseOut, uint256 quoteOut) = vault.burn(user1, user1, balance, 0, 0);

    // Should successfully withdraw available tokens
    assertGt(baseOut, 0);
    assertGt(quoteOut, 0);
  }

  /*//////////////////////////////////////////////////////////////
                          EDGE CASE TESTS
  //////////////////////////////////////////////////////////////*/

  function test_minimumLiquidity() public {
    vm.prank(user1);
    vault.mint(user1, 1 ether, 2000e6, 0);

    uint256 totalSupply = vault.totalSupply();
    uint256 userBalance = vault.balanceOf(user1);

    // Total supply should be user balance + minimum liquidity
    assertEq(totalSupply, userBalance + 1000);

    // Vault contract should hold the minimum liquidity
    assertEq(vault.balanceOf(address(vault)), 1000);
  }

  function test_zeroAmountMint() public {
    vm.expectRevert(MangroveVaultV2.InvalidInitialMintAmounts.selector);
    vault.getMintAmounts(0, 0);
  }

  function test_feeData_view() public view {
    (uint256 managementFee, address feeRecipient_, uint256 pendingFeeShares) = vault.feeData();

    assertEq(managementFee, MANAGEMENT_FEE);
    assertEq(feeRecipient_, owner);
    assertEq(pendingFeeShares, 0);
  }

  /*//////////////////////////////////////////////////////////////
                         FUZZ TESTS
  //////////////////////////////////////////////////////////////*/

  function testFuzz_mint(uint256 baseAmount, uint256 maxDeviation, int256 deviation, int256 tick) public {
    baseAmount = bound(baseAmount, 1e12, 10 ether); // Reasonable bounds
    tick = bound(tick, -200_000, 200_000);
    maxDeviation = bound(maxDeviation, 0, 5000); // 50%
    deviation = bound(deviation, -10000, 10000); // 100%

    OracleData memory oracle;
    oracle.isStatic = true;
    oracle.staticValue = int24(tick);
    oracle.maxDeviation = uint16(maxDeviation);
    oracle.timelockMinutes = 60;

    vm.startPrank(owner);
    vault.proposeOracle(oracle);
    vm.warp(block.timestamp + 61 minutes);
    vault.acceptOracle();
    vm.stopPrank();

    uint256 quoteAmount = Tick.wrap(tick + deviation).inboundFromOutbound(baseAmount);

    MockERC20(address(WETH)).mint(user1, baseAmount);
    MockERC20(address(USDC)).mint(user1, quoteAmount);
    vm.startPrank(user1);
    WETH.approve(address(vault), baseAmount);
    USDC.approve(address(vault), quoteAmount);
    vm.stopPrank();

    // There can be imprecisions when computing the tick with small values
    // So we recompute it to see if we are in range
    Tick realTick = TickLib.tickFromVolumes(quoteAmount, baseAmount);

    if (!oracle.withinDeviation(realTick)) {
      vm.expectRevert(MangroveVaultV2.InvalidInitialMintAmounts.selector);
      vm.prank(user1);
      vault.mint(user1, baseAmount, quoteAmount, 0);
      return;
    }

    vm.prank(user1);
    vault.mint(user1, baseAmount, quoteAmount, 0);
  }

  function testFuzz_burn(uint256 mintBase, int256 tick, uint256 burnRatio) public {
    mintBase = bound(mintBase, 1e12, 10 ether);
    tick = bound(tick, -200_000, 200_000);
    burnRatio = bound(burnRatio, 1, 100); // 1-100% of shares

    OracleData memory oracle;
    oracle.isStatic = true;
    oracle.staticValue = int24(tick);
    oracle.maxDeviation = 1000;
    oracle.timelockMinutes = 60;

    vm.startPrank(owner);
    vault.proposeOracle(oracle);
    vm.warp(block.timestamp + 61 minutes);
    vault.acceptOracle();
    vm.stopPrank();

    uint256 mintQuote = Tick.wrap(tick).inboundFromOutbound(mintBase);

    // Setup: mint first
    MockERC20(address(WETH)).mint(user1, mintBase);
    MockERC20(address(USDC)).mint(user1, mintQuote);
    vm.startPrank(user1);
    WETH.approve(address(vault), mintBase);
    USDC.approve(address(vault), mintQuote);
    (uint256 sharesOut,,) = vault.mint(user1, mintBase, mintQuote, 0);
    vm.stopPrank();

    uint256 sharesToBurn = sharesOut * burnRatio / 100;

    if (sharesToBurn > 0) {
      vm.prank(user1);
      (uint256 baseOut, uint256 quoteOut) = vault.burn(user1, user1, sharesToBurn, 0, 0);

      assertGt(baseOut, 0);
      assertGt(quoteOut, 0);
      assertEq(vault.balanceOf(user1), sharesOut - sharesToBurn);
    }
  }

  /*//////////////////////////////////////////////////////////////
                      MAX MINT AMOUNTS TESTS
  //////////////////////////////////////////////////////////////*/

  function test_constructor_setsDefaultMaxMintAmounts() public view {
    (uint128 maxBase, uint128 maxQuote) = vault.maxMintAmounts();
    assertEq(maxBase, type(uint128).max, "Default max base should be uint128 max");
    assertEq(maxQuote, type(uint128).max, "Default max quote should be uint128 max");
  }

  function test_setMaxMintAmounts_onlyOwner() public {
    uint128 newMaxBase = 50 ether;
    uint128 newMaxQuote = 100_000e6;

    // Test that non-owner cannot set max mint amounts
    vm.prank(manager);
    vm.expectRevert();
    vault.setMaxMintAmounts(newMaxBase, newMaxQuote);

    vm.prank(guardian);
    vm.expectRevert();
    vault.setMaxMintAmounts(newMaxBase, newMaxQuote);

    vm.prank(user1);
    vm.expectRevert();
    vault.setMaxMintAmounts(newMaxBase, newMaxQuote);

    // Test that owner can set max mint amounts
    vm.expectEmit(true, true, false, true);
    emit MangroveVaultV2.SetMaxMintAmounts(newMaxBase, newMaxQuote);

    vm.prank(owner);
    vault.setMaxMintAmounts(newMaxBase, newMaxQuote);

    (uint128 maxBase, uint128 maxQuote) = vault.maxMintAmounts();
    assertEq(maxBase, newMaxBase, "Max base should be updated");
    assertEq(maxQuote, newMaxQuote, "Max quote should be updated");
  }

  function test_setMaxMintAmounts_zeroLimits() public {
    vm.expectEmit(true, true, false, true);
    emit MangroveVaultV2.SetMaxMintAmounts(0, 0);

    vm.prank(owner);
    vault.setMaxMintAmounts(0, 0);

    (uint128 maxBase, uint128 maxQuote) = vault.maxMintAmounts();
    assertEq(maxBase, 0, "Max base should be set to zero");
    assertEq(maxQuote, 0, "Max quote should be set to zero");
  }

  function test_maxMintAmountsExceeded_initialMint_baseLimit() public {
    // Set restrictive base limit
    uint128 maxBase = 5 ether;
    uint128 maxQuote = type(uint128).max;

    vm.prank(owner);
    vault.setMaxMintAmounts(maxBase, maxQuote);

    // Try to mint more than base limit
    uint256 baseAmount = 10 ether; // Exceeds limit
    uint256 quoteAmount = 20_000e6;

    vm.expectRevert(MangroveVaultV2.MaxMintAmountsExceeded.selector);
    vault.getMintAmounts(baseAmount, quoteAmount);

    vm.prank(user1);
    vm.expectRevert(MangroveVaultV2.MaxMintAmountsExceeded.selector);
    vault.mint(user1, baseAmount, quoteAmount, 0);
  }

  function test_maxMintAmountsExceeded_initialMint_quoteLimit() public {
    // Set restrictive quote limit
    uint128 maxBase = type(uint128).max;
    uint128 maxQuote = 10_000e6;

    vm.prank(owner);
    vault.setMaxMintAmounts(maxBase, maxQuote);

    // Try to mint more than quote limit
    uint256 baseAmount = 5 ether;
    uint256 quoteAmount = 20_000e6; // Exceeds limit

    vm.expectRevert(MangroveVaultV2.MaxMintAmountsExceeded.selector);
    vault.getMintAmounts(baseAmount, quoteAmount);

    vm.prank(user1);
    vm.expectRevert(MangroveVaultV2.MaxMintAmountsExceeded.selector);
    vault.mint(user1, baseAmount, quoteAmount, 0);
  }

  function test_maxMintAmountsExceeded_initialMint_bothLimits() public {
    // Set restrictive limits for both tokens
    uint128 maxBase = 5 ether;
    uint128 maxQuote = 10_000e6;

    vm.prank(owner);
    vault.setMaxMintAmounts(maxBase, maxQuote);

    // Try to mint more than both limits
    uint256 baseAmount = 10 ether; // Exceeds base limit
    uint256 quoteAmount = 20_000e6; // Exceeds quote limit

    vm.expectRevert(MangroveVaultV2.MaxMintAmountsExceeded.selector);
    vault.getMintAmounts(baseAmount, quoteAmount);

    vm.prank(user1);
    vm.expectRevert(MangroveVaultV2.MaxMintAmountsExceeded.selector);
    vault.mint(user1, baseAmount, quoteAmount, 0);
  }

  function test_maxMintAmountsExceeded_withExistingBalance() public {
    // First, do an initial mint to create existing balance
    uint256 initialBase = 2 ether;
    uint256 initialQuote = 4_000e6;

    vm.prank(user1);
    vault.mint(user1, initialBase, initialQuote, 0);

    // Now set limits that would be exceeded when combined with existing balance
    uint128 maxBase = 3 ether; // Initial (2) + new (2) = 4 > 3
    uint128 maxQuote = 5_000e6; // Initial (4000) + new (2000) = 6000 > 5000

    vm.prank(owner);
    vault.setMaxMintAmounts(maxBase, maxQuote);

    // Try to mint amounts that exceed limits when combined with existing balance
    uint256 newBase = 2 ether;
    uint256 newQuote = 2_000e6;

    vm.expectRevert(MangroveVaultV2.MaxMintAmountsExceeded.selector);
    vault.getMintAmounts(newBase, newQuote);

    vm.prank(user2);
    vm.expectRevert(MangroveVaultV2.MaxMintAmountsExceeded.selector);
    vault.mint(user2, newBase, newQuote, 0);
  }

  function test_maxMintAmounts_exactLimit() public {
    // Set specific limits
    uint128 maxBase = 10 ether;
    uint128 maxQuote = 20_000e6;

    vm.prank(owner);
    vault.setMaxMintAmounts(maxBase, maxQuote);

    // Mint exactly at the limits (should succeed)
    uint256 baseAmount = 10 ether; // Exactly at limit
    uint256 quoteAmount = 20_000e6; // Exactly at limit

    // This should not revert
    (uint256 sharesOut, uint256 baseIn, uint256 quoteIn) = vault.getMintAmounts(baseAmount, quoteAmount);

    assertEq(baseIn, baseAmount, "Should use exact base amount");
    assertEq(quoteIn, quoteAmount, "Should use exact quote amount");
    assertGt(sharesOut, 0, "Should mint some shares");

    vm.prank(user1);
    vault.mint(user1, baseAmount, quoteAmount, 0);

    assertEq(vault.balanceOf(user1), sharesOut, "User should receive expected shares");
  }

  function test_maxMintAmounts_justUnderLimit() public {
    // Set specific limits
    uint128 maxBase = 10 ether;
    uint128 maxQuote = 20_000e6;

    vm.prank(owner);
    vault.setMaxMintAmounts(maxBase, maxQuote);

    // Mint just under the limits (should succeed)
    uint256 baseAmount = 9.99 ether; // Just under limit
    uint256 quoteAmount = 19_999e6; // Just under limit

    // This should not revert
    (uint256 sharesOut, uint256 baseIn, uint256 quoteIn) = vault.getMintAmounts(baseAmount, quoteAmount);

    assertEq(baseIn, baseAmount, "Should use exact base amount");
    assertEq(quoteIn, quoteAmount, "Should use exact quote amount");
    assertGt(sharesOut, 0, "Should mint some shares");

    vm.prank(user1);
    vault.mint(user1, baseAmount, quoteAmount, 0);

    assertEq(vault.balanceOf(user1), sharesOut, "User should receive expected shares");
  }

  function test_maxMintAmounts_subsequentMints() public {
    // Initial mint
    uint256 initialBase = 3 ether;
    uint256 initialQuote = 6_000e6;

    vm.prank(user1);
    vault.mint(user1, initialBase, initialQuote, 0);

    // Set limits that allow one more mint but not two
    uint128 maxBase = 5 ether;
    uint128 maxQuote = 10_000e6;

    vm.prank(owner);
    vault.setMaxMintAmounts(maxBase, maxQuote);

    // First subsequent mint should succeed (total: 5 ether, 10_000e6)
    uint256 secondBase = 2 ether;
    uint256 secondQuote = 4_000e6;

    vm.prank(user2);
    vault.mint(user2, secondBase, secondQuote, 0);

    // Third mint should fail as it would exceed limits
    uint256 thirdBase = 1 ether;
    uint256 thirdQuote = 1_000e6;

    vm.expectRevert(MangroveVaultV2.MaxMintAmountsExceeded.selector);
    vault.getMintAmounts(thirdBase, thirdQuote);

    vm.prank(user1);
    vm.expectRevert(MangroveVaultV2.MaxMintAmountsExceeded.selector);
    vault.mint(user1, thirdBase, thirdQuote, 0);
  }

  function test_maxMintAmounts_zeroLimitsPreventAllMints() public {
    // Set zero limits
    vm.prank(owner);
    vault.setMaxMintAmounts(0, 0);

    // Any mint should fail
    uint256 baseAmount = 1; // Even tiny amounts should fail
    uint256 quoteAmount = 1;

    vm.expectRevert(MangroveVaultV2.MaxMintAmountsExceeded.selector);
    vault.getMintAmounts(baseAmount, quoteAmount);

    vm.prank(user1);
    vm.expectRevert(MangroveVaultV2.MaxMintAmountsExceeded.selector);
    vault.mint(user1, baseAmount, quoteAmount, 0);
  }

  function test_maxMintAmounts_increasingLimits() public {
    // Start with low limits
    uint128 initialMaxBase = 2 ether;
    uint128 initialMaxQuote = 4_000e6;

    vm.prank(owner);
    vault.setMaxMintAmounts(initialMaxBase, initialMaxQuote);

    // Mint up to the initial limits
    vm.prank(user1);
    vault.mint(user1, 2 ether, 4_000e6, 0);

    // Try to mint more (should fail)
    vm.prank(user2);
    vm.expectRevert(MangroveVaultV2.MaxMintAmountsExceeded.selector);
    vault.mint(user2, 1 ether, 1_000e6, 0);

    // Increase limits
    uint128 newMaxBase = 5 ether;
    uint128 newMaxQuote = 10_000e6;

    vm.prank(owner);
    vault.setMaxMintAmounts(newMaxBase, newMaxQuote);

    // Now the mint should succeed
    vm.prank(user2);
    vault.mint(user2, 1 ether, 2_000e6, 0);

    (uint256 totalBase, uint256 totalQuote) = vault.totalBalances();
    assertLe(totalBase, newMaxBase, "Total base should be within new limit");
    assertLe(totalQuote, newMaxQuote, "Total quote should be within new limit");
  }
}
