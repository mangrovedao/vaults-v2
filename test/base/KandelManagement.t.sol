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


}
