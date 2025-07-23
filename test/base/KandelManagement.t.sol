// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
  KandelManagement,
  OracleRange,
  AbstractKandelSeeder,
  Tick,
  CoreKandel,
  OracleData
} from "../../src/base/KandelManagement.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {MangroveTest} from "./MangroveTest.t.sol";

contract KandelManagementTest is MangroveTest {
  KandelManagement public management;
  address public manager;
  address public guardian;
  address public owner;
  uint16 public constant MANAGEMENT_FEE = 500; // 5%

  function setUp() public virtual override {
    super.setUp();
    manager = makeAddr("manager");
    guardian = makeAddr("guardian");
    owner = makeAddr("owner");
    OracleData memory oracle;
    oracle.isStatic = true;
    oracle.maxDeviation = 100;
    oracle.timelockMinutes = 60; // 1 hour
    management =
      new KandelManagement(seeder, address(WETH), address(USDC), 1, manager, MANAGEMENT_FEE, oracle, owner, guardian);
  }

  function test_checkTick() public {
    CoreKandel.Params memory params;
    params.pricePoints = 11;
    params.stepSize = 1;
    vm.deal(address(manager), 0.01 ether);
    vm.prank(manager);
    management.populateFromOffset{value: 0.01 ether}(0, 11, Tick.wrap(0), 1, 5, 100e6, 1 ether, params);
  }

  function test_invalidDistribution() public {
    OracleData memory oracle;
    oracle.staticValue = Tick.wrap(100);
    oracle.maxDeviation = 50;
    oracle.isStatic = true;
    vm.startPrank(owner);
    management.proposeOracle(oracle);
    vm.warp(block.timestamp + 61 minutes);
    management.acceptOracle();
    vm.stopPrank();

    CoreKandel.Params memory params;
    params.pricePoints = 3;
    vm.deal(address(manager), 0.01 ether);
    vm.prank(manager);
    vm.expectRevert(KandelManagement.InvalidDistribution.selector);
    // create 3 asks from tick 0 to tick 3 (current tick is 100 with max deviation of 50)
    management.populateFromOffset{value: 0.01 ether}(0, 3, Tick.wrap(0), 1, 0, 0, 1 ether, params);
  }

  function test_validDistributionWithinDeviation() public {
    OracleData memory oracle;
    oracle.staticValue = Tick.wrap(100);
    oracle.maxDeviation = 100;
    oracle.isStatic = true;
    vm.startPrank(owner);
    management.proposeOracle(oracle);
    vm.warp(block.timestamp + 61 minutes);
    management.acceptOracle();
    vm.stopPrank();

    CoreKandel.Params memory params;
    params.pricePoints = 3;
    vm.deal(address(manager), 0.01 ether);
    vm.prank(manager);
    management.populateFromOffset{value: 0.01 ether}(0, 3, Tick.wrap(0), 1, 0, 0, 1 ether, params);
  }

  /*//////////////////////////////////////////////////////////////
                       ORACLE RANGE TESTS
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
    management.proposeOracle(newOracle);

    (,,, uint16 maxDev, uint40 proposedAt,) = management.proposedOracle();
    assertEq(maxDev, 150);
    assertEq(proposedAt, block.timestamp);
  }

  function test_proposeOracle_onlyOwner() public {
    OracleData memory newOracle;
    vm.prank(manager);
    vm.expectRevert();
    management.proposeOracle(newOracle);
  }

  function test_acceptOracle_afterTimelock() public {
    OracleData memory newOracle;
    newOracle.staticValue = Tick.wrap(300);
    newOracle.maxDeviation = 200;
    newOracle.isStatic = true;
    newOracle.timelockMinutes = 60; // 1 hour
    newOracle.proposedAt = uint40(block.timestamp);

    vm.startPrank(owner);
    management.proposeOracle(newOracle);

    // Fast forward past timelock
    vm.warp(block.timestamp + 61 minutes);

    vm.expectEmit(true, false, false, true);
    emit OracleRange.AcceptedOracle(keccak256(abi.encode(newOracle)));

    management.acceptOracle();
    vm.stopPrank();

    (,,, uint16 maxDev,,) = management.oracle();
    assertEq(maxDev, 200);
  }

    function test_acceptOracle_failsIfTimelocked() public {
    OracleData memory newOracle;
    newOracle.isStatic = true;
    newOracle.staticValue = Tick.wrap(200);
    newOracle.timelockMinutes = 60;
    
    vm.startPrank(owner);
    management.proposeOracle(newOracle);
    
    vm.expectRevert(OracleRange.OracleTimelocked.selector);
    management.acceptOracle();
    vm.stopPrank();
  }

  function test_acceptOracle_onlyOwner() public {
    vm.prank(manager);
    vm.expectRevert();
    management.acceptOracle();
  }

    function test_rejectOracle() public {
    OracleData memory newOracle;
    newOracle.isStatic = true;
    newOracle.staticValue = Tick.wrap(500);
    newOracle.proposedAt = uint40(block.timestamp);

    vm.prank(owner);
    management.proposeOracle(newOracle);

    vm.expectEmit(true, false, false, true);
    emit OracleRange.RejectedOracle(keccak256(abi.encode(newOracle)));
    
    vm.prank(guardian);
    management.rejectOracle();

    // Proposed oracle should be cleared
    (bool isStatic,,,,, uint8 timelockMinutes) = management.proposedOracle();
    assertEq(isStatic, false);
    assertEq(timelockMinutes, 0);
  }

  function test_rejectOracle_onlyGuardian() public {
    vm.prank(owner);
    vm.expectRevert(OracleRange.NotGuardian.selector);
    management.rejectOracle();
  }

  function test_proposeOracle_invalidStaticOracle() public {
    OracleData memory invalidOracle;
    invalidOracle.isStatic = true;
    invalidOracle.staticValue = Tick.wrap(type(int24).max); // Invalid tick value (out of range)
    invalidOracle.timelockMinutes = 60;

    vm.prank(owner);
    vm.expectRevert(OracleRange.InvalidOracle.selector);
    management.proposeOracle(invalidOracle);
  }

  function test_proposeOracle_invalidDynamicOracle() public {
    OracleData memory invalidOracle;
    // invalidOracle.isStatic = false; // false by default
    invalidOracle.oracle = IOracle(address(0)); // Zero address oracle (will fail)
    invalidOracle.timelockMinutes = 60;

    vm.prank(owner);
    vm.expectRevert(OracleRange.InvalidOracle.selector);
    management.proposeOracle(invalidOracle);
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
    management.proposeOracle(validOracle);

    (,,, uint16 maxDev, uint40 proposedAt,) = management.proposedOracle();
    assertEq(proposedAt, block.timestamp);
  }

  /*//////////////////////////////////////////////////////////////
                    KANDEL MANAGEMENT TESTS
  //////////////////////////////////////////////////////////////*/

  function test_setManager() public {
    address newManager = makeAddr("newManager");

    vm.expectEmit(true, false, false, true);
    emit KandelManagement.SetManager(newManager);

    vm.prank(owner);
    management.setManager(newManager);

    assertEq(management.manager(), newManager);
  }

  function test_setManager_onlyOwner() public {
    vm.prank(manager);
    vm.expectRevert();
    management.setManager(makeAddr("newManager"));
  }

  function test_setFeeRecipient() public {
    address newFeeRecipient = makeAddr("newFeeRecipient");

    vm.expectEmit(true, false, false, true);
    emit KandelManagement.SetFeeRecipient(newFeeRecipient);

    vm.prank(owner);
    management.setFeeRecipient(newFeeRecipient);

    (, address feeRecipient,,) = management.state();
    assertEq(feeRecipient, newFeeRecipient);
  }

  function test_setFeeRecipient_onlyOwner() public {
    vm.prank(manager);
    vm.expectRevert();
    management.setFeeRecipient(makeAddr("newFeeRecipient"));
  }

  function test_initialState() public view {
    (bool inKandel, address feeRecipient, uint16 managementFee, uint40 lastTimestamp) = management.state();

    assertEq(inKandel, false);
    assertEq(feeRecipient, owner);
    assertEq(managementFee, MANAGEMENT_FEE);
    assertGt(lastTimestamp, 0);
  }

  function test_populateFromOffset_setsInKandel() public {
    CoreKandel.Params memory params;
    params.pricePoints = 5;
    params.stepSize = 1;

    vm.deal(address(manager), 0.01 ether);
    vm.prank(manager);
    management.populateFromOffset{value: 0.01 ether}(0, 5, Tick.wrap(0), 1, 2, 100e6, 1 ether, params);

    (bool inKandel,,,) = management.state();
    assertTrue(inKandel);
  }

  function test_populateFromOffset_onlyManager() public {
    CoreKandel.Params memory params;

    vm.prank(owner);
    vm.expectRevert(KandelManagement.NotManager.selector);
    management.populateFromOffset(0, 5, Tick.wrap(0), 1, 2, 100e6, 1 ether, params);
  }

  function test_populateChunkFromOffset() public {
    // First populate to set up the Kandel
    CoreKandel.Params memory params;
    params.pricePoints = 10;
    params.stepSize = 1;

    vm.deal(address(manager), 0.01 ether);
    vm.startPrank(manager);
    management.populateFromOffset{value: 0.01 ether}(0, 10, Tick.wrap(0), 1, 5, 100e6, 1 ether, params);

    // Now test chunk populate
    management.populateChunkFromOffset(0, 5, Tick.wrap(10), 2, 200e6, 2 ether);
    vm.stopPrank();
  }

  function test_populateChunkFromOffset_onlyManager() public {
    vm.prank(owner);
    vm.expectRevert(KandelManagement.NotManager.selector);
    management.populateChunkFromOffset(0, 5, Tick.wrap(0), 2, 100e6, 1 ether);
  }

  function test_populateChunkFromOffset_invalidDistribution() public {
    // Set restrictive oracle
    OracleData memory restrictiveOracle;
    restrictiveOracle.staticValue = Tick.wrap(100);
    restrictiveOracle.maxDeviation = 10;
    restrictiveOracle.isStatic = true;
    restrictiveOracle.timelockMinutes = 60;

    vm.startPrank(owner);
    management.proposeOracle(restrictiveOracle);
    vm.warp(block.timestamp + 61 minutes);
    management.acceptOracle();
    vm.stopPrank();

    vm.prank(manager);
    vm.expectRevert(KandelManagement.InvalidDistribution.selector);
    management.populateChunkFromOffset(0, 3, Tick.wrap(0), 0, 0, 1 ether);
  }

  /*//////////////////////////////////////////////////////////////
                         EDGE CASE TESTS
  //////////////////////////////////////////////////////////////*/

  function test_constructor_initializesCorrectly() public view {
    assertEq(management.manager(), manager);
    assertEq(management.guardian(), guardian);
    assertEq(management.owner(), owner);

    // Check KANDEL was deployed
    assertTrue(address(management.KANDEL()) != address(0));
  }

  function test_oracleTimelock_edgeCase() public {
    OracleData memory newOracle;
    newOracle.isStatic = true;
    newOracle.staticValue = Tick.wrap(100);
    newOracle.timelockMinutes = 60;

    vm.startPrank(owner);
    management.proposeOracle(newOracle);

    // Exactly at timelock boundary
    vm.warp(block.timestamp + 60 minutes);
    management.acceptOracle(); // should succeed

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
    management.proposeOracle(oracle1);
    
    // Propose second oracle (should overwrite first)
    management.proposeOracle(oracle2);
    
    vm.warp(block.timestamp + 61 minutes);
    management.acceptOracle();
    vm.stopPrank();
    
    (,, Tick staticValue,,,) = management.oracle();
    assertEq(Tick.unwrap(staticValue), 200);
  }
}
