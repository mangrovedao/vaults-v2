// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OracleRange, OracleData, OracleLib} from "../../src/base/OracleRange.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";

/**
 * @title MockOracle
 * @notice Mock oracle contract for testing purposes
 * @dev Allows setting a tick value that can be queried, and can be configured to revert
 */
contract MockOracle is IOracle {
  Tick private _tick;
  bool private _shouldRevert;

  /**
   * @notice Sets the tick value that the oracle should return
   * @param newTick The tick value to set
   */
  function setTick(Tick newTick) external {
    _tick = newTick;
  }

  /**
   * @notice Configures whether the oracle should revert when queried
   * @param shouldRevert True if the oracle should revert, false otherwise
   */
  function setShouldRevert(bool shouldRevert) external {
    _shouldRevert = shouldRevert;
  }

  /**
   * @notice Returns the current tick value
   * @return Tick The current tick value
   * @dev Reverts if _shouldRevert is true
   */
  function tick() external view override returns (Tick) {
    if (_shouldRevert) {
      revert("MockOracle: Configured to revert");
    }
    return _tick;
  }
}

contract OracleRangeTest is Test {
  using OracleLib for OracleData;

  OracleRange public oracleRange;
  address public owner;
  address public guardian;
  address public nonOwner;

  function setUp() public {
    owner = makeAddr("owner");
    guardian = makeAddr("guardian");
    nonOwner = makeAddr("nonOwner");

    OracleData memory initialOracle;
    initialOracle.isStatic = true;
    initialOracle.staticValue = int24(100);
    initialOracle.maxDeviation = 100;
    initialOracle.timelockMinutes = 60; // 1 hour

    oracleRange = new OracleRange(initialOracle, owner, guardian);
  }

  /*//////////////////////////////////////////////////////////////
                       ORACLE PROPOSAL TESTS
  //////////////////////////////////////////////////////////////*/

  function test_proposeOracle() public {
    OracleData memory newOracle;
    newOracle.staticValue = int24(200);
    newOracle.maxDeviation = 150;
    newOracle.isStatic = true;
    newOracle.timelockMinutes = 120;
    newOracle.proposedAt = uint40(block.timestamp);

    vm.expectEmit(true, false, false, true);
    emit OracleRange.ProposedOracle(keccak256(abi.encode(newOracle)), newOracle);

    vm.prank(owner);
    oracleRange.proposeOracle(newOracle);

    (,,, uint16 maxDev, uint40 proposedAt,) = oracleRange.proposedOracle();
    assertEq(maxDev, 150);
    assertEq(proposedAt, block.timestamp);
  }

  function test_proposeOracle_onlyOwner() public {
    OracleData memory newOracle;
    vm.prank(nonOwner);
    vm.expectRevert();
    oracleRange.proposeOracle(newOracle);
  }

  function test_proposeOracle_invalidStaticOracle() public {
    OracleData memory invalidOracle;
    invalidOracle.isStatic = true;
    invalidOracle.staticValue = int24(type(int24).max); // Invalid tick value (out of range)
    invalidOracle.timelockMinutes = 60;

    vm.prank(owner);
    vm.expectRevert(OracleRange.InvalidOracle.selector);
    oracleRange.proposeOracle(invalidOracle);
  }

  function test_proposeOracle_invalidDynamicOracle() public {
    OracleData memory invalidOracle;
    invalidOracle.isStatic = false;
    invalidOracle.oracle = IOracle(address(0)); // Zero address oracle (will fail)
    invalidOracle.timelockMinutes = 60;

    vm.prank(owner);
    vm.expectRevert(OracleRange.InvalidOracle.selector);
    oracleRange.proposeOracle(invalidOracle);
  }

  function test_proposeOracle_validStaticOracle() public {
    OracleData memory validOracle;
    validOracle.isStatic = true;
    validOracle.staticValue = int24(1000); // Valid tick value
    validOracle.timelockMinutes = 60;
    validOracle.proposedAt = uint40(block.timestamp);

    vm.expectEmit(true, false, false, true);
    emit OracleRange.ProposedOracle(keccak256(abi.encode(validOracle)), validOracle);

    vm.prank(owner);
    oracleRange.proposeOracle(validOracle);

    (,,,, uint40 proposedAt,) = oracleRange.proposedOracle();
    assertEq(proposedAt, block.timestamp);
  }

  /*//////////////////////////////////////////////////////////////
                       ORACLE ACCEPTANCE TESTS
  //////////////////////////////////////////////////////////////*/

  function test_acceptOracle_afterTimelock() public {
    OracleData memory newOracle;
    newOracle.staticValue = int24(300);
    newOracle.maxDeviation = 200;
    newOracle.isStatic = true;
    newOracle.timelockMinutes = 60; // 1 hour
    newOracle.proposedAt = uint40(block.timestamp);

    vm.startPrank(owner);
    oracleRange.proposeOracle(newOracle);

    // Fast forward past timelock
    vm.warp(block.timestamp + 61 minutes);

    vm.expectEmit(true, false, false, true);
    emit OracleRange.AcceptedOracle(keccak256(abi.encode(newOracle)));

    oracleRange.acceptOracle();
    vm.stopPrank();

    (,,, uint16 maxDev,,) = oracleRange.oracle();
    assertEq(maxDev, 200);
  }

  function test_acceptOracle_failsIfTimelocked() public {
    OracleData memory newOracle;
    newOracle.isStatic = true;
    newOracle.staticValue = int24(200);
    newOracle.timelockMinutes = 60;

    vm.startPrank(owner);
    oracleRange.proposeOracle(newOracle);

    vm.expectRevert(OracleRange.OracleTimelocked.selector);
    oracleRange.acceptOracle();
    vm.stopPrank();
  }

  function test_acceptOracle_onlyOwner() public {
    vm.prank(nonOwner);
    vm.expectRevert();
    oracleRange.acceptOracle();
  }

  /*//////////////////////////////////////////////////////////////
                       ORACLE REJECTION TESTS
  //////////////////////////////////////////////////////////////*/

  function test_rejectOracle() public {
    OracleData memory newOracle;
    newOracle.isStatic = true;
    newOracle.staticValue = int24(500);
    newOracle.proposedAt = uint40(block.timestamp);

    vm.prank(owner);
    oracleRange.proposeOracle(newOracle);

    vm.expectEmit(true, false, false, true);
    emit OracleRange.RejectedOracle(keccak256(abi.encode(newOracle)));

    vm.prank(guardian);
    oracleRange.rejectOracle();

    // Proposed oracle should be cleared
    (bool isStatic,,,,, uint8 timelockMinutes) = oracleRange.proposedOracle();
    assertEq(isStatic, false);
    assertEq(timelockMinutes, 0);
  }

  function test_rejectOracle_onlyGuardian() public {
    vm.prank(owner);
    vm.expectRevert(OracleRange.NotGuardian.selector);
    oracleRange.rejectOracle();
  }

  /*//////////////////////////////////////////////////////////////
                         EDGE CASE TESTS
  //////////////////////////////////////////////////////////////*/

  function test_oracleTimelock_edgeCase() public {
    OracleData memory newOracle;
    newOracle.isStatic = true;
    newOracle.staticValue = int24(100);
    newOracle.timelockMinutes = 60;

    vm.startPrank(owner);
    oracleRange.proposeOracle(newOracle);

    // Exactly at timelock boundary
    vm.warp(block.timestamp + 60 minutes);
    oracleRange.acceptOracle(); // should succeed

    vm.stopPrank();
  }

  function test_multipleOracleProposals() public {
    OracleData memory oracle1;
    oracle1.isStatic = true;
    oracle1.staticValue = int24(100);
    oracle1.timelockMinutes = 60;

    OracleData memory oracle2;
    oracle2.isStatic = true;
    oracle2.staticValue = int24(200);
    oracle2.timelockMinutes = 60;

    vm.startPrank(owner);
    oracleRange.proposeOracle(oracle1);

    // Propose second oracle (should overwrite first)
    oracleRange.proposeOracle(oracle2);

    vm.warp(block.timestamp + 61 minutes);
    oracleRange.acceptOracle();
    vm.stopPrank();

    (,, int24 staticValue,,,) = oracleRange.oracle();
    assertEq(staticValue, 200);
  }

  /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
  //////////////////////////////////////////////////////////////*/

  function test_constructor_initializesCorrectly() public view {
    assertEq(oracleRange.owner(), owner);
    assertEq(oracleRange.guardian(), guardian);

    // Check initial oracle values
    (bool isStatic,, int24 staticValue, uint16 maxDev,,) = oracleRange.oracle();
    assertTrue(isStatic);
    assertEq(staticValue, 100);
    assertEq(maxDev, 100);
  }

  function test_constructor_emitsEvents() public {
    address newOwner = makeAddr("newOwner");
    address newGuardian = makeAddr("newGuardian");

    OracleData memory initialOracle;
    initialOracle.isStatic = true;
    initialOracle.staticValue = int24(200);
    initialOracle.maxDeviation = 150;
    initialOracle.timelockMinutes = 120;
    initialOracle.proposedAt = uint40(block.timestamp);

    // Expect GuardianChanged event from address(0) to newGuardian
    vm.expectEmit(true, true, false, true);
    emit OracleRange.GuardianChanged(address(0), newGuardian);

    // Expect ProposedOracle event for initial oracle
    vm.expectEmit(true, false, false, true);
    emit OracleRange.ProposedOracle(keccak256(abi.encode(initialOracle)), initialOracle);

    // Expect AcceptedOracle event for initial oracle
    vm.expectEmit(true, false, false, true);
    emit OracleRange.AcceptedOracle(keccak256(abi.encode(initialOracle)));

    // Create new OracleRange instance (should emit all three events)
    OracleRange newOracleRange = new OracleRange(initialOracle, newOwner, newGuardian);

    // Verify the contract was initialized correctly
    assertEq(newOracleRange.owner(), newOwner);
    assertEq(newOracleRange.guardian(), newGuardian);

    (bool isStatic,, int24 staticValue, uint16 maxDev,,) = newOracleRange.oracle();
    assertTrue(isStatic);
    assertEq(staticValue, 200);
    assertEq(maxDev, 150);
  }

  function test_constructor_emitsEventsWithZeroGuardian() public {
    address newOwner = makeAddr("newOwner");
    address zeroGuardian = address(0);

    OracleData memory initialOracle;
    initialOracle.isStatic = true;
    initialOracle.staticValue = int24(300);
    initialOracle.maxDeviation = 200;
    initialOracle.timelockMinutes = 60;
    initialOracle.proposedAt = uint40(block.timestamp);

    // Expect GuardianChanged event from address(0) to address(0)
    vm.expectEmit(true, true, false, true);
    emit OracleRange.GuardianChanged(address(0), address(0));

    // Expect ProposedOracle event
    vm.expectEmit(true, false, false, true);
    emit OracleRange.ProposedOracle(keccak256(abi.encode(initialOracle)), initialOracle);

    // Expect AcceptedOracle event
    vm.expectEmit(true, false, false, true);
    emit OracleRange.AcceptedOracle(keccak256(abi.encode(initialOracle)));

    // Create new OracleRange instance with zero guardian
    OracleRange newOracleRange = new OracleRange(initialOracle, newOwner, zeroGuardian);

    // Verify the contract was initialized correctly
    assertEq(newOracleRange.guardian(), address(0));
  }

  function test_constructor_emitsEventsWithDynamicOracle() public {
    MockOracle mockOracle = new MockOracle();
    mockOracle.setTick(Tick.wrap(1500));

    address newOwner = makeAddr("newOwner");
    address newGuardian = makeAddr("newGuardian");

    OracleData memory dynamicOracle;
    dynamicOracle.isStatic = false;
    dynamicOracle.oracle = IOracle(address(mockOracle));
    dynamicOracle.maxDeviation = 250;
    dynamicOracle.timelockMinutes = 90;
    dynamicOracle.proposedAt = uint40(block.timestamp);

    // Expect all three events for dynamic oracle
    vm.expectEmit(true, true, false, true);
    emit OracleRange.GuardianChanged(address(0), newGuardian);

    vm.expectEmit(true, false, false, true);
    emit OracleRange.ProposedOracle(keccak256(abi.encode(dynamicOracle)), dynamicOracle);

    vm.expectEmit(true, false, false, true);
    emit OracleRange.AcceptedOracle(keccak256(abi.encode(dynamicOracle)));

    // Create new OracleRange instance with dynamic oracle
    OracleRange newOracleRange = new OracleRange(dynamicOracle, newOwner, newGuardian);

    // Verify the contract was initialized correctly
    (bool isStatic, IOracle oracle,, uint16 maxDev,,) = newOracleRange.oracle();
    assertFalse(isStatic);
    assertEq(address(oracle), address(mockOracle));
    assertEq(maxDev, 250);
  }

  /*//////////////////////////////////////////////////////////////
                      DYNAMIC ORACLE TESTS
  //////////////////////////////////////////////////////////////*/

  function test_proposeOracle_validDynamicOracle() public {
    MockOracle mockOracle = new MockOracle();
    mockOracle.setTick(Tick.wrap(1500)); // Set valid tick value

    OracleData memory dynamicOracle;
    dynamicOracle.isStatic = false;
    dynamicOracle.oracle = IOracle(address(mockOracle));
    dynamicOracle.maxDeviation = 200;
    dynamicOracle.timelockMinutes = 30;
    dynamicOracle.proposedAt = uint40(block.timestamp);

    vm.expectEmit(true, false, false, true);
    emit OracleRange.ProposedOracle(keccak256(abi.encode(dynamicOracle)), dynamicOracle);

    vm.prank(owner);
    oracleRange.proposeOracle(dynamicOracle);

    // Verify the proposed oracle was set
    (bool isStatic, IOracle oracle,, uint16 maxDev, uint40 proposedAt, uint8 timelockMinutes) =
      oracleRange.proposedOracle();
    assertEq(isStatic, false);
    assertEq(address(oracle), address(mockOracle));
    assertEq(maxDev, 200);
    assertEq(timelockMinutes, 30);
    assertEq(proposedAt, block.timestamp);
  }

  function test_proposeOracle_dynamicOracleReturnsInvalidTick() public {
    MockOracle mockOracle = new MockOracle();
    mockOracle.setTick(Tick.wrap(type(int24).max)); // Invalid tick (out of range)

    OracleData memory dynamicOracle;
    dynamicOracle.isStatic = false;
    dynamicOracle.oracle = IOracle(address(mockOracle));
    dynamicOracle.timelockMinutes = 60;
    dynamicOracle.proposedAt = uint40(block.timestamp);

    vm.prank(owner);
    vm.expectRevert(OracleRange.InvalidOracle.selector);
    oracleRange.proposeOracle(dynamicOracle);
  }

  function test_proposeOracle_dynamicOracleReverts() public {
    MockOracle mockOracle = new MockOracle();
    mockOracle.setShouldRevert(true); // Configure oracle to revert

    OracleData memory dynamicOracle;
    dynamicOracle.isStatic = false;
    dynamicOracle.oracle = IOracle(address(mockOracle));
    dynamicOracle.timelockMinutes = 60;
    dynamicOracle.proposedAt = uint40(block.timestamp);

    vm.prank(owner);
    vm.expectRevert(OracleRange.InvalidOracle.selector);
    oracleRange.proposeOracle(dynamicOracle);
  }

  function test_acceptOracle_dynamicOracle() public {
    MockOracle mockOracle = new MockOracle();
    mockOracle.setTick(Tick.wrap(2000)); // Valid tick value

    OracleData memory dynamicOracle;
    dynamicOracle.isStatic = false;
    dynamicOracle.oracle = IOracle(address(mockOracle));
    dynamicOracle.maxDeviation = 300;
    dynamicOracle.timelockMinutes = 60;
    dynamicOracle.proposedAt = uint40(block.timestamp);

    vm.startPrank(owner);
    oracleRange.proposeOracle(dynamicOracle);

    // Fast forward past timelock
    vm.warp(block.timestamp + 61 minutes);

    vm.expectEmit(true, false, false, true);
    emit OracleRange.AcceptedOracle(keccak256(abi.encode(dynamicOracle)));

    oracleRange.acceptOracle();
    vm.stopPrank();

    // Verify the oracle was accepted
    (bool isStatic, IOracle oracle,, uint16 maxDev,,) = oracleRange.oracle();
    assertEq(isStatic, false);
    assertEq(address(oracle), address(mockOracle));
    assertEq(maxDev, 300);
  }

  function test_dynamicOracle_tickRetrieval() public {
    MockOracle mockOracle = new MockOracle();
    mockOracle.setTick(Tick.wrap(1800));

    OracleData memory dynamicOracle;
    dynamicOracle.isStatic = false;
    dynamicOracle.oracle = IOracle(address(mockOracle));
    dynamicOracle.timelockMinutes = 60;
    dynamicOracle.maxDeviation = 300;

    vm.startPrank(owner);
    oracleRange.proposeOracle(dynamicOracle);
    vm.warp(block.timestamp + 61 minutes);
    oracleRange.acceptOracle();
    vm.stopPrank();

    // Test that we can retrieve the tick from the dynamic oracle
    // This is done indirectly through the accepts function since tick() is internal
    OracleData memory currentOracle;
    (
      currentOracle.isStatic,
      currentOracle.oracle,
      currentOracle.staticValue,
      currentOracle.maxDeviation,
      currentOracle.proposedAt,
      currentOracle.timelockMinutes
    ) = oracleRange.oracle();

    // Test accepts function with dynamic oracle
    // Oracle tick is 1800, maxDeviation should allow ticks within range
    assertTrue(currentOracle.accepts(Tick.wrap(1500), Tick.wrap(-2100))); // Both within range
    assertTrue(currentOracle.accepts(Tick.wrap(1800), Tick.wrap(-1800))); // Exact match
  }

  function test_dynamicOracle_acceptsValidation() public {
    MockOracle mockOracle = new MockOracle();
    mockOracle.setTick(Tick.wrap(1000)); // Oracle returns tick 1000

    OracleData memory dynamicOracle;
    dynamicOracle.isStatic = false;
    dynamicOracle.oracle = IOracle(address(mockOracle));
    dynamicOracle.maxDeviation = 100; // Allow deviation of 100 ticks
    dynamicOracle.timelockMinutes = 60;
    dynamicOracle.proposedAt = uint40(block.timestamp);

    vm.startPrank(owner);
    oracleRange.proposeOracle(dynamicOracle);
    vm.warp(block.timestamp + 61 minutes);
    oracleRange.acceptOracle();
    vm.stopPrank();

    OracleData memory currentOracle;
    (
      currentOracle.isStatic,
      currentOracle.oracle,
      currentOracle.staticValue,
      currentOracle.maxDeviation,
      currentOracle.proposedAt,
      currentOracle.timelockMinutes
    ) = oracleRange.oracle();

    // Test cases for accepts function
    // Oracle tick = 1000, maxDeviation = 100
    // Formula: (oracleTick - askTick <= maxDeviation) && (-oracleTick - bidTick <= maxDeviation)

    // Valid cases (within deviation)
    assertTrue(currentOracle.accepts(Tick.wrap(900), Tick.wrap(-900))); // Ask: 1000-900=100 ≤ 100 ✓, Bid: -1000-(-900)=-100 ≤ 100 ✓
    assertTrue(currentOracle.accepts(Tick.wrap(950), Tick.wrap(-950))); // Ask: 1000-950=50 ≤ 100 ✓, Bid: -1000-(-950)=-50 ≤ 100 ✓
    assertTrue(currentOracle.accepts(Tick.wrap(1000), Tick.wrap(-1000))); // Ask: 1000-1000=0 ≤ 100 ✓, Bid: -1000-(-1000)=0 ≤ 100 ✓
    assertTrue(currentOracle.accepts(Tick.wrap(900), Tick.wrap(-899))); // Ask: 1000-900=100 ≤ 100 ✓, Bid: -1000-(-899)=-101 ≤ 100 ✓ (negative is fine)

    // Invalid cases (outside deviation)
    assertFalse(currentOracle.accepts(Tick.wrap(899), Tick.wrap(-900))); // Ask: 1000-899=101 > 100 ❌
    assertFalse(currentOracle.accepts(Tick.wrap(800), Tick.wrap(-800))); // Ask: 1000-800=200 > 100 ❌
  }

  function test_dynamicOracle_oracleFailsDuringAccepts() public {
    MockOracle mockOracle = new MockOracle();
    mockOracle.setTick(Tick.wrap(1500));

    OracleData memory dynamicOracle;
    dynamicOracle.isStatic = false;
    dynamicOracle.oracle = IOracle(address(mockOracle));
    dynamicOracle.maxDeviation = 3000; // Large enough to accommodate ask/bid calculations
    dynamicOracle.timelockMinutes = 60;
    dynamicOracle.proposedAt = uint40(block.timestamp);

    vm.startPrank(owner);
    oracleRange.proposeOracle(dynamicOracle);
    vm.warp(block.timestamp + 61 minutes);
    oracleRange.acceptOracle();
    vm.stopPrank();

    // Now make the oracle revert
    mockOracle.setShouldRevert(true);

    OracleData memory currentOracle;
    (
      currentOracle.isStatic,
      currentOracle.oracle,
      currentOracle.staticValue,
      currentOracle.maxDeviation,
      currentOracle.proposedAt,
      currentOracle.timelockMinutes
    ) = oracleRange.oracle();

    // The accepts function should revert when the oracle fails
    vm.expectRevert();
    currentOracle.accepts(Tick.wrap(1400), Tick.wrap(-1600)); // Ask: oracleTick-askTick, Bid: -oracleTick-bidTick
  }

  function test_dynamicOracle_changingTickValue() public {
    MockOracle mockOracle = new MockOracle();
    mockOracle.setTick(Tick.wrap(1000));

    OracleData memory dynamicOracle;
    dynamicOracle.isStatic = false;
    dynamicOracle.oracle = IOracle(address(mockOracle));
    dynamicOracle.maxDeviation = 50;
    dynamicOracle.timelockMinutes = 60;
    dynamicOracle.proposedAt = uint40(block.timestamp);

    vm.startPrank(owner);
    oracleRange.proposeOracle(dynamicOracle);
    vm.warp(block.timestamp + 61 minutes);
    oracleRange.acceptOracle();
    vm.stopPrank();

    OracleData memory currentOracle;
    (
      currentOracle.isStatic,
      currentOracle.oracle,
      currentOracle.staticValue,
      currentOracle.maxDeviation,
      currentOracle.proposedAt,
      currentOracle.timelockMinutes
    ) = oracleRange.oracle();

    // Test with initial tick value (1000), maxDeviation = 50
    // Ask: 1000-950=50 ✓, Bid: -1000-(-950)=-50 ✓
    assertTrue(currentOracle.accepts(Tick.wrap(950), Tick.wrap(-950))); // Within 50 tick deviation
    // Ask: 1000-949=51 > 50 ❌
    assertFalse(currentOracle.accepts(Tick.wrap(949), Tick.wrap(-950))); // Ask outside 50 tick deviation

    // Change the oracle's tick value
    mockOracle.setTick(Tick.wrap(2000));

    // Test with new tick value (2000) - the same OracleData should now use the new value
    // Ask: 2000-1950=50 ✓, Bid: -2000-(-1950)=-50 ✓
    assertTrue(currentOracle.accepts(Tick.wrap(1950), Tick.wrap(-1950))); // Within 50 tick deviation of new value
    // Ask: 2000-950=1050 > 50 ❌
    assertFalse(currentOracle.accepts(Tick.wrap(950), Tick.wrap(-950))); // Now outside deviation of new value
  }

  /*//////////////////////////////////////////////////////////////
                      GUARDIAN MANAGEMENT TESTS
  //////////////////////////////////////////////////////////////*/

  function test_setGuardian() public {
    address newGuardian = makeAddr("newGuardian");

    vm.expectEmit(true, true, false, true);
    emit OracleRange.GuardianChanged(guardian, newGuardian);

    vm.prank(guardian);
    oracleRange.setGuardian(newGuardian);

    assertEq(oracleRange.guardian(), newGuardian, "Guardian should be updated to new address");
  }

  function test_setGuardian_onlyGuardian() public {
    address newGuardian = makeAddr("newGuardian");

    // Test that owner cannot set guardian
    vm.prank(owner);
    vm.expectRevert(OracleRange.NotGuardian.selector);
    oracleRange.setGuardian(newGuardian);

    // Test that non-owner cannot set guardian
    vm.prank(nonOwner);
    vm.expectRevert(OracleRange.NotGuardian.selector);
    oracleRange.setGuardian(newGuardian);

    // Guardian should remain unchanged
    assertEq(oracleRange.guardian(), guardian, "Guardian should remain unchanged after failed attempts");
  }

  function test_setGuardian_newGuardianCanReject() public {
    address newGuardian = makeAddr("newGuardian");

    // First, set a new guardian
    vm.prank(guardian);
    oracleRange.setGuardian(newGuardian);

    // Propose an oracle as owner
    OracleData memory newOracle;
    newOracle.isStatic = true;
    newOracle.staticValue = int24(500);
    newOracle.timelockMinutes = 60;

    vm.prank(owner);
    oracleRange.proposeOracle(newOracle);

    // Old guardian should no longer be able to reject
    vm.prank(guardian);
    vm.expectRevert(OracleRange.NotGuardian.selector);
    oracleRange.rejectOracle();

    // New guardian should be able to reject
    vm.prank(newGuardian);
    oracleRange.rejectOracle(); // Should succeed

    // Verify proposed oracle was cleared
    (bool isStatic,,,,, uint8 timelockMinutes) = oracleRange.proposedOracle();
    assertEq(isStatic, false, "Proposed oracle should be cleared");
    assertEq(timelockMinutes, 0, "Proposed oracle timelock should be cleared");
  }

  function test_setGuardian_sameAddress() public {
    // Setting guardian to the same address should still work and emit event
    vm.expectEmit(true, true, false, true);
    emit OracleRange.GuardianChanged(guardian, guardian);

    vm.prank(guardian);
    oracleRange.setGuardian(guardian);

    assertEq(oracleRange.guardian(), guardian, "Guardian should remain the same");
  }

  function test_setGuardian_zeroAddress() public {
    // Setting guardian to zero address should be allowed (removes guardian functionality)
    vm.expectEmit(true, true, false, true);
    emit OracleRange.GuardianChanged(guardian, address(0));

    vm.prank(guardian);
    oracleRange.setGuardian(address(0));

    assertEq(oracleRange.guardian(), address(0), "Guardian should be set to zero address");

    // After setting to zero address, no one should be able to reject oracles
    OracleData memory newOracle;
    newOracle.isStatic = true;
    newOracle.staticValue = int24(500);
    newOracle.timelockMinutes = 60;

    vm.prank(owner);
    oracleRange.proposeOracle(newOracle);

    // No one should be able to reject now
    vm.prank(guardian); // Old guardian
    vm.expectRevert(OracleRange.NotGuardian.selector);
    oracleRange.rejectOracle();

    vm.prank(owner);
    vm.expectRevert(OracleRange.NotGuardian.selector);
    oracleRange.rejectOracle();
  }

  function test_setGuardian_chainedTransfer() public {
    address newGuardian1 = makeAddr("newGuardian1");
    address newGuardian2 = makeAddr("newGuardian2");

    // First transfer: original guardian -> newGuardian1
    vm.expectEmit(true, true, false, true);
    emit OracleRange.GuardianChanged(guardian, newGuardian1);

    vm.prank(guardian);
    oracleRange.setGuardian(newGuardian1);

    assertEq(oracleRange.guardian(), newGuardian1, "Guardian should be newGuardian1");

    // Second transfer: newGuardian1 -> newGuardian2
    vm.expectEmit(true, true, false, true);
    emit OracleRange.GuardianChanged(newGuardian1, newGuardian2);

    vm.prank(newGuardian1);
    oracleRange.setGuardian(newGuardian2);

    assertEq(oracleRange.guardian(), newGuardian2, "Guardian should be newGuardian2");

    // Verify only the final guardian can reject oracles
    OracleData memory newOracle;
    newOracle.isStatic = true;
    newOracle.staticValue = int24(500);
    newOracle.timelockMinutes = 60;

    vm.prank(owner);
    oracleRange.proposeOracle(newOracle);

    // Original guardian and first new guardian should not work
    vm.prank(guardian);
    vm.expectRevert(OracleRange.NotGuardian.selector);
    oracleRange.rejectOracle();

    vm.prank(newGuardian1);
    vm.expectRevert(OracleRange.NotGuardian.selector);
    oracleRange.rejectOracle();

    // Only the final guardian should work
    vm.prank(newGuardian2);
    oracleRange.rejectOracle(); // Should succeed
  }

  /*//////////////////////////////////////////////////////////////
                   GET CURRENT TICK INFO TESTS
  //////////////////////////////////////////////////////////////*/

  function test_getCurrentTickInfo_staticOracle() public view {
    // Test with the initial static oracle setup
    (Tick currentTick, bool isStatic, uint16 maxDeviation) = oracleRange.getCurrentTickInfo();

    assertEq(Tick.unwrap(currentTick), 100, "Current tick should match static value");
    assertTrue(isStatic, "Oracle should be static");
    assertEq(maxDeviation, 100, "Max deviation should match oracle config");
  }

  function test_getCurrentTickInfo_afterStaticOracleUpdate() public {
    // Propose and accept a new static oracle
    OracleData memory newOracle;
    newOracle.isStatic = true;
    newOracle.staticValue = int24(500);
    newOracle.maxDeviation = 250;
    newOracle.timelockMinutes = 60;

    vm.startPrank(owner);
    oracleRange.proposeOracle(newOracle);
    vm.warp(block.timestamp + 61 minutes);
    oracleRange.acceptOracle();
    vm.stopPrank();

    // Test the updated oracle info
    (Tick currentTick, bool isStatic, uint16 maxDeviation) = oracleRange.getCurrentTickInfo();

    assertEq(Tick.unwrap(currentTick), 500, "Current tick should match new static value");
    assertTrue(isStatic, "Oracle should still be static");
    assertEq(maxDeviation, 250, "Max deviation should match new oracle config");
  }

  function test_getCurrentTickInfo_dynamicOracle() public {
    MockOracle mockOracle = new MockOracle();
    mockOracle.setTick(Tick.wrap(1800));

    OracleData memory dynamicOracle;
    dynamicOracle.isStatic = false;
    dynamicOracle.oracle = IOracle(address(mockOracle));
    dynamicOracle.maxDeviation = 300;
    dynamicOracle.timelockMinutes = 60;

    vm.startPrank(owner);
    oracleRange.proposeOracle(dynamicOracle);
    vm.warp(block.timestamp + 61 minutes);
    oracleRange.acceptOracle();
    vm.stopPrank();

    // Test dynamic oracle info
    (Tick currentTick, bool isStatic, uint16 maxDeviation) = oracleRange.getCurrentTickInfo();

    assertEq(Tick.unwrap(currentTick), 1800, "Current tick should match dynamic oracle value");
    assertFalse(isStatic, "Oracle should not be static");
    assertEq(maxDeviation, 300, "Max deviation should match dynamic oracle config");
  }

  function test_getCurrentTickInfo_dynamicOracleChangingValue() public {
    MockOracle mockOracle = new MockOracle();
    mockOracle.setTick(Tick.wrap(1000));

    OracleData memory dynamicOracle;
    dynamicOracle.isStatic = false;
    dynamicOracle.oracle = IOracle(address(mockOracle));
    dynamicOracle.maxDeviation = 200;
    dynamicOracle.timelockMinutes = 60;

    vm.startPrank(owner);
    oracleRange.proposeOracle(dynamicOracle);
    vm.warp(block.timestamp + 61 minutes);
    oracleRange.acceptOracle();
    vm.stopPrank();

    // Initial state
    (Tick currentTick, bool isStatic, uint16 maxDeviation) = oracleRange.getCurrentTickInfo();
    assertEq(Tick.unwrap(currentTick), 1000, "Initial tick should be 1000");
    assertFalse(isStatic, "Oracle should not be static");
    assertEq(maxDeviation, 200, "Max deviation should be 200");

    // Change the mock oracle's value
    mockOracle.setTick(Tick.wrap(2500));

    // Test that getCurrentTickInfo reflects the new value
    (currentTick, isStatic, maxDeviation) = oracleRange.getCurrentTickInfo();
    assertEq(Tick.unwrap(currentTick), 2500, "Tick should reflect updated oracle value");
    assertFalse(isStatic, "Oracle should still not be static");
    assertEq(maxDeviation, 200, "Max deviation should remain unchanged");
  }

  function test_getCurrentTickInfo_dynamicOracleReverts() public {
    MockOracle mockOracle = new MockOracle();
    mockOracle.setTick(Tick.wrap(1500));

    OracleData memory dynamicOracle;
    dynamicOracle.isStatic = false;
    dynamicOracle.oracle = IOracle(address(mockOracle));
    dynamicOracle.maxDeviation = 100;
    dynamicOracle.timelockMinutes = 60;

    vm.startPrank(owner);
    oracleRange.proposeOracle(dynamicOracle);
    vm.warp(block.timestamp + 61 minutes);
    oracleRange.acceptOracle();
    vm.stopPrank();

    // Configure oracle to revert
    mockOracle.setShouldRevert(true);

    // getCurrentTickInfo should revert when the oracle fails
    vm.expectRevert("MockOracle: Configured to revert");
    oracleRange.getCurrentTickInfo();
  }

  function test_getCurrentTickInfo_multipleOracleTransitions() public {
    // Start with static oracle (already set up in setUp)
    (Tick currentTick, bool isStatic, uint16 maxDeviation) = oracleRange.getCurrentTickInfo();
    assertEq(Tick.unwrap(currentTick), 100, "Initial static tick should be 100");
    assertTrue(isStatic, "Should start with static oracle");
    assertEq(maxDeviation, 100, "Initial max deviation should be 100");

    // Transition to dynamic oracle
    MockOracle mockOracle = new MockOracle();
    mockOracle.setTick(Tick.wrap(2000));

    OracleData memory dynamicOracle;
    dynamicOracle.isStatic = false;
    dynamicOracle.oracle = IOracle(address(mockOracle));
    dynamicOracle.maxDeviation = 400;
    dynamicOracle.timelockMinutes = 60;

    vm.startPrank(owner);
    oracleRange.proposeOracle(dynamicOracle);
    vm.warp(block.timestamp + 61 minutes);
    oracleRange.acceptOracle();
    vm.stopPrank();

    // Test dynamic oracle
    (currentTick, isStatic, maxDeviation) = oracleRange.getCurrentTickInfo();
    assertEq(Tick.unwrap(currentTick), 2000, "Dynamic tick should be 2000");
    assertFalse(isStatic, "Should now be dynamic oracle");
    assertEq(maxDeviation, 400, "Max deviation should be 400");

    // Transition back to static oracle
    OracleData memory newStaticOracle;
    newStaticOracle.isStatic = true;
    newStaticOracle.staticValue = int24(750);
    newStaticOracle.maxDeviation = 150;
    newStaticOracle.timelockMinutes = 30;

    vm.startPrank(owner);
    oracleRange.proposeOracle(newStaticOracle);
    vm.warp(block.timestamp + 61 minutes);
    oracleRange.acceptOracle();
    vm.stopPrank();

    // Test back to static oracle
    (currentTick, isStatic, maxDeviation) = oracleRange.getCurrentTickInfo();
    assertEq(Tick.unwrap(currentTick), 750, "Static tick should be 750");
    assertTrue(isStatic, "Should be back to static oracle");
    assertEq(maxDeviation, 150, "Max deviation should be 150");
  }

  function test_getCurrentTickInfo_zeroMaxDeviation() public {
    OracleData memory zeroDeviationOracle;
    zeroDeviationOracle.isStatic = true;
    zeroDeviationOracle.staticValue = int24(1200);
    zeroDeviationOracle.maxDeviation = 0; // Zero deviation
    zeroDeviationOracle.timelockMinutes = 60;

    vm.startPrank(owner);
    oracleRange.proposeOracle(zeroDeviationOracle);
    vm.warp(block.timestamp + 61 minutes);
    oracleRange.acceptOracle();
    vm.stopPrank();

    (Tick currentTick, bool isStatic, uint16 maxDeviation) = oracleRange.getCurrentTickInfo();
    assertEq(Tick.unwrap(currentTick), 1200, "Current tick should be 1200");
    assertTrue(isStatic, "Oracle should be static");
    assertEq(maxDeviation, 0, "Max deviation should be 0");
  }

  function test_getCurrentTickInfo_maxDeviationBoundaries() public {
    OracleData memory maxDeviationOracle;
    maxDeviationOracle.isStatic = true;
    maxDeviationOracle.staticValue = int24(-500);
    maxDeviationOracle.maxDeviation = type(uint16).max; // Maximum possible deviation
    maxDeviationOracle.timelockMinutes = 60;

    vm.startPrank(owner);
    oracleRange.proposeOracle(maxDeviationOracle);
    vm.warp(block.timestamp + 61 minutes);
    oracleRange.acceptOracle();
    vm.stopPrank();

    (Tick currentTick, bool isStatic, uint16 maxDeviation) = oracleRange.getCurrentTickInfo();
    assertEq(Tick.unwrap(currentTick), -500, "Current tick should be -500");
    assertTrue(isStatic, "Oracle should be static");
    assertEq(maxDeviation, type(uint16).max, "Max deviation should be maximum uint16");
  }
}
