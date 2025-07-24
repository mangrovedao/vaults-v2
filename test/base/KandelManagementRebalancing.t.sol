// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {KandelManagementRebalancing, TickLib} from "../../src/base/KandelManagementRebalancing.sol";
import {
  KandelManagement,
  OracleRange,
  AbstractKandelSeeder,
  Tick,
  CoreKandel,
  OracleData
} from "../../src/base/KandelManagement.sol";
import {MangroveTest, MockERC20} from "./MangroveTest.t.sol";

/**
 * @title MockSwapContract
 * @notice Mock contract for testing rebalancing swaps
 * @dev Simulates token swaps with configurable exchange rates and slippage
 */
contract MockSwapContract {
  bool shouldRevert;

  function setShouldRevert(bool _shouldRevert) external {
    shouldRevert = _shouldRevert;
  }

  function swap(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 amountOut) external {
    if (shouldRevert) revert("MockSwapContract: should revert");
    MockERC20(_tokenIn).transferFrom(msg.sender, address(this), _amountIn);
    MockERC20(_tokenOut).mint(msg.sender, amountOut);
  }
}

contract KandelManagementRebalancingTest is MangroveTest {
  KandelManagementRebalancing public management;
  MockSwapContract public mockSwap;
  address public manager;
  address public guardian;
  address public owner;
  uint16 public constant MANAGEMENT_FEE = 500; // 5%

  function setUp() public virtual override {
    super.setUp();
    manager = makeAddr("manager");
    guardian = makeAddr("guardian");
    owner = makeAddr("owner");

    // Deploy mock swap contract
    mockSwap = new MockSwapContract();

    OracleData memory oracle;
    oracle.isStatic = true;
    oracle.maxDeviation = 100;
    oracle.timelockMinutes = 60; // 1 hour

    management = new KandelManagementRebalancing(
      seeder, address(WETH), address(USDC), 1, manager, MANAGEMENT_FEE, oracle, owner, guardian
    );
  }

  /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
  //////////////////////////////////////////////////////////////*/

  function test_constructor_initializesCorrectly() public {
    assertEq(management.manager(), manager, "Manager should be set correctly");
    assertEq(management.guardian(), guardian, "Guardian should be set correctly");
    assertEq(management.owner(), owner, "Owner should be set correctly");

    // Check KANDEL was deployed
    assertTrue(address(management.KANDEL()) != address(0), "KANDEL should be deployed");

    // Check initial whitelist state is empty
    address testAddress = makeAddr("testAddress");
    assertFalse(management.isWhitelisted(testAddress), "Address should not be whitelisted initially");
    assertEq(management.whitelistProposedAt(testAddress), 0, "Address should not be proposed initially");
  }

  function test_constructor_inheritsKandelManagementFunctionality() public view {
    // Test that inherited functionality works
    (bool inKandel, address feeRecipient, uint16 managementFee, uint40 lastTimestamp) = management.state();

    assertEq(inKandel, false, "inKandel should be false initially");
    assertEq(feeRecipient, owner, "Fee recipient should be owner initially");
    assertEq(managementFee, MANAGEMENT_FEE, "Management fee should match");
    assertGt(lastTimestamp, 0, "Last timestamp should be set");

    // Test market configuration
    (address base, address quote, uint256 tickSpacing) = management.market();
    assertEq(base, address(WETH), "Base token should be WETH");
    assertEq(quote, address(USDC), "Quote token should be USDC");
    assertEq(tickSpacing, 1, "Tick spacing should be 1");
  }

  /*//////////////////////////////////////////////////////////////
                     PROPOSE WHITELIST TESTS
  //////////////////////////////////////////////////////////////*/

  function test_proposeWhitelist() public {
    address proposedAddress = makeAddr("proposedAddress");

    vm.expectEmit(true, false, false, true);
    emit KandelManagementRebalancing.WhitelistProposed(proposedAddress);

    vm.prank(owner);
    management.proposeWhitelist(proposedAddress);

    // Check that proposal was recorded
    uint256 proposedAt = management.whitelistProposedAt(proposedAddress);
    assertEq(proposedAt, block.timestamp, "Proposal timestamp should be current block timestamp");

    // Address should not be whitelisted yet
    assertFalse(management.isWhitelisted(proposedAddress), "Address should not be whitelisted yet");

    // Should not be ready for acceptance yet
    assertFalse(management.canAcceptWhitelist(proposedAddress), "Should not be ready for acceptance yet");
  }

  function test_proposeWhitelist_onlyOwner() public {
    address proposedAddress = makeAddr("proposedAddress");

    // Test that manager cannot propose
    vm.prank(manager);
    vm.expectRevert();
    management.proposeWhitelist(proposedAddress);

    // Test that guardian cannot propose
    vm.prank(guardian);
    vm.expectRevert();
    management.proposeWhitelist(proposedAddress);

    // Test that random address cannot propose
    vm.prank(makeAddr("randomUser"));
    vm.expectRevert();
    management.proposeWhitelist(proposedAddress);

    // Verify no proposal was made
    assertEq(management.whitelistProposedAt(proposedAddress), 0, "No proposal should be recorded");
  }

  function test_proposeWhitelist_alreadyProposed() public {
    address proposedAddress = makeAddr("proposedAddress");

    // First proposal should succeed
    vm.prank(owner);
    management.proposeWhitelist(proposedAddress);

    // Second proposal should fail
    vm.prank(owner);
    vm.expectRevert(KandelManagementRebalancing.AlreadyProposed.selector);
    management.proposeWhitelist(proposedAddress);
  }

  function test_proposeWhitelist_multipleAddresses() public {
    address address1 = makeAddr("address1");
    address address2 = makeAddr("address2");
    address address3 = makeAddr("address3");

    vm.startPrank(owner);

    // Propose multiple addresses
    management.proposeWhitelist(address1);
    management.proposeWhitelist(address2);
    management.proposeWhitelist(address3);

    vm.stopPrank();

    // All should be proposed but not whitelisted
    assertGt(management.whitelistProposedAt(address1), 0, "Address1 should be proposed");
    assertGt(management.whitelistProposedAt(address2), 0, "Address2 should be proposed");
    assertGt(management.whitelistProposedAt(address3), 0, "Address3 should be proposed");

    assertFalse(management.isWhitelisted(address1), "Address1 should not be whitelisted yet");
    assertFalse(management.isWhitelisted(address2), "Address2 should not be whitelisted yet");
    assertFalse(management.isWhitelisted(address3), "Address3 should not be whitelisted yet");
  }

  function test_proposeWhitelist_invalidAddress_kandel() public {
    // Should not be able to whitelist the Kandel contract itself
    address kandelAddress = address(management.KANDEL());

    vm.prank(owner);
    vm.expectRevert(KandelManagementRebalancing.InvalidWhitelistAddress.selector);
    management.proposeWhitelist(kandelAddress);
  }

  function test_proposeWhitelist_invalidAddress_baseToken() public {
    // Should not be able to whitelist the base token
    (address base,,) = management.market();

    vm.prank(owner);
    vm.expectRevert(KandelManagementRebalancing.InvalidWhitelistAddress.selector);
    management.proposeWhitelist(base);
  }

  function test_proposeWhitelist_invalidAddress_quoteToken() public {
    // Should not be able to whitelist the quote token
    (, address quote,) = management.market();

    vm.prank(owner);
    vm.expectRevert(KandelManagementRebalancing.InvalidWhitelistAddress.selector);
    management.proposeWhitelist(quote);
  }

  function test_proposeWhitelist_validAddressStillWorks() public {
    // Ensure valid addresses can still be proposed after adding validation
    address validAddress = makeAddr("validRebalancer");

    vm.expectEmit(true, false, false, true);
    emit KandelManagementRebalancing.WhitelistProposed(validAddress);

    vm.prank(owner);
    management.proposeWhitelist(validAddress);

    // Should be proposed successfully
    assertGt(management.whitelistProposedAt(validAddress), 0, "Valid address should be proposed");
    assertFalse(management.isWhitelisted(validAddress), "Should not be whitelisted yet");
  }

  /*//////////////////////////////////////////////////////////////
                     ACCEPT WHITELIST TESTS
  //////////////////////////////////////////////////////////////*/

  function test_acceptWhitelist() public {
    address proposedAddress = makeAddr("proposedAddress");

    // First propose the address
    vm.prank(owner);
    management.proposeWhitelist(proposedAddress);

    // Fast forward past timelock
    vm.warp(block.timestamp + 61 minutes);

    // Should be ready for acceptance now
    assertTrue(management.canAcceptWhitelist(proposedAddress), "Should be ready for acceptance");

    vm.expectEmit(true, false, false, true);
    emit KandelManagementRebalancing.WhitelistAccepted(proposedAddress);

    vm.prank(owner);
    management.acceptWhitelist(proposedAddress);

    // Check final state
    assertTrue(management.isWhitelisted(proposedAddress), "Address should be whitelisted");
    assertEq(management.whitelistProposedAt(proposedAddress), 0, "Proposal should be cleared");
    assertFalse(management.canAcceptWhitelist(proposedAddress), "Should no longer be ready for acceptance");
  }

  function test_acceptWhitelist_onlyOwner() public {
    address proposedAddress = makeAddr("proposedAddress");

    // Propose and wait for timelock
    vm.prank(owner);
    management.proposeWhitelist(proposedAddress);
    vm.warp(block.timestamp + 61 minutes);

    // Test that manager cannot accept
    vm.prank(manager);
    vm.expectRevert();
    management.acceptWhitelist(proposedAddress);

    // Test that guardian cannot accept
    vm.prank(guardian);
    vm.expectRevert();
    management.acceptWhitelist(proposedAddress);

    // Test that random address cannot accept
    vm.prank(makeAddr("randomUser"));
    vm.expectRevert();
    management.acceptWhitelist(proposedAddress);

    // Verify address is still not whitelisted
    assertFalse(management.isWhitelisted(proposedAddress), "Address should not be whitelisted");
  }

  function test_acceptWhitelist_notProposed() public {
    address notProposedAddress = makeAddr("notProposedAddress");

    vm.prank(owner);
    vm.expectRevert(KandelManagementRebalancing.NotProposed.selector);
    management.acceptWhitelist(notProposedAddress);
  }

  function test_acceptWhitelist_timelockNotExpired() public {
    address proposedAddress = makeAddr("proposedAddress");

    // Propose the address
    vm.prank(owner);
    management.proposeWhitelist(proposedAddress);

    // Try to accept immediately (should fail)
    vm.prank(owner);
    vm.expectRevert(KandelManagementRebalancing.TimelockNotExpired.selector);
    management.acceptWhitelist(proposedAddress);

    // Try to accept just before timelock expires (should fail)
    vm.warp(block.timestamp + 59 minutes);
    vm.prank(owner);
    vm.expectRevert(KandelManagementRebalancing.TimelockNotExpired.selector);
    management.acceptWhitelist(proposedAddress);

    // Verify address is not whitelisted
    assertFalse(management.isWhitelisted(proposedAddress), "Address should not be whitelisted");
  }

  function test_acceptWhitelist_exactTimelockExpiry() public {
    address proposedAddress = makeAddr("proposedAddress");

    // Propose the address
    vm.prank(owner);
    management.proposeWhitelist(proposedAddress);

    // Fast forward to exact timelock expiry
    vm.warp(block.timestamp + 60 minutes);

    // Should succeed at exact expiry
    vm.prank(owner);
    management.acceptWhitelist(proposedAddress);

    assertTrue(management.isWhitelisted(proposedAddress), "Address should be whitelisted");
  }

  /*//////////////////////////////////////////////////////////////
                     REJECT WHITELIST TESTS
  //////////////////////////////////////////////////////////////*/

  function test_rejectWhitelist() public {
    address proposedAddress = makeAddr("proposedAddress");

    // Propose the address
    vm.prank(owner);
    management.proposeWhitelist(proposedAddress);

    // Verify initial state
    assertGt(management.whitelistProposedAt(proposedAddress), 0, "Address should be proposed");

    vm.expectEmit(true, false, false, true);
    emit KandelManagementRebalancing.WhitelistRejected(proposedAddress);

    // Guardian rejects the proposal
    vm.prank(guardian);
    management.rejectWhitelist(proposedAddress);

    // Check final state
    assertFalse(management.isWhitelisted(proposedAddress), "Address should not be whitelisted");
    assertEq(management.whitelistProposedAt(proposedAddress), 0, "Proposal should be cleared");
    assertFalse(management.canAcceptWhitelist(proposedAddress), "Should not be ready for acceptance");
  }

  function test_rejectWhitelist_onlyGuardian() public {
    address proposedAddress = makeAddr("proposedAddress");

    // Propose the address
    vm.prank(owner);
    management.proposeWhitelist(proposedAddress);

    // Test that owner cannot reject
    vm.prank(owner);
    vm.expectRevert(OracleRange.NotGuardian.selector);
    management.rejectWhitelist(proposedAddress);

    // Test that manager cannot reject
    vm.prank(manager);
    vm.expectRevert(OracleRange.NotGuardian.selector);
    management.rejectWhitelist(proposedAddress);

    // Test that random address cannot reject
    vm.prank(makeAddr("randomUser"));
    vm.expectRevert(OracleRange.NotGuardian.selector);
    management.rejectWhitelist(proposedAddress);

    // Verify proposal still exists
    assertGt(management.whitelistProposedAt(proposedAddress), 0, "Proposal should still exist");
  }

  function test_rejectWhitelist_notProposed() public {
    address notProposedAddress = makeAddr("notProposedAddress");

    vm.prank(guardian);
    vm.expectRevert(KandelManagementRebalancing.NotProposed.selector);
    management.rejectWhitelist(notProposedAddress);
  }

  function test_rejectWhitelist_canRejectAnytime() public {
    address proposedAddress = makeAddr("proposedAddress");

    // Propose the address
    vm.prank(owner);
    management.proposeWhitelist(proposedAddress);

    // Guardian can reject immediately
    vm.prank(guardian);
    management.rejectWhitelist(proposedAddress);
    assertEq(management.whitelistProposedAt(proposedAddress), 0, "Proposal should be cleared immediately");

    // Test rejecting during timelock period
    vm.prank(owner);
    management.proposeWhitelist(proposedAddress);

    vm.warp(block.timestamp + 30 minutes); // Halfway through timelock

    vm.prank(guardian);
    management.rejectWhitelist(proposedAddress);
    assertEq(management.whitelistProposedAt(proposedAddress), 0, "Proposal should be cleared during timelock");

    // Test rejecting after timelock expires
    vm.prank(owner);
    management.proposeWhitelist(proposedAddress);

    vm.warp(block.timestamp + 61 minutes); // After timelock

    vm.prank(guardian);
    management.rejectWhitelist(proposedAddress);
    assertEq(management.whitelistProposedAt(proposedAddress), 0, "Proposal should be cleared after timelock");
  }

  /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
  //////////////////////////////////////////////////////////////*/

  function test_whitelistProposedAt() public {
    address testAddress = makeAddr("testAddress");

    // Initially should return 0
    assertEq(management.whitelistProposedAt(testAddress), 0, "Should return 0 for non-proposed address");

    // After proposing, should return timestamp
    uint256 proposalTime = block.timestamp;
    vm.prank(owner);
    management.proposeWhitelist(testAddress);

    assertEq(management.whitelistProposedAt(testAddress), proposalTime, "Should return proposal timestamp");

    // After accepting, should return 0 again
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptWhitelist(testAddress);

    assertEq(management.whitelistProposedAt(testAddress), 0, "Should return 0 after acceptance");
  }

  function test_canAcceptWhitelist() public {
    address testAddress = makeAddr("testAddress");

    // Initially should return false
    assertFalse(management.canAcceptWhitelist(testAddress), "Should return false for non-proposed address");

    // After proposing, should return false until timelock expires
    vm.prank(owner);
    management.proposeWhitelist(testAddress);
    assertFalse(management.canAcceptWhitelist(testAddress), "Should return false immediately after proposal");

    // Just before timelock expires
    vm.warp(block.timestamp + 59 minutes);
    assertFalse(management.canAcceptWhitelist(testAddress), "Should return false just before timelock expires");

    // At exact timelock expiry
    vm.warp(block.timestamp + 1 minutes); // Now at 60 minutes
    assertTrue(management.canAcceptWhitelist(testAddress), "Should return true at exact timelock expiry");

    // After timelock expires
    vm.warp(block.timestamp + 1 minutes); // Now at 61 minutes
    assertTrue(management.canAcceptWhitelist(testAddress), "Should return true after timelock expires");

    // After acceptance, should return false
    vm.prank(owner);
    management.acceptWhitelist(testAddress);
    assertFalse(management.canAcceptWhitelist(testAddress), "Should return false after acceptance");
  }

  function test_isWhitelisted() public {
    address testAddress = makeAddr("testAddress");

    // Initially should be false
    assertFalse(management.isWhitelisted(testAddress), "Should be false initially");

    // Should remain false after proposing
    vm.prank(owner);
    management.proposeWhitelist(testAddress);
    assertFalse(management.isWhitelisted(testAddress), "Should remain false after proposing");

    // Should remain false during timelock
    vm.warp(block.timestamp + 30 minutes);
    assertFalse(management.isWhitelisted(testAddress), "Should remain false during timelock");

    // Should become true after acceptance
    vm.warp(block.timestamp + 31 minutes); // Total 61 minutes
    vm.prank(owner);
    management.acceptWhitelist(testAddress);
    assertTrue(management.isWhitelisted(testAddress), "Should be true after acceptance");
  }

  /*//////////////////////////////////////////////////////////////
                         WORKFLOW TESTS
  //////////////////////////////////////////////////////////////*/

  function test_completeWhitelistWorkflow() public {
    address rebalancer = makeAddr("rebalancer");

    // Step 1: Owner proposes address (should pass validation)
    vm.expectEmit(true, false, false, true);
    emit KandelManagementRebalancing.WhitelistProposed(rebalancer);

    vm.prank(owner);
    management.proposeWhitelist(rebalancer);

    // Verify intermediate state
    assertGt(management.whitelistProposedAt(rebalancer), 0, "Should be proposed");
    assertFalse(management.isWhitelisted(rebalancer), "Should not be whitelisted yet");
    assertFalse(management.canAcceptWhitelist(rebalancer), "Should not be ready for acceptance");

    // Step 2: Wait for timelock
    vm.warp(block.timestamp + 61 minutes);
    assertTrue(management.canAcceptWhitelist(rebalancer), "Should be ready for acceptance after timelock");

    // Step 3: Owner accepts proposal
    vm.expectEmit(true, false, false, true);
    emit KandelManagementRebalancing.WhitelistAccepted(rebalancer);

    vm.prank(owner);
    management.acceptWhitelist(rebalancer);

    // Verify final state
    assertTrue(management.isWhitelisted(rebalancer), "Should be whitelisted");
    assertEq(management.whitelistProposedAt(rebalancer), 0, "Proposal should be cleared");
    assertFalse(management.canAcceptWhitelist(rebalancer), "Should no longer be ready for acceptance");
  }

  function test_canWhitelistValidation_comprehensive() public {
    // Test that all invalid addresses are properly rejected
    (address base, address quote,) = management.market();
    address kandelAddress = address(management.KANDEL());

    vm.startPrank(owner);

    // Should fail for Kandel contract
    vm.expectRevert(KandelManagementRebalancing.InvalidWhitelistAddress.selector);
    management.proposeWhitelist(kandelAddress);

    // Should fail for base token
    vm.expectRevert(KandelManagementRebalancing.InvalidWhitelistAddress.selector);
    management.proposeWhitelist(base);

    // Should fail for quote token
    vm.expectRevert(KandelManagementRebalancing.InvalidWhitelistAddress.selector);
    management.proposeWhitelist(quote);

    // Should succeed for valid addresses
    address validAddress1 = makeAddr("validAddress1");
    address validAddress2 = makeAddr("validAddress2");

    // These should not revert
    management.proposeWhitelist(validAddress1);
    management.proposeWhitelist(validAddress2);

    vm.stopPrank();

    // Verify valid addresses were proposed
    assertGt(management.whitelistProposedAt(validAddress1), 0, "Valid address 1 should be proposed");
    assertGt(management.whitelistProposedAt(validAddress2), 0, "Valid address 2 should be proposed");
  }

  function test_guardianRejectionWorkflow() public {
    address rebalancer = makeAddr("rebalancer");

    // Step 1: Owner proposes address
    vm.prank(owner);
    management.proposeWhitelist(rebalancer);

    // Step 2: Guardian rejects before timelock expires
    vm.warp(block.timestamp + 30 minutes);

    vm.expectEmit(true, false, false, true);
    emit KandelManagementRebalancing.WhitelistRejected(rebalancer);

    vm.prank(guardian);
    management.rejectWhitelist(rebalancer);

    // Verify final state
    assertFalse(management.isWhitelisted(rebalancer), "Should not be whitelisted");
    assertEq(management.whitelistProposedAt(rebalancer), 0, "Proposal should be cleared");
    assertFalse(management.canAcceptWhitelist(rebalancer), "Should not be ready for acceptance");

    // Step 3: Owner can propose again after rejection
    vm.prank(owner);
    management.proposeWhitelist(rebalancer);
    assertGt(management.whitelistProposedAt(rebalancer), 0, "Should be proposed again");
  }

  function test_multipleAddressWorkflow() public {
    address rebalancer1 = makeAddr("rebalancer1");
    address rebalancer2 = makeAddr("rebalancer2");
    address rebalancer3 = makeAddr("rebalancer3");

    vm.startPrank(owner);

    // Propose all three addresses
    management.proposeWhitelist(rebalancer1);
    management.proposeWhitelist(rebalancer2);
    management.proposeWhitelist(rebalancer3);

    vm.stopPrank();

    // Wait for timelock
    vm.warp(block.timestamp + 61 minutes);

    // Accept first, reject second, leave third pending
    vm.prank(owner);
    management.acceptWhitelist(rebalancer1);

    vm.prank(guardian);
    management.rejectWhitelist(rebalancer2);

    // Verify states
    assertTrue(management.isWhitelisted(rebalancer1), "Rebalancer1 should be whitelisted");
    assertFalse(management.isWhitelisted(rebalancer2), "Rebalancer2 should not be whitelisted");
    assertFalse(management.isWhitelisted(rebalancer3), "Rebalancer3 should not be whitelisted yet");

    assertEq(management.whitelistProposedAt(rebalancer1), 0, "Rebalancer1 proposal should be cleared");
    assertEq(management.whitelistProposedAt(rebalancer2), 0, "Rebalancer2 proposal should be cleared");
    assertGt(management.whitelistProposedAt(rebalancer3), 0, "Rebalancer3 proposal should still exist");

    assertTrue(management.canAcceptWhitelist(rebalancer3), "Rebalancer3 should be ready for acceptance");
  }

  /*//////////////////////////////////////////////////////////////
                         EDGE CASE TESTS
  //////////////////////////////////////////////////////////////*/

  function test_zeroAddress() public {
    // Should be able to propose zero address (edge case)
    vm.prank(owner);
    management.proposeWhitelist(address(0));

    assertGt(management.whitelistProposedAt(address(0)), 0, "Zero address should be proposed");

    // Should be able to accept zero address
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptWhitelist(address(0));

    assertTrue(management.isWhitelisted(address(0)), "Zero address should be whitelisted");
  }

  function test_contractAddresses() public {
    // Test whitelisting arbitrary contract addresses (not the restricted ones)
    // Create a mock contract address that's not one of the restricted addresses
    address arbitraryContract = address(0x1234567890123456789012345678901234567890);

    vm.prank(owner);
    management.proposeWhitelist(arbitraryContract);

    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptWhitelist(arbitraryContract);

    assertTrue(management.isWhitelisted(arbitraryContract), "Arbitrary contract address should be whitelisted");
  }

  function test_proposeWhitelist_invalidAddress_managementContract() public {
    // Test that the management contract itself can be whitelisted (it's not in the restricted list)
    // This ensures our validation doesn't accidentally block the management contract
    address managementAddress = address(management);

    // This should succeed since management contract is not in the restricted list
    vm.prank(owner);
    management.proposeWhitelist(managementAddress);

    assertGt(management.whitelistProposedAt(managementAddress), 0, "Management contract should be proposable");
  }

  /*//////////////////////////////////////////////////////////////
                         INHERITANCE TESTS
  //////////////////////////////////////////////////////////////*/

  function test_inheritedKandelManagementFunctions() public {
    // Test that we can still use inherited KandelManagement functions
    address newManager = makeAddr("newManager");

    vm.expectEmit(true, false, false, true);
    emit KandelManagement.SetManager(newManager);

    vm.prank(owner);
    management.setManager(newManager);

    assertEq(management.manager(), newManager, "Manager should be updated");

    // Test balance functions work
    (uint256 baseBalance, uint256 quoteBalance) = management.vaultBalances();
    assertEq(baseBalance, 0, "Initial vault base balance should be zero");
    assertEq(quoteBalance, 0, "Initial vault quote balance should be zero");

    // Test populateFromOffset still works (basic test)
    CoreKandel.Params memory params;
    params.pricePoints = 5;
    params.stepSize = 1;

    vm.deal(address(newManager), 0.01 ether);
    vm.prank(newManager);
    management.populateFromOffset{value: 0.01 ether}(0, 5, Tick.wrap(0), 1, 2, 100e6, 1 ether, params);

    (bool inKandel,,,) = management.state();
    assertTrue(inKandel, "Should be in Kandel after populate");
  }

  /*//////////////////////////////////////////////////////////////
                       REBALANCING TESTS
  //////////////////////////////////////////////////////////////*/

  function test_rebalance_sellBaseForQuote() public {
    // setting the oracle to accept all ticks
    OracleData memory oracle;
    oracle.isStatic = true;
    oracle.maxDeviation = 100;
    oracle.timelockMinutes = 60;
    oracle.staticValue = TickLib.tickFromVolumes(1000e6, 1 ether);

    vm.prank(owner);
    management.proposeOracle(oracle);
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptOracle();

    // Setup: Whitelist the mock swap contract
    vm.prank(owner);
    management.proposeWhitelist(address(mockSwap));
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptWhitelist(address(mockSwap));

    // Add funds to management contract
    uint256 baseAmount = 10 ether;
    MockERC20(address(WETH)).mint(address(management), baseAmount);

    // Prepare swap parameters for selling base token
    uint256 swapAmount = 5 ether;
    uint256 expectedOutput = 5000e6; // 5000 USDC
    bytes memory swapData = abi.encodeWithSignature(
      "swap(address,address,uint256,uint256)", address(WETH), address(USDC), swapAmount, expectedOutput
    );

    KandelManagementRebalancing.RebalanceParams memory params = KandelManagementRebalancing.RebalanceParams({
      isSell: true,
      amountIn: swapAmount,
      minAmountOut: 4800e6, // Minimum acceptable output with slippage
      target: address(mockSwap),
      data: swapData
    });

    // Execute rebalance
    vm.prank(manager);
    (uint256 sent, uint256 received,) = management.rebalance(params, false);

    // Verify results
    assertEq(sent, swapAmount, "Should have sent the correct amount of base tokens");
    assertEq(received, expectedOutput, "Should have received the expected quote tokens");

    // Verify final balances
    assertEq(WETH.balanceOf(address(management)), baseAmount - swapAmount, "Remaining base tokens should be correct");
    assertEq(USDC.balanceOf(address(management)), expectedOutput, "Should have received quote tokens");
  }

  function test_rebalance_buyBaseWithQuote() public {
    // setting the oracle to accept all ticks

    OracleData memory oracle;
    oracle.isStatic = true;
    oracle.maxDeviation = 100;
    oracle.timelockMinutes = 60;
    oracle.staticValue = TickLib.tickFromVolumes(1000e6, 1 ether);

    vm.prank(owner);
    management.proposeOracle(oracle);
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptOracle();

    // Setup: Whitelist the mock swap contract
    vm.prank(owner);
    management.proposeWhitelist(address(mockSwap));
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptWhitelist(address(mockSwap));

    // Add funds to management contract
    uint256 quoteAmount = 10000e6;
    MockERC20(address(USDC)).mint(address(management), quoteAmount);

    // Prepare swap parameters for buying base token
    uint256 swapAmount = 5000e6;
    uint256 expectedOutput = 5 ether; // 5 ETH
    bytes memory swapData = abi.encodeWithSignature(
      "swap(address,address,uint256,uint256)", address(USDC), address(WETH), swapAmount, expectedOutput
    );

    KandelManagementRebalancing.RebalanceParams memory params = KandelManagementRebalancing.RebalanceParams({
      isSell: false,
      amountIn: swapAmount,
      minAmountOut: 4.8 ether, // Minimum acceptable output with slippage
      target: address(mockSwap),
      data: swapData
    });

    // Execute rebalance
    vm.prank(manager);
    (uint256 sent, uint256 received,) = management.rebalance(params, false);

    // Verify results
    assertEq(sent, swapAmount, "Should have sent the correct amount of quote tokens");
    assertEq(received, expectedOutput, "Should have received the expected base tokens");

    // Verify final balances
    assertEq(USDC.balanceOf(address(management)), quoteAmount - swapAmount, "Remaining quote tokens should be correct");
    assertEq(WETH.balanceOf(address(management)), expectedOutput, "Should have received base tokens");
  }

  function test_rebalance_invalidTarget() public {
    address nonWhitelistedTarget = makeAddr("nonWhitelistedTarget");

    KandelManagementRebalancing.RebalanceParams memory params = KandelManagementRebalancing.RebalanceParams({
      isSell: true,
      amountIn: 1 ether,
      minAmountOut: 900e6,
      target: nonWhitelistedTarget,
      data: ""
    });

    vm.prank(manager);
    vm.expectRevert(KandelManagementRebalancing.InvalidRebalanceAddress.selector);
    management.rebalance(params, false);
  }

  function test_rebalance_insufficientBalance() public {
    // Setup: Whitelist the mock swap contract
    vm.prank(owner);
    management.proposeWhitelist(address(mockSwap));
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptWhitelist(address(mockSwap));

    // Don't add any funds to management contract
    bytes memory swapData =
      abi.encodeWithSignature("swap(address,address,uint256,uint256)", address(WETH), address(USDC), 1 ether, 1000e6);

    KandelManagementRebalancing.RebalanceParams memory params = KandelManagementRebalancing.RebalanceParams({
      isSell: true,
      amountIn: 1 ether,
      minAmountOut: 900e6,
      target: address(mockSwap),
      data: swapData
    });

    vm.prank(manager);
    vm.expectRevert(KandelManagementRebalancing.InsufficientBalance.selector);
    management.rebalance(params, false);
  }

  function test_rebalance_swapContractReverts() public {
    // Setup: Whitelist the mock swap contract
    vm.prank(owner);
    management.proposeWhitelist(address(mockSwap));
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptWhitelist(address(mockSwap));

    // Set mock to revert
    mockSwap.setShouldRevert(true);

    // Add funds to management contract
    MockERC20(address(WETH)).mint(address(management), 10 ether);

    bytes memory swapData =
      abi.encodeWithSignature("swap(address,address,uint256,uint256)", address(WETH), address(USDC), 1 ether, 1000e6);

    KandelManagementRebalancing.RebalanceParams memory params = KandelManagementRebalancing.RebalanceParams({
      isSell: true,
      amountIn: 1 ether,
      minAmountOut: 900e6,
      target: address(mockSwap),
      data: swapData
    });

    vm.prank(manager);
    vm.expectRevert("MockSwapContract: should revert");
    management.rebalance(params, false);
  }

  function test_rebalance_withKandelFunds() public {
    // setting the oracle to accept all ticks
    OracleData memory oracle;
    oracle.isStatic = true;
    oracle.maxDeviation = 100;
    oracle.timelockMinutes = 60;
    oracle.staticValue = TickLib.tickFromVolumes(1000e6, 1 ether);

    vm.prank(owner);
    management.proposeOracle(oracle);
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptOracle();

    // Setup: Whitelist the mock swap contract
    vm.prank(owner);
    management.proposeWhitelist(address(mockSwap));
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptWhitelist(address(mockSwap));

    // Add funds to Kandel by populating it
    uint256 baseAmount = 10 ether;
    MockERC20(address(WETH)).mint(address(management), baseAmount);

    CoreKandel.Params memory kandelParams;
    kandelParams.pricePoints = 5;
    kandelParams.stepSize = 1;

    vm.deal(address(manager), 0.01 ether);
    vm.prank(manager);
    management.populateFromOffset{value: 0.01 ether}(0, 5, Tick.wrap(0), 1, 2, 0, 1 ether, kandelParams);

    // Verify funds are in Kandel
    (uint256 kandelBase,) = management.kandelBalances();
    assertGt(kandelBase, 0, "Should have funds in Kandel");

    // Prepare rebalance parameters
    uint256 swapAmount = 3 ether;
    uint256 expectedOutput = 3000e6;
    bytes memory swapData = abi.encodeWithSignature(
      "swap(address,address,uint256,uint256)", address(WETH), address(USDC), swapAmount, expectedOutput
    );

    KandelManagementRebalancing.RebalanceParams memory params = KandelManagementRebalancing.RebalanceParams({
      isSell: true,
      amountIn: swapAmount,
      minAmountOut: 2900e6,
      target: address(mockSwap),
      data: swapData
    });

    // Execute rebalance (should withdraw from Kandel)
    vm.prank(manager);
    (uint256 sent, uint256 received,) = management.rebalance(params, false);

    // Verify swap occurred
    assertEq(sent, swapAmount, "Should have sent the correct amount");
    assertEq(received, expectedOutput, "Should have received expected tokens");

    // Verify some funds were withdrawn from Kandel
    (uint256 kandelBaseAfter,) = management.kandelBalances();
    assertLt(kandelBaseAfter, kandelBase, "Should have withdrawn funds from Kandel");
  }

  function test_rebalance_invalidTradeTick() public {
    // Setup oracle with restrictive deviation
    OracleData memory restrictiveOracle;
    restrictiveOracle.isStatic = true;
    restrictiveOracle.staticValue = Tick.wrap(0);
    restrictiveOracle.maxDeviation = 10; // Very small deviation
    restrictiveOracle.timelockMinutes = 60;

    vm.prank(owner);
    management.proposeOracle(restrictiveOracle);
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptOracle();

    // Setup: Whitelist the mock swap contract
    vm.prank(owner);
    management.proposeWhitelist(address(mockSwap));
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptWhitelist(address(mockSwap));

    // Add funds to management contract
    MockERC20(address(WETH)).mint(address(management), 10 ether);

    // Create a swap with very bad exchange rate (1 ETH for 1 USDC instead of ~1000)
    uint256 swapAmount = 1 ether;
    uint256 badOutput = 1e6; // Only 1 USDC for 1 ETH (terrible rate)
    bytes memory swapData = abi.encodeWithSignature(
      "swap(address,address,uint256,uint256)", address(WETH), address(USDC), swapAmount, badOutput
    );

    KandelManagementRebalancing.RebalanceParams memory params = KandelManagementRebalancing.RebalanceParams({
      isSell: true,
      amountIn: swapAmount,
      minAmountOut: 0, // No minimum to ensure swap executes
      target: address(mockSwap),
      data: swapData
    });

    vm.prank(manager);
    vm.expectRevert(KandelManagementRebalancing.InvalidTradeTick.selector);
    management.rebalance(params, false);
  }

  function test_rebalance_withdrawAll() public {
    // setting the oracle to accept all ticks
    OracleData memory oracle;
    oracle.isStatic = true;
    oracle.maxDeviation = 100;
    oracle.timelockMinutes = 60;
    oracle.staticValue = TickLib.tickFromVolumes(1000e6, 1 ether);

    vm.prank(owner);
    management.proposeOracle(oracle);
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptOracle();

    // Setup: Whitelist the mock swap contract
    vm.prank(owner);
    management.proposeWhitelist(address(mockSwap));
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptWhitelist(address(mockSwap));

    // Setup Kandel with funds
    uint256 baseAmount = 10 ether;
    MockERC20(address(WETH)).mint(address(management), baseAmount);

    CoreKandel.Params memory kandelParams;
    kandelParams.pricePoints = 5;
    kandelParams.stepSize = 1;

    vm.deal(address(manager), 0.01 ether);
    vm.prank(manager);
    management.populateFromOffset{value: 0.01 ether}(0, 5, Tick.wrap(0), 1, 2, 0, 1 ether, kandelParams);

    // Get initial Kandel balance
    (uint256 kandelBaseBefore,) = management.kandelBalances();

    // Prepare rebalance with withdrawAll = true
    uint256 swapAmount = 1 ether;
    uint256 expectedOutput = 1000e6;
    bytes memory swapData = abi.encodeWithSignature(
      "swap(address,address,uint256,uint256)", address(WETH), address(USDC), swapAmount, expectedOutput
    );

    KandelManagementRebalancing.RebalanceParams memory params = KandelManagementRebalancing.RebalanceParams({
      isSell: true,
      amountIn: swapAmount,
      minAmountOut: 950e6,
      target: address(mockSwap),
      data: swapData
    });

    // Execute rebalance with withdrawAll = true
    vm.prank(manager);
    (uint256 sent, uint256 received,) = management.rebalance(params, true);

    // Verify swap occurred correctly
    assertEq(sent, swapAmount, "Should have sent the correct amount");
    assertEq(received, expectedOutput, "Should have received expected output");

    // Verify funds were withdrawn from Kandel (withdrawAll should pull more than needed)
    (uint256 kandelBaseAfter,) = management.kandelBalances();
    assertLt(kandelBaseAfter, kandelBaseBefore, "Should have withdrawn funds from Kandel");
  }

  function test_rebalance_autoDepositsToKandel() public {
    // setting the oracle to accept all ticks
    OracleData memory oracle;
    oracle.isStatic = true;
    oracle.maxDeviation = 100;
    oracle.timelockMinutes = 60;
    oracle.staticValue = TickLib.tickFromVolumes(1000e6, 1 ether);

    vm.prank(owner);
    management.proposeOracle(oracle);
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptOracle();

    // Setup: Whitelist the mock swap contract
    vm.prank(owner);
    management.proposeWhitelist(address(mockSwap));
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptWhitelist(address(mockSwap));

    // Add funds to management contract
    uint256 baseAmount = 15 ether;
    MockERC20(address(WETH)).mint(address(management), baseAmount);
    MockERC20(address(USDC)).mint(address(management), 1000e6);

    // First populate Kandel so we have a strategy
    CoreKandel.Params memory kandelParams;
    kandelParams.pricePoints = 5;
    kandelParams.stepSize = 1;

    vm.deal(address(manager), 0.01 ether);
    vm.prank(manager);
    management.populateFromOffset{value: 0.01 ether}(0, 5, Tick.wrap(0), 1, 2, 0, 1 ether, kandelParams);

    // Prepare swap that will leave remaining tokens
    uint256 swapAmount = 2 ether;
    uint256 expectedOutput = 2000e6;
    bytes memory swapData = abi.encodeWithSignature(
      "swap(address,address,uint256,uint256)", address(WETH), address(USDC), swapAmount, expectedOutput
    );

    KandelManagementRebalancing.RebalanceParams memory params = KandelManagementRebalancing.RebalanceParams({
      isSell: true,
      amountIn: swapAmount,
      minAmountOut: 1900e6,
      target: address(mockSwap),
      data: swapData
    });

    // Get initial balances
    (uint256 vaultBaseBefore, uint256 vaultQuoteBefore) = management.vaultBalances();
    (uint256 kandelBaseBefore, uint256 kandelQuoteBefore) = management.kandelBalances();

    // Execute rebalance
    vm.prank(manager);
    management.rebalance(params, false);

    // Verify remaining tokens were deposited to Kandel
    (uint256 vaultBaseAfter, uint256 vaultQuoteAfter) = management.vaultBalances();
    (uint256 kandelBaseAfter, uint256 kandelQuoteAfter) = management.kandelBalances();

    // Vault should have minimal tokens (only dust), Kandel should have more

    assertEq(vaultBaseAfter, 0, "Vault should have no remaining base tokens");
    assertEq(vaultQuoteAfter, 0, "Vault should have no remaining quote tokens");
    assertEq(vaultBaseBefore, 0, "Vault should have no remaining base tokens");
    assertEq(vaultQuoteBefore, 0, "Vault should have no remaining quote tokens");
    assertLt(kandelBaseAfter, kandelBaseBefore, "Kandel should have less base tokens");
    assertGt(kandelQuoteAfter, kandelQuoteBefore, "Kandel should have more quote tokens");
  }

  function test_rebalance_clearsTokenApprovals() public {
    // setting the oracle to accept all ticks
    OracleData memory oracle;
    oracle.isStatic = true;
    oracle.maxDeviation = 100;
    oracle.timelockMinutes = 60;
    oracle.staticValue = TickLib.tickFromVolumes(1000e6, 1 ether);

    vm.prank(owner);
    management.proposeOracle(oracle);
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptOracle();

    // Setup: Whitelist the mock swap contract
    vm.prank(owner);
    management.proposeWhitelist(address(mockSwap));
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptWhitelist(address(mockSwap));

    // Add funds to management contract
    MockERC20(address(WETH)).mint(address(management), 10 ether);

    uint256 swapAmount = 5 ether;
    uint256 expectedOutput = 5000e6;
    bytes memory swapData = abi.encodeWithSignature(
      "swap(address,address,uint256,uint256)", address(WETH), address(USDC), swapAmount, expectedOutput
    );

    KandelManagementRebalancing.RebalanceParams memory params = KandelManagementRebalancing.RebalanceParams({
      isSell: true,
      amountIn: swapAmount,
      minAmountOut: 4800e6,
      target: address(mockSwap),
      data: swapData
    });

    // Execute rebalance
    vm.prank(manager);
    management.rebalance(params, false);

    // Verify that token approval was cleared after the swap
    assertEq(WETH.allowance(address(management), address(mockSwap)), 0, "WETH approval should be cleared");
    assertEq(USDC.allowance(address(management), address(mockSwap)), 0, "USDC approval should be cleared");
  }

  function test_rebalance_onlyManager() public {
    // setting the oracle to accept all ticks
    OracleData memory oracle;
    oracle.isStatic = true;
    oracle.maxDeviation = 100;
    oracle.timelockMinutes = 60;
    oracle.staticValue = TickLib.tickFromVolumes(1000e6, 1 ether);

    vm.prank(owner);
    management.proposeOracle(oracle);
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptOracle();

    // Setup: Whitelist the mock swap contract
    vm.prank(owner);
    management.proposeWhitelist(address(mockSwap));
    vm.warp(block.timestamp + 61 minutes);
    vm.prank(owner);
    management.acceptWhitelist(address(mockSwap));

    // Add funds to management contract
    MockERC20(address(WETH)).mint(address(management), 10 ether);

    bytes memory swapData =
      abi.encodeWithSignature("swap(address,address,uint256,uint256)", address(WETH), address(USDC), 1 ether, 1000e6);

    KandelManagementRebalancing.RebalanceParams memory params = KandelManagementRebalancing.RebalanceParams({
      isSell: true,
      amountIn: 1 ether,
      minAmountOut: 950e6,
      target: address(mockSwap),
      data: swapData
    });

    // Test that non-manager cannot call rebalance
    address nonManager = makeAddr("nonManager");
    vm.prank(nonManager);
    vm.expectRevert(); // Should revert due to onlyManager modifier
    management.rebalance(params, false);

    // Test that owner cannot call rebalance (only manager can)
    vm.prank(owner);
    vm.expectRevert(); // Should revert due to onlyManager modifier
    management.rebalance(params, false);

    // Test that manager can call rebalance
    vm.prank(manager);
    (uint256 sent, uint256 received,) = management.rebalance(params, false);

    assertEq(sent, 1 ether, "Manager should be able to execute rebalance");
    assertEq(received, 1000e6, "Manager should be able to execute rebalance");
  }
}
