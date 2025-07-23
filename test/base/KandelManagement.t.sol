// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {KandelManagement, AbstractKandelSeeder, Tick, CoreKandel} from "../../src/base/KandelManagement.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MangroveTest} from "./MangroveTest.t.sol";

contract MockKandelManagement is KandelManagement {
  // int256 lastBidTick;
  // int256 lastAskTick;

  constructor(AbstractKandelSeeder seeder, address base, address quote, uint256 tickSpacing, address _manager)
    KandelManagement(seeder, base, quote, tickSpacing, _manager)
  {}

  function _checkTick(Tick tick, bool isBid) internal view override returns (bool) {
    // if (isBid) {
    //   lastBidTick = Tick.unwrap(tick);
    // } else {
    //   lastAskTick = Tick.unwrap(tick);
    // }
    return true;
  }
}

contract KandelManagementTest is MangroveTest {
  MockKandelManagement public management;
  address public manager;

  function setUp() public virtual override {
    super.setUp();
    manager = makeAddr("manager");
    management = new MockKandelManagement(seeder, address(WETH), address(USDC), 1, manager);
  }

  function test_checkTick() public {
    CoreKandel.Params memory params;
    params.pricePoints = 11;
    params.stepSize = 1;
    vm.deal(address(manager), 0.01 ether);
    vm.prank(manager);
    management.populateFromOffset{value: 0.01 ether}(0, 11, Tick.wrap(0), 1, 5, 100e6, 1 ether, params);
  }
}
