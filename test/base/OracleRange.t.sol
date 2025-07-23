// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OracleRange, OracleData} from "../../src/base/OracleRange.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";

contract OracleRangeTest is Test {
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
    initialOracle.staticValue = Tick.wrap(100);
    initialOracle.maxDeviation = 100;
    initialOracle.timelockMinutes = 60; // 1 hour

    oracleRange = new OracleRange(initialOracle, owner, guardian);
  }

  /*//////////////////////////////////////////////////////////////
                       ORACLE PROPOSAL TESTS
  //////////////////////////////////////////////////////////////*/

  function test_proposeOracle() public {
    OracleData memory newOracle;
    newOracle.staticValue = Tick.wrap(200);
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
    invalidOracle.staticValue = Tick.wrap(type(int24).max); // Invalid tick value (out of range)
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
    validOracle.staticValue = Tick.wrap(1000); // Valid tick value
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
    newOracle.staticValue = Tick.wrap(300);
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
    newOracle.staticValue = Tick.wrap(200);
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
    newOracle.staticValue = Tick.wrap(500);
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
    newOracle.staticValue = Tick.wrap(100);
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
    oracle1.staticValue = Tick.wrap(100);
    oracle1.timelockMinutes = 60;

    OracleData memory oracle2;
    oracle2.isStatic = true;
    oracle2.staticValue = Tick.wrap(200);
    oracle2.timelockMinutes = 60;

    vm.startPrank(owner);
    oracleRange.proposeOracle(oracle1);

    // Propose second oracle (should overwrite first)
    oracleRange.proposeOracle(oracle2);

    vm.warp(block.timestamp + 61 minutes);
    oracleRange.acceptOracle();
    vm.stopPrank();

    (,, Tick staticValue,,,) = oracleRange.oracle();
    assertEq(Tick.unwrap(staticValue), 200);
  }

  /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
  //////////////////////////////////////////////////////////////*/

  function test_constructor_initializesCorrectly() public view {
    assertEq(oracleRange.owner(), owner);
    assertEq(oracleRange.guardian(), guardian);

    // Check initial oracle values
    (bool isStatic,, Tick staticValue, uint16 maxDev,,) = oracleRange.oracle();
    assertTrue(isStatic);
    assertEq(Tick.unwrap(staticValue), 100);
    assertEq(maxDev, 100);
  }
}
