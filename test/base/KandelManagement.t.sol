// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
  KandelManagement, AbstractKandelSeeder, Tick, CoreKandel, OracleData
} from "../../src/base/KandelManagement.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MangroveTest} from "./MangroveTest.t.sol";

contract KandelManagementTest is MangroveTest {
  KandelManagement public management;
  address public manager;
  address public guardian;
  address public owner;

  function setUp() public virtual override {
    super.setUp();
    manager = makeAddr("manager");
    guardian = makeAddr("guardian");
    owner = makeAddr("owner");
    OracleData memory oracle;
    oracle.isStatic = true;
    oracle.maxDeviation = 100;
    management = new KandelManagement(seeder, address(WETH), address(USDC), 1, manager, oracle, owner, guardian);
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
    management.acceptOracle();
    vm.stopPrank();

    CoreKandel.Params memory params;
    params.pricePoints = 3;
    vm.deal(address(manager), 0.01 ether);
    vm.prank(manager);
    management.populateFromOffset{value: 0.01 ether}(0, 3, Tick.wrap(0), 1, 0, 0, 1 ether, params);
  }
}
