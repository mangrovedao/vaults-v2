// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {KandelManagement, AbstractKandelSeeder, Tick} from "../../src/base/KandelManagement.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MangroveTest} from "./MangroveTest.t.sol";

contract MockKandelManagement is KandelManagement {
  constructor(AbstractKandelSeeder seeder, address base, address quote, uint256 tickSpacing, address _manager)
    KandelManagement(seeder, base, quote, tickSpacing, _manager)
  {}

  function _checkTick(Tick tick, bool isBid) internal view override returns (bool) {
    return true;
  }
}

contract KandelManagementTest is MangroveTest {
  MockKandelManagement public management;  
  
  function setUp() public virtual override {
    super.setUp();
  }

  function test_checkTick() public {
    console.log("WETH", address(WETH));
  }
}
